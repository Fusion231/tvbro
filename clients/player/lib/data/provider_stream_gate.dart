import 'dart:math' as math;

import '../sources/source.dart';
import '../l10n/app_localizations.dart';

class ProviderStreamLimitReached implements Exception {
  const ProviderStreamLimitReached(this.limit);
  final int limit;

  @override
  String toString() => tr(
    'The provider stream limit ({limit}) is in use. Stop another stream or recording.',
    {'limit': limit},
  );
}

/// One reservation per physical playback/capture owner, not per UI surface.
/// Preview/fullscreen handoffs reuse their owner; local DVR playback has none.
class ProviderStreamGate {
  ProviderStreamGate({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final instance = ProviderStreamGate();
  final DateTime Function() _now;
  final Map<Object, ProviderStreamAccount> _owners = {};
  final Map<String, ({DateTime checkedAt, int external})> _observations = {};

  int activeStreams(String accountId) =>
      _owners.values.where((account) => account.id == accountId).length;

  /// Playback may exceed the advisory quota after the viewer confirms a warning.
  /// The reservation still counts and only this physical owner is admitted.
  void reserve(
    StreamInfo stream, {
    required Object owner,
    bool allowLimitExceeded = false,
  }) {
    final account = stream.providerAccount;
    if (account == null) {
      release(owner);
      return;
    }
    final previous = _owners[owner];
    final active = activeStreams(account.id);
    final checkedAt = account.checkedAt;
    if (checkedAt != null &&
        account.reportedActiveStreams != null &&
        (_observations[account.id] == null ||
            checkedAt.isAfter(_observations[account.id]!.checkedAt))) {
      _observations[account.id] = (
        checkedAt: checkedAt,
        external: math.max(0, account.reportedActiveStreams! - active),
      );
    }
    final observation = _observations[account.id];
    final age = observation == null
        ? null
        : _now().difference(observation.checkedAt);
    final external =
        age != null && !age.isNegative && age < const Duration(seconds: 30)
        ? observation!.external
        : 0;
    final alreadyOwned = previous?.id == account.id;
    var limit = account.maximumStreams;
    for (final entry in _owners.entries) {
      if (!identical(entry.key, owner) &&
          entry.value.id == account.id &&
          entry.value.maximumStreams > 0) {
        limit = limit <= 0
            ? entry.value.maximumStreams
            : math.min(limit, entry.value.maximumStreams);
      }
    }
    if (!allowLimitExceeded &&
        !alreadyOwned &&
        limit > 0 &&
        active + external >= limit) {
      throw ProviderStreamLimitReached(limit);
    }
    _owners[owner] = account;
  }

  void release(Object owner) => _owners.remove(owner);

  void debugReset() {
    _owners.clear();
    _observations.clear();
  }
}
