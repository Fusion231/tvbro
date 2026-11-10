import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/screens/channel_list_chrome.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';

Future<void> _loadInterFont() async {
  final loader = FontLoader('Inter');
  for (final path in const [
    'android/app/src/main/res/font/inter_regular.ttf',
    'android/app/src/main/res/font/inter_semibold.ttf',
    'android/app/src/main/res/font/inter_bold.ttf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) {
      fail(
        'Inter face missing at $path; the sizing regression needs the real font.',
      );
    }
    loader.addFont(Future.value(file.readAsBytesSync().buffer.asByteData()));
  }
  await loader.load();
}

void main() {
  setUpAll(_loadInterFont);

  testWidgets('Favorites follows Series and activates with the remote', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 540);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final focusNodes = {
      ContentKind.live: FocusNode(),
      ContentKind.movie: FocusNode(),
      ContentKind.series: FocusNode(),
    };
    final favoritesFocus = FocusNode();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final node in [...focusNodes.values, favoritesFocus]) {
        node.dispose();
      }
    });
    var selected = ContentKind.series;
    var favoritesSelected = false;
    var favoritesActivations = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Align(
              alignment: Alignment.topLeft,
              child: ChannelContentTabs(
                value: selected,
                focusNodes: focusNodes,
                favoritesFocusNode: favoritesFocus,
                favoritesSelected: favoritesSelected,
                onFavoritesSelected: () => setState(() {
                  favoritesActivations++;
                  favoritesSelected = true;
                }),
                onChanged: (kind) => setState(() {
                  selected = kind;
                  favoritesSelected = false;
                }),
              ),
            ),
          ),
        ),
      ),
    );

    final favorites = find.text('Favorites');
    expect(
      tester.getRect(favorites).left,
      greaterThan(tester.getRect(find.text('Series')).right),
    );
    for (final label in ['Live', 'Movies', 'Series', 'Favorites']) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(tester.getRect(find.text(label)).right, lessThanOrEqualTo(960));
    }

    focusNodes[ContentKind.series]!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(favoritesFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(favoritesActivations, 1);
    expect(tester.widget<Text>(favorites).style!.fontWeight, FontWeight.w700);
    for (final label in ['Live', 'Movies', 'Series']) {
      expect(
        tester.widget<Text>(find.text(label)).style!.fontWeight,
        FontWeight.w600,
      );
    }

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    expect(selected, ContentKind.movie);
    expect(favoritesSelected, isFalse);
    expect(tester.widget<Text>(favorites).style!.fontWeight, FontWeight.w600);
    expect(
      tester.widget<Text>(find.text('Movies')).style!.fontWeight,
      FontWeight.w700,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('focused Favorites scrolls into a narrow tab row', (
    tester,
  ) async {
    final focusNodes = {
      ContentKind.live: FocusNode(),
      ContentKind.movie: FocusNode(),
      ContentKind.series: FocusNode(),
    };
    final favoritesFocus = FocusNode();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final node in [...focusNodes.values, favoritesFocus]) {
        node.dispose();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 220,
              child: ChannelContentTabs(
                value: ContentKind.live,
                focusNodes: focusNodes,
                onChanged: (_) {},
                onFavoritesSelected: () {},
                favoritesFocusNode: favoritesFocus,
              ),
            ),
          ),
        ),
      ),
    );

    favoritesFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(favoritesFocus.hasFocus, isTrue);
    final label = tester.getRect(find.text('Favorites'));
    final row = tester.getRect(find.byType(ChannelContentTabs));
    expect(label.left, greaterThanOrEqualTo(row.left));
    expect(label.right, lessThanOrEqualTo(row.right));
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(1266, 714), Size(960, 540)]) {
    testWidgets('content tabs fit full Inter labels at $size', (tester) async {
      await _exerciseTabs(tester, size, checkFocus: true);
    });

    testWidgets('tab width follows inherited text metrics at $size', (
      tester,
    ) async {
      await _exerciseTabs(
        tester,
        size,
        inheritedLetterSpacing: 14,
        proveBareMeasurementWouldClip: true,
      );
    });
  }
}

Future<void> _exerciseTabs(
  WidgetTester tester,
  Size size, {
  double? inheritedLetterSpacing,
  bool proveBareMeasurementWouldClip = false,
  bool checkFocus = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final focusNodes = {
    ContentKind.live: FocusNode(debugLabel: 'tabs.live'),
    ContentKind.movie: FocusNode(debugLabel: 'tabs.movies'),
    ContentKind.series: FocusNode(debugLabel: 'tabs.series'),
  };

  Widget tabs = ChannelContentTabs(
    value: ContentKind.live,
    onChanged: (_) {},
    focusNodes: focusNodes,
  );
  if (inheritedLetterSpacing != null) {
    tabs = DefaultTextStyle.merge(
      // Stress the inherited-style path so an unstyled TextPainter would be
      // measurably too narrow even with Flutter test's fallback font metrics.
      style: TextStyle(letterSpacing: inheritedLetterSpacing),
      child: tabs,
    );
  }

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: tabs),
      ),
    ),
  );

  for (final label in const ['Live', 'Movies', 'Series']) {
    final finder = find.text(label);
    expect(finder, findsOneWidget);
    expect(
      DefaultTextStyle.of(tester.element(finder)).style.fontFamily,
      'Inter',
    );
    final text = tester.widget<Text>(finder);
    expect(text.maxLines, 1);
    expect(text.softWrap, isFalse);

    final paragraph = tester.renderObject<RenderParagraph>(finder);
    expect(paragraph.didExceedMaxLines, isFalse);
    final glyphWidth = paragraph.getMaxIntrinsicWidth(1000);
    expect(
      glyphWidth,
      lessThanOrEqualTo(paragraph.size.width + 0.5),
      reason: '$label must fit without clipping or wrapping at $size',
    );

    if (proveBareMeasurementWouldClip) {
      // This mirrors the former measurement, which omitted DefaultTextStyle's
      // font and spacing. The tab keeps 4 px of width slack after its border
      // and padding, so the old measured width would be insufficient here.
      final bareMeasure = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: text.style!.color,
            fontSize: text.style!.fontSize,
            fontWeight: text.style!.fontWeight,
          ),
        ),
        textDirection: Directionality.of(tester.element(finder)),
        textScaler: MediaQuery.textScalerOf(tester.element(finder)),
      )..layout();
      expect(
        glyphWidth,
        greaterThan(bareMeasure.width + 4.5),
        reason: 'the old bare measurement would clip $label at $size',
      );
      bareMeasure.dispose();
    }
  }

  if (checkFocus) {
    final moviesFinder = find.text('Movies');
    final moviesTab = find
        .ancestor(of: moviesFinder, matching: find.byType(AnimatedContainer))
        .first;
    final beforeFocusSize = tester.getSize(moviesTab);
    expect(beforeFocusSize.height, 40);
    focusNodes[ContentKind.movie]!.requestFocus();
    await tester.pump(const Duration(milliseconds: 150));

    final focusedDecoration =
        tester.widget<AnimatedContainer>(moviesTab).decoration as BoxDecoration;
    expect(focusedDecoration.color, AppColors.panelHi);
    expect(focusedDecoration.border, isA<Border>());
    expect((focusedDecoration.border! as Border).top.color, AppColors.accent);
    expect(tester.getSize(moviesTab), beforeFocusSize);
  }

  await tester.pumpWidget(const SizedBox.shrink());
  for (final node in focusNodes.values) {
    node.dispose();
  }
  expect(tester.takeException(), isNull);
}
