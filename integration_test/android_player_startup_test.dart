import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/player/resource_counters.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  const channel = MethodChannel('iptvs/native_hdr_player');

  for (final adopt in [false, true]) {
    testWidgets(
      'Android native open (adopt=$adopt) never creates a Dart player',
      (tester) async {
        var opens = 0;
        int? playersAtOpen;
        bool? requestedAdoption;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'open') {
              opens++;
              playersAtOpen = ResourceCounters.mediaKitPlayers;
              requestedAdoption = (call.arguments as Map)['adoptShared'] as bool;
            }
            return true;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
        });

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              title: 'Native startup',
              stream: StreamInfo(
                url: 'http://127.0.0.1:1/startup-test.m3u8',
                isLive: true,
              ),
              adoptNativePreview: adopt,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(opens, 1);
        expect(playersAtOpen, 0);
        expect(requestedAdoption, adopt);
        expect(ResourceCounters.mediaKitPlayers, 0);
        expect(ResourceCounters.reconnectTimers, 0);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(ResourceCounters.mediaKitPlayers, 0);
        expect(ResourceCounters.channelOwners, 0);
      },
      skip: !Platform.isAndroid,
    );
  }
}
