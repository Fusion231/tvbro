import '../data/net.dart';
import '../data/provider_stream_gate.dart';
import '../dvr/dvr_models.dart';
import '../l10n/app_localizations.dart';

/// Player engines may attach private stream locators to their errors. Only
/// known causes or fixed guidance belong in playback UI.
String playbackErrorMessage(Object error) {
  if (error is DvrException) return tr(error.message);
  if (error is ProviderStreamLimitReached) return error.toString();
  if (isProviderConnectionError(error)) return sourceLoadErrorMessage(error);
  final message = '$error'.toLowerCase();
  if (message.contains('codec') ||
      message.contains('decoder') ||
      message.contains('unsupported format')) {
    return tr(
      'This device could not decode the stream. Try another channel or playback engine.',
    );
  }
  return tr(
    'The stream could not be started. Try again; if the problem persists, contact your provider.',
  );
}

String lostPlaybackConnectionMessage([Object? cause]) {
  final message = tr(
    'The connection to the stream was lost. Automatic reconnection failed. Check your connection and try again.',
  );
  return cause != null && isProviderConnectionError(cause)
      ? '$message\n${sourceLoadErrorMessage(cause)}'
      : message;
}
