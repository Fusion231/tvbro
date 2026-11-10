import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/provider_stream_gate.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_identity.dart';

void main() {
  const account = ProviderStreamAccount(id: 'account');
  const stream = StreamInfo(
    url: 'https://provider.test/live',
    providerAccount: account,
  );

  test(
    'one physical owner survives preview/fullscreen handoff and reconnect',
    () {
      final gate = ProviderStreamGate();
      final owner = Object();
      gate.reserve(stream, owner: owner);
      gate.reserve(stream, owner: owner);
      expect(gate.activeStreams(account.id), 1);
      expect(
        () => gate.reserve(stream, owner: Object()),
        throwsA(isA<ProviderStreamLimitReached>()),
      );
      gate.release(owner);
      gate.reserve(stream, owner: Object());
      expect(gate.activeStreams(account.id), 1);
    },
  );

  test('replacing an old physical owner cannot release the new one', () {
    final gate = ProviderStreamGate();
    final oldOwner = Object();
    final newOwner = Object();
    gate.reserve(stream, owner: oldOwner);
    gate.release(oldOwner);
    gate.reserve(stream, owner: newOwner);
    gate.release(oldOwner);
    expect(gate.activeStreams(account.id), 1);
    expect(
      () => gate.reserve(stream, owner: Object()),
      throwsA(isA<ProviderStreamLimitReached>()),
    );
  });

  test(
    'accountless local playback does not take a second upstream reservation',
    () {
      final gate = ProviderStreamGate();
      final viewer = Object();
      final capture = Object();
      gate.reserve(stream, owner: viewer);
      gate.release(viewer);
      gate.reserve(stream, owner: capture);
      gate.reserve(
        const StreamInfo(url: 'http://127.0.0.1/live/index.m3u8'),
        owner: viewer,
      );
      expect(gate.activeStreams(account.id), 1);
      gate.release(viewer);
      expect(gate.activeStreams(account.id), 1);
      gate.release(capture);
      expect(gate.activeStreams(account.id), 0);
    },
  );

  test('distinct accounts on one server do not consume each other slots', () {
    final gate = ProviderStreamGate();
    gate.reserve(stream, owner: Object());
    gate.reserve(
      stream.withProviderAccount(const ProviderStreamAccount(id: 'other')),
      owner: Object(),
    );
    expect(gate.activeStreams(account.id), 1);
    expect(gate.activeStreams('other'), 1);
  });

  test('a duplicate source cannot raise a cap already held by the account', () {
    for (final higher in [0, 2, 8]) {
      final gate = ProviderStreamGate();
      gate.reserve(stream, owner: Object());
      expect(
        () => gate.reserve(
          stream.withProviderAccount(
            ProviderStreamAccount(id: account.id, maximumStreams: higher),
          ),
          owner: Object(),
        ),
        throwsA(isA<ProviderStreamLimitReached>()),
      );
      expect(gate.activeStreams(account.id), 1);
    }
  });

  test('explicit unlimited accounts allow multiple physical owners', () {
    final gate = ProviderStreamGate();
    final unlimited = stream.withProviderAccount(
      const ProviderStreamAccount(id: 'unlimited', maximumStreams: 0),
    );
    for (var i = 0; i < 4; i++) {
      gate.reserve(unlimited, owner: Object());
    }
    expect(gate.activeStreams('unlimited'), 4);
  });

  test('watch anyway admits only the confirmed owner and keeps counting', () {
    final gate = ProviderStreamGate();
    final viewer = Object();
    gate.reserve(stream, owner: Object());
    gate.reserve(stream, owner: viewer, allowLimitExceeded: true);
    gate.reserve(stream, owner: viewer);
    expect(gate.activeStreams(account.id), 2);
    expect(
      () => gate.reserve(stream, owner: Object()),
      throwsA(isA<ProviderStreamLimitReached>()),
    );
    gate.release(viewer);
    expect(gate.activeStreams(account.id), 1);
    expect(
      () => gate.reserve(stream, owner: viewer),
      throwsA(isA<ProviderStreamLimitReached>()),
    );
  });

  test('watch anyway can override a fresh remote occupancy report', () {
    final now = DateTime.utc(2026, 10, 27);
    final gate = ProviderStreamGate(now: () => now);
    final busy = stream.withProviderAccount(
      ProviderStreamAccount(
        id: account.id,
        reportedActiveStreams: 1,
        checkedAt: now,
      ),
    );
    final viewer = Object();
    gate.reserve(busy, owner: viewer, allowLimitExceeded: true);
    gate.reserve(busy, owner: viewer);
    expect(gate.activeStreams(account.id), 1);
    expect(
      () => gate.reserve(busy, owner: Object()),
      throwsA(isA<ProviderStreamLimitReached>()),
    );
  });

  test(
    'fresh remote usage is advisory without double-counting local streams',
    () {
      var now = DateTime.utc(2026, 10, 24);
      final gate = ProviderStreamGate(now: () => now);
      final remoteBusy = stream.withProviderAccount(
        ProviderStreamAccount(
          id: account.id,
          reportedActiveStreams: 1,
          checkedAt: now,
        ),
      );
      expect(
        () => gate.reserve(remoteBusy, owner: Object()),
        throwsA(isA<ProviderStreamLimitReached>()),
      );
      now = now.add(const Duration(seconds: 30));
      final local = Object();
      gate.reserve(remoteBusy, owner: local);
      final refreshed = stream.withProviderAccount(
        ProviderStreamAccount(
          id: account.id,
          maximumStreams: 2,
          reportedActiveStreams: 1,
          checkedAt: now,
        ),
      );
      gate.reserve(refreshed, owner: local);
      gate.reserve(refreshed, owner: Object());
      expect(gate.activeStreams(account.id), 2);
    },
  );

  test(
    'failed cross-account admission preserves the prior owner reservation',
    () {
      final gate = ProviderStreamGate();
      final owner = Object();
      const other = ProviderStreamAccount(id: 'other');
      gate.reserve(stream, owner: owner);
      gate.reserve(stream.withProviderAccount(other), owner: Object());
      expect(
        () => gate.reserve(stream.withProviderAccount(other), owner: owner),
        throwsA(isA<ProviderStreamLimitReached>()),
      );
      expect(gate.activeStreams(account.id), 1);
      expect(gate.activeStreams(other.id), 1);
    },
  );

  test(
    'M3U and Xtream credentials share opaque identity across source aliases',
    () {
      final xtream = providerStreamAccountId(
        'https://Provider.test.:443',
        username: 'u',
        password: 'p',
      );
      expect(
        providerStreamAccountId(
          'http://provider.test:8080/get.php?username=u&password=p',
        ),
        xtream,
      );
      expect(
        providerStreamAccountId('http://u:p@provider.test/get.php'),
        xtream,
      );
      expect(
        providerStreamAccountId(
          'http://provider.test',
          username: 'other',
          password: 'p',
        ),
        isNot(xtream),
      );
      expect(
        providerStreamAccountId(
          'http://provider.test',
          username: 'u',
          password: 'other',
        ),
        isNot(xtream),
      );
      expect(xtream, matches(RegExp(r'^provider-account:[a-f0-9]{64}$')));
      expect(
        providerStreamAccountId('https://provider.test/a.m3u'),
        isNot(providerStreamAccountId('https://provider.test/b.m3u')),
      );
    },
  );
}
