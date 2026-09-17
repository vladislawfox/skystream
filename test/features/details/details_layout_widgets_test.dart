import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/router/app_router.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/details/presentation/details_controller.dart';
import 'package:skystream/features/details/presentation/downloaded_file_provider.dart';
import 'package:skystream/features/details/presentation/widgets/details_layout_widgets.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/custom_widgets.dart';

/// Every history getter goes through Hive-backed [StorageService]; the action
/// row only asks for the resume position, so answer "never watched" and skip
/// the boxes entirely.
class _NoHistory extends HistoryRepository {
  _NoHistory() : super(StorageService());

  @override
  int getPosition(String url) => 0;
  @override
  int getDuration(String url) => 0;
  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
}

/// The real notifier hits path_provider through DownloadService on the
/// post-frame check; keep the map and drop the disk probe.
class _FakeDownloadedFiles extends DownloadedFiles {
  @override
  Map<String, File?> build() => const <String, File?>{};

  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {}
}

class _NoDownloadedFile extends Fake implements DownloadService {
  @override
  Future<File?> getDownloadedFile(
    MultimediaItem item, {
    Episode? episode,
  }) async => null;
}

class _PlaybackHarness {
  _PlaybackHarness(this.container);
  final ProviderContainer container;
  PlayerRouteExtra? pushed;
}

class _FakeExtensionManager extends ExtensionManager {
  _FakeExtensionManager(this._providers);
  final List<SkyStreamProvider> _providers;

  @override
  List<SkyStreamProvider> build() => _providers;
}

class _FakeProvider extends SkyStreamProvider {
  _FakeProvider({required this.packageName, required this.name});

  @override
  final String packageName;
  @override
  final String name;
  @override
  String get mainUrl => 'https://fake.test';
  @override
  String get version => '1.0.0';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.movie};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) => throw UnimplementedError();
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

const _kUrl = 'https://fake.test/title/1';

MultimediaItem _item({
  MultimediaContentType contentType = MultimediaContentType.movie,
  List<Episode>? episodes,
}) => MultimediaItem(
  title: 'A Title',
  url: _kUrl,
  posterUrl: '',
  contentType: contentType,
  episodes: episodes,
);

