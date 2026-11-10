import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/player/mpv_options.dart';

/// Pure-logic coverage for the shared live-reconnect backoff policy
/// (`reconnectMinGapMs`), the Dart mirror of Android's
/// `ReconnectPolicy.minGapMs`. The embedded/Windows watchdog and the
/// Linux-native IPC watchdog both go through this, so all three platforms back
/// off identically. Mirrors `android/.../player/ReconnectPolicyTest.kt`.
void main() {
  test('ffmpeg does not multiply the host reconnect budget', () {
    expect(kLiveMpvOptions['ytdl'], 'no');
    expect(kLiveMpvOptions['stream-lavf-o'], 'reconnect=0,reconnect_streamed=0');
    expect(kLiveMpvOptions['demuxer-lavf-o'], contains('seg_max_retry=0'));
    expect(kLiveMpvOptions['demuxer-lavf-o'], contains('http_multiple=0'));
    expect(kProviderMpvDemuxerOptions, contains('http_multiple=0'));
    expect(kLiveMpvOptions['stream-lavf-o'], isNot(contains('reconnect_at_eof')));
  });
  test('a media refusal pauses other requests on its host', () {
    recordPlaybackProviderRejection('https://media-refusal.example.test/live', 429);
    expect(
      () => ProviderRequestGate.instance.check(
        Uri.parse('http://media-refusal.example.test:8080/player_api.php'),
      ),
      throwsA(isA<ProviderRequestBlocked>().having((error) => error.status, 'status', 429)),
    );
  });
  group('automatic reconnect budget', () {
    test('backoff waiting cannot reset the three attempt limit', () {
      final budget = LiveReconnectBudget();
      for (var attempt = 0; attempt < 3; attempt++) {
        expect(budget.recordAttempt(), isTrue);
        // A delayed timer or one new sample is not sustained playback.
        budget.observe(
          nowMs: attempt * 60000,
          positionMs: 0,
          healthy: true,
        );
      }
      expect(budget.attempts, 3);
      expect(budget.recordAttempt(), isFalse);
    });

    test('only thirty seconds of continuous playback progress restore retries', () {
      final budget = LiveReconnectBudget()..recordAttempt();
      for (var time = 0; time < 30000; time += 1000) {
        budget.observe(nowMs: time, positionMs: time, healthy: true);
      }
      expect(budget.attempts, 1);
      budget.observe(nowMs: 30000, positionMs: 30000, healthy: true);
      expect(budget.attempts, 0);
    });

    test('stalling or a gap in observations interrupts healthy recovery', () {
      final budget = LiveReconnectBudget()..recordAttempt();
      for (var time = 0; time <= 20000; time += 1000) {
        budget.observe(nowMs: time, positionMs: time, healthy: true);
      }
      budget.observe(nowMs: 21000, positionMs: 20000, healthy: false);
      for (var time = 22000; time <= 42000; time += 1000) {
        budget.observe(nowMs: time, positionMs: time, healthy: true);
      }
      expect(budget.attempts, 1);
      budget.observe(nowMs: 100000, positionMs: 100000, healthy: true);
      expect(budget.attempts, 1);
    });

    test('provider rejection remains terminal until an explicit reset', () {
      final budget = LiveReconnectBudget()..reject();
      for (var time = 0; time <= 60000; time += 1000) {
        budget.observe(nowMs: time, positionMs: time, healthy: true);
      }
      expect(budget.recordAttempt(), isFalse);
      budget.reset();
      expect(budget.recordAttempt(), isTrue);
    });
  });

  test('HTTP refusal detection does not match unrelated codec/channel numbers', () {
    for (final status in [401, 403, 429]) {
      expect(playbackProviderRejectionStatus('HTTP error $status'), status);
      expect(playbackProviderRejectionStatus('status code: $status'), status);
      expect(
        playbackProviderRejectionStatus(ProviderRequestBlocked(
          status: status,
          retryAt: DateTime.utc(2026),
        )),
        status,
      );
    }
    expect(playbackProviderRejectionStatus('codec 403 failed'), isNull);
    expect(playbackProviderRejectionStatus('channel 429 ended'), isNull);
    expect(playbackProviderRejectionStatus('HTTP error 503'), isNull);
  });

  group('reconnectMinGapMs', () {
    test('first attempt waits one stall interval', () {
      expect(
        reconnectMinGapMs(priorAttempts: 0, force: false),
        kReconnectStallMs,
      );
    });

    test('backoff grows with each prior attempt', () {
      expect(
        reconnectMinGapMs(priorAttempts: 1, force: false),
        kReconnectStallMs * 2,
      );
      expect(
        reconnectMinGapMs(priorAttempts: 2, force: false),
        kReconnectStallMs * 3,
      );
    });

    test('backoff is capped at the maximum', () {
      expect(
        reconnectMinGapMs(priorAttempts: 3, force: false),
        kReconnectMaxBackoffMs,
      );
      expect(
        reconnectMinGapMs(priorAttempts: 10, force: false),
        kReconnectMaxBackoffMs,
      );
    });

    test('a forced reconnect always uses the base stall threshold', () {
      expect(
        reconnectMinGapMs(priorAttempts: 5, force: true),
        kReconnectStallMs,
      );
    });
  });

  group('shouldReconnectOnCompleted', () {
    // A clean server-side EOF maps to completed=true with buffering=false, so
    // the buffering-gated stall watchdog can never see it — live must treat
    // it as a drop (parity with the Linux-native end-file drop signal).
    test('live clean EOF on the embedded/Windows path reconnects', () {
      expect(
        shouldReconnectOnCompleted(
          completed: true,
          isLive: true,
          nativeSessionActive: false,
        ),
        isTrue,
      );
    });

    test('VOD completing is a legitimate end of playback', () {
      expect(
        shouldReconnectOnCompleted(
          completed: true,
          isLive: false,
          nativeSessionActive: false,
        ),
        isFalse,
      );
    });

    test('ignored while a separate engine owns playback and the embedded '
        'player is idle (Linux native mpv / Android native Activity)', () {
      // `nativeSessionActive` is true only when the media_kit `_player` sits
      // idle behind a separate engine — its `completed` describes a stopped
      // engine, not the stream.
      expect(
        shouldReconnectOnCompleted(
          completed: true,
          isLive: true,
          nativeSessionActive: true,
        ),
        isFalse,
      );
    });

    test('Windows native HDR-live reconnects on a clean EOF (the same _player '
        'plays through the HWND, so nativeSessionActive stays false)', () {
      // On Windows the native HWND path renders through the SAME media_kit
      // `_player` (a `vo` swap, no separate engine), so its `completed` is a
      // genuine live drop. `_PlayerScreenState` derives `nativeSessionActive`
      // from `_separateEngineOwnsPlayback`, which excludes Windows by design —
      // so the reconnect fires (and `_reconnectLive` reopens `_player` on the
      // HWND surface).
      expect(
        shouldReconnectOnCompleted(
          completed: true,
          isLive: true,
          nativeSessionActive: false,
        ),
        isTrue,
      );
    });

    test('completed=false (open/stop resets) never reconnects', () {
      expect(
        shouldReconnectOnCompleted(
          completed: false,
          isLive: true,
          nativeSessionActive: false,
        ),
        isFalse,
      );
    });
  });

  group('shouldReloadStalledLive', () {
    test('a buffering stall waits out the stall threshold', () {
      expect(
        shouldReloadStalledLive(
          buffering: true,
          endedPending: false,
          stalledForMs: kReconnectStallMs - 1,
        ),
        isFalse,
      );
      expect(
        shouldReloadStalledLive(
          buffering: true,
          endedPending: false,
          stalledForMs: kReconnectStallMs,
        ),
        isTrue,
      );
    });

    test('healthy playback never reloads', () {
      expect(
        shouldReloadStalledLive(
          buffering: false,
          endedPending: false,
          stalledForMs: 60000,
        ),
        isFalse,
      );
    });

    test('a pending EOF reloads immediately, with no stall threshold', () {
      // Nothing is recoverable at EOF: mpv sits at `eof-reached` and no amount
      // of waiting produces another byte.
      expect(
        shouldReloadStalledLive(
          buffering: false,
          endedPending: true,
          stalledForMs: 0,
        ),
        isTrue,
      );
    });

    test('an EOF the min-gap suppressed is still pending on the next tick — '
        'the regression this exists for', () {
      // The EOF listener is edge-triggered and `reconnectMinGapMs` is not, so
      // a `completed` arriving inside the rate-limit window used to be dropped
      // and never reconsidered: the poll read `buffering` only, which is
      // **false** at EOF. A stream that drops again within 8 s of the previous
      // reconnect — exactly what a provider cutting the link on a timer looks
      // like — stayed dead, with no indicator and no further attempt.
      // `_endedPending` makes it a level, like Android's sticky
      // `PlayerUiState.ended`, so every poll re-offers it until a reload
      // actually fires.
      const suppressed = 1000; // well inside reconnectMinGapMs
      expect(
        reconnectMinGapMs(priorAttempts: 1, force: true),
        greaterThan(suppressed),
        reason: 'the gap really does suppress this attempt',
      );
      expect(
        shouldReloadStalledLive(
          buffering: false,
          endedPending: true,
          stalledForMs: suppressed,
        ),
        isTrue,
        reason: 'the watchdog must keep offering it, not drop it',
      );
    });

    test('an EOF outranks the buffering clock rather than waiting on it', () {
      expect(
        shouldReloadStalledLive(
          buffering: true,
          endedPending: true,
          stalledForMs: 0,
        ),
        isTrue,
      );
    });
  });

  group('shouldApplyEmbeddedResume', () {
    const resume = Duration(minutes: 12);
    const duration = Duration(minutes: 90);

    test('seeks the embedded player once a real duration arrives', () {
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: resume,
          duration: duration,
          nativeSessionActive: false,
        ),
        isTrue,
      );
    });

    test('Windows native HDR VOD still resumes — the HWND surface is this '
        'same _player, so nativeSessionActive stays false', () {
      // The regression this pins: `_nativePlaybackLaunched` starts **true** on
      // Windows for every non-preview open (`_usesWindowsNativeSurface`), and
      // gating the resume seek on it suppressed the seek for every Windows VOD.
      // Positions were saved (`_persistPlaybackPosition` gates on Android/iOS
      // only) but never restored, so Continue Watching always restarted at 0.
      // `_separateEngineOwnsPlayback` excludes Windows, so the seek fires.
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: resume,
          duration: duration,
          nativeSessionActive: false,
        ),
        isTrue,
      );
    });

    test('a separate engine is never seeked here', () {
      // Android/iOS native players get the resume point in the `resumeMs` open
      // payload and the Linux native mpv process via `--start=`; this `_player`
      // is idle, so seeking it would do nothing but could clobber state.
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: resume,
          duration: duration,
          nativeSessionActive: true,
        ),
        isFalse,
      );
    });

    test('an unknown duration waits rather than seeking blind', () {
      // mpv reports 0 until the demuxer is ready; a cold seek there is dropped.
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: resume,
          duration: Duration.zero,
          nativeSessionActive: false,
        ),
        isFalse,
      );
    });

    test('no saved position means no seek', () {
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: null,
          duration: duration,
          nativeSessionActive: false,
        ),
        isFalse,
      );
    });

    test('a resume point at or past the end is ignored', () {
      // Guards a shorter re-resolved variant of the same title (and the
      // kFinishedFraction row that should have been cleared) from seeking to
      // EOF and instantly "completing".
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: duration,
          duration: duration,
          nativeSessionActive: false,
        ),
        isFalse,
      );
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: duration + const Duration(minutes: 1),
          duration: duration,
          nativeSessionActive: false,
        ),
        isFalse,
      );
    });
  });
}
