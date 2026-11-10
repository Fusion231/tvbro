import 'package:media_kit/media_kit.dart';

class MpvHttpResponseMonitor {
  int get observedEventCount => 0;
  static Future<MpvHttpResponseMonitor?> attach(
    NativePlayer player, {
    required void Function(int status) onRefusal,
  }) async => null;
  void begin(String url) {}
  void dispose() {}
}
