import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/player/playback_error.dart';

void main() {
  test('playback retains the network cause without exposing a locator', () {
    final error = TimeoutException('https://user:password@private.test/live');
    final message = playbackErrorMessage(error);
    expect(message, sourceLoadErrorMessage(error));
    expect(message, isNot(contains('private.test')));
    expect(message, isNot(contains('password')));
  });

  test('unknown and decoder failures receive fixed actionable guidance', () {
    expect(
      playbackErrorMessage(StateError('Failed to open https://secret.test')),
      contains('contact your provider'),
    );
    expect(
      playbackErrorMessage(StateError('decoder failed at https://secret.test')),
      contains('could not decode'),
    );
    expect(
      playbackErrorMessage(StateError('decoder failed at https://secret.test')),
      isNot(contains('secret.test')),
    );
  });

  test('terminal recovery names both the interruption and its last cause', () {
    const cause = SocketException('Connection reset by peer');
    final message = lostPlaybackConnectionMessage(cause);
    expect(message, contains('Automatic reconnection failed'));
    expect(message, contains(sourceLoadErrorMessage(cause)));
  });

  test('playback guidance is localized', () {
    AppLanguageController.instance.preview(AppLanguage.polish);
    addTearDown(
      () => AppLanguageController.instance.preview(AppLanguage.english),
    );
    expect(lostPlaybackConnectionMessage(), contains('Utracono połączenie'));
    expect(playbackErrorMessage(StateError('unknown')), contains('strumienia'));
  });
}
