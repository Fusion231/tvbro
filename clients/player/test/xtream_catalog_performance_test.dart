import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  XtreamSource sourceWith(Future<dynamic> Function(Map<String, String>) api) {
    final source = XtreamSource(
      sourceId: 'test',
      host: 'http://provider.invalid',
      username: 'test',
      password: 'test',
      debugApi: api,
    );
    addTearDown(source.dispose);
    return source;
  }

  test('a superseded search stops before fetching another category', () async {
    final first = Completer<dynamic>();
    final started = Completer<void>();
    final fetchedCategories = <String?>[];
    final source = sourceWith((params) async {
      if (params['action'] == 'get_vod_categories') {
        return [
          {'category_id': 'a', 'category_name': 'A'},
          {'category_id': 'b', 'category_name': 'B'},
        ];
      }
      fetchedCategories.add(params['category_id']);
      started.complete();
      return first.future;
    });

    final oldSearch = source.searchMedia(ContentKind.movie, 'old');
    await started.future;
    final newSearch = source.searchMedia(
      ContentKind.movie,
      'new',
      categoryId: 'a',
    );
    first.complete([
      {'stream_id': 1, 'name': 'New movie', 'category_id': 'a'},
    ]);

    expect(await oldSearch, isEmpty);
    expect((await newSearch).single.title, 'New movie');
    expect(fetchedCategories, ['a']);
  });

  test(
    'concurrent movie and series searches do not cancel each other',
    () async {
      final source = sourceWith((params) async {
        if (params['action']!.endsWith('_categories')) return <Object>[];
        return [
          {'stream_id': 1, 'series_id': 2, 'name': 'Shared title'},
        ];
      });

      final results = await Future.wait([
        source.searchMedia(ContentKind.movie, 'shared'),
        source.searchMedia(ContentKind.series, 'shared'),
      ]);

      expect(results[0].single.kind, ContentKind.movie);
      expect(results[1].single.kind, ContentKind.series);
    },
  );

  test('a failed category can be fetched again without invalidation', () async {
    var requests = 0;
    final source = sourceWith((_) async {
      if (++requests == 1) throw const FormatException('temporary bad body');
      return [
        {'stream_id': 1, 'name': 'Recovered movie'},
      ];
    });

    await expectLater(
      source.mediaItemsPage(ContentKind.movie, categoryId: 'a'),
      throwsFormatException,
    );
    final recovered = await source.mediaItemsPage(
      ContentKind.movie,
      categoryId: 'a',
    );
    expect(recovered.items.single.title, 'Recovered movie');
    expect(requests, 2);
  });

  test('an older failure does not evict the replacement category', () async {
    final first = Completer<dynamic>();
    var requests = 0;
    final source = sourceWith((_) async {
      if (++requests == 1) return first.future;
      return [
        for (var i = 0; i < 30; i++) {'stream_id': i, 'name': 'Movie $i'},
      ];
    });
    final old = source.mediaItemsPage(ContentKind.movie, categoryId: 'a');
    final oldFailure = expectLater(old, throwsFormatException);
    source.invalidate();
    await source.mediaItemsPage(ContentKind.movie, categoryId: 'a');
    first.completeError(const FormatException('old request failed'));
    await oldFailure;

    final nextPage = await source.mediaItemsPage(
      ContentKind.movie,
      categoryId: 'a',
      page: 2,
    );
    expect(nextPage.items, hasLength(14));
    expect(requests, 2);
  });

  test(
    'evicted category counts let aggregate paging skip without refetching',
    () async {
      final requests = <String, int>{};
      final source = sourceWith((params) async {
        if (params['action'] == 'get_vod_categories') {
          return [
            for (final id in ['a', 'b', 'c', 'd'])
              {'category_id': id, 'category_name': id},
          ];
        }
        final id = params['category_id']!;
        requests.update(id, (n) => n + 1, ifAbsent: () => 1);
        return [
          for (var i = 0; i < 3000; i++)
            {'stream_id': '$id-$i', 'name': 'Movie $i', 'category_id': id},
        ];
      });
      // Searching exceeds the 5,000-row cache and leaves only category counts
      // for the earlier catalogs. Their aggregate offsets must still work.
      expect(await source.searchMedia(ContentKind.movie, 'absent'), isEmpty);
      expect(requests, {'a': 1, 'b': 1, 'c': 1, 'd': 1});
      expect(
        (await source.mediaItemsPage(ContentKind.movie)).items.first.id,
        'a-0',
      );
      expect(requests['a'], 2);

      final nextCategory = await source.mediaItemsPage(
        ContentKind.movie,
        page: 216,
      );
      expect(nextCategory.items.first.id, 'b-10');
      expect(requests, {'a': 2, 'b': 2, 'c': 1, 'd': 1});
      await source.mediaItemsPage(ContentKind.movie, page: 217);
      expect(requests['a'], 2);
      expect(requests['b'], 2);

      // An explicit revisit may fetch an evicted category once; its following
      // pages share that response instead of repeatedly downloading it.
      expect(
        (await source.mediaItemsPage(ContentKind.movie)).items.first.id,
        'a-0',
      );
      await source.mediaItemsPage(ContentKind.movie, categoryId: 'a', page: 2);
      expect(requests['a'], 3);
    },
  );

  test(
    'an oversized active category is retained across its following pages',
    () async {
      var requests = 0;
      final source = sourceWith((_) async {
        requests++;
        return [
          for (var i = 0; i < 6000; i++) {'stream_id': i, 'name': 'Movie $i'},
        ];
      });
      await source.mediaItemsPage(ContentKind.movie, categoryId: 'a');
      await source.mediaItemsPage(ContentKind.movie, categoryId: 'a', page: 2);
      expect(requests, 1);
    },
  );
}
