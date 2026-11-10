import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/adaptive_buffer.dart';
import 'package:iptvs/player/buffer_preset.dart';

void main() {
  test('startup buffering is ignored and one stall promotes one tier', () {
    final policy = AdaptiveBufferPolicy();
    expect(
      policy.observe(
        nowMs: 0,
        playing: false,
        buffering: true,
        ended: false,
        bufferAheadMs: 0,
      ),
      isNull,
    );
    expect(
      policy.observe(
        nowMs: 5000,
        playing: false,
        buffering: true,
        ended: false,
        bufferAheadMs: 0,
      ),
      isNull,
    );
    policy.observe(
      nowMs: 6000,
      playing: true,
      buffering: false,
      ended: false,
      bufferAheadMs: 12000,
    );

    expect(
      policy.observe(
        nowMs: 6100,
        playing: false,
        buffering: true,
        ended: false,
        bufferAheadMs: 0,
      ),
      isNull,
    );
    expect(
      policy.observe(
        nowMs: 7100,
        playing: false,
        buffering: true,
        ended: false,
        bufferAheadMs: 0,
      ),
      BufferPreset.high,
    );
    expect(
      policy.observe(
        nowMs: 30000,
        playing: false,
        buffering: true,
        ended: false,
        bufferAheadMs: 0,
      ),
      isNull,
      reason: 'one long stall may only promote once',
    );
    expect(policy.effectivePreset, BufferPreset.high);
  });

  test('separate confirmed stalls promote gradually and stop at max', () {
    final policy = AdaptiveBufferPolicy();
    policy.observe(
      nowMs: 0,
      playing: true,
      buffering: false,
      ended: false,
      bufferAheadMs: 12000,
    );
    expect(
      policy.observe(
        nowMs: 1000,
        playing: false,
        buffering: true,
        ended: false,
        bufferAheadMs: 0,
      ),
      isNull,
    );
    expect(
      policy.observe(
        nowMs: 2000,
        playing: false,
        buffering: true,
        ended: false,
        bufferAheadMs: 0,
      ),
      BufferPreset.high,
    );
    policy.observe(
      nowMs: 3000,
      playing: true,
      buffering: false,
      ended: false,
      bufferAheadMs: 12000,
    );
    policy.observe(
      nowMs: 18000,
      playing: false,
      buffering: true,
      ended: false,
      bufferAheadMs: 0,
    );
    expect(
      policy.observe(
        nowMs: 19000,
        playing: false,
        buffering: true,
        ended: false,
        bufferAheadMs: 0,
      ),
      BufferPreset.max,
    );
    policy.observe(
      nowMs: 20000,
      playing: true,
      buffering: false,
      ended: false,
      bufferAheadMs: 12000,
    );
    policy.observe(
      nowMs: 35000,
      playing: false,
      buffering: true,
      ended: false,
      bufferAheadMs: 0,
    );
    expect(
      policy.observe(
        nowMs: 36000,
        playing: false,
        buffering: true,
        ended: false,
        bufferAheadMs: 0,
      ),
      isNull,
    );
    expect(policy.effectivePreset, BufferPreset.max);
  });

  test('healthy playback lowers one step only with a usable cushion', () {
    final policy = AdaptiveBufferPolicy(initial: BufferPreset.max);
    policy.observe(
      nowMs: 1000,
      playing: true,
      buffering: false,
      ended: false,
      bufferAheadMs: 12000,
    );
    expect(
      policy.observe(
        nowMs: 91000,
        playing: true,
        buffering: false,
        ended: false,
        bufferAheadMs: 12000,
      ),
      BufferPreset.high,
    );
    expect(
      policy.observe(
        nowMs: 181000,
        playing: true,
        buffering: false,
        ended: false,
        bufferAheadMs: 12000,
      ),
      BufferPreset.normal,
    );
    expect(
      policy.observe(
        nowMs: 271000,
        playing: true,
        buffering: false,
        ended: false,
        bufferAheadMs: 5000,
      ),
      isNull,
      reason: 'low occupancy resets the healthy window',
    );
  });

  test('DVR gap does not count toward the live healthy window', () {
    final policy = AdaptiveBufferPolicy(initial: BufferPreset.max);
    policy.observe(
      nowMs: 1000,
      playing: true,
      buffering: false,
      ended: false,
      bufferAheadMs: 12000,
    );

    policy.resetObservationWindow();

    expect(
      policy.observe(
        nowMs: 1_000_000,
        playing: true,
        buffering: false,
        ended: false,
        bufferAheadMs: 12000,
      ),
      isNull,
    );
    expect(policy.effectivePreset, BufferPreset.max);
    expect(
      policy.observe(
        nowMs: 1_000_100,
        playing: true,
        buffering: false,
        ended: false,
        bufferAheadMs: 12000,
      ),
      isNull,
    );
    expect(policy.effectivePreset, BufferPreset.max);
  });

  test('EOF does not promote and channel reset clears history', () {
    final policy = AdaptiveBufferPolicy(initial: BufferPreset.high);
    expect(
      policy.observe(
        nowMs: 1000,
        playing: false,
        buffering: false,
        ended: true,
        bufferAheadMs: 0,
      ),
      isNull,
    );
    policy.reset();
    expect(policy.effectivePreset, BufferPreset.normal);
    expect(
      policy.observe(
        nowMs: 2000,
        playing: false,
        buffering: true,
        ended: false,
        bufferAheadMs: 0,
      ),
      isNull,
    );
    expect(policy.effectivePreset, BufferPreset.normal);
  });

  test(
    'three sub-second stalls promote, repeated samples do not count twice',
    () {
      final policy = AdaptiveBufferPolicy();
      BufferPreset? sample(int at, bool stalled) => policy.observe(
        nowMs: at,
        playing: !stalled,
        buffering: stalled,
        ended: false,
        bufferAheadMs: stalled ? 0 : 12000,
      );
      sample(0, false);
      sample(1000, true);
      expect(sample(1100, true), isNull);
      sample(1200, false);
      expect(sample(3000, true), isNull);
      sample(3200, false);
      expect(sample(5000, true), BufferPreset.high);
      expect(
        sample(25000, true),
        isNull,
        reason: 'same stall only promotes once',
      );
      sample(25100, false);
      sample(26000, true);
      sample(26200, false);
      expect(
        sample(27000, true),
        isNull,
        reason: 'promotion cleared old incidents',
      );
      sample(27200, false);
      expect(sample(28000, true), BufferPreset.max);
    },
  );

  test('expired short stalls and reset history cannot trigger promotion', () {
    final policy = AdaptiveBufferPolicy();
    BufferPreset? sample(int at, bool stalled) => policy.observe(
      nowMs: at,
      playing: !stalled,
      buffering: stalled,
      ended: false,
      bufferAheadMs: stalled ? 0 : 12000,
    );
    sample(0, false);
    sample(1000, true);
    sample(1200, false);
    sample(3000, true);
    sample(3200, false);
    expect(sample(34000, true), isNull);
    sample(34200, false);
    policy.resetObservationWindow();
    sample(35000, false);
    expect(sample(36000, true), isNull);
  });

  test('short-stall bursts respect the adjustment cooldown', () {
    final policy = AdaptiveBufferPolicy();
    BufferPreset? sample(int at, bool stalled) => policy.observe(
      nowMs: at,
      playing: !stalled,
      buffering: stalled,
      ended: false,
      bufferAheadMs: stalled ? 0 : 12000,
    );
    sample(0, false);
    for (final at in [1000, 3000]) {
      sample(at, true);
      sample(at + 200, false);
    }
    expect(sample(5000, true), BufferPreset.high);
    sample(5200, false);
    for (final at in [6000, 8000, 10000]) {
      expect(sample(at, true), isNull);
      sample(at + 200, false);
    }
    expect(sample(20000, true), BufferPreset.max);
  });
}
