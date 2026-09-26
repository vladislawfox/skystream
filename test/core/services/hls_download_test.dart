import 'dart:io';
import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/dio_client_provider.dart';
import 'package:skystream/core/network/http_response_metadata.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/core/services/hls_download_plan.dart';
import 'package:skystream/core/services/hls_download_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final downloader = FileDownloader(
    persistentStorage: _InMemoryDownloadStorage(),
  );
  const channel = MethodChannel('com.bbflight.background_downloader');
  late Directory directory;
  late HttpServer origin;
  late Dio dio;
  late HlsDownloadManager manager;
  late List<TaskUpdate> updates;
  late Map<String, DownloadTask> queued;
  late List<String> requests;
  late Map<String, String> playlists;
  late Map<String, List<int>> bodies;
  late bool rejectQueue;
  late int rejectAfter;
  const auth = {'Referer': 'https://tortuga.test/', 'Cookie': 'access=episode'};
  String url(String path) => 'http://127.0.0.1:${origin.port}$path';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hls-test');
    dio = Dio();
    queued = {};
    updates = [];
    requests = [];
    rejectQueue = false;
    rejectAfter = 10000;
    playlists = {
      '/episode/1080.m3u8':
          '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nfirst.ts\n#EXTINF:6,\nsecond.ts\n#EXT-X-ENDLIST\n',
    };
    bodies = {
      '/episode/first.ts': [1, 2, 3],
      '/episode/second.ts': [4, 5, 6, 7],
    };
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      if (request.headers.value('referer') != auth['Referer'] ||
          request.headers.value('cookie') != auth['Cookie']) {
        request.response.statusCode = 403;
      } else if (request.uri.path == '/redirect.m3u8') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/episode/1080.m3u8');
      } else if (playlists.containsKey(request.uri.path)) {
        final body = playlists[request.uri.path]!;
        request.response.headers.contentType = request.uri.path == '/opaque'
            ? ContentType.text
            : ContentType('application', 'vnd.apple.mpegurl');
        request.response.contentLength = utf8.encode(body).length;
        if (request.method != 'HEAD') request.response.write(body);
      } else if (bodies.containsKey(request.uri.path)) {
        var body = bodies[request.uri.path]!;
        final range = request.headers.value('range');
        if (range != null) {
          final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
          final start = int.parse(match[1]!);
          final end = int.parse(match[2]!);
          request.response.statusCode = 206;
          request.response.headers.set(
            'content-range',
            'bytes $start-$end/${body.length}',
          );
          body = body.sublist(start, end + 1);
        }
        request.response.add(body);
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'enqueue':
              final task =
                  Task.createFromJsonString(
                        (call.arguments as List).first as String,
                      )
                      as DownloadTask;
              if (rejectQueue || queued.length >= rejectAfter) return false;
              queued[task.taskId] = task;
              return true;
            case 'allTasks':
              return queued.values
                  .map((task) => jsonEncode(task.toJson()))
                  .toList();
            case 'cancelTasksWithIds':
              for (final id in call.arguments as List) {
                queued.remove(id);
              }
              return true;
            default:
              return null;
          }
        });
    await downloader.database.deleteAllRecords();
    manager = HlsDownloadManager(downloader: downloader, onUpdate: updates.add);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    dio.close(force: true);
    await origin.close(force: true);
    await directory.delete(recursive: true);
  });

  DownloadTask parent() => DownloadTask(
    taskId: 'episode',
    url: url('/episode/1080.m3u8'),
    filename: 'S1-E2.m3u8',
    directory: directory.path,
    baseDirectory: BaseDirectory.root,
    group: HlsDownloadManager.parentGroup,
    metaData: 'https://series.test/arrow#s1e2',
  );
  Future<HlsDownloadPlan> plan([String path = '/episode/1080.m3u8']) =>
      HlsDownloadPlan.load(dio, url(path), headers: auth);
  Future<void> deliver(DownloadTask task) async {
    await dio.download(
      task.url,
      await task.filePath(),
      options: Options(headers: task.headers),
    );
    queued.remove(task.taskId);
    await manager.handle(TaskStatusUpdate(task, TaskStatus.complete));
  }

  test(
    'selected episode rendition is an offline package only after all media arrives',
    () async {
      final task = parent();
      await manager.start(task, await plan('/redirect.m3u8'));
      expect(File(await task.filePath()).existsSync(), isFalse);
      final children = queued.values.toList();
      expect(children.map((task) => task.url), [
        url('/episode/first.ts'),
        url('/episode/second.ts'),
      ]);
      await deliver(children.first);
      expect(File(await task.filePath()).existsSync(), isFalse);
      await deliver(children.last);
      expect(
        (await downloader.database.recordForId(task.taskId))!.status,
        TaskStatus.complete,
      );
      expect(
        (await downloader.database.recordForId(task.taskId))!.expectedFileSize,
        7,
      );
      final root = await File(await task.filePath()).readAsString();
      expect(root, contains('hls-21fa6ec133797cc2.hls/asset0.ts'));
      expect(root, isNot(contains('http')));
      expect(
        await File(
          p.join(directory.path, 'hls-21fa6ec133797cc2.hls/asset1.ts'),
        ).readAsBytes(),
        [4, 5, 6, 7],
      );
      expect(
        requests,
        containsAll(['GET /episode/first.ts', 'GET /episode/second.ts']),
      );
    },
  );

  test(
    'Auto preserves the best variant, external audio, keys and byte ranges',
    () async {
      playlists['/master.m3u8'] =
          '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="dub",NAME="ICTV",DEFAULT=YES,URI="audio.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=640x480,AUDIO="dub"\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=500,RESOLUTION=1920x1080,AUDIO="dub"\nhigh.m3u8\n';
      playlists['/audio.m3u8'] =
          '#EXTM3U\n#EXTINF:6,\nsound.aac\n#EXT-X-ENDLIST\n';
      playlists['/high.m3u8'] =
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXT-X-MAP:URI="media.mp4",BYTERANGE="2@0"\n#EXTINF:6,\n#EXT-X-BYTERANGE:3@2\nmedia.mp4\n#EXTINF:6,\n#EXT-X-BYTERANGE:3\nmedia.mp4\n#EXT-X-ENDLIST\n';
      bodies.addAll({
        '/sound.aac': [9],
        '/key': List.filled(16, 8),
        '/media.mp4': [0, 1, 2, 3, 4, 5, 6, 7],
      });
      final parsed = await plan('/master.m3u8');
      expect(requests, isNot(contains('GET /low.m3u8')));
      expect(parsed.playlists['index.m3u8'], contains('RESOLUTION=1920x1080'));
      expect(parsed.playlists['index.m3u8'], contains('TYPE=AUDIO'));
      expect(
        parsed.assets
            .where((asset) => asset.headers.containsKey('Range'))
            .map((asset) => asset.headers['Range']),
        ['bytes=0-1', 'bytes=2-4', 'bytes=5-7'],
      );
      await manager.start(parent(), parsed);
      for (final task in queued.values.toList()) {
        await deliver(task);
      }
      expect(
        (await downloader.database.recordForId('episode'))!.status,
        TaskStatus.complete,
      );
      expect(
        await File(
          p.join(directory.path, 'hls-21fa6ec133797cc2.hls/asset4.mp4'),
        ).readAsBytes(),
        [5, 6, 7],
      );
    },
  );

  test(
    'pause, restart and resume keep completed media and ignore stale callbacks',
    () async {
      final task = parent();
      await manager.start(task, await plan());
      final firstGeneration = queued.values.toList();
      await deliver(firstGeneration.first);
      await manager.pause(task.taskId);
      expect(
        (await downloader.database.recordForId(task.taskId))!.status,
        TaskStatus.paused,
      );
      manager = HlsDownloadManager(
        downloader: downloader,
        onUpdate: updates.add,
      );
      await manager.restore(await downloader.database.allRecords());
      expect(queued, isEmpty);
      await manager.resume(task.taskId);
      expect(queued, hasLength(1));
      await manager.handle(
        TaskStatusUpdate(firstGeneration.last, TaskStatus.failed),
      );
      expect(
        (await downloader.database.recordForId(task.taskId))!.status,
        TaskStatus.running,
      );
      await deliver(queued.values.single);
      expect(
        (await downloader.database.recordForId(task.taskId))!.status,
        TaskStatus.complete,
      );
      expect(
        requests.where((value) => value == 'GET /episode/first.ts'),
        hasLength(1),
      );
    },
  );

  test(
    'cancel removes a package and late completion cannot recreate its root',
    () async {
      final task = parent();
      await manager.start(task, await plan());
      final stale = queued.values.last;
      await manager.cancel(task.taskId);
      await manager.handle(TaskStatusUpdate(stale, TaskStatus.complete));
      expect(File(await task.filePath()).existsSync(), isFalse);
      expect(
        Directory(
          p.join(directory.path, 'hls-21fa6ec133797cc2.hls'),
        ).existsSync(),
        isFalse,
      );
      expect(await downloader.database.recordForId(task.taskId), isNull);
    },
  );

  test('live and DRM sources fail before media is enqueued', () async {
    playlists['/live.m3u8'] = '#EXTM3U\n#EXTINF:6,\nfirst.ts\n';
    playlists['/drm.m3u8'] =
        '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key"\n#EXTINF:6,\nfirst.ts\n#EXT-X-ENDLIST\n';
    await expectLater(plan('/live.m3u8'), throwsA(isA<FormatException>()));
    await expectLater(plan('/drm.m3u8'), throwsA(isA<FormatException>()));
    expect(queued, isEmpty);
  });

  test(
    'rejected native enqueue is failed, never a completed playlist',
    () async {
      rejectQueue = true;
      await expectLater(
        manager.start(parent(), await plan()),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        (await downloader.database.recordForId('episode'))!.status,
        TaskStatus.failed,
      );
      expect(File(await parent().filePath()).existsSync(), isFalse);
    },
  );

  test(
    'a truncated ranged response fails the package instead of waiting forever',
    () async {
      playlists['/range.m3u8'] =
          '#EXTM3U\n#EXTINF:6,\n#EXT-X-BYTERANGE:8@0\nmedia.mp4\n#EXT-X-ENDLIST\n';
      await manager.start(parent(), await plan('/range.m3u8'));
      final task = queued.values.single;
      await File(await task.filePath()).writeAsBytes([1, 2]);
      await manager.handle(TaskStatusUpdate(task, TaskStatus.complete));
      expect(
        (await downloader.database.recordForId('episode'))!.status,
        TaskStatus.failed,
      );
      expect(File(await parent().filePath()).existsSync(), isFalse);
    },
  );

  test(
    'resume enqueue failure stops partially queued assets and marks parent failed',
    () async {
      await manager.start(parent(), await plan());
      await manager.pause('episode');
      rejectAfter = 1;
      await expectLater(
        manager.resume('episode'),
        throwsA(isA<FileSystemException>()),
      );
      expect(queued, isEmpty);
      expect(
        (await downloader.database.recordForId('episode'))!.status,
        TaskStatus.failed,
      );
    },
  );

  test('restart enqueue failure ignores stale child completion', () async {
    await manager.start(parent(), await plan());
    queued.clear(); // Native tasks lost when the app was killed.
    rejectAfter = 1;
    manager = HlsDownloadManager(downloader: downloader, onUpdate: updates.add);
    await manager.restore(await downloader.database.allRecords());
    await manager.reconcile();
    expect(queued, isEmpty);
    expect(
      (await downloader.database.recordForId('episode'))!.status,
      TaskStatus.failed,
    );
  });

  test(
    'restore waits for native backlog before restarting missing assets',
    () async {
      await manager.start(parent(), await plan());
      final old = queued.values.first;
      queued.clear();
      manager = HlsDownloadManager(
        downloader: downloader,
        onUpdate: updates.add,
      );
      await manager.restore(await downloader.database.allRecords());
      expect(
        queued,
        isEmpty,
        reason: 'native failed/canceled statuses must be replayed before retry',
      );
      await manager.handle(TaskStatusUpdate(old, TaskStatus.failed));
      expect(
        (await downloader.database.recordForId('episode'))!.status,
        TaskStatus.failed,
      );
    },
  );

  test('initialization map byte range may precede its URI attribute', () async {
    playlists['/map.m3u8'] =
        '#EXTM3U\n#EXT-X-MAP:BYTERANGE="2@0",URI="media.mp4"\n#EXTINF:6,\nsegment.m4s\n#EXT-X-ENDLIST\n';
    final parsed = await plan('/map.m3u8');
    expect(
      parsed.playlists['index.m3u8'],
      contains('#EXT-X-MAP:URI="asset0.mp4"'),
    );
  });

  test(
    'native Apple transport final URI resolves relative episode assets',
    () async {
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            // URLSession supplies the final URI separately, without redirect history.
            if (response.requestOptions.path.endsWith('/episode/1080.m3u8')) {
              response.extra[nativeResponseUriKey] = Uri.parse(
                url('/native/final.m3u8'),
              );
            }
            handler.next(response);
          },
        ),
      );
      final parsed = await plan();
      expect(parsed.assets.first.url, url('/native/first.ts'));
    },
  );

  test('a non-key HTTP response cannot complete encrypted HLS', () async {
    playlists['/key.m3u8'] =
        '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="bad-key"\n#EXTINF:6,\nepisode/first.ts\n#EXT-X-ENDLIST\n';
    bodies['/bad-key'] = [1, 2, 3];
    await manager.start(parent(), await plan('/key.m3u8'));
    final tasks = queued.values.toList();
    for (final task in tasks) {
      await deliver(task);
    }
    expect(
      (await downloader.database.recordForId('episode'))!.status,
      TaskStatus.failed,
    );
    expect(File(await parent().filePath()).existsSync(), isFalse);
  });

  test(
    'asset requests preserve inherited and overridden browser headers',
    () async {
      dio.options.headers['User-Agent'] = 'manifest-browser';
      final inherited = await plan();
      expect(inherited.assets.first.headers['User-Agent'], 'manifest-browser');
      final overridden = await HlsDownloadPlan.load(
        dio,
        url('/episode/1080.m3u8'),
        headers: {...auth, 'user-agent': 'provider-browser'},
      );
      final agents = overridden.assets.first.headers.entries.where(
        (entry) => entry.key.toLowerCase() == 'user-agent',
      );
      expect(agents.map((entry) => entry.value), ['provider-browser']);
    },
  );

  test(
    'restore finishes a persisted pause whose native cancellation was interrupted',
    () async {
      await manager.start(parent(), await plan());
      final jobFile = File(
        p.join(directory.path, 'hls-21fa6ec133797cc2.hls/job.json'),
      );
      final json =
          jsonDecode(await jobFile.readAsString()) as Map<String, dynamic>;
      json['status'] = TaskStatus.paused.index;
      await jobFile.writeAsString(jsonEncode(json));
      manager = HlsDownloadManager(
        downloader: downloader,
        onUpdate: updates.add,
      );
      await manager.restore(await downloader.database.allRecords());
      await manager.reconcile();
      expect(queued, isEmpty);
      expect(
        (await downloader.database.recordForId('episode'))!.status,
        TaskStatus.paused,
      );
    },
  );

  test(
    'episode filenames with spaces produce portable local playlist references',
    () async {
      final task = parent().copyWith(filename: 'S1-E13 13.m3u8');
      await manager.start(task, await plan());
      for (final child in queued.values.toList()) {
        await deliver(child);
      }
      final playlist = await File(await task.filePath()).readAsString();
      final resources = playlist
          .split('\n')
          .where((line) => line.isNotEmpty && !line.startsWith('#'));
      for (final resource in resources) {
        expect(
          resource,
          matches(RegExp(r'^hls-[a-f0-9]{16}\.hls/asset[0-9]+\.ts$')),
        );
        expect(File(p.join(directory.path, resource)).existsSync(), isTrue);
      }
    },
  );

  test('a playlist publication failure marks the package failed', () async {
    await manager.start(parent(), await plan());
    final tasks = queued.values.toList();
    await deliver(tasks.first);
    await Directory('${await parent().filePath()}.pending').create();
    await expectLater(deliver(tasks.last), completes);
    expect(
      (await downloader.database.recordForId('episode'))!.status,
      TaskStatus.failed,
    );
    expect(File(await parent().filePath()).existsSync(), isFalse);
  });

  for (final invalidateBy in ['removing', 'truncating']) {
    test(
      'resume revalidates cached media after $invalidateBy a completed file',
      () async {
        // A byte range gives truncation a known expected length.
        playlists['/episode/1080.m3u8'] =
            '#EXTM3U\n#EXTINF:6,\n#EXT-X-BYTERANGE:3@0\nfirst.ts\n#EXTINF:6,\nsecond.ts\n#EXT-X-ENDLIST\n';
        final task = parent();
        await manager.start(task, await plan());
        final firstGeneration = queued.values.toList();
        await deliver(firstGeneration.first);
        await manager.pause(task.taskId);
        final completedFile = File(await firstGeneration.first.filePath());
        if (invalidateBy == 'removing') {
          await completedFile.delete();
        } else {
          await completedFile.writeAsBytes([1]);
        }
        await manager.resume(task.taskId);
        final replacements = queued.values.toList();
        expect(replacements, hasLength(2));
        await deliver(replacements.last);
        expect(
          (await downloader.database.recordForId(task.taskId))!.status,
          TaskStatus.running,
        );
        expect(File(await task.filePath()).existsSync(), isFalse);
        expect(queued.values.single.url, url('/episode/first.ts'));
        await deliver(replacements.first);
        expect(
          (await downloader.database.recordForId(task.taskId))!.status,
          TaskStatus.complete,
        );
        expect(await completedFile.readAsBytes(), [1, 2, 3]);
      },
    );
  }

  test('extensionless mislabeled HLS is detected by a bounded GET', () async {
    playlists['/opaque'] = playlists['/episode/1080.m3u8']!;
    final container = ProviderContainer(
      overrides: [dioClientProvider.overrideWithValue(dio)],
    );
    addTearDown(container.dispose);
    final metadata = await container
        .read(downloadServiceProvider)
        .getMetadata(url('/opaque'), headers: auth);
    expect(metadata!.hlsPlan, isNotNull);
    expect(metadata.size, isNull);
    expect(
      requests.where((request) => request.contains('.ts')),
      isEmpty,
      reason: 'verification fetches only playlists, never the episode media',
    );
  });

  test(
    'playable HLS fixture downloads to an offline package',
    () async {
      final fixture = Platform.environment['HLS_FIXTURE_DIR']!;
      final output = Platform.environment['HLS_OUTPUT_DIR']!;
      for (final file in Directory(fixture).listSync().whereType<File>()) {
        final path = '/${p.basename(file.path)}';
        if (p.extension(file.path) == '.m3u8') {
          playlists[path] = await file.readAsString();
        } else {
          bodies[path] = await file.readAsBytes();
        }
      }
      final task = DownloadTask(
        taskId: 'playable',
        url: url('/index.m3u8'),
        filename: Platform.environment['HLS_OUTPUT_FILENAME'] ?? 'offline.m3u8',
        directory: output,
        baseDirectory: BaseDirectory.root,
        group: HlsDownloadManager.parentGroup,
      );
      await manager.start(task, await plan('/index.m3u8'));
      for (final child in queued.values.toList()) {
        await deliver(child);
      }
      expect(
        (await downloader.database.recordForId('playable'))!.status,
        TaskStatus.complete,
      );
      expect(File(await task.filePath()).existsSync(), isTrue);
    },
    skip:
        Platform.environment['HLS_FIXTURE_DIR'] == null ||
        Platform.environment['HLS_OUTPUT_DIR'] == null,
  );

  test('HLS verification never reports playlist bytes as episode size', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
      );
      const playlist =
          '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n';
      request.response.contentLength = playlist.length;
      if (request.method != 'HEAD') request.response.write(playlist);
      await request.response.close();
    });
    final dio = Dio();
    addTearDown(dio.close);
    final container = ProviderContainer(
      overrides: [dioClientProvider.overrideWithValue(dio)],
    );
    addTearDown(container.dispose);
    final metadata = await container
        .read(downloadServiceProvider)
        .getMetadata('http://127.0.0.1:${server.port}/episode.m3u8');
    expect(metadata, isNotNull);
    expect(metadata!.mimeType, contains('mpegurl'));
    expect(
      metadata.size,
      isNull,
      reason: 'manifest size is not the total media size',
    );
  });
}

