import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/screens/library_home_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';

void main() {
  final kinds = [ContentKind.live, ContentKind.movie, ContentKind.series];

  Future<({Map<ContentKind, FocusNode> sections, FocusNode favorites})>
  pumpHome(
    WidgetTester tester, {
    required Size size,
    bool television = false,
    ValueChanged<ContentKind>? onSelected,
    VoidCallback? onFavoritesSelected,
  }) async {
    debugIsTelevision = television;
    addTearDown(() => debugIsTelevision = false);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final focusNodes = {for (final kind in kinds) kind: FocusNode()};
    final favoritesFocusNode = FocusNode();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final node in focusNodes.values) {
        node.dispose();
      }
      favoritesFocusNode.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          appBar: AppBar(title: const Text('TVBro')),
          body: LibraryHomeView(
            focusNodes: focusNodes,
            onSelected: onSelected ?? (_) {},
            favoritesFocusNode: favoritesFocusNode,
            onFavoritesSelected: onFavoritesSelected ?? () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (sections: focusNodes, favorites: favoritesFocusNode);
  }

  for (final size in const [
    Size(960, 540),
    Size(1280, 720),
    Size(360, 800),
    Size(740, 280),
    Size(700, 540),
  ]) {
    testWidgets('home tiles fit or scroll at $size', (tester) async {
      await pumpHome(tester, size: size);
      expect(tester.takeException(), isNull);
      for (final section in [...kinds.map((kind) => kind.name), 'favorites']) {
        final tile = find.byKey(ValueKey('home-$section'));
        expect(tile, findsOneWidget);
        final rect = tester.getRect(tile);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        expect(tile.hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      final tv = tester.getRect(find.byKey(const ValueKey('home-live')));
      final movies = tester.getRect(find.byKey(const ValueKey('home-movie')));
      final series = tester.getRect(find.byKey(const ValueKey('home-series')));
      final favorites = tester.getRect(
        find.byKey(const ValueKey('home-favorites')),
      );
      if (size.width >= 700) {
        expect(movies.left, greaterThan(tv.right));
        expect(favorites.left, greaterThan(series.right));
      } else {
        expect(movies.top, greaterThan(tv.bottom));
        expect(favorites.top, greaterThan(series.bottom));
      }
    });
  }

  testWidgets('TV Home stays wide at 640x360dp', (tester) async {
    await pumpHome(tester, size: const Size(640, 360), television: true);

    final tv = tester.getRect(find.byKey(const ValueKey('home-live')));
    final movies = tester.getRect(find.byKey(const ValueKey('home-movie')));
    final series = tester.getRect(find.byKey(const ValueKey('home-series')));
    final favorites = tester.getRect(
      find.byKey(const ValueKey('home-favorites')),
    );
    expect(movies.left, greaterThan(tv.right));
    expect(series.left, greaterThan(movies.right));
    expect(favorites.left, greaterThan(series.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('non-TV Home stays wide at 800dp', (tester) async {
    await pumpHome(tester, size: const Size(800, 450));

    final tv = tester.getRect(find.byKey(const ValueKey('home-live')));
    final movies = tester.getRect(find.byKey(const ValueKey('home-movie')));
    expect(movies.left, greaterThan(tv.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote and pointer activate their home sections', (
    tester,
  ) async {
    final selected = <ContentKind>[];
    var favoritesSelected = 0;
    final focusNodes = await pumpHome(
      tester,
      size: const Size(960, 540),
      onSelected: selected.add,
      onFavoritesSelected: () => favoritesSelected++,
    );
    expect(focusNodes.sections[ContentKind.live]!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusNodes.sections[ContentKind.movie]!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(find.byKey(const ValueKey('home-series')));
    expect(selected, kinds);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusNodes.sections[ContentKind.series]!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusNodes.favorites.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(find.byKey(const ValueKey('home-favorites')));
    expect(favoritesSelected, 2);
  });
}