Future<_PlaybackHarness> _pumpActionButtons(
  WidgetTester tester, {
  required MultimediaItem item,
  required MultimediaItem? details,
  required bool isMovie,
  Episode? targetEpisode,
}) async {
  final container = ProviderContainer(
    overrides: [
      historyRepositoryProvider.overrideWithValue(_NoHistory()),
      downloadedFilesProvider.overrideWith(_FakeDownloadedFiles.new),
      downloadServiceProvider.overrideWithValue(_NoDownloadedFile()),
      playerSettingsProvider.overrideWithBuild(
        (_, _) => const PlayerSettings(),
      ),
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile()),
      ),
      detailsControllerProvider(_kUrl).overrideWithBuild(
        (_, _) => DetailsState(
          details: AsyncValue.data(details),
          isMovie: isMovie,
          item: item,
          targetEpisode: targetEpisode,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final harness = _PlaybackHarness(container);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: DetailsActionButtons(
            item: item,
            details: details,
            itemUrl: _kUrl,
          ),
        ),
      ),
      GoRoute(
        path: '/player',
        builder: (_, state) {
          harness.pushed = state.extra! as PlayerRouteExtra;
          return const Scaffold(body: Text('Player opened'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  return harness;
}

Future<void> _pumpProviderChip(
  WidgetTester tester, {
  required String providerName,
  required List<SkyStreamProvider> installed,
}) async {
  final container = ProviderContainer(
    overrides: [
      extensionManagerProvider.overrideWith(
        () => _FakeExtensionManager(installed),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(child: DetailsProviderChip(providerName: providerName)),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('DetailsActionButtons playback', () {
    for (final episodes in <List<Episode>?>[null, []]) {
      testWidgets(
        'a movie with ${episodes == null ? 'null' : 'empty'} episodes '
        'opens its page in the player',
        (tester) async {
          final movie = _item(episodes: episodes);
          final harness = await _pumpActionButtons(
            tester,
            item: movie,
            details: movie,
            isMovie: true,
          );

          await tester.tap(find.text('Play'));
          await tester.pumpAndSettle();

          expect(find.text('Player opened'), findsOneWidget);
          expect(harness.pushed!.videoUrl, _kUrl);
          expect(harness.pushed!.episode, isNull);
          expect(harness.pushed!.item, same(movie));
        },
      );
    }

    testWidgets('autoplay can launch a movie without episodes', (tester) async {
      final movie = _item();
      final harness = await _pumpActionButtons(
        tester,
        item: movie,
        details: movie,
        isMovie: true,
      );
      unawaited(
        harness.container
            .read(detailsControllerProvider(_kUrl).notifier)
            .handlePlayPress(tester.element(find.text('Play')), movie),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(harness.pushed!.videoUrl, _kUrl);
    });

    testWidgets('a movie keeps its provider-supplied playback entry', (
      tester,
    ) async {
      final movie = _item(
        episodes: [Episode(name: 'Full movie', url: '$_kUrl/watch')],
      );
      final harness = await _pumpActionButtons(
        tester,
        item: movie,
        details: movie,
        isMovie: true,
      );
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();

      expect(harness.pushed!.videoUrl, '$_kUrl/watch');
    });

    testWidgets('series playback keeps the selected episode', (tester) async {
      final episodes = [
        Episode(name: 'E1', url: '$_kUrl/e1', season: 1, episode: 1),
        Episode(name: 'E2', url: '$_kUrl/e2', season: 1, episode: 2),
      ];
      final series = _item(
        contentType: MultimediaContentType.series,
        episodes: episodes,
      );
      final harness = await _pumpActionButtons(
        tester,
        item: series,
        details: series,
        isMovie: false,
        targetEpisode: episodes.last,
      );
      await tester.tap(find.textContaining('Play'));
      await tester.pumpAndSettle();

      expect(harness.pushed!.videoUrl, '$_kUrl/e2');
      expect(harness.pushed!.episode, same(episodes.last));
    });

    testWidgets('an unresolved movie keeps Play disabled', (tester) async {
      await _pumpActionButtons(
        tester,
        item: _item(),
        details: null,
        isMovie: true,
      );
      final button = tester.widget<CustomButton>(
        find.ancestor(
          of: find.text('Play'),
          matching: find.byType(CustomButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('a series without episodes keeps Play disabled', (
      tester,
    ) async {
      final series = _item(contentType: MultimediaContentType.series);
      await _pumpActionButtons(
        tester,
        item: series,
        details: series,
        isMovie: false,
      );
      final button = tester.widget<CustomButton>(
        find.ancestor(
          of: find.text('Play'),
          matching: find.byType(CustomButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('DetailsActionButtons download affordance', () {
    testWidgets('a movie whose resolved details carry no episodes still '
        'offers Download', (tester) async {
      // Providers that expose a movie as a single playable page return
      // `episodes: null` from getDetails. Gating the button on
      // `details.episodes.length == 1` hid Download for all of them.
      final item = _item();
      await _pumpActionButtons(
        tester,
        item: item,
        details: MultimediaItem(
          title: 'A Title',
          url: _kUrl,
          posterUrl: '',
          contentType: MultimediaContentType.movie,
        ),
        isMovie: true,
      );

      expect(find.text('Download'), findsOneWidget);
    });

    testWidgets('a movie listing several mirrors as episodes offers Download', (
      tester,
    ) async {
      final episodes = [
        Episode(name: 'Server 1', url: '$_kUrl/s1'),
        Episode(name: 'Server 2', url: '$_kUrl/s2'),
      ];
      await _pumpActionButtons(
        tester,
        item: _item(episodes: episodes),
        details: _item(episodes: episodes),
        isMovie: true,
      );

      expect(find.text('Download'), findsOneWidget);
    });

    testWidgets('a one-episode series still offers Download', (tester) async {
      final episodes = [Episode(name: 'E1', url: '$_kUrl/e1', episode: 1)];
      await _pumpActionButtons(
        tester,
        item: _item(
          contentType: MultimediaContentType.series,
          episodes: episodes,
        ),
        details: _item(
          contentType: MultimediaContentType.series,
          episodes: episodes,
        ),
        isMovie: true,
      );

      expect(find.text('Download'), findsOneWidget);
    });

    testWidgets('a multi-episode series does not offer Download', (
      tester,
    ) async {
      final episodes = [
        Episode(name: 'E1', url: '$_kUrl/e1', season: 1, episode: 1),
        Episode(name: 'E2', url: '$_kUrl/e2', season: 1, episode: 2),
      ];
      await _pumpActionButtons(
        tester,
        item: _item(
          contentType: MultimediaContentType.series,
          episodes: episodes,
        ),
        details: _item(
          contentType: MultimediaContentType.series,
          episodes: episodes,
        ),
        isMovie: false,
      );

      expect(find.text('Download'), findsNothing);
    });

    testWidgets('a livestream never offers Download', (tester) async {
      await _pumpActionButtons(
        tester,
        item: _item(contentType: MultimediaContentType.livestream),
        details: _item(contentType: MultimediaContentType.livestream),
        isMovie: true,
      );

      expect(find.text('Download'), findsNothing);
    });
  });

  group('DetailsProviderChip', () {
    testWidgets('an installed provider renders its display name', (
      tester,
    ) async {
      await _pumpProviderChip(
        tester,
        providerName: 'test.pkg',
        installed: [_FakeProvider(packageName: 'test.pkg', name: 'Nice Name')],
      );

      expect(find.text('NICE NAME'), findsOneWidget);
    });

    testWidgets('an uninstalled provider renders the raw name without '
        'throwing out of build', (tester) async {
      // A library or history item can name an extension the user has since
      // removed. firstWhere threw StateError out of build for those, once per
      // rebuild - caught, but logged every single frame.
      final logged = <String>[];
      final previous = debugPrint;
      // flutter_test asserts the foundation debug vars are back at their
      // defaults before tearDown runs, so restore in-body.
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logged.add(message);
      };
      try {
        await _pumpProviderChip(
          tester,
          providerName: 'gone.pkg',
          installed: [_FakeProvider(packageName: 'other.pkg', name: 'Other')],
        );
      } finally {
        debugPrint = previous;
      }

      expect(tester.takeException(), isNull);
      expect(find.text('GONE.PKG'), findsOneWidget);
      expect(
        logged.where((l) => l.contains('DetailsProviderChip.build')),
        isEmpty,
        reason: 'a missing extension is an ordinary state, not an exception',
      );
    });
  });
}
