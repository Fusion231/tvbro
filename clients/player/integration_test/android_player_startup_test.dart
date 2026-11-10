import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:iptvs/player/player_overlay.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/player/resource_counters.dart';
import 'package:iptvs/sources/source.dart';

const _nativeChannel = MethodChannel('iptvs/native_hdr_player');
const _previewChannel = MethodChannel('iptvs/native_preview');
const _storageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);
const _startupKey = ValueKey('native-player-startup');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) MediaKit.ensureInitialized();

  for (final adopt in [false, true]) {
    testWidgets(
      'Android native open (adopt=$adopt) paints loading before launch and keeps it after ACK',
      (tester) async {
        var opens = 0;
        var paints = 0;
        int? playersAtOpen;
        int? nativeOpenId;
        bool? requestedAdoption;
        final openCalled = Completer<void>();
        final openResult = Completer<bool>();
        _mockBridges(tester, (call) async {
          opens++;
          playersAtOpen = ResourceCounters.mediaKitPlayers;
          final args = call.arguments as Map;
          requestedAdoption = args['adoptShared'] as bool;
          nativeOpenId = args['nativeOpenId'] as int;
          expect(paints, greaterThan(0));
          _expectLoading(tester);
          openCalled.complete();
          return openResult.future;
        });

        await tester.pumpWidget(
          MaterialApp(
            home: _PaintObserver(
              onPaint: () => paints++,
              child: _player(adopt: adopt),
            ),
          ),
        );
        await tester.pump();
        await openCalled.future.timeout(const Duration(seconds: 3));
        _expectLoading(tester);
        openResult.complete(true);
        await tester.pump();
        _expectLoading(tester);
        expect(opens, 1);
        expect(playersAtOpen, 0);
        expect(requestedAdoption, adopt);
        expect(ResourceCounters.mediaKitPlayers, 0);
        expect(ResourceCounters.reconnectTimers, 0);

        await _nativeEvent(tester, 'nativePlayback', {
          'event': 'firstFrame',
          'nativeOpenId': nativeOpenId! - 1,
        });
        await tester.pump();
        _expectLoading(tester);
        await _nativeEvent(tester, 'nativePlayback', {
          'event': 'firstFrame',
          'nativeOpenId': nativeOpenId,
        });
        await tester.pump();
        if (adopt) {
          expect(find.byKey(_startupKey), findsNothing);
        }
        expect(find.byType(PlayerLoadingIndicator), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(ResourceCounters.mediaKitPlayers, 0);

        await _unmount(tester);
      },
      skip: !Platform.isAndroid,
    );
  }

  testWidgets(
    'System route pop during preferences never opens a native or Dart player',
    (tester) async {
      var opens = 0;
      var previewPauses = 0;
      final readStarted = Completer<void>();
      final preferences = Completer<String?>();
      _mockBridges(
        tester,
        (_) async {
          opens++;
          return true;
        },
        onRead: () {
          readStarted.complete();
          return preferences.future;
        },
        onPreviewPause: () => previewPauses++,
      );

      final route = await _pushPlayer(tester, loadPreferences: true);
      await readStarted.future.timeout(const Duration(seconds: 3));
      _expectLoading(tester);
      expect(opens, 0);

      await tester.binding.handlePopRoute();
      expect(route.isCurrent, isFalse);
      // Finish the read while the popped route still exists in its reverse
      // transition. A mounted check alone cannot prevent this late launch.
      expect(route.subtreeContext?.mounted, isTrue);
      preferences.complete(null);
      await tester.pump();
      expect(opens, 0);
      expect(previewPauses, 0);
      expect(ResourceCounters.mediaKitPlayers, 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.text('Library'), findsOneWidget);
      await _unmount(tester);
    },
    skip: !Platform.isAndroid,
  );

  testWidgets(
    'nativeClosed during pending open prevents a late false ACK from starting fallback',
    (tester) async {
      var opens = 0;
      var previewPauses = 0;
      final openCalled = Completer<void>();
      final openResult = Completer<bool>();
      _mockBridges(tester, (_) async {
        opens++;
        openCalled.complete();
        return openResult.future;
      }, onPreviewPause: () => previewPauses++);

      final route = await _pushPlayer(tester);
      await openCalled.future.timeout(const Duration(seconds: 3));
      _expectLoading(tester);
      await _nativeEvent(tester, 'nativeClosed');
      expect(route.isCurrent, isFalse);
      expect(route.subtreeContext?.mounted, isTrue);
      openResult.complete(false);
      await tester.pump();
      expect(opens, 1);
      expect(previewPauses, 0);
      expect(ResourceCounters.mediaKitPlayers, 0);
      expect(ResourceCounters.reconnectTimers, 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.text('Library'), findsOneWidget);
      await _unmount(tester);
    },
    skip: !Platform.isAndroid,
  );
}

