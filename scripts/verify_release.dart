import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'package:iptvs/data/update_manifest.dart';

/// Uses the same manifest verifier as the installed application, before upload.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) {
    stderr.writeln(
      'Usage: dart --packages=clients/player/.dart_tool/package_config.json scripts/verify_release.dart <directory> <version> <public-key-base64> (from the repository root)',
    );
    exitCode = 2;
    return;
  }
  final directory = arguments[0];
  final version = arguments[1];
  final manifestFile = File(
    path.join(directory, 'iptvs-$version-manifest.json'),
  );
  final manifest = await const ReleaseManifestVerifier().verify(
    manifestBytes: await manifestFile.readAsBytes(),
    signatureBase64: await File('${manifestFile.path}.sig').readAsString(),
    publicKeyBase64: arguments[2],
  );
  if (manifest.version != version) {
    throw const FormatException(
      'Requested version differs from signed version',
    );
  }
  if (manifest.artifacts.isEmpty) {
    throw const FormatException('No supported release artifacts');
  }
  for (final artifact in manifest.artifacts.values) {
    final file = File(path.join(directory, artifact.filename));
    if (await file.length() != artifact.byteSize ||
        (await sha256.bind(file.openRead()).first).toString() !=
            artifact.sha256) {
      throw FormatException(
        'Artifact does not match signed manifest: ${artifact.filename}',
      );
    }
  }
  stdout.writeln(
    jsonEncode({
      'version': manifest.version,
      'signature_verified': true,
      'verified_artifacts': manifest.artifacts.keys.toList(),
    }),
  );
}
