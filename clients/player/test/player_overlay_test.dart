import 'dart:async';

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_overlay.dart';
import 'package:iptvs/player/dvr_controls.dart';
import 'package:iptvs/player/zap_command.dart';
import 'package:iptvs/player/zap_quick_list.dart';
import 'package:iptvs/sources/source.dart';
import 'package:media_kit/media_kit.dart';

/// Widget-level coverage for [EmbeddedPlayerControls] — the shared Flutter
/// overlay used by Linux and the Windows SDR preview→fullscreen handoff. It is
/// driven through the [EmbeddedControls] seam with a pure stub, so the test
/// needs no libmpv engine and runs everywhere (a real media_kit [Player] can't
/// be constructed under plain `flutter test`).
///
/// Pins three behaviors called out in review:
///  1. Gesture layering/latency (guards commit aa01efb) — the double-tap
///     recognizer is a sibling *behind* the bars, so a control tap fires without
///     waiting out `kDoubleTapTimeout`; taps on the exposed video area toggle
///     playback and show the chrome; a double-tap toggles fullscreen.
///  2. The live-vs-VOD control set.
///  3. Responsive collapse below 720px, with no RenderFlex overflow on a narrow
///     surface carrying a full EPG + every badge, plus the favorite star gating.
Future<void> openSetting(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Playback settings'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  Future<_StubControls> pumpOverlay(
    WidgetTester tester, {
    required bool isLive,
    PlayerState state = const PlayerState(),
    bool canFavorite = false,
    bool favorite = false,
    bool liveSynced = true,
    Programme? epgNow,
    Programme? epgNext,
    String? sourceName,
    double width = 1000,
    double height = 720,
    EdgeInsets padding = EdgeInsets.zero,
    String Function(VideoParams params)? dynamicRangeLabel,
    VoidCallback? onPlayPause,
    VoidCallback? onToggleFullscreen,
    VoidCallback? onToggleFavorite,
    VoidCallback? onGoLive,
    VoidCallback? onPlaybackSettings,
    ZapBannerState? zap,
    ZapQuickListState? quickList,
    bool zapEnabled = false,
    VoidCallback? onOpenQuickList,
    ValueChanged<ZapCommand>? onQuickListCommand,
    GlobalKey<EmbeddedPlayerControlsState>? controlsKey,
    DvrControls dvr = const DvrControls(),
    ValueChanged<Duration>? onDvrSeek,
    double textScale = 1,
  }) async {
    // Size the whole test surface (not a nested SizedBox) so the overlay fills
    // it and `getCenter` lands on-screen; the width drives the <720 compact
    // logic and the badge wrap.
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final stub = _StubControls(state: state);
    addTearDown(stub.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // Inside the Scaffold so this is exactly the padding the overlay
          // reads (edge-to-edge system-bar insets on Android).
          body: MediaQuery(
            data: MediaQueryData(
              size: Size(width, height),
              padding: padding,
              textScaler: TextScaler.linear(textScale),
            ),
            child: EmbeddedPlayerControls(
              key: controlsKey,
              controls: stub,
              title: 'Channel One',
              sourceName: sourceName,
              aspectLabel: 'Fill',
              epgNow: epgNow,
              epgNext: epgNext,
              isLive: isLive,
              canFavorite: canFavorite,
              favorite: favorite,
              liveSynced: liveSynced,
              dvr: dvr,
              onStartTimeshift: () {},
              onToggleRecording: () {},
              onDvrSeek: onDvrSeek,
              zap: zap,
              quickList: quickList,
              zapEnabled: zapEnabled,
              onOpenQuickList: onOpenQuickList,
              onQuickListCommand: onQuickListCommand,
              dynamicRangeLabel: dynamicRangeLabel ?? (_) => '',
              onBack: () {},
              onToggleFavorite: onToggleFavorite ?? () {},
              onPlayPause: () async => onPlayPause?.call(),
              onGoLive: () async => onGoLive?.call(),
              onPlaybackSettings: onPlaybackSettings,
              onCycleAspect: () async {},
              onToggleFullscreen: onToggleFullscreen ?? () {},
            ),
          ),
        ),
      ),
    );
    // A single frame — never pumpAndSettle: the overlay holds a periodic clock
    // timer, and settling would also mask the double-tap latency this pins.
    await tester.pump();
    return stub;
  }

  testWidgets('playback settings gear is usable on a narrow player', (
    tester,
  ) async {
    var opened = 0;
    await pumpOverlay(
      tester,
      isLive: true,
      width: 480,
      onPlaybackSettings: () => opened++,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Playback settings'));
    await tester.pump();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  group('local DVR controls', () {
    const dvr = DvrControls(
      available: true,
      active: true,
      recording: true,
      start: Duration(minutes: 2),
      end: Duration(minutes: 12),
      position: Duration(minutes: 5),
      message: 'Recording · Local buffer 02:00–12:00 · 24 MB',
    );

    testWidgets('recording controls wrap at 320px with large text', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: true,
        width: 320,
        textScale: 2,
        dvr: dvr,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Stop recording'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Timeshift on'), findsNothing);
    });

    testWidgets('dragging the disk timeline commits only on release', (
      tester,
    ) async {
      final seeks = <Duration>[];
      await pumpOverlay(tester, isLive: true, dvr: dvr, onDvrSeek: seeks.add);
      final timeline = find.byKey(const ValueKey('dvr-timeline'));
      final gesture = await tester.startGesture(tester.getCenter(timeline));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(seeks, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(seeks, hasLength(1));
      expect(seeks.single, greaterThan(dvr.position));
    });
  });

  group('edge-to-edge system-bar insets', () {
    // This overlay is the Android fallback when the native player Activity
    // can't launch, and it renders in the ordinary (non-immersive) Flutter
    // window — so under edge-to-edge enforcement the status/navigation bars sit
    // over the video. Insets default to zero in tests, which is exactly why a
    // regression here would otherwise be invisible.
    testWidgets('the bars inset their controls by the system-bar padding', (
      tester,
    ) async {
      const inset = EdgeInsets.fromLTRB(0, 48, 0, 60);

      await pumpOverlay(tester, isLive: false);
      final backTop = tester.getTopLeft(find.byIcon(Icons.arrow_back)).dy;
      final playBottom = tester.getBottomLeft(find.byIcon(Icons.play_arrow)).dy;

      await pumpOverlay(tester, isLive: false, padding: inset);
      final insetBackTop = tester.getTopLeft(find.byIcon(Icons.arrow_back)).dy;
      final insetPlayBottom = tester
          .getBottomLeft(find.byIcon(Icons.play_arrow))
          .dy;

      // Back moves down out of the status bar; the transport moves up out of
      // the navigation bar. Without the fix both would be unchanged.
      expect(insetBackTop - backTop, inset.top);
      expect(playBottom - insetPlayBottom, inset.bottom);
    });
  });

  group('gesture layering + latency', () {
    for (final isLive in [false, true]) {
      testWidgets(
        'clicking the picture toggles playback once (live: $isLive)',
        (tester) async {
          var playPauseCalls = 0;
          await pumpOverlay(
            tester,
            isLive: isLive,
            onPlayPause: () => playPauseCalls++,
          );

          await tester.tapAt(
            tester.getCenter(find.byType(EmbeddedPlayerControls)),
          );
          await tester.pump(const Duration(milliseconds: 350));
          expect(playPauseCalls, 1);

          await tester.tapAt(
            tester.getCenter(find.byType(EmbeddedPlayerControls)),
          );
          await tester.pump(const Duration(milliseconds: 350));
          expect(playPauseCalls, 2);
        },
      );
    }

    testWidgets('clicking the picture closes information without pausing', (
      tester,
    ) async {
      var playPauseCalls = 0;
      final key = GlobalKey<EmbeddedPlayerControlsState>();
      await pumpOverlay(
        tester,
        isLive: false,
        controlsKey: key,
        onPlayPause: () => playPauseCalls++,
      );
      key.currentState!.toggleInfo();
      await tester.pump();

      await tester.tapAt(const Offset(100, 350));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Stream information'), findsNothing);
      expect(playPauseCalls, 0);
    });

    testWidgets('a control tap fires without waiting out the double-tap '
        'timeout (double-tap recognizer stays a sibling behind the bars)', (
      tester,
    ) async {
      var playPauseCalls = 0;
      await pumpOverlay(
        tester,
        isLive: false,
        onPlayPause: () => playPauseCalls++,
      );

      // Not playing → the play button shows play_arrow.
      await tester.tap(find.byIcon(Icons.play_arrow));
      // Well under kDoubleTapTimeout (300ms). If the double-tap recognizer were
      // an ancestor of the bars it would hold the arena and delay this press to
      // the full timeout — the aa01efb "heavy overlay" regression.
      await tester.pump(const Duration(milliseconds: 50));
      expect(playPauseCalls, 1);
    });

    testWidgets('double-tapping the exposed video area toggles fullscreen', (
      tester,
    ) async {
      var fullscreenCalls = 0;
      var playPauseCalls = 0;
      await pumpOverlay(
        tester,
        isLive: false,
        onPlayPause: () => playPauseCalls++,
        onToggleFullscreen: () => fullscreenCalls++,
      );

      final center = tester.getCenter(find.byType(EmbeddedPlayerControls));
      await tester.tapAt(center);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(center);
      // Flush the double-tap recognizer's own timers before the test ends.
      await tester.pump(const Duration(milliseconds: 350));
      expect(fullscreenCalls, 1);
      expect(playPauseCalls, 0);
    });

    testWidgets('tapping the exposed video area re-shows hidden controls', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: true,
        state: const PlayerState(playing: true),
      );

      // Playing → the chrome auto-hides after its 4s timer.
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.byIcon(Icons.pause), findsNothing);

      // A tap on the exposed video area brings the chrome back. The background
      // detector also owns double-tap, so a single tap only resolves after
      // kDoubleTapTimeout (~300ms) — pump past it.
      await tester.tapAt(tester.getCenter(find.byType(EmbeddedPlayerControls)));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byIcon(Icons.pause), findsOneWidget);
    });
  });

  group('live vs VOD control set', () {
    testWidgets('live shows a LIVE badge and no VOD affordances', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: true, epgNow: _programme('News'));

      expect(find.text('LIVE'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // No seek/skip/speed/position — those belong to VOD.
      expect(find.byIcon(Icons.replay_10), findsNothing);
      expect(find.byIcon(Icons.forward_10), findsNothing);
      expect(find.byIcon(Icons.speed), findsNothing);
      // Synced → no "Go to live".
      expect(find.text('Go to live'), findsNothing);
      expect(find.byIcon(Icons.skip_next), findsNothing);
    });

    testWidgets('a live stream behind the edge shows "Go to live"', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: true, liveSynced: false);
      // Wide surface → the labelled button, not the collapsed icon.
      expect(find.text('Go to live'), findsOneWidget);
    });

    testWidgets('VOD shows the seek bar, ±10s, speed menu and position, no '
        'LIVE badge', (tester) async {
      await pumpOverlay(tester, isLive: false);

      expect(find.text('LIVE'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.replay_10), findsOneWidget);
      expect(find.byIcon(Icons.forward_10), findsOneWidget);
      expect(find.byIcon(Icons.speed), findsNothing);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      // Seek bar (VOD) + volume slider (wide) = two Sliders; live has only the
      // volume slider.
      expect(find.byType(Slider), findsNWidgets(2));
    });
  });

  group('responsive collapse + favorite star', () {
    testWidgets('below 720px the volume slider and "Go to live" collapse', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: true, liveSynced: false, width: 500);

      // Volume slider gone (mute button stays); no seek bar on live either.
      expect(find.byType(Slider), findsNothing);
      expect(find.byIcon(Icons.volume_up), findsOneWidget);
      // "Go to live" collapses to its icon.
      expect(find.text('Go to live'), findsNothing);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
    });

    testWidgets('a narrow surface with full EPG + all badges never overflows', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: true,
        liveSynced: false,
        canFavorite: true,
        width: 500,
        sourceName: 'Provider Network HD',
        epgNow: _programme(
          'A Very Long Currently Airing Programme Title That Runs On',
        ),
        epgNext: _programme('An Equally Long Up-Next Programme Title Here'),
        state: const PlayerState(
          width: 3840,
          height: 2160,
          videoParams: VideoParams(
            w: 3840,
            h: 2160,
            gamma: 'pq',
            primaries: 'bt.2020',
          ),
          tracks: Tracks(
            video: [VideoTrack('1', null, null, codec: 'hevc', fps: 50)],
          ),
        ),
        dynamicRangeLabel: (_) => 'HDR10 · PQ',
      );

      // Resolution / HDR / FPS / source / clock all present, in the compact
      // forms the native overlays use …
      expect(find.text('4K'), findsOneWidget);
      expect(find.text('HDR10'), findsOneWidget);
      expect(find.text('50fps'), findsOneWidget);
      // … and no RenderFlex overflow from any of it.
      expect(tester.takeException(), isNull);
    });

    testWidgets('favorite star appears only when canFavorite and reflects '
        'state', (tester) async {
      var favoriteToggles = 0;

      // Not favorited → outline star, toggles the callback.
      await pumpOverlay(
        tester,
        isLive: true,
        canFavorite: true,
        favorite: false,
        onToggleFavorite: () => favoriteToggles++,
      );
      expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsNothing);
      await tester.tap(find.byIcon(Icons.star_outline_rounded));
      await tester.pump();
      expect(favoriteToggles, 1);

      // Favorited → filled star.
      await pumpOverlay(
        tester,
        isLive: true,
        canFavorite: true,
        favorite: true,
      );
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      expect(find.byIcon(Icons.star_outline_rounded), findsNothing);

      // Not favoritable → no star at all.
      await pumpOverlay(tester, isLive: true, canFavorite: false);
      expect(find.byIcon(Icons.star_rounded), findsNothing);
      expect(find.byIcon(Icons.star_outline_rounded), findsNothing);
    });
  });

  group('info panel tap-outside dismiss', () {
    testWidgets('opening then tapping outside closes the info panel', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: false);

      await openSetting(tester, 'Stream information');
      await tester.pump();
      expect(find.text('Stream information'), findsOneWidget);

      // Tap the exposed video area (outside the panel) → panel closes. The
      // background detector owns double-tap too, so the single tap resolves
      // only after kDoubleTapTimeout (~300ms).
      await tester.tapAt(tester.getCenter(find.byType(EmbeddedPlayerControls)));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Stream information'), findsNothing);
    });
  });

  group('auto-hide pinning', () {
    // Regression: the 4 s hide timer used to survive an open menu. `_show(keep:
    // true)` skipped *re-arming* it but never cancelled the one already
    // running, so opening a track menu a second after the chrome appeared let
    // the bars disappear three seconds later — taking the open menu's own
    // button out of the tree. `PopupMenuButton` guards its result callback on
    // `mounted`, so that silently discarded the user's selection *and* left the
    // pin flag stuck true, after which the overlay never auto-hid again for the
    // rest of the route.
    testWidgets('an open track menu keeps the chrome up past the hide delay', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: false,
        state: const PlayerState(
          playing: true,
          tracks: Tracks(
            audio: [AudioTrack('1', null, 'eng'), AudioTrack('2', null, 'fra')],
          ),
        ),
      );

      // Let the initial reveal arm its timer, then open the menu partway
      // through — the ordering that used to lose the race.
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byIcon(Icons.audiotrack));
      await tester.pump();
      expect(find.byType(PopupMenuItem<String>), findsWidgets);

      // Well past the 4 s hide delay measured from the original reveal.
      await tester.pump(const Duration(seconds: 6));

      expect(
        find.byIcon(Icons.audiotrack),
        findsOneWidget,
        reason: 'the bars must not be torn out from under an open menu',
      );
      expect(find.byType(PopupMenuItem<String>), findsWidgets);
    });

    testWidgets('and hides again once the menu closes', (tester) async {
      await pumpOverlay(
        tester,
        isLive: false,
        state: const PlayerState(
          playing: true,
          tracks: Tracks(
            audio: [AudioTrack('1', null, 'eng'), AudioTrack('2', null, 'fra')],
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.audiotrack));
      await tester.pump();
      await tester.tap(find.byType(PopupMenuItem<String>).first);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.pump(const Duration(seconds: 6));
      expect(
        find.byIcon(Icons.audiotrack),
        findsNothing,
        reason: 'a stuck pin would keep the chrome up forever',
      );
    });
  });

  // The Windows SDR (embedded) surface and the Windows native GDI surface show
  // the *same* channel to the same user depending only on whether the stream is
  // HDR, so their live chrome has to agree. These pin the structure the three
  // native overlays share — Kotlin `LiveEpgStrip`, iOS `epgStrip`, the GDI
  // `epg_title`/`epg_time`/`epg_progress`/`epg_next` rects — which this overlay
  // used to contradict: it compacted now/next into one line under the *title*
  // and put a `LIVE ▸ bar ▸ title` row where the strip belongs.
  group('live EPG strip (parity with the native overlays)', () {
    testWidgets('now/next render as a three-row strip in the bottom bar', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: true,
        epgNow: _programme('News at Nine'),
        epgNext: _programme('Late Film', startHour: 21, stopHour: 23),
      );

      // Row 1: programme title + its own range. Row 3: the next programme,
      // labelled the way every other overlay labels it.
      expect(find.text('News at Nine'), findsOneWidget);
      expect(find.text('20:00 – 21:00'), findsOneWidget);
      expect(find.text('Next · 21:00 – 23:00 · Late Film'), findsOneWidget);

      final title = tester.getRect(find.text('News at Nine'));
      final progress = tester.getRect(find.byType(LinearProgressIndicator));
      final next = tester.getRect(
        find.text('Next · 21:00 – 23:00 · Late Film'),
      );
      final transport = tester.getRect(find.byIcon(Icons.play_arrow));

      // Stacked in that order, above the transport row.
      expect(title.bottom, lessThanOrEqualTo(progress.top));
      expect(progress.bottom, lessThanOrEqualTo(next.top));
      expect(next.bottom, lessThanOrEqualTo(transport.top));

      // The range is right-aligned against the strip; the bar spans it.
      final range = tester.getRect(find.text('20:00 – 21:00'));
      expect(range.left, greaterThan(title.right - 1));
      expect(progress.width, greaterThan(range.right - title.left - 1));
    });

    testWidgets('the LIVE pill sits in the top-bar badge cluster, not the '
        'strip', (tester) async {
      await pumpOverlay(
        tester,
        isLive: true,
        sourceName: 'Provider Network HD',
        epgNow: _programme('News at Nine'),
      );

      final live = tester.getRect(find.text('LIVE'));
      final source = tester.getRect(find.text('Provider Network HD'));
      final strip = tester.getRect(find.text('News at Nine'));

      expect(
        live.bottom,
        lessThan(strip.top),
        reason: 'top bar, not the strip',
      );
      // Native badge order is source, LIVE, resolution, HDR, fps, clock.
      expect(source.right, lessThanOrEqualTo(live.left));
      expect(
        tester.getRect(find.byIcon(Icons.arrow_back)).right,
        lessThan(source.left),
      );
    });

    testWidgets('a live channel with no guide drops the strip but keeps the '
        'LIVE pill', (tester) async {
      await pumpOverlay(tester, isLive: true);

      expect(find.text('LIVE'), findsOneWidget);
      expect(
        find.byType(LinearProgressIndicator),
        findsNothing,
        reason: 'a bar frozen at 0.0 reads as "still loading" forever',
      );
    });
  });

  // The badges say the same thing on every surface or they say nothing useful:
  // a Windows user meets this overlay on an SDR channel and the GDI one on an
  // HDR channel, and used to be told `3840×2160`/`50.00 FPS`/`SDR` on one and
  // `4K`/`50fps`/nothing on the other.
  group('badge labels (shared with the native overlays)', () {
    test('resolution tiers are the loose ones every overlay uses', () {
      expect(resolutionBadgeLabel(width: 3840, height: 2160), '4K');
      expect(resolutionBadgeLabel(width: 2560, height: 1440), '1440p');
      expect(resolutionBadgeLabel(width: 1920, height: 1080), '1080p');
      // The cases the old exact `h >= 1080` / `h >= 720` tests got wrong.
      expect(resolutionBadgeLabel(width: 1920, height: 1088), '1080p');
      expect(resolutionBadgeLabel(width: 1280, height: 718), '720p');
      expect(resolutionBadgeLabel(width: 720, height: 576), 'SD');
      expect(resolutionBadgeLabel(width: 0, height: 0), isNull);
      expect(resolutionBadgeLabel(width: null, height: 1080), isNull);
    });

    test('the HDR badge is compact, and SDR shows nothing at all', () {
      expect(hdrBadgeLabel('HDR10+ · PQ'), 'HDR10+');
      expect(hdrBadgeLabel('HDR10 · PQ'), 'HDR10');
      expect(hdrBadgeLabel('HLG'), 'HLG');
      expect(hdrBadgeLabel('HDR · BT.2020'), 'HDR');
      expect(hdrBadgeLabel('Dolby Vision'), 'DV');
      expect(hdrBadgeLabel('SDR'), isNull);
      expect(hdrBadgeLabel(''), isNull);
    });

    test('fps drops trailing zeros and the space', () {
      expect(fpsBadgeLabel(50), '50fps');
      expect(fpsBadgeLabel(23.976), '23.976fps');
      expect(fpsBadgeLabel(29.97), '29.97fps');
      expect(fpsBadgeLabel(0), isNull);
      expect(fpsBadgeLabel(null), isNull);
    });

    test('a long source name is truncated at 20', () {
      expect(sourceBadgeLabel('  CandyCloud '), 'CandyCloud');
      expect(
        sourceBadgeLabel('A Provider With A Very Long Name'),
        'A Provider With A V…',
      );
      expect(sourceBadgeLabel('   '), isNull);
      expect(sourceBadgeLabel(null), isNull);
    });

    test('the clock is dated on pointer surfaces and bare under touch', () {
      final when = DateTime(2026, 8, 8, 16, 2);
      expect(playerClockLabel(when, dated: true), 'Sat 8 Aug · 16:02');
      expect(playerClockLabel(when, dated: false), '16:02');
    });

    testWidgets('the overlay renders the compact forms, not raw values', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: false,
        sourceName: 'CandyCloud',
        state: const PlayerState(
          videoParams: VideoParams(w: 1920, h: 1080),
          tracks: Tracks(
            video: [VideoTrack('1', null, null, codec: 'hevc', fps: 25)],
          ),
        ),
        dynamicRangeLabel: (_) => 'SDR',
      );

      expect(find.text('1080p'), findsOneWidget);
      expect(find.text('25fps'), findsOneWidget);
      expect(find.text('CandyCloud'), findsOneWidget);
      expect(find.text('1920×1080'), findsNothing);
      expect(find.text('SDR'), findsNothing);
    });
  });

  // Phase 3 of in-player live zapping: the shared Flutter overlay's own
  // render of the zap banner (docs/player.md "Live zapping"). Mirrors the
  // Kotlin `PlayerControls.kt`/`PlayerUiState.kt` zap-banner tests.
  group('zap banner', () {
    testWidgets('chrome hidden, a revision bump shows the card and the '
        'identity label, not the bars', (tester) async {
      await pumpOverlay(
        tester,
        isLive: true,
        state: const PlayerState(playing: true),
      );
      // Let the chrome auto-hide first, with no zap yet.
      await tester.pump(const Duration(seconds: 5));
      expect(find.byIcon(Icons.pause), findsNothing);

      await pumpOverlay(
        tester,
        isLive: true,
        state: const PlayerState(playing: true),
        zap: _zap(revision: 1, channelNumber: 12, channelName: 'BBC One'),
      );
      await tester.pump();

      expect(find.text('12 · BBC One'), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing, reason: 'bars stay down');
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('a half-typed digit buffer keeps the banner up without a '
        'revision bump', (tester) async {
      await pumpOverlay(
        tester,
        isLive: true,
        state: const PlayerState(playing: true),
        zap: _zap(revision: 1, channelName: 'BBC One'),
      );
      // Hides the chrome and lets the plain dwell timer run out.
      await tester.pump(const Duration(seconds: 5));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0.0,
      );

      // Same revision — no bump — but a digit is now half-typed.
      await pumpOverlay(
        tester,
        isLive: true,
        state: const PlayerState(playing: true),
        zap: _zap(revision: 1, channelName: 'BBC One', digits: '1'),
      );
      await tester.pump();

      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1.0,
      );
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('a transient message keeps the banner up past the dwell '
        'timer', (tester) async {
      await pumpOverlay(
        tester,
        isLive: true,
        state: const PlayerState(playing: true),
        zap: _zap(revision: 1, message: "Couldn't play Channel B"),
      );
      // Well past both the chrome auto-hide and the plain 3s dwell.
      await tester.pump(const Duration(seconds: 5));

      expect(find.byIcon(Icons.pause), findsNothing);
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1.0,
        reason: 'a transient note outlives the plain timer',
      );
      expect(find.text("Couldn't play Channel B"), findsOneWidget);
    });

    testWidgets('a plain cursor move fades the banner after its own 3s '
        'dwell timer', (tester) async {
      await pumpOverlay(
        tester,
        isLive: true,
        state: const PlayerState(playing: true),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(find.byIcon(Icons.pause), findsNothing);

      // A cursor move arrives once the chrome is already hidden.
      await pumpOverlay(
        tester,
        isLive: true,
        state: const PlayerState(playing: true),
        zap: _zap(revision: 1, channelNumber: 12, channelName: 'BBC One'),
      );
      await tester.pump();
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1.0,
      );

      await tester.pump(const Duration(milliseconds: 2900));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1.0,
        reason: 'still inside the 3s dwell',
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0.0,
      );
    });

    testWidgets('VOD, or a live stream with no zap, renders no banner at '
        'all', (tester) async {
      await pumpOverlay(
        tester,
        isLive: false,
        state: const PlayerState(playing: true),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(AnimatedOpacity), findsNothing);

      // Live but zap == null (VOD/catch-up/no-range shape).
      await pumpOverlay(
        tester,
        isLive: true,
        state: const PlayerState(playing: true),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(AnimatedOpacity), findsNothing);
    });

    testWidgets('chrome visible: no identity run in the bar with only a '
        'name, one more with a number, and the bar strip stays the playing '
        'programme', (tester) async {
      final playing = _programme('Playing Now');
      final cursor = _programme('Cursor Now', startHour: 21, stopHour: 22);

      // Only a name — nothing the ordinary title doesn't already say — so
      // `showsIdentity` is false and the bottom bar draws no extra run. The
      // banner (built off-screen at opacity 0 while chrome is visible) still
      // carries its own copy, so exactly one match exists.
      await pumpOverlay(
        tester,
        isLive: true,
        epgNow: playing,
        zap: _zap(revision: 1, channelName: 'BBC One', epgNow: cursor),
      );
      expect(find.text('BBC One'), findsOneWidget);
      expect(find.text('Playing Now'), findsOneWidget);

      // With a number, `showsIdentity` is true: the bottom bar draws its own
      // run *beside* the banner's, so the label now matches twice.
      await pumpOverlay(
        tester,
        isLive: true,
        epgNow: playing,
        zap: _zap(
          revision: 1,
          channelNumber: 12,
          channelName: 'BBC One',
          epgNow: cursor,
        ),
      );
      expect(find.text('12 · BBC One'), findsNWidgets(2));
      expect(find.text('Playing Now'), findsOneWidget);
    });

    testWidgets('the banner strip shows the cursor programme while the '
        'bottom bar strip shows the one actually playing', (tester) async {
      final playing = _programme('Playing Now');
      final cursor = _programme('Cursor Now', startHour: 21, stopHour: 22);

      await pumpOverlay(
        tester,
        isLive: true,
        epgNow: playing,
        zap: _zap(
          revision: 1,
          channelNumber: 12,
          channelName: 'BBC One',
          epgNow: cursor,
        ),
      );

      // Chrome starts visible: the bar shows the *playing* channel's guide.
      expect(find.text('Playing Now'), findsOneWidget);
      // The banner already carries the *cursor's* guide — proof the two
      // never share one strip.
      expect(find.text('Cursor Now'), findsOneWidget);
    });
  });

  // Phase 6: the shared Flutter overlay's render of the quick list
  // (docs/player.md "The quick list (Phase 6)"). A selection model —
  // one selected index, rows that are not focus targets, an explicit
  // itemExtent — drawn from a pure [ZapQuickListState] and nothing else.
  group('quick list', () {
    testWidgets('draws the heading, the window and the cursor', (tester) async {
      await pumpOverlay(
        tester,
        isLive: true,
        quickList: _quickList(
          heading: 'Sport',
          labels: const ['One', 'Two', 'Three'],
          selectedIndex: 1,
        ),
      );
      expect(find.text('Sport'), findsOneWidget);
      expect(find.text('One'), findsOneWidget);
      expect(find.text('Two'), findsOneWidget);
      expect(find.text('Three'), findsOneWidget);
      // The position readout is absolute, so a windowed list still says
      // where in the whole range the cursor is.
      expect(find.text('2/3'), findsOneWidget);
    });

    testWidgets('a windowed cursor reports its absolute position', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: true,
        quickList: _quickList(
          heading: 'All channels',
          labels: List.generate(kZapWindowRows, (i) => 'Row ${1200 + i}'),
          selectedIndex: 1210,
          windowStart: 1200,
          total: 250000,
        ),
      );
      expect(find.text('1211/250000'), findsOneWidget);
      expect(find.text('Row 1210'), findsOneWidget);
    });

    testWidgets('the rows use one explicit itemExtent', (tester) async {
      await pumpOverlay(
        tester,
        isLive: true,
        quickList: _quickList(labels: const ['One', 'Two']),
      );
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(
        list.itemExtent,
        isNotNull,
        reason:
            'index→offset must be exact — the selection-model rule every '
            'long D-pad list in this app follows',
      );
    });

    testWidgets('never becomes a focus target', (tester) async {
      await pumpOverlay(
        tester,
        isLive: true,
        quickList: _quickList(labels: const ['One', 'Two']),
      );
      // The list is a readout driven by the route's key bindings, exactly
      // like the zap banner; a focusable row would fight them.
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Focus),
        ),
        findsNothing,
      );
    });

    testWidgets('an empty mode says why, and a loading one spins', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: true,
        quickList: const ZapQuickListState(
          open: true,
          mode: ZapQuickListMode.schedule,
          heading: 'BBC One',
          rows: <ZapQuickListRow>[],
          selectedIndex: 0,
          windowStart: 0,
          total: 0,
          emptyLabel: 'No guide for today',
        ),
      );
      expect(find.text('No guide for today'), findsOneWidget);

      await pumpOverlay(
        tester,
        isLive: true,
        quickList: const ZapQuickListState(
          open: true,
          mode: ZapQuickListMode.channels,
          heading: 'All channels',
          rows: <ZapQuickListRow>[],
          selectedIndex: 0,
          windowStart: 0,
          total: 0,
          loading: true,
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('a closed list, VOD, and a null list all draw nothing', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: true,
        quickList: ZapQuickListState.closed,
      );
      expect(find.text('One'), findsNothing);

      await pumpOverlay(
        tester,
        isLive: false,
        quickList: _quickList(labels: const ['One']),
      );
      expect(find.text('One'), findsNothing);

      await pumpOverlay(tester, isLive: true);
      expect(find.byType(ListView), findsNothing);
    });

    // The pointer/touch half of the opener: `G`/`GUIDE`/D-pad Left are the
    // key halves, and before this button a mouse could not open the list at
    // all. The slot rule is identical on all four surfaces — right cluster,
    // immediately LEFT of "Go to live", which itself sits left of the star.
    testWidgets('the quick-list button sits immediately left of "Go to '
        'live", ahead of the favorite star', (tester) async {
      await pumpOverlay(
        tester,
        isLive: true,
        liveSynced: false,
        canFavorite: true,
        zapEnabled: true,
        onOpenQuickList: () {},
      );
      final list = find.byIcon(Icons.format_list_bulleted);
      expect(list, findsOneWidget);
      final listX = tester.getCenter(list).dx;
      final goLiveX = tester.getCenter(find.text('Go to live')).dx;
      final starX = tester
          .getCenter(find.byIcon(Icons.star_outline_rounded))
          .dx;
      expect(listX, lessThan(goLiveX));
      expect(goLiveX, lessThan(starX));
      // One row: it takes the control row's ordinary geometry, like the star.
      expect(
        tester.getCenter(list).dy,
        tester.getCenter(find.byIcon(Icons.settings_outlined)).dy,
      );
    });

    testWidgets('the quick-list button is absent on VOD and off a zapping '
        'route, and pressing it opens the list', (tester) async {
      await pumpOverlay(tester, isLive: true);
      expect(find.byIcon(Icons.format_list_bulleted), findsNothing);

      await pumpOverlay(
        tester,
        isLive: false,
        zapEnabled: true,
        onOpenQuickList: () {},
      );
      expect(find.byIcon(Icons.format_list_bulleted), findsNothing);

      var opens = 0;
      await pumpOverlay(
        tester,
        isLive: true,
        zapEnabled: true,
        onOpenQuickList: () => opens++,
      );
      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await tester.pump();
      expect(opens, 1);
    });

    testWidgets('opening the list stands the chrome down', (tester) async {
      // The list claims the arrows and Back whatever the chrome is doing, so
      // a control row left up behind it strands the D-pad — every other
      // surface hides it on the closed→open edge.
      final key = GlobalKey<EmbeddedPlayerControlsState>();
      await pumpOverlay(
        tester,
        isLive: true,
        zapEnabled: true,
        onOpenQuickList: () {},
        quickList: ZapQuickListState.closed,
        controlsKey: key,
      );
      expect(key.currentState!.chromeVisible, isTrue);

      await pumpOverlay(
        tester,
        isLive: true,
        zapEnabled: true,
        onOpenQuickList: () {},
        quickList: _quickList(labels: const ['One']),
        controlsKey: key,
      );
      expect(key.currentState!.chromeVisible, isFalse);
      expect(find.text('One'), findsOneWidget);
    });

    for (final size in const [Size(960, 540), Size(1266, 714)]) {
      testWidgets('the list owns hover, taps and focus at $size', (
        tester,
      ) async {
        final key = GlobalKey<EmbeddedPlayerControlsState>();
        final commands = <ZapCommand>[];
        var plays = 0;
        var fullscreen = 0;
        await pumpOverlay(
          tester,
          isLive: true,
          width: size.width,
          height: size.height,
          epgNow: _programme('On screen now'),
          controlsKey: key,
          onPlayPause: () => plays++,
          onToggleFullscreen: () => fullscreen++,
        );
        final play = find.byIcon(Icons.play_arrow);
        final oldPlayCenter = tester.getCenter(play);
        final playFocus = Focus.of(tester.element(play));
        playFocus.requestFocus();
        await tester.pump();
        expect(playFocus.hasPrimaryFocus, isTrue);
        key.currentState!.toggleInfo();
        await tester.pump();
        expect(find.text('Stream information'), findsOneWidget);

        await pumpOverlay(
          tester,
          isLive: true,
          width: size.width,
          height: size.height,
          epgNow: _programme('On screen now'),
          controlsKey: key,
          quickList: _quickList(labels: const ['One', 'Two', 'Three']),
          onQuickListCommand: commands.add,
          onPlayPause: () => plays++,
          onToggleFullscreen: () => fullscreen++,
        );

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset(size.width - 40, 180));
        addTearDown(mouse.removePointer);
        await mouse.moveTo(const Offset(200, 40));
        key.currentState!.revealChrome();
        key.currentState!.toggleInfo();
        await tester.pump();

        expect(key.currentState!.chromeVisible, isFalse);
        expect(find.text('Channel One'), findsNothing);
        expect(find.text('On screen now'), findsNothing);
        expect(find.byIcon(Icons.play_arrow), findsNothing);
        expect(find.byIcon(Icons.settings_outlined), findsNothing);
        expect(find.text('Stream information'), findsNothing);
        expect(FocusManager.instance.primaryFocus, isNot(same(playFocus)));

        final panel = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('player.quickList.panel')),
        );
        expect((panel.decoration as BoxDecoration).color!.a, 1);
        expect(find.text('Categories › Channels'), findsOneWidget);
        expect(find.text('One').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Blank panel space must neither activate the removed controls nor
        // pass through and close/reveal the surface.
        final pane = tester.getRect(
          find.byKey(const ValueKey('player.quickList.panel')),
        );
        await tester.tapAt(Offset(pane.left + 20, oldPlayCenter.dy));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(commands, isEmpty);
        expect(plays, 0);
        expect(key.currentState!.chromeVisible, isFalse);

        // Outside the pane, a tap closes only the list through the same
        // command path as Guide/G; it cannot activate the old fullscreen chip.
        await tester.tapAt(Offset(size.width - 40, size.height - 40));
        await tester.pump();
        expect(commands, const [ZapCommand(ZapCommandKind.closeList)]);
        expect(fullscreen, 0);
        expect(plays, 0);

        await pumpOverlay(
          tester,
          isLive: true,
          width: size.width,
          height: size.height,
          controlsKey: key,
          quickList: ZapQuickListState.closed,
        );
        key.currentState!.revealChrome();
        await tester.pump();
        expect(find.byType(ListView), findsNothing);
        expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      });
    }

    testWidgets('an initially open list keeps playing and owns the cursor', (
      tester,
    ) async {
      final commands = <ZapCommand>[];
      final controls = await pumpOverlay(
        tester,
        isLive: true,
        state: const PlayerState(playing: true),
        onQuickListCommand: commands.add,
        quickList: const ZapQuickListState(
          open: true,
          mode: ZapQuickListMode.channels,
          heading: 'News',
          selectedIndex: 1201,
          windowStart: 1200,
          total: 250000,
          rows: [
            ZapQuickListRow(
              index: 1200,
              id: 'playing',
              label: '7 · Playing channel',
              secondary: 'Current programme',
              kind: ZapQuickListRowKind.channel,
              playing: true,
              // Stale row flags must never override the canonical cursor.
              selected: true,
            ),
            ZapQuickListRow(
              index: 1201,
              id: 'cursor',
              label: '8 · Selected channel',
              secondary: 'Another programme',
              kind: ZapQuickListRowKind.channel,
            ),
          ],
        ),
      );
      final cursor = find.byWidgetPredicate(
        (w) => w is Container && w.foregroundDecoration != null,
      );
      expect(cursor, findsOneWidget);
      expect(
        find.descendant(
          of: cursor,
          matching: find.text('8 · Selected channel'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: cursor,
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsNothing,
      );
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text('Current programme'), findsOneWidget);
      expect(find.text('1202/250000'), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing);
      expect(controls.state.playing, isTrue);

      await tester.tap(find.text('7 · Playing channel'));
      await tester.pump();
      expect(commands, const [
        ZapCommand(ZapCommandKind.move, -1),
        ZapCommand(ZapCommandKind.activate),
      ]);
      expect(controls.state.playing, isTrue);
    });

    testWidgets('guide, Back and Close use the existing command vocabulary', (
      tester,
    ) async {
      final commands = <ZapCommand>[];
      await pumpOverlay(
        tester,
        isLive: true,
        quickList: _quickList(labels: const ['One', 'Two', 'Three']),
        onQuickListCommand: commands.add,
      );

      await tester.tap(find.byIcon(Icons.chevron_right_rounded).at(2));
      await tester.pump();
      expect(commands, const [
        ZapCommand(ZapCommandKind.move, 2),
        ZapCommand(ZapCommandKind.descend),
      ]);
      commands.clear();
      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await tester.pump();
      expect(commands, const [ZapCommand(ZapCommandKind.back)]);
      commands.clear();
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(commands, const [ZapCommand(ZapCommandKind.closeList)]);
      // Commands cannot optimistically rewrite the mode or close the pane;
      // only the next authoritative snapshot may change its presentation.
      expect(find.text('One'), findsOneWidget);
    });

    testWidgets('the zap banner yields to the list', (tester) async {
      // Both live in the lower-left; drawn together they would print the
      // cursor's channel twice, from two different cursors.
      await pumpOverlay(
        tester,
        isLive: true,
        zap: _zap(revision: 1, channelName: 'BBC One', message: 'Hello'),
        quickList: _quickList(labels: const ['One']),
      );
      await tester.pump(const Duration(seconds: 5));
      final banner = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity).first,
      );
      expect(banner.opacity, 0);
    });
  });

  // The app-wide ladder: menu → info → hide chrome → exit (docs/development.md,
  // docs/tv-navigation.md). This used to peel the info panel *only*, so on
  // the Windows SDR live surface Escape with the chrome up skipped straight
  // out to the channel list — two rungs in one press.
  group('the Back/Escape ladder peels one rung per press', () {
    testWidgets('info → hide chrome → exit', (tester) async {
      final key = GlobalKey<EmbeddedPlayerControlsState>();
      await pumpOverlay(tester, isLive: true, controlsKey: key);
      final state = key.currentState!;

      state.toggleInfo();
      await tester.pump();
      expect(find.text('Stream information'), findsOneWidget);

      // Rung 1: the info panel, chrome untouched.
      expect(state.handleBackPeel(), isTrue);
      await tester.pump();
      expect(find.text('Stream information'), findsNothing);
      expect(state.chromeVisible, isTrue);

      // Rung 2: the visible chrome.
      expect(state.handleBackPeel(), isTrue);
      await tester.pump();
      expect(state.chromeVisible, isFalse);

      // Rung 3: nothing left — the route exits.
      expect(state.handleBackPeel(), isFalse);
    });

    testWidgets('with the chrome already hidden, one press exits', (
      tester,
    ) async {
      final key = GlobalKey<EmbeddedPlayerControlsState>();
      await pumpOverlay(
        tester,
        isLive: true,
        // `_scheduleHide` only arms while playing — a paused player keeps its
        // chrome, which is the whole reason the reveal-on-input rule exists.
        state: const PlayerState(playing: true),
        controlsKey: key,
      );
      final state = key.currentState!;
      // The chrome auto-hides after 4 s; PlayerScreen's Escape binding
      // deliberately does not reveal it first, or this rung could never be
      // reached.
      await tester.pump(const Duration(seconds: 5));
      expect(state.chromeVisible, isFalse);
      expect(state.handleBackPeel(), isFalse);
    });
  });
}

