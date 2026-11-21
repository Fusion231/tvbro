import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/screens/library_home_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/profile_avatar.dart';

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

  testWidgets('Home updates its network badge and opens Android settings', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settingsOpened = false;
    messenger.setMockMethodCallHandler(
      const MethodChannel('iptvs/network_status'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(const MethodChannel('iptvs/device'), (
      call,
    ) async {
      settingsOpened = call.method == 'openNetworkSettings';
      return settingsOpened;
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomeNetworkStatus())),
    );

    Future<void> publish(String status) async {
      await messenger.handlePlatformMessage(
        'iptvs/network_status',
        const StandardMethodCodec().encodeSuccessEnvelope(status),
        null,
      );
      await tester.pump();
    }

    await publish('wifi');
    expect(find.text('Wi-Fi'), findsOneWidget);
    await publish('offline');
    expect(find.text('No internet'), findsOneWidget);
    await tester.tap(find.text('No internet'));
    await tester.pump();
    expect(settingsOpened, isTrue);
    await publish('ethernet');
    expect(find.text('Ethernet'), findsOneWidget);
    expect(find.text('No internet'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('profile menu highlights the focused option in touch mode', (
    tester,
  ) async {
    final focusManager = FocusManager.instance;
    final previous = focusManager.highlightStrategy;
    focusManager.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
    addTearDown(() => focusManager.highlightStrategy = previous);
    var settingsOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          appBar: AppBar(
            leading: ProfileAvatarButton(
              profileName: 'Living room',
              colorIndex: 0,
              onChangeProfile: () {},
              onProfileSettings: () => settingsOpened = true,
            ),
          ),
        ),
      ),
    );
    Color? borderOf(String title) {
      final material = find
          .ancestor(of: find.text(title), matching: find.byType(Material))
          .first;
      final shape = tester.widget<Material>(material).shape;
      return shape is OutlinedBorder ? shape.side.color : null;
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(borderOf('L'), AppColors.accent);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(borderOf('Change profile'), AppColors.accent);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(borderOf('TVBro account'), AppColors.accent);
    expect(borderOf('Change profile'), isNot(AppColors.accent));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(settingsOpened, isTrue);
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