class _InMemoryDownloadStorage implements PersistentStorage {
  final Map<String, TaskRecord> _records = <String, TaskRecord>{};
  final Map<String, Task> _paused = <String, Task>{};
  final Map<String, ResumeData> _resume = <String, ResumeData>{};

  @override
  (String, int) get currentDatabaseVersion => ('memory', 1);

  @override
  Future<(String, int)> get storedDatabaseVersion async =>
      currentDatabaseVersion;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> storeTaskRecord(TaskRecord record) async =>
      _records[record.taskId] = record;

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) async =>
      _records[taskId];

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async =>
      _records.values.toList();

  @override
  Future<void> removeTaskRecord(String? taskId) async =>
      taskId == null ? _records.clear() : _records.remove(taskId);

  @override
  Future<void> storePausedTask(Task task) async => _paused[task.taskId] = task;

  @override
  Future<Task?> retrievePausedTask(String taskId) async => _paused[taskId];

  @override
  Future<List<Task>> retrieveAllPausedTasks() async => _paused.values.toList();

  @override
  Future<void> removePausedTask(String? taskId) async =>
      taskId == null ? _paused.clear() : _paused.remove(taskId);

  @override
  Future<void> storeResumeData(ResumeData resumeData) async =>
      _resume[resumeData.taskId] = resumeData;

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) async =>
      _resume[taskId];

  @override
  Future<List<ResumeData>> retrieveAllResumeData() async =>
      _resume.values.toList();

  @override
  Future<void> removeResumeData(String? taskId) async =>
      taskId == null ? _resume.clear() : _resume.remove(taskId);
}