ZapQuickListState _quickList({
  String heading = 'All channels',
  ZapQuickListMode mode = ZapQuickListMode.channels,
  List<String> labels = const ['One'],
  int selectedIndex = 0,
  int windowStart = 0,
  int? total,
}) => ZapQuickListState(
  open: true,
  mode: mode,
  heading: heading,
  rows: [
    for (var i = 0; i < labels.length; i++)
      ZapQuickListRow(
        index: windowStart + i,
        id: 'r${windowStart + i}',
        label: labels[i],
        kind: ZapQuickListRowKind.channel,
        selected: windowStart + i == selectedIndex,
      ),
  ],
  selectedIndex: selectedIndex,
  windowStart: windowStart,
  total: total ?? labels.length,
);

ZapBannerState _zap({
  required int revision,
  int? channelNumber,
  String channelName = 'BBC One',
  String? logoUrl,
  String digits = '',
  String? message,
  int position = 0,
  int total = 0,
  Programme? epgNow,
  Programme? epgNext,
}) => ZapBannerState(
  revision: revision,
  channelNumber: channelNumber,
  channelName: channelName,
  logoUrl: logoUrl,
  digits: digits,
  message: message,
  position: position,
  total: total,
  epgNow: epgNow,
  epgNext: epgNext,
);

