import 'dart:math';

/// A bounded recovery budget for one period without a complete media segment.
class DvrRetryPolicy {
  const DvrRetryPolicy({
    this.maxRetries = 5,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 8),
    this.maxRecovery = const Duration(minutes: 2),
    this.jitterFraction = 0.2,
  });

  final int maxRetries;
  final Duration initialDelay;
  final Duration maxDelay;
  final Duration maxRecovery;
  final double jitterFraction;

  Duration delayFor(int retry, {double? randomValue}) {
    final ceiling = min(
      maxDelay.inMilliseconds,
      initialDelay.inMilliseconds * pow(2, max(0, retry - 1)),
    );
    final jitter =
        1 + ((randomValue ?? Random().nextDouble()) * 2 - 1) * jitterFraction;
    return Duration(milliseconds: max(0, (ceiling * jitter).round()));
  }
}
