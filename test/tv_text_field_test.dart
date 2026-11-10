// Widget tests for TvTextField — guards the edit-mode behaviour and, critically,
// that it builds under a plain Navigator (it must not use Router-only APIs like
// BackButtonListener, which threw "context does not include a Router").

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

void main() {
  Future<void> hideNativeKeyboard(WidgetTester tester) async {
    const channel = MethodChannel('iptvs/keyboard');
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('hidden')),
      (_) {},
    );
  }

  testWidgets('builds under a Navigator (no Router) and shows its hint', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'Search channels',
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Search channels'), findsOneWidget);
  });

  testWidgets('tapping enters edit mode and accepts input', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(controller: controller, hintText: 'hint'),
        ),
      ),
    );

    await tester.tap(find.byType(TvTextField));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), 'hello');
    expect(controller.text, 'hello');
  });

  testWidgets('one OK reopens a hidden keyboard while the editor keeps focus', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'bbc news');
    final cellFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(cellFocus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'Search channels',
            cellFocusNode: cellFocus,
            textInputAction: TextInputAction.search,
          ),
        ),
      ),
    );

    cellFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    final editorFocus = tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode;
    expect(editorFocus.hasPrimaryFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    const selection = TextSelection.collapsed(offset: 3);
    controller.selection = selection;
    // A floating TV IME can disappear without an inset or focus change.
    // Keep that editor focused, without sending the native hidden callback.
    tester.testTextInput.hide();
    await tester.pump();
    expect(editorFocus.hasPrimaryFocus, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(tester.testTextInput.isVisible, isTrue);
    expect(editorFocus.hasPrimaryFocus, isTrue);
    expect(controller.text, 'bbc news');
    expect(controller.selection, selection);
  });

  for (final tapToEdit in [true, false]) {
    for (final obscureText in [false, true]) {
      testWidgets(
        'Windows Ctrl+V pastes into ${obscureText ? 'password' : 'text'} '
        'field after ${tapToEdit ? 'clicking' : 'focusing'}',
        (tester) async {
          final controller = TextEditingController(text: 'before old after');
          final cellFocus = FocusNode();
          final changes = <String>[];
          addTearDown(controller.dispose);
          addTearDown(cellFocus.dispose);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async => switch (call.method) {
              'Clipboard.getData' => {'text': 'pasted'},
              'Clipboard.hasStrings' => {'value': true},
              _ => null,
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TvTextField(
                  controller: controller,
                  hintText: 'Paste here',
                  cellFocusNode: cellFocus,
                  obscureText: obscureText,
                  onChanged: changes.add,
                ),
              ),
            ),
          );
          if (tapToEdit) {
            await tester.tap(find.byType(TvTextField));
          } else {
            cellFocus.requestFocus();
          }
          await tester.pumpAndSettle();
          controller.selection = const TextSelection(
            baseOffset: 7,
            extentOffset: 10,
          );

          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();

          expect(controller.text, 'before pasted after');
          expect(
            controller.selection,
            const TextSelection.collapsed(offset: 13),
          );
          expect(changes, ['before pasted after']);
          expect(
            focusRouteKey(FocusManager.instance.primaryFocus),
            'TvTextField.field',
          );

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(cellFocus.hasPrimaryFocus, isTrue);
          controller.text = '';
          expect(controller.selection.isValid, isFalse);

          // Re-entering via paste also initializes an empty field's selection.
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();

          expect(controller.text, 'pasted');
          expect(
            controller.selection,
            const TextSelection.collapsed(offset: 6),
          );
          expect(changes, ['before pasted after', 'pasted']);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }
  }

  testWidgets('Back closes edit mode and restores focus to the search cell', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final cellFocus = RoutedFocusNode('search.cell');
    addTearDown(cellFocus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'Search channels',
            cellFocusNode: cellFocus,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TvTextField));
    await tester.pumpAndSettle();
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'TvTextField.field',
    );

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(focusRouteKey(FocusManager.instance.primaryFocus), 'search.cell');
    expect(find.byType(TvTextField), findsOneWidget);
  });

  testWidgets(
    'hiding the IME restores D-pad navigation and allows editing again',
    (tester) async {
      final controller = TextEditingController();
      final cellFocus = RoutedFocusNode('search.cell');
      final nextFocus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(cellFocus.dispose);
      addTearDown(nextFocus.dispose);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: Column(
              children: [
                TvTextField(
                  controller: controller,
                  hintText: 'Search channels',
                  cellFocusNode: cellFocus,
                ),
                TextButton(
                  focusNode: nextFocus,
                  onPressed: () {},
                  child: const Text('Next control'),
                ),
              ],
            ),
          ),
        ),
      );

      cellFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bbc');
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await tester.pumpAndSettle();

      // A shrinking inset during the IME animation must not end editing early.
      tester.view.viewInsets = const FakeViewPadding(bottom: 100);
      await tester.pump();
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'TvTextField.field',
      );

      // Android's IME consumes Back without a Navigator pop or field focus loss.
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();

      expect(cellFocus.hasPrimaryFocus, isTrue);
      expect(controller.text, 'bbc');
      expect(find.byType(TvTextField), findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(nextFocus.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(cellFocus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'TvTextField.field',
      );
      expect(tester.testTextInput.isVisible, isTrue);

      // With the keyboard open again, the app's Back path must also leave editing.
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pump();
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(cellFocus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(nextFocus.hasPrimaryFocus, isTrue);
    },
  );

  testWidgets(
    'metrics without an open IME keep hardware keyboard editing active',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvTextField(
              controller: controller,
              hintText: 'Search channels',
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TvTextField));
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(1000, 700);
      await tester.pumpAndSettle();
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'TvTextField.field',
      );
      await tester.enterText(find.byType(TextField), 'bbc');
      expect(controller.text, 'bbc');
    },
  );

  testWidgets('native IME dismissal restores navigation with zero insets', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'bbc');
    final cellFocus = RoutedFocusNode('search.cell');
    final nextFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(cellFocus.dispose);
    addTearDown(nextFocus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TvTextField(
                controller: controller,
                hintText: 'Search channels',
                cellFocusNode: cellFocus,
              ),
              TextButton(
                focusNode: nextFocus,
                onPressed: () {},
                child: const Text('Next control'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TvTextField));
    await tester.pumpAndSettle();
    expect(tester.view.viewInsets.bottom, 0);
    expect(tester.testTextInput.isVisible, isTrue);

    // Floating Android TV IMEs report visibility without occupying any inset.
    await hideNativeKeyboard(tester);
    await tester.pumpAndSettle();
    expect(cellFocus.hasPrimaryFocus, isTrue);
    expect(controller.text, 'bbc');
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(nextFocus.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'TvTextField.field',
    );
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('a late native hidden event cannot close the next edit', (
    tester,
  ) async {
    final controller = TextEditingController();
    final cellFocus = RoutedFocusNode('search.cell');
    addTearDown(controller.dispose);
    addTearDown(cellFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'Search channels',
            cellFocusNode: cellFocus,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TvTextField));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(cellFocus.hasPrimaryFocus, isTrue);

    // The engine buffers native messages while no handler is registered.
    // TestDefaultBinaryMessenger.handlePlatformMessage would drop this event
    // immediately and cannot reproduce the Android IME's delayed dismissal.
    const channel = MethodChannel('iptvs/keyboard');
    tester.binding.channelBuffers.push(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('hidden')),
      (_) {},
    );
    await tester.pump();

    await tester.tap(find.byType(TvTextField));
    await tester.pumpAndSettle();
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'TvTextField.field',
    );
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.enterText(find.byType(TextField), 'bbc');
    expect(controller.text, 'bbc');

    // A current dismissal still returns to D-pad navigation.
    await hideNativeKeyboard(tester);
    await tester.pumpAndSettle();
    expect(cellFocus.hasPrimaryFocus, isTrue);
  });

  testWidgets(
    'native dismissal reaches the active field and ignores inactive ones',
    (tester) async {
      final firstController = TextEditingController(text: 'first');
      final secondController = TextEditingController(text: 'second');
      final firstCell = FocusNode();
      final secondCell = FocusNode();
      final nextFocus = FocusNode();
      final showFirst = ValueNotifier(true);
      addTearDown(firstController.dispose);
      addTearDown(secondController.dispose);
      addTearDown(firstCell.dispose);
      addTearDown(secondCell.dispose);
      addTearDown(nextFocus.dispose);
      addTearDown(showFirst.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: showFirst,
              builder: (context, visible, _) => Column(
                children: [
                  if (visible)
                    TvTextField(
                      key: const ValueKey('first'),
                      controller: firstController,
                      hintText: 'First',
                      cellFocusNode: firstCell,
                    ),
                  TvTextField(
                    key: const ValueKey('second'),
                    controller: secondController,
                    hintText: 'Second',
                    cellFocusNode: secondCell,
                  ),
                  TextButton(
                    focusNode: nextFocus,
                    onPressed: () {},
                    child: const Text('Next control'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('first')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('second')));
      await tester.pumpAndSettle();
      // Disposing an earlier editor must not clear the current editor's handler.
      showFirst.value = false;
      await tester.pumpAndSettle();
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'TvTextField.field',
      );
      const channel = MethodChannel('iptvs/keyboard');
      tester.binding.channelBuffers.push(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('hidden')),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(secondCell.hasPrimaryFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(firstController.text, 'first');
      expect(secondController.text, 'second');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(nextFocus.hasPrimaryFocus, isTrue);
      await hideNativeKeyboard(tester);
      await tester.pump();
      expect(nextFocus.hasPrimaryFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final key in [LogicalKeyboardKey.goBack, LogicalKeyboardKey.escape]) {
    testWidgets('raw ${key.keyLabel} exits editing without popping the route', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'bbc');
      final cellFocus = FocusNode();
      final nextFocus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(cellFocus.dispose);
      addTearDown(nextFocus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Edit form')),
                      body: Column(
                        children: [
                          TvTextField(
                            controller: controller,
                            hintText: 'Search channels',
                            cellFocusNode: cellFocus,
                          ),
                          TextButton(
                            focusNode: nextFocus,
                            onPressed: () {},
                            child: const Text('Next control'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                child: const Text('Open form'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open form'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TvTextField));
      await tester.pumpAndSettle();
      expect(tester.view.viewInsets.bottom, 0);

      // Android remotes have a logical Back key but no dedicated scan-code
      // mapping in the test simulator. Keep its logical key with a known scan.
      const physicalKey = PhysicalKeyboardKey.escape;
      expect(
        await tester.sendKeyDownEvent(key, physicalKey: physicalKey),
        isTrue,
      );
      await tester.pump();
      expect(
        await tester.sendKeyUpEvent(key, physicalKey: physicalKey),
        isTrue,
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit form'), findsOneWidget);
      expect(cellFocus.hasPrimaryFocus, isTrue);
      expect(controller.text, 'bbc');
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(nextFocus.hasPrimaryFocus, isTrue);
    });
  }

  // Regression guard for the recurring "hint sits high on Android" bug: with
  // prefix/suffix icons inside the InputDecoration, the InputDecorator's
  // dense-layout vertical centering differed between platforms. The icons now
  // live in a manually centered Row, and these assertions pin the geometry on
  // both platforms so a future decorator change can't silently reintroduce it.
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('hint is vertically centered in the cell on $platform', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: TvTextField(
                  controller: controller,
                  hintText: 'Search channels',
                  height: 40,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final cellRect = tester.getRect(
        find.descendant(
          of: find.byType(TvTextField),
          matching: find.byType(Container),
        ),
      );
      final hintRect = tester.getRect(find.text('Search channels'));
      expect(
        hintRect.center.dy,
        moreOrLessEquals(cellRect.center.dy, epsilon: 1.0),
        reason: 'hint must be vertically centered within the 40px cell',
      );

      // Typed text must share the hint's geometry.
      await tester.tap(find.byType(TvTextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bbc');
      await tester.pump();
      final textRect = tester.getRect(
        find.descendant(
          of: find.byType(TextField),
          matching: find.byType(EditableText),
        ),
      );
      expect(
        textRect.center.dy,
        moreOrLessEquals(cellRect.center.dy, epsilon: 1.0),
        reason: 'entered text must be vertically centered within the cell',
      );
    });
  }

  // Regression guard for the double-border bug: under the app theme (whose
  // InputDecorationTheme sets OutlineInputBorders), a decoration that leaves
  // any border slot null gets it filled by applyDefaults — the InputDecorator
  // then paints a second rounded box *inside* the cell's own border. The
  // InputDecoration.collapsed constructor only sets `border`, so reverting to
  // it reintroduces the bug; this pins every slot to InputBorder.none.
  testWidgets('inner field paints no border under the app theme', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: TvTextField(controller: controller, hintText: 'hint'),
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    final decoration = field.decoration!.applyDefaults(
      Theme.of(tester.element(find.byType(TextField))).inputDecorationTheme,
    );
    expect(decoration.border, InputBorder.none);
    expect(decoration.enabledBorder, InputBorder.none);
    expect(decoration.focusedBorder, InputBorder.none);
    expect(decoration.errorBorder, InputBorder.none);
    expect(decoration.focusedErrorBorder, InputBorder.none);
    expect(decoration.disabledBorder, InputBorder.none);
    expect(decoration.filled, isFalse);
  });

  testWidgets('renders an external label when provided', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'Paste key',
            label: 'TMDB API credential',
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('TMDB API credential'), findsOneWidget);
  });

  // The clear (×) button is a sibling always-focusable stop *outside* the edit
  // barrier (the same pattern as the password show/hide toggle) — a suffixIcon
  // inside the barrier can never be reached by D-pad, which left the search
  // box's clear unusable on TV.
  testWidgets('clear button is a focusable D-pad stop and clears on OK', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'bbc');
    addTearDown(controller.dispose);
    var cleared = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'Search channels',
            showClear: true,
            onClear: () {
              cleared++;
              controller.clear();
            },
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.clear), findsOneWidget);

    // It's a real focus stop, reachable outside edit mode.
    final detector = tester.widget<FocusableActionDetector>(
      find
          .ancestor(
            of: find.byIcon(Icons.clear),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    final clearNode = detector.focusNode!;
    // Pin the release-safe route key the Back ladder branches on.
    expect(focusRouteKey(clearNode), 'TvTextField.clear');

    clearNode.requestFocus();
    await tester.pump();
    expect(
      clearNode.hasPrimaryFocus,
      isTrue,
      reason: 'the clear button must be focusable without entering edit mode',
    );

    // OK activates it: the field is cleared and focus is parked back on the
    // cell (the button disappears once the text empties).
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(cleared, 1);
    expect(controller.text, isEmpty);
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'TvTextField.cell',
      reason: 'after clearing, focus returns to the cell',
    );
  });

  testWidgets('a suffixIcon still renders when the clear button is off', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'hint',
            suffixIcon: const Icon(Icons.tune, size: 18),
            onClear: () {},
            // showClear defaults to false → the suffix slot falls back.
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.byIcon(Icons.clear), findsNothing);
  });
}
