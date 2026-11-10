import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

Future<Directory> isolatedHostDirectory(
  String environmentKey,
  String prefix,
) async {
  final configured = Platform.environment[environmentKey];
  if (configured == null) {
    throw StateError('Use tv/native_probe/run.ps1 to create isolated storage.');
  }
  // Flutter's compiled test runtime has no Isolate.resolvePackageUri. Read the
  // same generated package config passed to the CLI with --packages instead.
  final config = jsonDecode(
    await File(
      p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
    ).readAsString(),
  ) as Map;
  final owner = (config['packages'] as List).cast<Map>().singleWhere(
    (package) => package['name'] == 'iptvs',
  );
  final ownerUri = Uri.parse(owner['rootUri'] as String);
  if (ownerUri.scheme != 'file') {
    throw StateError('The original iptvs package must resolve to local files.');
  }
  final app = Directory.fromUri(ownerUri).path;
  final output = Directory(p.join(app, 'tv', 'output', 'native-probe'))
      .resolveSymbolicLinksSync();
  if (!p.equals(Directory.current.resolveSymbolicLinksSync(), output)) {
    throw StateError('Storage proof must run from its isolated TV output.');
  }
  final directory = Directory(configured).resolveSymbolicLinksSync();
  if (!p.equals(p.dirname(directory), output) ||
      !RegExp('^${RegExp.escape(prefix)}-[0-9a-f]{32}\$')
          .hasMatch(p.basename(directory))) {
    throw StateError('Storage must be a fresh direct child of probe output.');
  }
  return Directory(directory);
}

class IsolatedHostPaths extends PathProviderPlatform {
  IsolatedHostPaths(this.path);

  final String path;

  @override
  Future<String> getApplicationSupportPath() async => path;

  @override
  Future<String> getTemporaryPath() async => path;
}
