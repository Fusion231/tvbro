import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

const _deviceChannel = MethodChannel('iptvs/device');

/// An app-scoped hint for recognizing a device during account-approved pairing.
///
/// Native code supplies platform/user/app-scoped material inside the app process.
/// Only its SHA-256 digest leaves this helper. It is never an authentication
/// credential: a matching hint cannot grant account or Supporter access alone.
/// Unsupported platforms and unavailable native identifiers return null, leaving
/// the existing anonymous-session pairing flow available.
Future<String?> detectDeviceIdentity({
  String? operatingSystem,
  MethodChannel channel = _deviceChannel,
}) async {
  final platform = operatingSystem ?? Platform.operatingSystem;
  if (platform != 'android' && platform != 'windows') return null;
  try {
    final scope = await channel.invokeMethod<String>('stableIdentity');
    if (scope == null ||
        scope.isEmpty ||
        scope.length > 512 ||
        scope.trim() != scope ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(scope)) {
      return null;
    }
    return sha256
        .convert(utf8.encode('tvbro-device-v1|$platform|$scope'))
        .toString();
  } catch (_) {
    // Native failures, old runners and malformed channel replies must not stop
    // users from pairing. Never log the underlying platform identifier.
    return null;
  }
}
