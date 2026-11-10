// What may be drawn *over* the live preview video, and what may not.
//
// The preview renders through a **hybrid-composition SurfaceView** on Android
// (`PreviewPlatformView` / `_NativePreviewView`), which is what makes 4K50 HDR
// affordable — the decoder's buffers reach the system compositor untouched
// instead of going through the app's GPU as an external texture. The cost of
// that path is at the other end: **every Flutter widget painted over a
// hybrid-composition view is promoted onto its own overlay surface**, composited
// separately, every frame.
//
// One small static chip is a fine price. A full-bleed scrim over live 4K video
// is not — it would hand back a large share of what the SurfaceView switch just
// bought. Initial loading and errors replace video; switching an already active
// native preview retains its surface without a loading scrim. These tests also
// keep channel switches from tearing down and recreating that native surface.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/screens/live_focus_coordinator.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';

void main() {
  setUpAll(() => debugDisableNetworkChannelLogos = true);
  tearDownAll(() => debugDisableNetworkChannelLogos = false);

  const videoKey = Key('preview-video-sentinel');
  const channels = [Channel(id: 'c1', name: 'Channel One', number: 1)];

  /// Builds the live tab with the preview panel in a given state, standing in
  /// for the platform view with a keyed sentinel.
  Future<void> pumpPanel(
    WidgetTester tester, {
    required bool previewLoading,
    required String? previewError,
    bool previewRetainVideo = false,
    Widget? previewVideo,
  }) async {
    const size = Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final scroll = ScrollController();
    final categoryScroll = ScrollController();
    // `flutter_test` reports Android as the default target platform, and
    // LiveTabView derives `compactWideLayout` from it — so the metrics here
    // must be built the same way or the extent assert fires before any of this
    // gets a chance to run. Android is also the faithful platform for this
    // file: the hybrid-composition SurfaceView it is about is Android-only.
    final metrics = LiveLayoutMetrics.forSize(
      size,
      compactWideLayout: true,
      textScale: 1.0,
    );
    final focus = LiveFocusCoordinator(
      scrollController: scroll,
      categoryScrollController: categoryScroll,
      visibleChannels: () => channels,
      orderedCategoryIds: () => const [null],
      channelRowExtent: () => metrics.channelRowExtent(false),
      categoryRowExtent: () => metrics.categoryRowExtent,
      isWide: () => true,
      isMounted: () => true,
      onChannelSelectionChanged: (_, _) {},
      onCategoryActivated: (_) {},
      onPlayChannel: (_) {},
      onToggleFavorite: (_) {},
      onFocusTabs: () {},
    );
    addTearDown(() {
      focus.dispose();
      scroll.dispose();
      categoryScroll.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: SafeArea(
            top: false,
            child: LiveTabView(
              loading: false,
              error: null,
              onRetry: () {},
              visible: channels,
              resolvePreviewChannel: () => channels.first,
              // The panel treats this row as the previewing one, which is what
              // puts the video into the stack at all.
              isPreviewingRow: (_) => true,
              now: const {},
              next: const {},
              showsEpg: false,
              deliberate: true,
              resolving: false,
              scrollController: scroll,
              categoryScrollController: categoryScroll,
              focus: focus,
              channelRowExtent: metrics.channelRowExtent(false),
              categoryRowExtent: metrics.categoryRowExtent,
              lastPlayedChannelId: null,
              previewChannelId: 'c1',
              isFavorite: (_) => false,
              onToggleFavorite: (_) {},
              onPlayChannel: (_) {},
              onPreviewChannel: (_) {},
              onCatchup: (_) {},
              categories: const [],
              selectedCategoryId: null,
              onCategorySelected: (_) {},
              previewVideoBuilder: () =>
                  previewVideo ??
                  const ColoredBox(key: videoKey, color: Color(0xFF000000)),
              previewLoading: previewLoading,
              previewError: previewError,
              previewRetainVideo: previewRetainVideo,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a playing preview carries no full-bleed overlay', (
    tester,
  ) async {
    await pumpPanel(tester, previewLoading: false, previewError: null);

    expect(find.byKey(videoKey), findsOneWidget);
    // The two expensive overlays, neither of which may sit over live video.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Preview unavailable'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the loading scrim replaces the video rather than covering it', (
    tester,
  ) async {
    await pumpPanel(tester, previewLoading: true, previewError: null);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.byKey(videoKey),
      findsNothing,
      reason:
          'a scrim over a live hybrid-composition surface is the one '
          'overlay shape that costs real money — it must be an alternative to '
          'the video, not a layer on it',
    );
  });

  testWidgets('the error scrim replaces the video rather than covering it', (
    tester,
  ) async {
    await pumpPanel(tester, previewLoading: false, previewError: 'boom');

    expect(find.text('Preview unavailable'), findsOneWidget);
    expect(find.byKey(videoKey), findsNothing);
  });

  testWidgets('switching native channels keeps the same preview surface', (
    tester,
  ) async {
    var mounted = 0;
    var disposed = 0;
    final video = _PreviewSurfaceSentinel(
      key: videoKey,
      onMounted: () => mounted++,
      onDisposed: () => disposed++,
    );

    await pumpPanel(
      tester,
      previewLoading: false,
      previewError: null,
      previewRetainVideo: true,
      previewVideo: video,
    );
    expect(mounted, 1);

    await pumpPanel(
      tester,
      previewLoading: true,
      previewError: null,
      previewRetainVideo: true,
      previewVideo: video,
    );
    expect(find.byKey(videoKey), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(mounted, 1);
    expect(disposed, 0);

    await pumpPanel(
      tester,
      previewLoading: false,
      previewError: null,
      previewRetainVideo: true,
      previewVideo: video,
    );
    expect(mounted, 1);
    expect(disposed, 0);

    await pumpPanel(
      tester,
      previewLoading: false,
      previewError: 'unavailable',
      previewRetainVideo: true,
      previewVideo: video,
    );
    expect(find.byKey(videoKey), findsNothing);
    expect(find.text('Preview unavailable'), findsOneWidget);
    expect(disposed, 1);
    expect(tester.takeException(), isNull);
  });
}

class _PreviewSurfaceSentinel extends StatefulWidget {
  final VoidCallback onMounted;
  final VoidCallback onDisposed;

  const _PreviewSurfaceSentinel({
    super.key,
    required this.onMounted,
    required this.onDisposed,
  });

  @override
  State<_PreviewSurfaceSentinel> createState() => _PreviewSurfaceSentinelState();
}

class _PreviewSurfaceSentinelState extends State<_PreviewSurfaceSentinel> {
  @override
  void initState() {
    super.initState();
    widget.onMounted();
  }

  @override
  void dispose() {
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Color(0xFF000000));
}
