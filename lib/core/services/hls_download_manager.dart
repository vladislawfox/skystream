import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../logger/app_logger.dart';
import 'hls_download_plan.dart';

/// Owns a persisted parent task and native downloads for its HLS resources.
/// The root playlist is an atomic completion marker: it never exists until
/// every segment, initialization map and encryption key is stored locally.
class HlsDownloadManager {
  static const parentGroup = 'hls-packages';
  static const assetGroup = 'hls-assets';
  final FileDownloader downloader;
  final void Function(TaskUpdate) onUpdate;
  final _jobs = <String, _HlsJob>{};
  Future<void> _pending = Future.value();

  HlsDownloadManager({required this.downloader, required this.onUpdate});

  bool canResume(String id) => _jobs.containsKey(id);

  static String packagePath(String playlistPath) {
    // Local HLS demuxers disagree on decoding %20. ASCII names keep every URI
    // portable while the episode's visible filename can contain spaces/Unicode.
    final digest = sha256
        .convert(utf8.encode(p.basename(playlistPath)))
        .toString()
        .substring(0, 16);
    return p.join(p.dirname(playlistPath), 'hls-$digest.hls');
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        talker.error('HLS download operation failed', error, stack);
      },
    );
    return next;
  }

  Future<void> start(DownloadTask parent, HlsDownloadPlan plan) => _serial(
    () async {
      final root = File(await parent.filePath());
      // A new rendition owns the output path exclusively. Retire even a
      // persisted parent whose job.json was lost, so a stale Retry/Delete
      // cannot reuse or remove the replacement's media.
      final owners = <String, Task>{
        for (final record in await downloader.database.allRecords(
          group: parentGroup,
        ))
          record.taskId: record.task,
        for (final old in _jobs.values) old.parent.taskId: old.parent,
      };
      for (final old in owners.values) {
        if (old.taskId == parent.taskId || await old.filePath() != root.path) {
          continue;
        }
        _jobs.remove(old.taskId)?.status = TaskStatus.canceled;
        await _stopChildrenById(old.taskId);
        await downloader.database.deleteRecordWithId(old.taskId);
        onUpdate(TaskStatusUpdate(old, TaskStatus.canceled));
      }
      final job = _HlsJob(parent, plan, TaskStatus.running, 0);
      _jobs[parent.taskId] = job;
      if (await root.exists()) await root.delete();
      final directory = Directory(packagePath(root.path));
      // A previous incomplete attempt at this episode must not satisfy a new
      // rendition's assets merely because both use asset0.ts as a local name.
      if (await directory.exists()) await directory.delete(recursive: true);
      await directory.create(recursive: true);
      await _save(job);
      await _publish(job);
      try {
        await _enqueueMissing(job, const {});
      } catch (error) {
        await _fail(job, error);
        rethrow;
      }
    },
  );

  Future<void> restore(List<TaskRecord> records) => _serial(() async {
    for (final record in records.where(
      (record) => record.group == parentGroup,
    )) {
      if (record.status == TaskStatus.complete ||
          record.status == TaskStatus.canceled) {
        continue;
      }
      final parent = record.task as DownloadTask;
      try {
        final file = File(
          p.join(packagePath(await parent.filePath()), 'job.json'),
        );
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final job = _HlsJob(
          parent,
          HlsDownloadPlan.fromJson(
            Map<String, dynamic>.from(json['plan'] as Map),
          ),
          // A terminal DB failure can be newer if writing job.json failed.
          record.status == TaskStatus.failed
              ? TaskStatus.failed
              : TaskStatus.values[json['status'] as int],
          json['generation'] as int,
        );
        _jobs[parent.taskId] = job;
        if (job.status == TaskStatus.running ||
            job.status == TaskStatus.complete) {
          // A crash can occur after publishing the playlist but before the
          // parent database record is updated. Recheck all package files.
          job.status = TaskStatus.running;
        }
        job.progress = record.progress;
        job.size = record.expectedFileSize;
        job.exception = json['exception'] is Map
            ? TaskException.fromJson(
                Map<String, dynamic>.from(json['exception'] as Map),
              )
            : record.exception;
        if (record.status == TaskStatus.failed && record.exception != null) {
          job.exception = record.exception;
        }
        await _publish(job);
      } catch (error, stack) {
        talker.error('Could not restore HLS download', error, stack);
        final job = _jobs[parent.taskId];
        if (job != null) {
          await _fail(job, error);
          continue;
        }
        await _stopChildrenById(parent.taskId);
        await downloader.database.updateRecord(
          TaskRecord(
            parent,
            TaskStatus.failed,
            record.progress,
            -1,
            _exception(error),
          ),
        );
        onUpdate(
          TaskStatusUpdate(parent, TaskStatus.failed, _exception(error)),
        );
      }
    }
  });

  /// Run only after FileDownloader has replayed statuses persisted while the
  /// app was suspended, so old terminal callbacks cannot hit a fresh retry.
  Future<void> reconcile() => _serial(() async {
    final native = (await downloader.allTasks(allGroups: true))
        .map((task) => task.taskId)
        .toSet();
    for (final job in _jobs.values.toList()) {
      if (job.status == TaskStatus.paused || job.status == TaskStatus.failed) {
        await _stopChildren(job);
        continue;
      }
      if (job.status != TaskStatus.running) continue;
      try {
        await _enqueueMissing(job, native);
      } catch (error, stack) {
        talker.error(
          'Could not resume HLS download after restart',
          error,
          stack,
        );
        await _fail(job, error);
      }
    }
  });

  Future<void> handle(TaskUpdate update) => _serial(() async {
    try {
      await _handle(update);
    } catch (error, stack) {
      talker.error('Could not finalize HLS download', error, stack);
      final job = _jobs[update.task.metaData];
      if (job != null) await _fail(job, error);
    }
  });

  Future<void> _handle(TaskUpdate update) async {
    final job = _jobs[update.task.metaData];
    if (job == null ||
        job.status != TaskStatus.running ||
        !update.task.taskId.startsWith(
          '${job.parent.taskId}:${job.generation}:',
        )) {
      return;
    }
    if (update is TaskStatusUpdate) {
      if (update.status == TaskStatus.failed ||
          update.status == TaskStatus.notFound ||
          update.status == TaskStatus.canceled) {
        await _fail(
          job,
          update.exception ??
              (update.status == TaskStatus.notFound ||
                      update.responseStatusCode != null
                  ? TaskHttpException(
                      'Media request failed',
                      update.responseStatusCode ?? 404,
                    )
                  : TaskException('Media download ${update.status.name}')),
        );
      } else if (update.status == TaskStatus.complete) {
        final index = int.tryParse(update.task.taskId.split(':').last);
        if (index == null ||
            index >= job.plan.assets.length ||
            !await _validAsset(job, job.plan.assets[index])) {
          await _fail(job, TaskFileSystemException('Incomplete media segment'));
          return;
        }
        await _checkCompletion(job);
      }
    }
  }

  Future<bool> pause(String id) async {
    final job = _jobs[id];
    if (job == null) return false;
    if (job.status != TaskStatus.running) return true;
    job.status = TaskStatus.paused;
    await _serial(() async {
      if (!identical(_jobs[id], job)) return;
      await _save(job);
      await _stopChildren(job);
      await _publish(job);
    });
    return true;
  }

  Future<bool> resume(String id) => _serial(() async {
    final job = _jobs[id];
    if (job == null) return false;
    if (job.status == TaskStatus.complete || job.status == TaskStatus.running) {
      return true;
    }
    job.generation++;
    job.status = TaskStatus.running;
    job.exception = null;
    try {
      await _save(job);
      await _publish(job);
      await _enqueueMissing(job, const {});
    } catch (error) {
      await _fail(job, error);
      rethrow;
    }
    return true;
  });

  Future<bool> cancel(String id) async {
    final job = _jobs[id];
    if (job == null) return false;
    job.status =
        TaskStatus.canceled; // Invalidate in-flight callbacks immediately.
    await _serial(() async {
      if (!identical(_jobs[id], job)) return;
      await _stopChildren(job);
      _jobs.remove(id);
      final root = File(await job.filePath());
      if (await root.exists()) await root.delete();
      final directory = Directory(packagePath(root.path));
      if (await directory.exists()) await directory.delete(recursive: true);
      await downloader.database.deleteRecordWithId(id);
      onUpdate(TaskStatusUpdate(job.parent, TaskStatus.canceled));
    });
    return true;
  }

  static TaskException _exception(Object error) {
    final exception = switch (error) {
      TaskException() => error,
      FileSystemException() => TaskFileSystemException(error.message),
      _ => TaskException(error.toString()),
    };
    // CDN paths can contain signatures even without named query parameters.
    final description = redactSecrets(
      exception.description.replaceAll(
        RegExp(r'https?://[^\s<>"\x27]+'),
        '[URL]',
      ),
    );
    return TaskException.fromJson({
      ...exception.toJson(),
      'description': description,
    });
  }

  Future<void> _fail(_HlsJob job, Object error) async {
    job.status = TaskStatus.failed;
    job.exception = _exception(error);
    try {
      await _save(job);
    } on FileSystemException catch (error, stack) {
      talker.error('Could not persist failed HLS job', error, stack);
    }
    await _stopChildren(job);
    talker.warning('HLS download failed: ${job.exception}');
    await _publish(job);
  }

  Future<void> _stopChildren(_HlsJob job) =>
      _stopChildrenById(job.parent.taskId);

  Future<void> _stopChildrenById(String parentId) async {
    final tasks = await downloader.allTasks(allGroups: true);
    final ids = tasks
        .where((task) => task.group == assetGroup && task.metaData == parentId)
        .map((task) => task.taskId)
        .toList();
    if (ids.isNotEmpty) await downloader.cancelTasksWithIds(ids);
    final records = await downloader.database.allRecords(group: assetGroup);
    await downloader.database.deleteRecordsWithIds(
      records
          .where((record) => record.task.metaData == parentId)
          .map((record) => record.taskId),
    );
  }

  Future<void> _enqueueMissing(_HlsJob job, Set<String> native) async {
    final directory = p.join(
      job.parent.directory,
      p.basename(packagePath(job.parent.filename)),
    );
    for (var index = 0; index < job.plan.assets.length; index++) {
      if (job.status != TaskStatus.running) return;
      final asset = job.plan.assets[index];
      if (await _validAsset(job, asset)) continue;
      final task = DownloadTask(
        taskId: '${job.parent.taskId}:${job.generation}:$index',
        url: asset.url,
        filename: asset.filename,
        directory: directory,
        baseDirectory: job.parent.baseDirectory,
        headers: asset.headers,
        group: assetGroup,
        metaData: job.parent.taskId,
        updates: Updates.statusAndProgress,
        retries: 3,
      );
      // Queue sequentially; native holdingQueue bounds concurrent transfers
      // and retains all pending segments while the Dart isolate is suspended.
      if (!native.contains(task.taskId) && !await downloader.enqueue(task)) {
        throw const FileSystemException('Could not queue HLS media download.');
      }
    }
    await _checkCompletion(job);
  }

  Future<bool> _validAsset(_HlsJob job, HlsDownloadAsset asset) async {
    job.assetLengths.remove(asset.filename);
    final file = File(
      p.join(packagePath(await job.filePath()), asset.filename),
    );
    if (!await file.exists()) return false;
    final length = await file.length();
    final valid =
        length > 0 && (asset.length == null || asset.length == length);
    if (valid) job.assetLengths[asset.filename] = length;
    return valid;
  }

  Future<void> _checkCompletion(_HlsJob job) async {
    if (job.status != TaskStatus.running) return;
    // Each asset is verified once when its native task completes (or during
    // restart reconciliation). Avoid rescanning the entire episode on every
    // segment: long VOD playlists otherwise cause quadratic filesystem I/O.
    final count = job.assetLengths.length;
    final bytes = job.assetLengths.values.fold<int>(
      0,
      (total, length) => total + length,
    );
    final root = File(await job.filePath());
    final directory = packagePath(root.path);
    job.progress = count / job.plan.assets.length;
    if (count == job.plan.assets.length) {
      for (final entry in job.plan.playlists.entries) {
        if (entry.key != 'index.m3u8') {
          await File(p.join(directory, entry.key))
              .writeAsString(entry.value, flush: true);
        }
      }
      final prefix = p.basename(directory);
      final playlist = job.plan.playlists['index.m3u8']!
          .split('\n')
          .map((line) {
            if (line.isNotEmpty && !line.startsWith('#')) {
              return '$prefix/$line';
            }
            return line.replaceAllMapped(
              RegExp(r'URI="([^"]*)"'),
              (match) => 'URI="$prefix/${match[1]}"',
            );
          })
          .join('\n');
      final temporary = File('${root.path}.pending');
      await temporary.writeAsString(playlist, flush: true);
      // pause/cancel can invalidate the job while filesystem writes yield.
      if (job.status != TaskStatus.running) {
        await temporary.delete();
        return;
      }
      await temporary.rename(root.path);
      if (job.status != TaskStatus.running) {
        await root.delete();
        return;
      }
      job.status = TaskStatus.complete;
      job.size = bytes;
      await _save(job);
      await _stopChildren(job);
    }
    await _publish(job);
  }

  Future<void> _save(_HlsJob job) async {
    final path = p.join(packagePath(await job.filePath()), 'job.json');
    final temp = File('$path.pending');
    await temp.writeAsString(
      jsonEncode({
        'plan': job.plan.toJson(),
        'status': job.status.index,
        'generation': job.generation,
        'exception': job.exception?.toJson(),
      }),
      flush: true,
    );
    await temp.rename(path);
  }

  Future<void> _publish(_HlsJob job) async {
    await downloader.database.updateRecord(
      TaskRecord(job.parent, job.status, job.progress, job.size, job.exception),
    );
    onUpdate(TaskProgressUpdate(job.parent, job.progress, job.size));
    onUpdate(TaskStatusUpdate(job.parent, job.status, job.exception));
  }
}

class _HlsJob {
  final DownloadTask parent;
  final HlsDownloadPlan plan;
  TaskStatus status;
  int generation;
  double progress = 0;
  int size = -1;
  TaskException? exception;
  final assetLengths = <String, int>{};
  Future<String>? _filePath;
  Future<String> filePath() => _filePath ??= parent.filePath();
  _HlsJob(this.parent, this.plan, this.status, this.generation);
}