Programme _programme(String title, {int startHour = 20, int stopHour = 21}) =>
    Programme(
      channelId: 'c1',
      start: DateTime(2026, 1, 1, startHour),
      stop: DateTime(2026, 1, 1, stopHour),
      title: title,
    );

/// Pure [EmbeddedControls] stub — no libmpv. Only the streams the overlay
/// actually listens to carry real broadcast controllers; the rest are empty
/// (`Stream<Never>` is assignable to any `Stream<T>`), and mutating state is
/// injected via [PlayerState].
class _StubControls implements EmbeddedControls {
  _StubControls({this.state = const PlayerState()});

  @override
  final PlayerState state;

  final _playing = StreamController<bool>.broadcast();
  final _tracks = StreamController<Tracks>.broadcast();
  final _track = StreamController<Track>.broadcast();
  final _videoParams = StreamController<VideoParams>.broadcast();
  final _volume = StreamController<double>.broadcast();
  final _position = StreamController<Duration>.broadcast();

  @override
  late final PlayerStream stream = PlayerStream(
    const Stream<Never>.empty(), // playlist
    _playing.stream,
    const Stream<Never>.empty(), // completed
    _position.stream,
    const Stream<Never>.empty(), // duration
    _volume.stream,
    const Stream<Never>.empty(), // rate
    const Stream<Never>.empty(), // pitch
    const Stream<Never>.empty(), // buffering
    const Stream<Never>.empty(), // bufferingPercentage
    const Stream<Never>.empty(), // buffer
    const Stream<Never>.empty(), // playlistMode
    const Stream<Never>.empty(), // shuffle
    const Stream<Never>.empty(), // audioParams
    _videoParams.stream,
    const Stream<Never>.empty(), // audioBitrate
    const Stream<Never>.empty(), // audioDevice
    const Stream<Never>.empty(), // audioDevices
    _track.stream,
    _tracks.stream,
    const Stream<Never>.empty(), // width
    const Stream<Never>.empty(), // height
    const Stream<Never>.empty(), // subtitle
    const Stream<Never>.empty(), // log
    const Stream<Never>.empty(), // error
  );

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> seek(Duration to) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  Future<void> dispose() async {
    await _playing.close();
    await _tracks.close();
    await _track.close();
    await _videoParams.close();
    await _volume.close();
    await _position.close();
  }
}
