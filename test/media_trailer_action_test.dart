import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/metadata_provider.dart';
import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

class _TrailerRepository implements LibraryRepository {
  @override
  List<MetadataProvider> get metadataProviders => const [];

  @override
  LoadToken? loadToken;

  @override
  Future<ExternalMetadata?> cachedExternalMetadata(
    MediaItem item,
    String provider,
  ) async => null;

  @override
  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
    bool enrichChildren = true,
  }) async => MediaLibrarySnapshot(
    kind: kind,
    categories: const [],
    items: const [],
    fromCache: true,
    syncedAt: null,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _movie = MediaItem(
  id: 'movie-with-trailer',
  title: 'Movie with trailer',
  kind: ContentKind.movie,
  extra: {
    'details': {
      'info': {'youtube_trailer': 'dQw4w9WgXcQ'},
    },
  },
);

const _series = MediaItem(
  id: 'series-without-trailer',
  title: 'Serial & przygoda',
  year: '2024',
  kind: ContentKind.series,
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final trailer = find.byKey(const ValueKey('media.details.trailer'));
  late List<MethodCall> launches;
  late List<String> playbackActions;
  var launchResult = true;
  var launchThrows = false;

  setUp(() {
    launches = [];
    playbackActions = [];
    launchResult = true;
    launchThrows = false;
    AppLanguageController.instance.preview(AppLanguage.english);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      launches.add(call);
      if (launchThrows) throw PlatformException(code: 'NO_ACTIVITY');
      return launchResult;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    AppLanguageController.instance.preview(AppLanguage.english);
  });

  Future<void> openDetails(
    WidgetTester tester,
    MediaItem item, {
    Size size = const Size(960, 540),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => MediaDetailsSheet(
                  repo: _TrailerRepository(),
                  item: item,
                  favorite: false,
                  onToggleFavorite: () {},
                  onPlay: item.kind == ContentKind.movie
                      ? () => playbackActions.add('play')
                      : null,
                  onPlayEpisode: (_) => playbackActions.add('episode'),
                  onPlayFromStart: () => playbackActions.add('fromStart'),
                  resume: item.kind == ContentKind.movie
                      ? PlaybackPosition(
                          kind: item.kind,
                          itemId: item.id,
                          position: const Duration(minutes: 12),
                          duration: const Duration(minutes: 90),
                          updatedAt: DateTime(2026, 10, 22),
                        )
                      : null,
                ),
              ),
              child: const Text('Open details'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open details'));
    await tester.pumpAndSettle();
    expect(trailer, findsOneWidget);
  }

  Uri expectExternalLaunch(int index) {
    final call = launches[index];
    expect(call.method, 'launch');
    final arguments = Map<String, dynamic>.from(call.arguments as Map);
    expect(arguments['useWebView'], isFalse);
    expect(arguments['useSafariVC'], isFalse);
    expect(arguments['universalLinksOnly'], isFalse);
    expect(playbackActions, isEmpty);
    expect(find.byType(MediaDetailsSheet), findsOneWidget);
    return Uri.parse(arguments['url'] as String);
  }

  testWidgets('TV remote opens the movie trailer without starting the movie', (
    tester,
  ) async {
    await openDetails(tester, _movie);
    expect(find.text('Watch trailer'), findsOneWidget);
    final node = tester.widget<OutlinedButton>(trailer).focusNode!;
    expect(focusRouteKey(node), 'media.details.trailer');
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(node));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(launches, hasLength(1));
    expect(
      expectExternalLaunch(0).toString(),
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    );
    expect(FocusManager.instance.primaryFocus, same(node));
    expect(find.text('Resume from 12:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow Polish series details open an encoded YouTube search', (
    tester,
  ) async {
    AppLanguageController.instance.preview(AppLanguage.polish);
    await openDetails(tester, _series, size: const Size(390, 844));
    expect(find.text('Szukaj zwiastuna na YouTube'), findsOneWidget);
    await tester.ensureVisible(trailer);
    await tester.tap(trailer);
    await tester.pumpAndSettle();
    expect(launches, hasLength(1));
    final uri = expectExternalLaunch(0);
    expect(uri.host, 'www.youtube.com');
    expect(uri.path, '/results');
    expect(
      uri.queryParameters['search_query'],
      'Serial & przygoda 2024 zwiastun PL',
    );
    expect(tester.takeException(), isNull);
  });

  for (final throws in [false, true]) {
    testWidgets(
      'launch failure (exception=$throws) keeps details and allows retry',
      (tester) async {
        launchResult = false;
        launchThrows = throws;
        await openDetails(tester, _movie);
        await tester.ensureVisible(trailer);
        await tester.tap(trailer);
        await tester.pumpAndSettle();
        expect(launches, hasLength(1));
        expectExternalLaunch(0);
        expect(
          find.text('Could not open the trailer or YouTube.'),
          findsOneWidget,
        );

        launchResult = true;
        launchThrows = false;
        await tester.tap(trailer);
        await tester.pumpAndSettle();
        expect(launches, hasLength(2));
        expectExternalLaunch(1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
