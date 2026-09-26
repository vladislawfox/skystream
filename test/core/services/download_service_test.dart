import 'dart:io';
import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/logger/app_logger.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/core/services/hls_download_plan.dart';
import 'package:skystream/core/services/hls_download_manager.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/library/presentation/downloads_provider.dart';
import 'package:skystream/features/library/presentation/widgets/downloads_tab.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// Two manners problems in the download path, driven through the real
/// [DownloadService] against a mocked `com.bbflight.background_downloader`
/// method channel.
///
/// 1. The notification permission used to be requested during the launch
///    sequence - `DownloadService.init` ran from the first post-frame callback
///    of every cold start and asked for it as step 3, and iOS asked a second
///    time from `AppDelegate.didFinishLaunchingWithOptions`. The very first
///    thing a new user saw, before any app content, was a system modal asking
///    to send notifications the app had nothing to send yet. It has to be
///    asked for where it means something: the moment a download starts.
///
/// 2. `startDownload` reported nothing when it threw. `dir.create` throws a
///    FileSystemException whenever the target is unwritable - the default
///    outcome on Android 11+ once All-files-access is declined - and no caller
///    caught it and nothing was logged, so "Download Now" simply did nothing.
///
/// The channel mock is what makes this observable at all: under `flutter_test`
/// `defaultTargetPlatform` is android, so `FileDownloader().permissions` is
/// the real `AndroidPermissionsService` and every permission question it asks
/// arrives here as a `permissionStatus` / `requestPermission` call.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CachedNetworkImageProvider.defaultCacheManager = _NoPosterCache();
  // Must be the first FileDownloader() call in the process - the singleton
  // keeps whichever storage it was built with.
  FileDownloader(persistentStorage: _InMemoryDownloadStorage());

  late Directory tempDir;
  late StorageService storage;
  late ProviderContainer container;
  late DownloadService service;
  late List<String> nativeCalls;
  late List<List<dynamic>> queueConfigurations;
  late Map<String, Task> queued;
  late bool rejectQueue;
  late PermissionStatus reportedStatus;

  const MethodChannel downloaderChannel = MethodChannel(
    'com.bbflight.background_downloader',
  );
  const MethodChannel pathProviderChannel = MethodChannel(
    'plugins.flutter.io/path_provider',
  );

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('download_service_test');
    nativeCalls = <String>[];
    queueConfigurations = [];
    queued = {};
    rejectQueue = false;
    reportedStatus = PermissionStatus.denied;

    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      pathProviderChannel,
      (MethodCall call) async => tempDir.path,
    );
    messenger.setMockMethodCallHandler(downloaderChannel, (
      MethodCall call,
    ) async {
      nativeCalls.add(call.method);
      switch (call.method) {
        case 'configHoldingQueue':
          queueConfigurations.add(List<dynamic>.from(call.arguments as List));
          return null;
        case 'permissionStatus':
          return reportedStatus.index;
        case 'requestPermission':
          // false = "handled synchronously", which keeps the plugin from
          // parking on a completer only the native side can resolve.
          return false;
        case 'enqueue':
          if (rejectQueue) return false;
          final task = Task.createFromJsonString(
            (call.arguments as List).first as String,
          );
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
        case 'popResumeData':
        case 'popStatusUpdates':
        case 'popProgressUpdates':
          return '{}';
        default:
          return null;
      }
    });

    Hive.init(tempDir.path);
    storage = StorageService();
    await storage.init();
    container = ProviderContainer(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
    );
    service = container.read(downloadServiceProvider);
    await FileDownloader().database.deleteAllRecords();
    talker.cleanHistory();
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(downloaderChannel, null);
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    talker.cleanHistory();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<bool> start({String? directory}) => service.startDownload(
    url: 'https://example.com/a.mp4',
    filename: 'a.mp4',
    directory: directory ?? p.join(tempDir.path, 'out'),
    item: MultimediaItem(
      title: 'A Movie',
      url: 'https://example.com/a',
      posterUrl: '',
    ),
  );

  group('the notification permission is asked in context, not at launch', () {
    test('init() completes without ever asking for it', () async {
      await service.init();

      // This guards the whole of init, not just the deleted lines. The
      // permission question sat at step 3, between `configHoldingQueue`
      // (step 1) and the `pop*` calls that `FileDownloader().start()` makes at
      // step 4, so seeing both ends arrive with nothing in between is what
      // makes the absence meaningful - init really did run past the old site
      // rather than bailing out early.
      expect(
        nativeCalls,
        containsAllInOrder(<String>[
          'configHoldingQueue',
          'popProgressUpdates',
        ]),
      );
      expect(
        nativeCalls,
        isNot(contains('permissionStatus')),
        reason:
            'a cold start must not raise the notification prompt; '
            'saw $nativeCalls',
      );
      expect(nativeCalls, isNot(contains('requestPermission')));
    });

    test('the first startDownload asks for it', () async {
      await service.init();
      nativeCalls.clear();

      await expectLater(start(), completion(isTrue));

      expect(nativeCalls, contains('permissionStatus'));
      expect(
        nativeCalls,
        contains('requestPermission'),
        reason: 'status was denied, so the prompt is the point of the call',
      );
    });

    test('a granted permission is not re-requested', () async {
      reportedStatus = PermissionStatus.granted;
      await service.init();
      nativeCalls.clear();

      await start();

      expect(nativeCalls, contains('permissionStatus'));
      expect(nativeCalls, isNot(contains('requestPermission')));
    });

    test('a second download does not prompt again', () async {
      await service.init();
      await start();
      nativeCalls.clear();

      await start(directory: p.join(tempDir.path, 'out2'));

      expect(
        nativeCalls,
        isNot(contains('requestPermission')),
        reason: 'one prompt per process; re-asking on every download is rude',
      );
      expect(nativeCalls, isNot(contains('permissionStatus')));
    });

    test('iOS does not ask a second time from AppDelegate', () {
      // The native half of the same finding, and the only place a Dart test
      // can see it. `requestAuthorization` in
      // `didFinishLaunchingWithOptions` fires before the engine has drawn
      // anything at all, so it beats even the Dart prompt to the screen.
      final File appDelegate = File('ios/Runner/AppDelegate.swift');
      expect(
        appDelegate.existsSync(),
        isTrue,
        reason: 'run this from the package root',
      );
      expect(
        appDelegate.readAsStringSync(),
        isNot(contains('requestAuthorization')),
        reason:
            'the launch sequence must only install the UNUserNotificationCenter '
            'delegate; authorisation is requested by '
            'DownloadService.ensureNotificationPermission',
      );
    });
  });

  group('startDownload reports its own failures', () {
    test('a directory it cannot create is logged and rethrown', () async {
      await service.init();

      // A plain file standing where a parent directory has to go. This is the
      // portable stand-in for the real trigger - Android 11+ with
      // All-files-access declined - and it reaches the same line:
      // `dir.create(recursive: true)` throws FileSystemException.
      final File blocker = File(p.join(tempDir.path, 'not-a-directory'))
        ..writeAsStringSync('x');
      final String unusable = p.join(blocker.path, 'Skystream', 'A Movie');

      await expectLater(
        start(directory: unusable),
        throwsA(isA<FileSystemException>()),
      );

      // The user-visible half is the launcher's job; this is the half that
      // used to leave us with nothing to look at. Before the fix the throw
      // escaped an uncaught async callback and `/logs` stayed empty.
      final String log = _text(talker);
      expect(
        log,
        contains('DownloadService.startDownload failed'),
        reason: 'a silent start failure is unsupportable; log was:\n$log',
      );
      expect(log, contains('a.mp4'));
      expect(log, contains('FileSystemException'));
    });

    test('a successful start logs nothing', () async {
      await service.init();
      talker.cleanHistory();

      await expectLater(start(), completion(isTrue));

      expect(_text(talker), isNot(contains('startDownload failed')));
    });
  });
  test(
    'initial and updated queue limits allow concurrent HLS segments',
    () async {
      await storage.setDownloadConcurrency(5);
      await service.init();
      // Native contract: total, per-host, per-group. Every HLS asset shares a group.
      expect(queueConfigurations.last, [5, 2, 5]);
      await service.applyQueueSettings(maxConcurrent: 6, chunks: 1);
      expect(queueConfigurations.last, [6, 2, 6]);
      await service.applyQueueSettings(maxConcurrent: 1, chunks: 1);
      expect(queueConfigurations.last, [1, 2, 1]);
    },
  );

  test('failed HLS episodes remain in the library after a refresh', () async {
    await service.init();
    final task = DownloadTask(
      taskId: 'failed-episode',
      url: 'https://cdn.test/episode.m3u8',
      group: HlsDownloadManager.parentGroup,
    );
    await storage.saveDownloadMetadata(
      task.taskId,
      MultimediaItem(
        title: 'Arrow',
        url: 'https://series.test/arrow',
        posterUrl: '',
      ),
    );
    await FileDownloader().database.updateRecord(
      TaskRecord(
        task,
        TaskStatus.failed,
        0.5,
        -1,
        TaskHttpException('Unavailable', 503),
      ),
    );
    final items = await container.read(downloadsProvider.future);
    expect(items, hasLength(1));
    expect(items.single.status, TaskStatus.failed);
    expect(items.single.progress, 0.5);
  });

  for (final lostJob in [false, true]) {
    test(
      'starting a failed HLS source recovers with missing job=$lostJob',
      () async {
        await service.init();
        const tracking = 'https://series.test/arrow#s1e15';
        final item = MultimediaItem(
          title: 'Arrow',
          url: tracking,
          posterUrl: '',
        );
        final hls = HlsDownloadPlan(
          {
            'index.m3u8': '#EXTM3U\n#EXTINF:6,\nasset0.ts\n#EXTINF:6,\nasset1.ts\n#EXT-X-ENDLIST\n',
          },
          [
            HlsDownloadAsset(
              'https://cdn.test/first.ts',
              'asset0.ts',
              {},
              null,
            ),
            HlsDownloadAsset(
              'https://cdn.test/second.ts',
              'asset1.ts',
              {},
              null,
            ),
          ],
        );
        Future<bool> startEpisode() => service.startDownload(
          url: 'https://cdn.test/episode.m3u8',
          filename: 'episode.m3u8',
          directory: tempDir.path,
          item: item,
          trackingUrl: tracking,
          hlsPlan: hls,
        );
        await startEpisode();
        final parent = (await FileDownloader().database.allRecords(
          group: HlsDownloadManager.parentGroup,
        )).single;
        final children = queued.values.toList();
        final saved = File(await children.first.filePath());
        await saved.writeAsBytes([1, 2, 3]);
        // Persist a terminal failure, as if the app closed after cancellation.
        queued.clear();
        final jobFile = File(p.join(saved.parent.path, 'job.json'));
        final json =
            jsonDecode(await jobFile.readAsString()) as Map<String, dynamic>;
        json['status'] = TaskStatus.failed.index;
        await jobFile.writeAsString(jsonEncode(json));
        await FileDownloader().database.updateRecord(
          parent.copyWith(status: TaskStatus.failed),
        );
        if (lostJob) await jobFile.delete();
        container.dispose();
        container = ProviderContainer(
          overrides: [storageServiceProvider.overrideWithValue(storage)],
        );
        service = container.read(downloadServiceProvider);
        await service.init();
        expect(await startEpisode(), isTrue);
        if (lostJob) {
          expect(queued, hasLength(2));
        } else {
          expect(await saved.exists(), isTrue);
          expect(await saved.readAsBytes(), [1, 2, 3]);
          expect(queued, hasLength(1));
          expect(queued.values.single.url, 'https://cdn.test/second.ts');
        }
        final records = await FileDownloader().database.allRecords(
          group: HlsDownloadManager.parentGroup,
        );
        expect(records, hasLength(1));
        expect(
          records.single.taskId,
          lostJob ? isNot(parent.taskId) : parent.taskId,
        );
        expect(records.single.status, TaskStatus.running);
      },
    );
  }

  test(
    'Retry reports unavailable saved data instead of silently doing nothing',
    () async {
      await service.init();
      final task = DownloadTask(
        taskId: 'missing-job',
        url: 'https://cdn.test/episode.m3u8',
        group: HlsDownloadManager.parentGroup,
      );
      await FileDownloader().database.updateRecord(
        TaskRecord(task, TaskStatus.failed, 0.5, -1),
      );
      await expectLater(
        service.resumeDownload(task.taskId),
        throwsA(isA<TaskResumeException>()),
      );
      expect(
        (await FileDownloader().database.recordForId(task.taskId))!.exception,
        isA<TaskResumeException>(),
      );
      expect(queued, isEmpty);
    },
  );

  test('Resume all after restart preserves completed HLS downloads', () async {
    await service.init();
    for (final status in [TaskStatus.complete, TaskStatus.failed]) {
      final task = DownloadTask(
        taskId: status.name,
        url: 'https://cdn.test/${status.name}.m3u8',
        group: HlsDownloadManager.parentGroup,
      );
      await FileDownloader().database.updateRecord(
        TaskRecord(task, status, 1, 100),
      );
      await storage.saveDownloadMetadata(
        task.taskId,
        MultimediaItem(title: status.name, url: task.url, posterUrl: ''),
      );
    }
    await service.resumeDownload('complete');
    await container.read(downloadsProvider.future);
    await container.read(downloadsProvider.notifier).resumeAll();
    final complete = (await FileDownloader().database.recordForId('complete'))!;
    expect(complete.status, TaskStatus.complete);
    expect(complete.exception, isNull);
  });

  for (final retryRejected in [false, true]) {
    testWidgets(
      'failed episode Retry preserves media and handles rejection=$retryRejected',
      (tester) async {
        await tester.runAsync(() async {
          final task = DownloadTask(
            taskId: 'retry-episode',
            url: 'https://cdn.test/episode.m3u8',
            filename: 'episode.m3u8',
            directory: tempDir.path,
            baseDirectory: BaseDirectory.root,
            group: HlsDownloadManager.parentGroup,
          );
          await storage.saveDownloadMetadata(
            task.taskId,
            MultimediaItem(
              title: 'Arrow S1E15',
              url: 'https://series.test/arrow',
              posterUrl: '',
            ),
          );
          final manager = HlsDownloadManager(
            downloader: FileDownloader(),
            onUpdate: (_) {},
          );
          await manager.start(
            task,
            HlsDownloadPlan(
              {
                'index.m3u8': '#EXTM3U\n#EXTINF:6,\nasset0.ts\n#EXTINF:6,\nasset1.ts\n#EXT-X-ENDLIST\n',
              },
              [
                HlsDownloadAsset(
                  'https://cdn.test/first.ts',
                  'asset0.ts',
                  {},
                  null,
                ),
                HlsDownloadAsset(
                  'https://cdn.test/second.ts',
                  'asset1.ts',
                  {},
                  null,
                ),
              ],
            ),
          );
          final children = queued.values.toList();
          await File(await children.first.filePath()).writeAsBytes([1, 2, 3]);
          queued.remove(children.first.taskId);
          await manager.handle(
            TaskStatusUpdate(children.first, TaskStatus.complete),
          );
          await manager.handle(
            TaskStatusUpdate(
              children.last,
              TaskStatus.failed,
              TaskHttpException('Server unavailable', 503),
            ),
          );
          await service.init();
          await container.read(downloadsProvider.future);
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: DownloadsTab()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Arrow S1E15'), findsOneWidget);
        expect(find.textContaining('HTTP 503'), findsOneWidget);
        expect(find.byTooltip('Retry'), findsOneWidget);
        await tester.runAsync(() async {
          rejectQueue = retryRejected;
          final expectedStatus = retryRejected
              ? TaskStatus.failed
              : TaskStatus.running;
          final changed = service.updates
              .where(
                (update) =>
                    update is TaskStatusUpdate &&
                    update.task.taskId == 'retry-episode' &&
                    update.status == expectedStatus,
              )
              .first;
          await tester.tap(find.byTooltip('Retry'));
          await changed.timeout(const Duration(seconds: 5));
          // Resume publishes running before it queues the missing files.
          for (
            var attempt = 0;
            !retryRejected && queued.isEmpty && attempt < 100;
            attempt++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();
        if (retryRejected) {
          expect(queued, isEmpty);
          expect(find.byTooltip('Retry'), findsOneWidget);
          expect(find.textContaining('Could not queue'), findsOneWidget);
        } else {
          expect(queued.values.map((task) => task.url), [
            'https://cdn.test/second.ts',
          ]);
          expect(find.byTooltip('Retry'), findsNothing);
        }
        expect(find.textContaining('HTTP 503'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test('system Cancel resolves a synthetic HLS parent and cancels every media task', () async {
    await service.init();
    const tracking = 'https://series.test/arrow#s1e2';
    await service.startDownload(
      url: 'https://cdn.test/episode.m3u8',
      filename: 'episode.m3u8',
      directory: tempDir.path,
      item: MultimediaItem(title: 'Arrow', url: tracking, posterUrl: ''),
      trackingUrl: tracking,
      hlsPlan: HlsDownloadPlan(
        {'index.m3u8': '#EXTM3U\n#EXTINF:6,\nasset0.ts\n#EXT-X-ENDLIST\n'},
        [HlsDownloadAsset('https://cdn.test/first.ts', 'asset0.ts', {}, null)],
      ),
    );
    final parent = (await FileDownloader().database.allRecords(
      group: HlsDownloadManager.parentGroup,
    )).single.task;
    expect(queued.values.single.group, HlsDownloadManager.assetGroup);
    await service.cancelFromSystemUI(parent.taskId);
    expect(queued, isEmpty);
    expect(await FileDownloader().database.recordForId(parent.taskId), isNull);
    expect(container.read(activeDownloadsProvider), isNot(contains(tracking)));
    expect(
      Directory(
        HlsDownloadManager.packagePath(p.join(tempDir.path, 'episode.m3u8')),
      ).existsSync(),
      isFalse,
    );
  });
}

String _text(Talker logger) =>
    logger.history.map((TalkerData e) => e.generateTextMessage()).join('\n');

// Poster fetching is unrelated to the real download persistence/UI path.
class _NoPosterCache implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The package's own [PersistentStorage] spawns a background isolate that
/// reaches for `path_provider` through the root isolate token, which a mocked
/// method channel cannot answer - `FileDownloader().ready` then never
/// completes. An in-memory store keeps the real downloader, minus the isolate.
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
