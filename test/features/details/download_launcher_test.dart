import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/logger/app_logger.dart';
import 'package:skystream/core/router/app_router.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/core/services/hls_download_plan.dart';
import 'package:skystream/core/services/notification_service.dart';
import 'package:skystream/features/details/presentation/download_launcher.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:talker_flutter/talker_flutter.dart';

/// "Download Now" used to be able to do nothing at all.
///
/// The confirm button's `onPressed` popped its dialog and then awaited
/// `startDownload` with no try/catch, and `startDownload` had none either.
/// `dir.create(recursive: true)` throws a FileSystemException whenever the
/// target is unwritable - the default outcome on Android 11+ once
/// All-files-access is declined - so the dialog closed and that was the end of
/// it: no progress row, no toast, no error, nothing in the log. The user taps
/// again and gets the same nothing, and the feature is simply broken from
/// where they are standing.
///
/// The `if (!started)` toast that was already there only ever covered `enqueue`
/// returning false, which is not the failure that happens.
void main() {
  late ProviderContainer container;
  late _StubDownloadService downloads;

  Future<void> pumpLauncher(
    WidgetTester tester, {
    Object? failure,
    bool enqueueSucceeds = true,
    DownloadMetadata? metadata,
  }) async {
    container = ProviderContainer(
      overrides: [
        downloadServiceProvider.overrideWith(
          (Ref ref) => downloads = _StubDownloadService(
            ref,
            failure: failure,
            enqueueSucceeds: enqueueSucceeds,
            metadata: metadata,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    talker.cleanHistory();
    addTearDown(talker.cleanHistory);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
  }

  /// Drives the real widget path: source verified, confirmation dialog shown,
  /// "Download Now" tapped.
  Future<void> tapDownloadNow(WidgetTester tester) async {
    final BuildContext context = tester.element(find.byType(Scaffold));
    unawaited(
      container
          .read(downloadLauncherProvider)
          .verifyAndDownload(context, _stream, _item, _item.url),
    );

    await tester.pump(); // verification dialog in
    await tester.pump(const Duration(milliseconds: 400)); // metadata + pop
    await tester.pump(const Duration(milliseconds: 400)); // confirm dialog in

    expect(
      find.text('Download Now'),
      findsOneWidget,
      reason: 'the confirmation dialog is the thing under test',
    );
    await tester.tap(find.text('Download Now'));
    await tester.pump(); // dialog pops, handler runs
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Toast timers are the service's, not the widget tree's, so they outlive
  /// the last pump and `flutter_test` fails the test on them.
  Future<void> drainToasts(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 6));

  testWidgets(
    'HLS confirmation accepts unknown size and preserves the selected episode and rendition',
    (tester) async {
      final plan = HlsDownloadPlan({'index.m3u8': '#EXTM3U'}, []);
      await pumpLauncher(tester, metadata: DownloadMetadata(hlsPlan: plan));
      final episode = Episode(
        name: '13',
        url: 'https://series.test/arrow#s1e13',
        season: 1,
        episode: 13,
      );
      final series = MultimediaItem(
        title: 'Arrow',
        url: 'https://series.test/arrow',
        posterUrl: '',
        contentType: MultimediaContentType.series,
        episodes: [episode],
      );
      const selected = StreamResult(
        url: 'https://cdn.test/s1e13/1080.m3u8',
        source: 'ICTV · 1080p',
        headers: {'Referer': 'https://tortuga.test/'},
      );
      unawaited(
        container
            .read(downloadLauncherProvider)
            .verifyAndDownload(
              tester.element(find.byType(Scaffold)),
              selected,
              series,
              episode.url,
            ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Unknown size'), findsOneWidget);
      expect(find.textContaining('ICTV · 1080p'), findsOneWidget);
      await tester.tap(find.text('Download Now'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(downloads.startedUrl, 'https://cdn.test/s1e13/1080.m3u8');
      expect(downloads.startedFilename, 'S1-E13 13.m3u8');
      expect(downloads.startedEpisode, same(episode));
      expect(downloads.startedTrackingUrl, episode.url);
      expect(downloads.startedHeaders, {'Referer': 'https://tortuga.test/'});
      expect(downloads.startedPlan, same(plan));
      await drainToasts(tester);
    },
  );

  testWidgets('a throwing startDownload becomes a visible error', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(
      tester,
      failure: const FileSystemException(
        'Creation failed',
        '/storage/emulated/0/Download/Skystream',
      ),
    );

    await tapDownloadNow(tester);

    expect(downloads.startCalls, 1);
    final List<ToastItem> toasts = container
        .read(notificationServiceProvider)
        .toasts;
    expect(
      toasts,
      hasLength(1),
      reason: 'the dialog is already gone; a toast is all that is left',
    );
    expect(toasts.single.type, ToastType.error);
    expect(toasts.single.message, contains('FileSystemException'));
    expect(
      toasts.single.message,
      contains('/storage/emulated/0/Download/Skystream'),
      reason: 'the path is the one thing that tells the user what to fix',
    );

    expect(
      _text(talker),
      contains('DownloadLauncher: "Download Now" failed'),
      reason: 'and it has to be in /logs too, or we cannot answer them',
    );

    await drainToasts(tester);
  });

  testWidgets('the enqueue-returned-false path still reports', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester, enqueueSucceeds: false);

    await tapDownloadNow(tester);

    final List<ToastItem> toasts = container
        .read(notificationServiceProvider)
        .toasts;
    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error);
    expect(toasts.single.message, contains('Failed to start download'));

    await drainToasts(tester);
  });

  testWidgets('a download that starts says nothing', (
    WidgetTester tester,
  ) async {
    await pumpLauncher(tester);

    await tapDownloadNow(tester);

    expect(downloads.startCalls, 1);
    expect(container.read(notificationServiceProvider).toasts, isEmpty);
    expect(_text(talker), isNot(contains('Download Now')));

    await drainToasts(tester);
  });
}

final MultimediaItem _item = MultimediaItem(
  title: 'A Movie',
  url: 'https://example.com/a-movie',
  posterUrl: '',
);

const StreamResult _stream = StreamResult(
  url: 'https://cdn.example.com/a-movie.mp4',
  source: 'Test Source',
);

class _StubDownloadService extends DownloadService {
  _StubDownloadService(
    super.ref, {
    required this.failure,
    required this.enqueueSucceeds,
    this.metadata,
  });

  final Object? failure;
  final bool enqueueSucceeds;
  final DownloadMetadata? metadata;
  int startCalls = 0;
  String? startedUrl;
  String? startedFilename;
  String? startedTrackingUrl;
  Episode? startedEpisode;
  Map<String, String>? startedHeaders;
  HlsDownloadPlan? startedPlan;

  @override
  Future<DownloadMetadata?> getMetadata(
    String url, {
    Map<String, String>? headers,
  }) async =>
      metadata ?? DownloadMetadata(size: 734003200, mimeType: 'video/mp4');

  @override
  Future<String> getDownloadPath(
    MultimediaItem? item, {
    Episode? episode,
    bool absolute = false,
  }) async => '/storage/emulated/0/Download/Skystream/A Movie';

  @override
  Future<bool> startDownload({
    required String url,
    required String filename,
    required String directory,
    required MultimediaItem item,
    Episode? episode,
    String? trackingUrl,
    Map<String, String>? headers,
    HlsDownloadPlan? hlsPlan,
  }) async {
    startCalls++;
    startedUrl = url;
    startedFilename = filename;
    startedTrackingUrl = trackingUrl;
    startedEpisode = episode;
    startedHeaders = headers;
    startedPlan = hlsPlan;
    if (failure != null) throw failure!;
    return enqueueSucceeds;
  }
}

String _text(Talker logger) =>
    logger.history.map((TalkerData e) => e.generateTextMessage()).join('\n');
