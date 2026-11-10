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
}