PlayerScreen _player({bool adopt = true, bool loadPreferences = false}) =>
    PlayerScreen(
      title: 'Native startup',
      stream: StreamInfo(
        url: 'http://127.0.0.1:1/startup-test.m3u8',
        isLive: true,
      ),
      adoptNativePreview: adopt,
      dvrSourceId: loadPreferences ? 'startup-source' : null,
      dvrChannelId: loadPreferences ? 'startup-channel' : null,
    );

void _mockBridges(
  WidgetTester tester,
  Future<bool> Function(MethodCall) onOpen, {
  Future<String?> Function()? onRead,
  VoidCallback? onPreviewPause,
}) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_nativeChannel, (call) async {
    if (call.method == 'open') return onOpen(call);
    return true;
  });
  messenger.setMockMethodCallHandler(_previewChannel, (call) async {
    if (call.method == 'pause') onPreviewPause?.call();
    return null;
  });
  messenger.setMockMethodCallHandler(_storageChannel, (call) async {
    if (call.method == 'read') return onRead?.call();
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(_nativeChannel, null);
    messenger.setMockMethodCallHandler(_previewChannel, null);
    messenger.setMockMethodCallHandler(_storageChannel, null);
  });
}

void _expectLoading(WidgetTester tester) {
  expect(find.byType(PlayerLoadingIndicator), findsOneWidget);
  expect(find.byType(CircularProgressIndicator), findsOneWidget);
  final placeholder = find.byKey(_startupKey);
  expect(placeholder, findsOneWidget);
  expect(tester.widget<ColoredBox>(placeholder).color, Colors.black);
  expect(
    tester.getSize(placeholder),
    tester.getSize(find.byType(PlayerScreen)),
  );
  expect(
    find.descendant(
      of: placeholder,
      matching: find.byType(PlayerLoadingIndicator),
    ),
    findsOneWidget,
  );
}

Future<PageRouteBuilder<void>> _pushPlayer(
  WidgetTester tester, {
  bool loadPreferences = false,
}) async {
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: Text('Library'))),
  );
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  final route = PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => _player(loadPreferences: loadPreferences),
  );
  unawaited(navigator.push(route));
  await tester.pump();
  return route;
}

Future<void> _nativeEvent(
  WidgetTester tester,
  String method, [
  Map<String, Object?>? arguments,
]) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
  _nativeChannel.name,
  _nativeChannel.codec.encodeMethodCall(MethodCall(method, arguments)),
  (_) {},
);

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  expect(ResourceCounters.mediaKitPlayers, 0);
  expect(ResourceCounters.reconnectTimers, 0);
  expect(ResourceCounters.channelOwners, 0);
}

class _PaintObserver extends SingleChildRenderObjectWidget {
  const _PaintObserver({required this.onPaint, required super.child});

  final VoidCallback onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PaintObserverBox(onPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _PaintObserverBox renderObject,
  ) => renderObject.onPaint = onPaint;
}

class _PaintObserverBox extends RenderProxyBox {
  _PaintObserverBox(this.onPaint);

  VoidCallback onPaint;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPaint();
  }
}
