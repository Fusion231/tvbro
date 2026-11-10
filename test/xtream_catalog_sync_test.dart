import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';

XtreamSource _source(
  Future<dynamic> Function(Map<String, String>) api, {
  DateTime Function()? now,
  int? maximumStreams,
}) => XtreamSource(
  sourceId: 'catalog',
  host: 'https://provider.test',
  username: 'user',
  password: 'password',
  debugApi: api,
  debugNow: now,
  maximumStreams: maximumStreams,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => ProviderRequestGate.instance.debugReset());
  test('concurrent authentication and expiry share the same account request', () async {
    final gate = Completer<dynamic>();
    var calls = 0;
    final source = _source((params) async {
      expect(params, isEmpty);
      calls++;
      return gate.future;
    });
    addTearDown(source.dispose);
    final login = source.connect();
    final expiry = source.subscriptionExpiry();
    gate.complete({'user_info': {'auth': 1, 'exp_date': '4102444800'}});
    await Future.wait([login, expiry]);
    expect(calls, 1);
  });

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    test(
      'loads the full ${kind.name} catalog in one request across categories',
      () async {
        final calls = <String>[];
        final categoriesAction = kind == ContentKind.movie
            ? 'get_vod_categories'
            : 'get_series_categories';
        final itemsAction = kind == ContentKind.movie
            ? 'get_vod_streams'
            : 'get_series';
        final idField = kind == ContentKind.movie ? 'stream_id' : 'series_id';
        final source = _source((params) async {
          final action = params['action'];
          calls.add('$action:${params['category_id'] ?? ''}');
          if (action == categoriesAction) {
            return [
              {'category_id': 'a', 'category_name': 'First'},
              {'category_id': 'b', 'category_name': 'Second'},
              {'category_id': 'a', 'category_name': 'Duplicate category'},
            ];
          }
          expect(action, itemsAction);
          expect(params, isNot(contains('category_id')));
          return [
            for (var id = 1; id < 50; id++)
              {
                idField: id,
                'name': '${id < 31 ? 'a' : 'b'} $id',
                'category_id': id < 31 ? 'a' : 'b',
              },
            {idField: 20, 'name': 'Duplicate', 'category_id': 'b'},
          ];
        });
        addTearDown(source.dispose);

        final results = await Future.wait([
          source.mediaCategories(kind),
          source.allMediaItems(kind),
        ]);
        final items = results[1] as List<MediaItem>;

        expect(items.map((item) => item.id), [
          for (var id = 1; id < 50; id++) '$id',
        ]);
        expect(items.first.kind, kind);
        expect(items[19].title, 'a 20');
        expect(items.last.title, 'b 49');
        expect(calls, ['$categoriesAction:', '$itemsAction:']);
      },
    );
  }

  test(
    'cancellation discards a bulk response without category requests',
    () async {
      final firstCategoryStarted = Completer<void>();
      final firstCategoryResponse = Completer<void>();
      final fetchedCategories = <String>[];
      final source = _source((params) async {
        if (params['action'] == 'get_vod_categories') {
          return [
            {'category_id': 'a', 'category_name': 'First'},
            {'category_id': 'b', 'category_name': 'Second'},
          ];
        }
        fetchedCategories.add(params['category_id'] ?? 'bulk');
        firstCategoryStarted.complete();
        await firstCategoryResponse.future;
        return [
          {'stream_id': '1', 'name': 'Movie'},
        ];
      });
      addTearDown(source.dispose);
      final token = LoadToken();
      final load = source.allMediaItems(ContentKind.movie, token: token);
      final cancelled = expectLater(
        load,
        throwsA(isA<LoadCancelledException>()),
      );

      await firstCategoryStarted.future;
      token.cancel();
      firstCategoryResponse.complete();
      await cancelled;

      expect(fetchedCategories, ['bulk']);
    },
  );

  test(
    'uses the global catalog when the provider exposes no categories',
    () async {
      final calls = <Map<String, String>>[];
      final source = _source((params) async {
        calls.add(params);
        if (params['action'] == 'get_vod_categories') return [];
        return [
          {'stream_id': 'one', 'name': 'First'},
          {'stream_id': 'one', 'name': 'Duplicate'},
          {'stream_id': 'two', 'name': 'Second'},
        ];
      });
      addTearDown(source.dispose);

      final items = await source.allMediaItems(ContentKind.movie);

      expect(items.map((item) => item.title), ['First', 'Second']);
      expect(calls, [
        {'action': 'get_vod_streams'},
      ]);
    },
  );

  test('invalidation fetches the changed bulk catalog', () async {
    var version = 1;
    final calls = <String>[];
    final source = _source((params) async {
      calls.add('${params['action']}:${params['category_id'] ?? ''}');
      if (params['action'] == 'get_vod_categories') {
        return [
          {'category_id': '$version', 'category_name': 'Version $version'},
        ];
      }
      return [
        {'stream_id': version, 'name': 'Movie $version'},
      ];
    });
    addTearDown(source.dispose);

    expect((await source.allMediaItems(ContentKind.movie)).single.id, '1');
    source.invalidate();
    version = 2;
    expect((await source.allMediaItems(ContentKind.movie)).single.id, '2');
    expect(calls, ['get_vod_streams:', 'get_vod_streams:']);
  });

  test(
    'a failed category lookup can retry without poisoning its cache',
    () async {
      var attempts = 0;
      final source = _source((params) async {
        expect(params['action'], 'get_series_categories');
        if (++attempts == 1) throw StateError('temporarily unavailable');
        return [
          {'category_id': '1', 'category_name': 'Recovered'},
        ];
      });
      addTearDown(source.dispose);

      await expectLater(
        source.mediaCategories(ContentKind.series),
        throwsStateError,
      );
      expect(
        (await source.mediaCategories(ContentKind.series)).single.title,
        'Recovered',
      );
      await source.mediaCategories(ContentKind.series);
      expect(attempts, 2);
    },
  );

  test(
    'unsupported bulk falls back and reuses successful category requests',
    () async {
      final calls = <String, int>{};
      final source = _source((params) async {
        final key = '${params['action']}:${params['category_id'] ?? ''}';
        calls[key] = (calls[key] ?? 0) + 1;
        if (params['action'] == 'get_vod_categories') {
          return [
            {'category_id': 'a', 'category_name': 'First'},
            {'category_id': 'b', 'category_name': 'Second'},
          ];
        }
        if (!params.containsKey('category_id')) {
          throw StateError('HTTP 405 from provider');
        }
        if (params['category_id'] == 'b' && calls[key] == 1) {
          throw StateError('temporarily unavailable');
        }
        return [
          {'stream_id': params['category_id'], 'name': 'Movie'},
        ];
      });
      addTearDown(source.dispose);

      await expectLater(
        source.allMediaItems(ContentKind.movie),
        throwsStateError,
      );
      expect(
        (await source.allMediaItems(ContentKind.movie)).map((item) => item.id),
        ['a', 'b'],
      );
      expect(calls, {
        'get_vod_streams:': 2,
        'get_vod_categories:': 1,
        'get_vod_streams:a': 1,
        'get_vod_streams:b': 2,
      });
    },
  );

  for (final error in [
    StateError('HTTP 500 from provider'),
    const FormatException('invalid JSON'),
    const HttpWorkloadException('request failed for a non-size reason'),
    ProviderRequestBlocked(status: 429, retryAt: DateTime(2100)),
  ]) {
    test(
      'bulk failure $error does not fan out into category requests',
      () async {
        var calls = 0;
        final source = _source((params) async {
          calls++;
          throw error;
        });
        addTearDown(source.dispose);
        await expectLater(
          source.allMediaItems(ContentKind.movie),
          throwsA(same(error)),
        );
        expect(calls, 1);
      },
    );
  }

  test('a successful empty bulk list needs no category fallback', () async {
    var calls = 0;
    final source = _source((params) async {
      calls++;
      return [];
    });
    addTearDown(source.dispose);
    expect(await source.allMediaItems(ContentKind.movie), isEmpty);
    expect(calls, 1);
  });

  test(
    'an oversized bulk response falls back to distinct categories',
    () async {
      final calls = <String>[];
      final source = _source((params) async {
        calls.add('${params['action']}:${params['category_id'] ?? ''}');
        if (params['action'] == 'get_vod_categories') {
          return [
            {'category_id': 'a', 'category_name': 'First'},
            {'category_id': 'a', 'category_name': 'Duplicate'},
            {'category_id': 'b', 'category_name': 'Second'},
          ];
        }
        if (!params.containsKey('category_id')) {
          throw const HttpWorkloadException(
            'provider JSON is 129 MB, over the 128 MB limit',
            isSizeLimit: true,
          );
        }
        return [
          {'stream_id': params['category_id'], 'name': 'Movie'},
        ];
      });
      addTearDown(source.dispose);
      expect(
        (await source.allMediaItems(ContentKind.movie)).map((item) => item.id),
        ['a', 'b'],
      );
      expect(calls, [
        'get_vod_streams:',
        'get_vod_categories:',
        'get_vod_streams:a',
        'get_vod_streams:b',
      ]);
    },
  );

  test(
    'shares authentication in flight and renews it after 24 hours',
    () async {
      final response = Completer<dynamic>();
      var now = DateTime.utc(2026, 10, 23);
      var calls = 0;
      final source = _source((params) async {
        expect(params, isEmpty);
        calls++;
        return response.future;
      }, now: () => now);
      addTearDown(source.dispose);

      final connects = Future.wait([
        source.connect(),
        source.connect(),
        source.connect(),
      ]);
      expect(calls, 1);
      response.complete({
        'user_info': {'auth': 1},
        'server_info': {'timezone': 'Europe/Warsaw'},
      });
      await connects;
      source.invalidate();
      now = now.add(const Duration(hours: 23, minutes: 59));
      await source.connect();
      expect(calls, 1);
      expect(source.catchupCapability.timezone, 'Europe/Warsaw');

      now = now.add(const Duration(minutes: 1));
      await source.connect();
      expect(calls, 2);
    },
  );

  test(
    'a later explicit connection can recover after a transport failure',
    () async {
      var calls = 0;
      final source = _source((params) async {
        calls++;
        if (calls == 1) {
          throw StateError('temporarily unavailable');
        }
        return {
          'user_info': {'auth': 1},
        };
      });
      addTearDown(source.dispose);

      await expectLater(source.connect(), throwsStateError);
      await source.connect();
      await source.connect();
      expect(calls, 2);
    },
  );

  test('rejected credentials stop later authentication attempts', () async {
    var calls = 0;
    final source = _source((_) async {
      calls++;
      return {'user_info': {'auth': false}};
    });
    addTearDown(source.dispose);
    await expectLater(source.connect(), throwsA(isA<ProviderRequestBlocked>()));
    await expectLater(source.connect(), throwsA(isA<ProviderRequestBlocked>()));
    expect(calls, 1);
  });

  for (final response in <Object?>[
    null,
    [],
    {},
    {'user_info': []},
    {'user_info': {}},
    {
      'user_info': {'auth': 'unexpected'},
    },
  ]) {
    test(
      'malformed account $response cannot authenticate or pause the host',
      () async {
        var calls = 0;
        var reply = response;
        final source = _source((_) async {
          calls++;
          return reply;
        });
        addTearDown(source.dispose);

        await expectLater(source.connect(), throwsFormatException);
        expect(
          () => ProviderRequestGate.instance.check(Uri.parse(source.host)),
          returnsNormally,
        );
        reply = {
          'user_info': {'auth': 1},
        };
        await source.connect();
        await source.connect();
        expect(calls, 2, reason: 'only the valid reply is cached');
      },
    );
  }

  for (final status in ['Expired', 'Disabled', 'Banned']) {
    test('an authenticated but $status account is refused', () async {
      final source = _source(
        (_) async => {
          'user_info': {'auth': 1, 'status': status},
        },
      );
      addTearDown(source.dispose);

      await expectLater(
        source.connect(),
        throwsA(isA<ProviderRequestBlocked>()),
      );
    });
  }

  test(
    'a past or current expiry cannot authenticate; unlimited accounts can',
    () async {
      final now = DateTime.utc(2026, 10, 24);
      for (final expiry in [now.subtract(const Duration(seconds: 1)), now]) {
        ProviderRequestGate.instance.debugReset();
        final source = _source(
          (_) async => {
            'user_info': {
              'auth': 1,
              'status': 'Active',
              'exp_date': '${expiry.millisecondsSinceEpoch ~/ 1000}',
            },
          },
          now: () => now,
        );
        addTearDown(source.dispose);
        await expectLater(
          source.connect(),
          throwsA(isA<ProviderRequestBlocked>()),
        );
      }
      for (final expiry in [null, '0', 'never', '4102444800']) {
        ProviderRequestGate.instance.debugReset();
        final source = _source(
          (_) async => {
            'user_info': {'auth': 1, 'status': 'Active', 'exp_date': expiry},
          },
          now: () => now,
        );
        addTearDown(source.dispose);
        await source.connect();
      }
    },
  );

  test(
    'a malformed live catalog retains the previous complete cache',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'xtream_live_cache_',
      );
      final db = await AppDatabase.openAt('${directory.path}/library.db');
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });
      var now = DateTime.utc(2026, 10, 24);
      Object? liveReply = [
        {'stream_id': 1, 'name': 'Cached channel'},
      ];
      final source = _source((params) async {
        if (params.isEmpty) {
          return {
            'user_info': {'auth': 1},
          };
        }
        if (params['action'] == 'get_live_categories') return [];
        expect(params['action'], 'get_live_streams');
        return liveReply;
      }, now: () => now);
      addTearDown(source.dispose);
      final repo = LibraryRepository(source: source, db: db, now: () => now);
      await repo.synchronizeMediaCatalog(ContentKind.live);
      final synced = await db.lastCatalogSynced(source.id, ContentKind.live);

      liveReply = {'error': 'Provider temporarily unavailable'};
      now = now.add(const Duration(hours: 1));
      await expectLater(
        repo.synchronizeMediaCatalog(ContentKind.live, forceRefresh: true),
        throwsFormatException,
      );
      expect((await db.readChannels(source.id)).single.name, 'Cached channel');
      expect(await db.lastCatalogSynced(source.id, ContentKind.live), synced);

      liveReply = [];
      await repo.synchronizeMediaCatalog(ContentKind.live, forceRefresh: true);
      expect(await db.readChannels(source.id), isEmpty);
      expect(
        await db.lastCatalogSynced(source.id, ContentKind.live),
        isNotNull,
      );
    },
  );

  for (final sample in <({Object? reported, int? configured, int expected})>[
    (reported: '3', configured: null, expected: 3),
    (reported: 3, configured: 1, expected: 1),
    (reported: 3, configured: 5, expected: 3),
    (reported: 3, configured: 0, expected: 3),
    (reported: 0, configured: null, expected: 0),
    (reported: '0', configured: 2, expected: 2),
    (reported: null, configured: null, expected: 1),
    (reported: 'invalid', configured: null, expected: 1),
    (reported: -1, configured: null, expected: 1),
  ]) {
    test(
      'account stream limit $sample is attached to every playback type',
      () async {
        final now = DateTime.utc(2026, 10, 24);
        final source = _source(
          (_) async => {
            'user_info': {
              'auth': 1,
              'max_connections': sample.reported,
              'active_cons': '2',
            },
          },
          now: () => now,
          maximumStreams: sample.configured,
        );
        addTearDown(source.dispose);
        expect(source.streamAccount.maximumStreams, 1);
        expect(source.streamAccount.checkedAt, isNull);
        await source.connect();
        final account = source.streamAccount;
        expect(account.maximumStreams, sample.expected);
        expect(account.reportedActiveStreams, 2);
        expect(account.checkedAt, now);
        const channel = Channel(id: '1', name: 'Live');
        final streams = [
          await source.resolve(channel),
          await source.resolveArchive(
            channel,
            Programme(
              channelId: channel.id,
              title: 'Archive',
              start: now.subtract(const Duration(hours: 1)),
              stop: now,
            ),
          ),
          await source.resolveMedia(
            const MediaItem(
              id: 'movie',
              title: 'Movie',
              kind: ContentKind.movie,
            ),
          ),
          await source.resolveMedia(
            const MediaItem(
              id: 'episode',
              title: 'Episode',
              kind: ContentKind.episode,
            ),
          ),
        ];
        expect(
          streams.map((stream) => stream.providerAccount?.id),
          everyElement(account.id),
        );
        expect(
          streams.map((stream) => stream.providerAccount?.maximumStreams),
          everyElement(sample.expected),
        );
        expect(account.id, isNot(contains(source.password)));
      },
    );
  }

  test(
    'expiry reads refresh account limits without hiding an expired date',
    () async {
      var now = DateTime.utc(2026, 10, 24);
      var calls = 0;
      final source = _source((_) async {
        calls++;
        return {
          'user_info': {
            'auth': 1,
            'max_connections': calls == 1 ? '3' : '2',
            'active_cons': calls == 1 ? '1' : '-1',
            'exp_date': calls == 1 ? '0' : '1609459200',
          },
        };
      }, now: () => now);
      addTearDown(source.dispose);
      await source.connect();
      expect(source.streamAccount.maximumStreams, 3);
      now = now.add(const Duration(minutes: 1));

      expect(
        (await source.subscriptionExpiry()).date?.toUtc(),
        DateTime.utc(2021),
      );
      expect(source.streamAccount.maximumStreams, 2);
      expect(source.streamAccount.reportedActiveStreams, isNull);
      expect(source.streamAccount.checkedAt, now);
    },
  );

  test(
    'an explicit expiry read still fetches fresh account information',
    () async {
      var calls = 0;
      final source = _source((_) async {
        calls++;
        return {
          'user_info': {'auth': 1, 'exp_date': calls == 1 ? '0' : 'never'},
        };
      });
      addTearDown(source.dispose);

      await source.connect();
      final expiry = await source.subscriptionExpiry();
      await source.resolve(const Channel(id: '1', name: 'Live'));
      expect(expiry.kind, SubscriptionExpiryKind.unlimited);
      expect(calls, 2);
    },
  );
}
