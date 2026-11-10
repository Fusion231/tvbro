import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:crypto/crypto.dart';

String digest(List<int> bytes) => sha256.convert(bytes).toString();

String? declarationName(AstNode node) {
  if (node is ClassDeclaration) return node.name.lexeme;
  if (node is FunctionDeclaration) return node.name.lexeme;
  if (node is EnumDeclaration) return node.name.lexeme;
  if (node is ExtensionDeclaration) return node.name?.lexeme;
  if (node is TypeAlias) return node.name.lexeme;
  if (node is TopLevelVariableDeclaration) {
    if (node.variables.variables.length != 1) throw StateError('Grouped declaration requires explicit handling');
    return node.variables.variables.single.name.lexeme;
  }
  if (node is MethodDeclaration) return node.name.lexeme;
  return null;
}

Future<void> main(List<String> args) async {
  if (args.length != 4 && args.length != 5) {
    throw ArgumentError('Usage: build_core.dart OWNER OUT DART FLUTTER_TOOLS_PACKAGE_CONFIG [PLAYER_PACKAGE_CONFIG]');
  }
  final owner = Directory(args[0]).absolute.path;
  final playerRoot = Directory.fromUri(Directory(owner).uri.resolve('clients/player/')).path;
  final output = Directory(args[1]).absolute;
  final dart = File(args[2]).absolute.path;
  final toolsConfig = File(args[3]).absolute;
  String sourcePath(String relative) => 'clients/player/$relative';
  String sourceUri(String relative) => 'owner://${sourcePath(relative)}';
  output.createSync(recursive: true);
  final texts = <String, String>{};
  final fileHashes = <String, String>{};
  final units = <String, dynamic>{};
  dynamic unit(String relative) {
    if (units.containsKey(relative)) return units[relative];
    final file = File('$playerRoot/$relative');
    final bytes = file.readAsBytesSync();
    final text = utf8.decode(bytes);
    final parsed = parseString(content: text, path: file.absolute.path, throwIfDiagnostics: false);
    if (parsed.errors.isNotEmpty) throw StateError('AST parse errors: $relative: ' + parsed.errors.toString());
    texts[relative] = text;
    fileHashes[sourcePath(relative)] = digest(bytes);
    return units[relative] = parsed;
  }

  final proof = <Map<String, dynamic>>[];
  final emitted = <String, Set<String>>{};
  final generated = StringBuffer(imports);
  String capture(String relative, AnnotatedNode node, String label) {
    final parsed = unit(relative);
    final text = texts[relative]!;
    for (final annotation in node.metadata) {
      final name = annotation.name.toSource();
      if (!const {'immutable', 'visibleForTesting', 'override'}.contains(name)) {
        throw StateError('Unreviewed metadata: $relative $label $name');
      }
    }
    final start = node.firstTokenAfterCommentAndMetadata.offset;
    final body = text.substring(start, node.end);
    proof.add({
      'sourceUri': sourceUri(relative), 'declaration': label,
      'offsetUnits': 'UTF-16', 'startOffset': start, 'endOffsetExclusive': node.end,
      'startLine': parsed.lineInfo.getLocation(start).lineNumber,
      'endLine': parsed.lineInfo.getLocation(node.end - 1).lineNumber,
      'bodySha256': digest(utf8.encode(body)),
      'metadataOmitted': node.metadata.map((m) => m.name.toSource()).toList(),
      'bodyVerbatim': true,
    });
    return body;
  }

  void declarations(String relative, Set<String>? selected, {StringBuffer? target}) {
    final parsed = unit(relative);
    final found = <String>{};
    for (final CompilationUnitMember node in parsed.unit.declarations) {
      final name = declarationName(node);
      if (name == null) throw StateError('Unnamed/unhandled top-level AST node in $relative');
      if (selected != null && !selected.contains(name)) continue;
      found.add(name);
      if (!(emitted[relative] ??= <String>{}).add(name)) continue;
      (target ?? generated).writeln(capture(relative, node, name));
    }
    if (selected != null && !found.containsAll(selected)) {
      throw StateError('Missing canonical declarations: $relative ' + selected.difference(found).toString());
    }
  }

  declarations('lib/data/load_token.dart', null);
  declarations('lib/sources/source.dart', null);
  declarations('lib/sources/expiry.dart', null);
  declarations('lib/data/net.dart', {'HttpWorkloadPolicy', '_mib', 'kPlaylistWorkload', 'kProviderJsonWorkload', 'kMetadataJsonWorkload'});
  declarations('lib/data/secret_locator_vault.dart', {'secretLocatorKey', 'hasSealedLocator'});
  declarations('lib/sources/source_identity.dart', null);
  declarations('lib/sources/source_config.dart', {'newSourceId'});
  declarations('lib/sources/m3u_catalog.dart', null);
  declarations('lib/sources/m3u_source.dart',
      {'M3uParsed', '_parseM3uBytes', 'parseM3uPlaylist', 'm3uPlaybackHeaders', '_attr', '_headerEpgAttribute', '_name'});
  declarations('lib/sources/xtream_source.dart', {
    'kXtreamStreamExtensions', 'resolveXtreamStreamExtension',
    'mapLiveChannels', 'decodeLiveChannelsBytes', 'mapMediaItemsFromDecoded',
    'XtreamMediaDecodeArgs', 'decodeMediaItemsBytes', '_mapMediaItem',
    '_listFromAny', '_parseInt', '_archiveDays', '_parseDouble',
    '_firstString', '_firstImageUrl',
  });

  MethodDeclaration member(String relative, String className, String name) {
    final parsed = unit(relative);
    final classes = parsed.unit.declarations.whereType<ClassDeclaration>()
        .where((c) => c.name.lexeme == className).toList();
    if (classes.length != 1) throw StateError('Expected one class $className');
    final members = classes.single.members.whereType<MethodDeclaration>()
        .where((m) => m.name.lexeme == name).toList();
    if (members.length != 1) throw StateError('Expected one method $className.$name');
    return members.single;
  }

  const xtream = 'lib/sources/xtream_source.dart';
  generated.writeln(xtreamBindingStart);
  for (final name in ['_base', '_credentialPath', 'resolve', '_hasPositiveAuthentication']) {
    generated.writeln(capture(xtream, member(xtream, 'XtreamSource', name), 'XtreamSource.$name'));
  }
  final apiMethod = member(xtream, 'XtreamSource', '_apiUnshared');
  final body = apiMethod.body;
  if (body is! BlockFunctionBody) throw StateError('Unexpected _apiUnshared body');
  final uriStatements = body.block.statements.whereType<VariableDeclarationStatement>()
      .where((s) => s.variables.variables.any((v) => v.name.lexeme == 'uri')).toList();
  if (uriStatements.length != 1) throw StateError('Expected one canonical API URI statement');
  final uriNode = uriStatements.single;
  final uriText = texts[xtream]!.substring(uriNode.offset, uriNode.end);
  proof.add({
    'sourceUri': sourceUri(xtream), 'declaration': 'XtreamSource._apiUnshared::uri',
    'offsetUnits': 'UTF-16', 'startOffset': uriNode.offset, 'endOffsetExclusive': uriNode.end,
    'startLine': unit(xtream).lineInfo.getLocation(uriNode.offset).lineNumber,
    'endLine': unit(xtream).lineInfo.getLocation(uriNode.end - 1).lineNumber,
    'bodySha256': digest(utf8.encode(uriText)), 'metadataOmitted': [], 'bodyVerbatim': true,
  });
  generated.writeln('String apiUrl(Map<String, String> params) {');
  generated.writeln(uriText);
  generated.writeln('return uri.toString(); }');
  String excerpt(String relative, int start, int end, String label) {
    final text = texts[relative]!.substring(start, end);
    proof.add({
      'sourceUri': sourceUri(relative), 'declaration': label,
      'offsetUnits': 'UTF-16', 'startOffset': start, 'endOffsetExclusive': end,
      'startLine': unit(relative).lineInfo.getLocation(start).lineNumber,
      'endLine': unit(relative).lineInfo.getLocation(end - 1).lineNumber,
      'bodySha256': digest(utf8.encode(text)), 'metadataOmitted': [], 'bodyVerbatim': true,
    });
    return text;
  }
  final authentication = member(xtream, 'XtreamSource', '_authenticate');
  final authenticationBody = authentication.body as BlockFunctionBody;
  final accountRead = authenticationBody.block.statements.whereType<ExpressionStatement>()
      .where((s) => s.expression is MethodInvocation &&
          (s.expression as MethodInvocation).methodName.name == '_readStreamAccount').toList();
  if (accountRead.length != 1) throw StateError('Authentication prefix boundary changed');
  generated.writeln('Future<void> validateAuth(Object? input) async { _input = input;');
  generated.writeln(excerpt(xtream, authenticationBody.block.leftBracket.end,
      accountRead.single.offset, 'XtreamSource._authenticate::status-expiry-prefix'));
  generated.writeln('}');
  final categories = member(xtream, 'XtreamSource', 'categories').body as BlockFunctionBody;
  final statements = categories.block.statements;
  if (statements.length < 2 || statements.first is! VariableDeclarationStatement ||
      (statements.first as VariableDeclarationStatement).variables.variables.single.name.lexeme != 'r') {
    throw StateError('Categories transport boundary changed');
  }
  generated.writeln('List<Category> categoriesFromDecoded(dynamic r) {');
  generated.writeln(excerpt(xtream, statements[1].offset, statements.last.end,
      'XtreamSource.categories::after-transport'));
  generated.writeln('}');
  generated.writeln('}');
  generated.writeln('class CanonicalSourceConfigBinding { final Map<String, String> fields; CanonicalSourceConfigBinding(this.fields);');
  generated.writeln(capture('lib/sources/source_config.dart',
      member('lib/sources/source_config.dart', 'SourceConfig', '_opt'), 'SourceConfig._opt'));
  generated.writeln('}');
  generated.writeln('class CanonicalM3uBinding { final String? userAgent; CanonicalM3uBinding(this.userAgent); ProviderStreamAccount? get streamAccount => null;');
  generated.writeln(capture('lib/sources/m3u_source.dart',
      member('lib/sources/m3u_source.dart', 'M3uSource', 'resolve'), 'M3uSource.resolve'));
  generated.writeln('}');
  // Entire provider classes remain verbatim. Only their native IO vocabulary
  // is bound to the browser transport/session resources below.
  declarations('lib/data/net.dart', {
    'HttpReadMetrics', 'kEpgWorkload', 'kStalkerJsonWorkload',
    'isTransientHttpStatus', 'HttpWorkloadException', 'isTransientNetworkError',
    'providerHttpRefusalStatus',
    'HttpOperation', 'readBoundedBytes', 'writeBoundedStreamToFile',
    '_consumeWithTimeouts', 'formatBytes', '_checkContentLength', '_checkLimit',
    '_isGzip', 'isGzipBytes', 'decodeGzipBounded', '_BoundedByteSink',
    'redactText', '_kCredentialPathKeywords', '_redactUrlPath', 'redactUrl',
  });
  for (final relative in [
    'lib/data/metadata_config.dart',
    'lib/data/metadata_provider.dart',
    'lib/data/metadata_clients.dart',
    'lib/data/tmdb_client.dart',
    'lib/data/tvdb_client.dart',
    'lib/data/mdblist_client.dart',
    'lib/data/tvmaze_client.dart',
  ]) {
    declarations(relative, null);
  }
  const repository = 'lib/data/library_repository.dart';
  const metadataMethodNames = [
    '_mergeCachedMetadata',
    '_applyChildExternalMetadata',
    '_applyOneChildExternalMetadata',
    '_supportsMetadata',
    '_shouldLookupMetadata',
    '_hasExternalMetadataId',
    '_applyExternalMetadata',
    '_mergeMetadata',
    'cachedExternalMetadata',
    'cacheExternalMetadata',
    'mergeExternalMetadata',
    'refreshExternalMetadata',
    '_enrichConcurrency',
    'enrichMediaMetadata',
  ];
  final metadataBindingsFile = File.fromUri(Platform.script.resolve('metadata_bindings.dart.txt'));
  final metadataBindingsText = metadataBindingsFile.readAsStringSync();
  final methodMarker = '// __LIBRARY_REPOSITORY_METADATA_METHODS__';
  if (metadataBindingsText.split(methodMarker).length != 2) {
    throw StateError('Expected one metadata repository insertion point');
  }
  final metadataClassMarker = metadataBindingsText.indexOf('class _WebMetadata {');
  final metadataMarkerOffset = metadataBindingsText.indexOf(methodMarker);
  if (metadataClassMarker < 0 || metadataMarkerOffset < metadataClassMarker) {
    throw StateError('Metadata repository methods must be inside _WebMetadata');
  }
  final repositoryMethods = StringBuffer();
  for (final name in metadataMethodNames) {
    final parsed = unit(repository);
    final repositoryClass = (parsed.unit as CompilationUnit).declarations.whereType<ClassDeclaration>()
        .singleWhere((c) => c.name.lexeme == 'LibraryRepository');
    final memberNode = repositoryClass.members.where((member) =>
        member is MethodDeclaration && member.name.lexeme == name ||
        member is FieldDeclaration && member.fields.variables.any((variable) => variable.name.lexeme == name)).toList();
    if (memberNode.length != 1) throw StateError('Expected one LibraryRepository.$name');
    repositoryMethods.writeln(capture(repository, memberNode.single, 'LibraryRepository.$name'));
  }
  final metadataPort = metadataBindingsText.replaceFirst(methodMarker, repositoryMethods.toString());
  generated.writeln(metadataPort);
  const metadataBindingsRelative = 'clients/tv/samsung_web/core_builder/metadata_bindings.dart.txt';
  fileHashes[metadataBindingsRelative] = digest(metadataBindingsFile.readAsBytesSync());
  declarations('lib/data/provider_request_gate.dart', null);
  declarations('lib/sources/epg_matching.dart', null);
  declarations('lib/sources/epg_mapping.dart', null);
  // The browser IO port adds document validation before committing raw files.
  final xmltvDeclarations=(unit('lib/sources/xmltv.dart').unit as CompilationUnit)
    .declarations.map(declarationName).whereType<String>().toSet()..remove('_guideEvents');
  declarations('lib/sources/xmltv.dart', xmltvDeclarations);
  declarations('lib/sources/epg_guides.dart', null);
  declarations('lib/sources/m3u_source.dart', null);
  declarations('lib/sources/xtream_source.dart', null);
  declarations('lib/sources/stalker_source.dart', null);
  declarations('lib/sources/demo_source.dart', null);
  declarations('lib/sources/source_config.dart', null);
  declarations('lib/player/episode_navigation.dart', {'orderPlaybackEpisodes', 'adjacentPlaybackEpisode'});
  final presentation = StringBuffer("import 'canonical.generated.dart' show MediaItem;\n");
  declarations('lib/data/media_info.dart', null, target: presentation);
  declarations('lib/data/media_trailer.dart', null, target: presentation);
  declarations('lib/data/source_hint_parser.dart', null, target: presentation);
  final presentationFile = File(output.path + '/canonical.media_presentation.dart');
  presentationFile.writeAsStringSync(presentation.toString());
  declarations('lib/data/profile_pin.dart', null);
  declarations('lib/data/parental_controls.dart', {'ParentalRules'});
  declarations('lib/data/supporter_status.dart', null);
  declarations('lib/data/local_profile_store.dart', {'ProfileSnapshot', 'LocalProfile', 'ProfilePickerStartup', 'shouldShowPickerAtStartup'});
  declarations('lib/data/distribution_channel.dart', {'DistributionChannel', 'parseDistributionChannel', 'DistributionChannelPolicy', 'DistributionConfig'});
  declarations('lib/data/cloud_config.dart', {'CloudConfig', 'panelAccountLink', 'panelUrlForChannel', 'isConfiguredApiUrl', 'isConfiguredPanelUrl', 'pairingPanelLink'});
  // Locale is a Flutter value at this boundary; translations and supported
  // language definitions below remain the application's original Dart.
  generated.writeln('class Locale { final String languageCode; const Locale(this.languageCode); }');
  declarations('lib/l10n/app_language.dart', {'AppLanguage'});
  for (final file in ['messages_browsing.dart', 'messages_settings.dart', 'messages_player.dart', 'messages_onboarding.dart']) {
    declarations('lib/l10n/$file', null);
  }
  declarations('lib/l10n/app_localizations.dart', {'polishMessages', 'translate'});
  declarations(repository, {'LibrarySnapshot'});
  final repositoryClass = (unit(repository).unit as CompilationUnit).declarations.whereType<ClassDeclaration>()
      .singleWhere((c) => c.name.lexeme == 'LibraryRepository');
  generated.writeln('class CanonicalTvCachePolicy {');
  for (final name in ['catalogMaxAge', '_epgMaxAge']) {
    final field = repositoryClass.members.whereType<FieldDeclaration>()
        .singleWhere((f) => f.fields.variables.any((v) => v.name.lexeme == name));
    generated.writeln(capture(repository, field, 'LibraryRepository.' + name));
  }
  final retryDelays = <Expression>[];
  void findRetryDelay(AstNode node) {
    if (node is MethodInvocation && node.methodName.name == 'deferRetry') {
      final deadline = node.argumentList.arguments.last;
      if (deadline is MethodInvocation && deadline.methodName.name == 'add') {
        retryDelays.add(deadline.argumentList.arguments.single);
      } else if (deadline is! NullLiteral) { throw StateError('Unexpected EPG retry deadline'); }
    }
    for (final child in node.childEntities.whereType<AstNode>()) { findRetryDelay(child); }
  }
  findRetryDelay(repositoryClass);
  final retryDelay = retryDelays.single;
  generated.writeln('static const epgRetryDelay = ' + excerpt(repository, retryDelay.offset, retryDelay.end, 'LibraryRepository.epgIngest.deferRetry.delay') + ';');
  generated.writeln('}');
  const database = 'lib/data/app_database.dart';
  final ClassDeclaration databaseClass = (unit(database).unit as CompilationUnit).declarations.whereType<ClassDeclaration>()
      .singleWhere((c) => c.name.lexeme == 'AppDatabase');
  final finishedFraction = databaseClass.members.whereType<FieldDeclaration>()
      .singleWhere((f) => f.fields.variables.any((v) => v.name.lexeme == 'kFinishedFraction'));
  generated.writeln('class CanonicalResumeDecision { String action = "ignore"; int? positionMs, durationMs;');
  generated.writeln(capture(database, finishedFraction, 'AppDatabase.kFinishedFraction'));
  for (final name in ['savePlaybackPosition', 'clearPlaybackPosition']) {
    generated.writeln(capture(database, member(database, 'AppDatabase', name), 'AppDatabase.$name'));
  }
  generated.writeln('Future<void> _writePlaybackPosition(String sourceId, ContentKind kind, String itemId, {required int positionMs, required int durationMs, required bool removed}) async { action = removed ? "clear" : "save"; this.positionMs = positionMs; this.durationMs = durationMs; } }');
  declarations(database, {'PlaybackPosition'});
  generated.writeln('class AppDatabase { static const kFinishedFraction=CanonicalResumeDecision.kFinishedFraction; }');
  declarations('lib/data/series_watch_progress.dart', {'SeriesWatchProgress'});
  const guideScreen = 'lib/screens/epg_grid_screen.dart';
  final screenClass = (unit(guideScreen).unit as CompilationUnit).declarations.whereType<ClassDeclaration>()
      .singleWhere((c) => c.members.whereType<MethodDeclaration>().any((m) => m.name.lexeme == '_showProgrammeDetails'));
  final guideBody = (member(guideScreen, screenClass.name.lexeme, '_showProgrammeDetails').body as BlockFunctionBody).block;
  generated.writeln('JSBoolean canCatchupBridge(JSString channelText, JSString programmeText, JSString nowText) { final channel = channelFromJson(objectJson(channelText.toDart)); final programme = programmeFromJson(objectJson(programmeText.toDart)); final now = DateTime.parse(nowText.toDart);');
  for (final name in ['isPast', 'canCatchup']) {
    final statement = guideBody.statements.whereType<VariableDeclarationStatement>()
        .singleWhere((s) => s.variables.variables.any((v) => v.name.lexeme == name));
    generated.writeln(excerpt(guideScreen, statement.offset, statement.end, '_showProgrammeDetails::$name'));
  }
  generated.writeln('return canCatchup.toJS; }');
  final portFile = File.fromUri(Platform.script.resolve('web_bindings.dart.txt'));
  generated.writeln(portFile.readAsStringSync());
  generated.writeln(bridge);
  final source = File(output.path + '/canonical.generated.dart');
  source.writeAsStringSync(generated.toString());

  // Keep generator tooling separate, but compile business with the exact
  // player's cached pure dependencies. No pub resolution occurs in the player.
  final merged = jsonDecode(toolsConfig.readAsStringSync()) as Map<String, dynamic>;
  final packages = (merged['packages'] as List).map((p) => Map<String, dynamic>.from(p as Map)).toList();
  // An isolated validation environment may supply the same pinned pure
  // dependencies without resolving the unrelated Flutter/native application.
  final playerConfig = File(args.length == 5 ? args[4] : '$playerRoot/.dart_tool/package_config.json').absolute;
  final playerPackages = jsonDecode(playerConfig.readAsStringSync())['packages'] as List;
  final sourceDependencies = <Map<String, dynamic>>[];
  for (final name in ['xml', 'petitparser', 'meta', 'collection', 'crypto', 'timezone', 'qr']) {
    final entries = playerPackages.where((p) => p['name'] == name).toList();
    if (entries.length != 1) throw StateError('Expected cached player package: $name');
    final entry = Map<String, dynamic>.from(entries.single);
    entry['rootUri'] = playerConfig.uri.resolve(entry['rootUri'] as String).toString();
    packages.removeWhere((p) => p['name'] == name);
    packages.add(entry);
    final pubspec = File.fromUri(Directory.fromUri(Uri.parse(entry['rootUri'] as String)).uri.resolve('pubspec.yaml'));
    sourceDependencies.add({'name': name, 'rootUri': entry['rootUri'],
      'pubspecSha256': digest(pubspec.readAsBytesSync())});
  }
  for (final package in packages) {
    package['rootUri'] = toolsConfig.uri.resolve(package['rootUri'] as String).toString();
  }
  merged['packages'] = packages;
  final packageConfig = File(output.path + '/package_config.json');
  packageConfig.writeAsStringSync(jsonEncode(merged));
  final version = await Process.run(dart, ['--version']);
  final result = await Process.run(dart, [
    'compile', 'js', '--packages=' + packageConfig.absolute.path,
    '-O2', '-o', output.path + '/core.js', source.absolute.path,
  ]);
  File(output.path + '/compile.log').writeAsStringSync(result.stdout.toString() + result.stderr.toString());
  for (final input in fileHashes.entries) {
    if (digest(File('$owner/' + input.key).readAsBytesSync()) != input.value) {
      throw StateError('Original source changed during generation: ' + input.key);
    }
  }
  final manifest = <String, dynamic>{
    'schemaVersion': 1, 'status': result.exitCode == 0 ? 'canonical_core_compiled' : 'compile_failed',
    'owner': owner, 'playerRoot': playerRoot,
    'dartVersion': (version.stdout.toString() + version.stderr.toString()).trim(),
    'parser': 'installed analyzer 10.1.0 AST', 'sourceFilesSha256': fileHashes,
    'originalSourcesUnchanged': true, 'declarations': proof,
    'sourceDependencies': sourceDependencies,
    'generatedDartSha256': digest(source.readAsBytesSync()),
    'generatedLibrariesSha256': {'canonical.media_presentation.dart': digest(presentationFile.readAsBytesSync())},
    'compilerExitCode': result.exitCode,
    'jsSha256': result.exitCode == 0 ? digest(File(output.path + '/core.js').readAsBytesSync()) : null,
    'scope': 'Original SourceConfig and complete M3U/Xtream/Stalker/Demo Source classes, XMLTV/matching/merge, request admission/retries and pure parental/PIN rules. No LibraryRepository, SQLite, cloud or Flutter widgets.',
    'bindings': {
      'newCode': 'JSON/JS DTO projections and browser transport/session IO ports',
      'providerAccountMetadata': 'Full Source retains original metadata; legacy standalone URL helpers omit it',
      'nativeImportsRemoved': true,
      'annotationsOmitted': ['immutable', 'visibleForTesting', 'override'],
      'webPortSha256': digest(portFile.readAsBytesSync()),
      'metadataPortSha256': fileHashes[metadataBindingsRelative],
      'transport': 'Injected physical GET callback; no silent header omission',
      'filesAndGuideHeaderCache': 'Session memory IO; catalog snapshots restore M3U guide hints. One XMLTV download uses the native EPG max-age and a 32 MiB ceiling',
      'workers': 'Source engine hosted by platform/source_worker.js; internal isolate channels stay in that browser Worker',
    },
    'chrome47RuntimeQualified': false,
  };
  File(output.path + '/reuse-proof.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) exitCode = result.exitCode;
  stdout.writeln('Canonical declarations: ' + proof.length.toString());
}

const imports = '''
// Generated from owner AST declarations. Do not hand-edit business rules.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:math' as math;
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'canonical.media_presentation.dart' as media_presentation;
import 'package:crypto/crypto.dart';
import 'package:qr/qr.dart' as qr;
import 'package:meta/meta.dart' show immutable, visibleForTesting;
import 'package:xml/xml_events.dart';
import 'package:archive/archive.dart' as archive;
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;
''';

const xtreamBindingStart = '''
// Platform input binding for exact owner URL/positive-auth method bodies.
class CanonicalXtreamBinding {
  final String host, username, password, streamExtension;
  CanonicalXtreamBinding(this.host, this.username, this.password, this.streamExtension);
  ProviderStreamAccount? get streamAccount => null;
  Object? _input;
  DateTime Function()? debugNow;
  Future<dynamic> _api(Map<String, String> params) async => _input;
  Future<void> _rejectAuthentication() async => throw const FormatException('Xtream authentication refused');
''';

const bridge = '''
Map<String, dynamic> channelJson(Channel c) => {
  'id': c.id, 'name': c.name, 'number': c.number, 'logo': c.logo,
  'categoryId': c.categoryId, 'archiveDays': c.archiveDays, 'extra': c.extra,
};
// Storage needs only the reversible Source model, never derived UI metadata.
Map<String, dynamic> mediaStorageJson(MediaItem m) => {
  'id': m.id, 'title': m.title, 'kind': m.kind.name, 'parentId': m.parentId,
  'categoryId': m.categoryId, 'poster': m.poster, 'backdrop': m.backdrop,
  'description': m.description, 'year': m.year, 'rating': m.rating,
  'durationSeconds': m.durationSeconds, 'seasonNumber': m.seasonNumber,
  'episodeNumber': m.episodeNumber, 'providerId': m.providerId, 'extra': m.extra,
};
Map<String, dynamic> mediaCatalogStorageJson(MediaItem m) => {
  'id': m.id, 'title': m.title, 'kind': m.kind.name,
  if (m.parentId != null) 'parentId': m.parentId,
  if (m.categoryId != null) 'categoryId': m.categoryId,
  if (m.poster != null) 'poster': m.poster,
  if (m.backdrop != null) 'backdrop': m.backdrop,
  if (m.description != null) 'description': m.description,
  if (m.year != null) 'year': m.year,
  if (m.rating != null) 'rating': m.rating,
  if (m.durationSeconds != null) 'durationSeconds': m.durationSeconds,
  if (m.seasonNumber != null) 'seasonNumber': m.seasonNumber,
  if (m.episodeNumber != null) 'episodeNumber': m.episodeNumber,
  if (m.providerId != null) 'providerId': m.providerId,
  if (m.extra.isNotEmpty) 'extra': m.extra,
};
Map<String, dynamic> mediaJson(MediaItem m) {
  final info = media_presentation.MediaInfo.fromItem(m);
  return {
   ...mediaStorageJson(m),
  'info': {'cast': [for (final member in info.cast)
      {'name':member.name,'role':member.role,'photoUrl':member.photoUrl}],
    'directors':info.directors,'creators':info.creators,'genres':info.genres,
    'countries':info.countries,'originalTitle':info.originalTitle,
    'releaseDate':info.releaseDate,'durationSeconds':info.durationSeconds},
  'trailerUrl': media_presentation.mediaTrailerUri(m).toString(),
  'sourceHints': media_presentation.sourceHintLabels(m),
  'sourceTitle': media_presentation.providerSourceTitle(m),
  };
}
Map<String, dynamic> objectJson(String text) => Map<String, dynamic>.from(jsonDecode(text) as Map);
CanonicalXtreamBinding binding(String text) {
  final config = objectJson(text);
  final fields = config['fields'] is Map ? Map<String, dynamic>.from(config['fields']) : config;
  final settings = config['settings'] is Map ? Map<String, dynamic>.from(config['settings']) : <String, dynamic>{};
  return CanonicalXtreamBinding(fields['host'] as String, fields['username'] as String,
      fields['password'] as String,
      resolveXtreamStreamExtension(settings['streamExtension'] as String?, isIOS: false));
}
JSString parseM3uBridge(JSString text) {
  final result = parseM3uPlaylist(text.toDart);
  return jsonEncode({
    'channels': result.channels.map(channelJson).toList(),
    'categories': result.categories.map((c) => {'id': c.id, 'title': c.title}).toList(),
    'headerEpgUrl': result.headerEpgUrl, 'rejectedRows': result.rejectedRows,
    'catchupCapability': {
      'mode': result.catchupCapability.mode.name,
      'supported': result.catchupCapability.supported,
      'template': result.catchupCapability.template,
      'timezone': result.catchupCapability.timezone,
      'fixedOffsetMinutes': result.catchupCapability.fixedOffsetMinutes,
      'maxArchiveWindowMs': result.catchupCapability.maxArchiveWindow?.inMilliseconds,
    },
  }).toJS;
}
JSString mapLiveBridge(JSString text) => jsonEncode(
    mapLiveChannels(jsonDecode(text.toDart)).map(channelJson).toList()).toJS;
JSString mapMediaBridge(JSString text, JSString kind) => jsonEncode(
    mapMediaItemsFromDecoded(jsonDecode(text.toDart), ContentKind.values.byName(kind.toDart))
        .map(mediaJson).toList()).toJS;
JSPromise<JSString> resolveXtreamBridge(JSString config, JSString row) {
  final data = objectJson(row.toDart);
  final channel = Channel(id: data['id'] as String, name: data['name'] as String? ?? '',
      extra: data['extra'] is Map ? Map<String, dynamic>.from(data['extra']) : const {});
  return binding(config.toDart).resolve(channel).then((stream) =>
      jsonEncode({'url': stream.url, 'headers': stream.headers, 'isLive': stream.isLive}).toJS).toJS;
}
JSString apiUrlBridge(JSString config, JSString params) {
  final values = objectJson(params.toDart).map((key, value) => MapEntry(key, value.toString()));
  return binding(config.toDart).apiUrl(values).toJS;
}
JSPromise<JSString> resolveM3uBridge(JSString config, JSString row) {
  final configMap = objectJson(config.toDart);
  final fields = configMap['fields'] is Map ? Map<String, dynamic>.from(configMap['fields']) : configMap;
  final data = objectJson(row.toDart);
  final channel = Channel(id: data['id'] as String, name: data['name'] as String? ?? '',
      extra: data['extra'] is Map ? Map<String, dynamic>.from(data['extra']) : const {});
  final options = CanonicalSourceConfigBinding(Map<String, String>.from(fields));
  return CanonicalM3uBinding(options._opt('userAgent')).resolve(channel).then((stream) =>
      jsonEncode({'url': stream.url, 'headers': stream.headers, 'isLive': stream.isLive}).toJS).toJS;
}
JSPromise<JSBoolean> authBridge(JSString text) =>
    CanonicalXtreamBinding('', '', '', 'ts').validateAuth(jsonDecode(text.toDart)).then((_) => true.toJS).toJS;
JSString categoriesBridge(JSString text) => jsonEncode(
    CanonicalXtreamBinding('', '', '', 'ts').categoriesFromDecoded(jsonDecode(text.toDart))
        .map((c) => {'id': c.id, 'title': c.title}).toList()).toJS;
JSString networkPolicyBridge(JSString name) {
  final policy = switch (name.toDart) {
    'playlist' => kPlaylistWorkload,
    'provider-json' => kProviderJsonWorkload,
    'stalker-json' => kStalkerJsonWorkload,
    'epg' => kEpgWorkload,
    _ => throw ArgumentError('Unknown canonical network policy'),
  };
  return jsonEncode({'maximumBodyBytes': policy.maximumBodyBytes,
      'maximumDecodedBytes': policy.maximumDecodedBytes,
      'totalTimeoutMs': policy.totalTimeout.inMilliseconds,
      'idleTimeoutMs': policy.idleTimeout.inMilliseconds}).toJS;
}
@JS('TVBroCanonical')
external set canonicalApi(JSObject value);
Future<JSString> providerGateInitBridge(JSString saved,JSFunction persist) async {
  _providerCooldownPersist=persist;
  _memoryFiles[_providerCooldownPath]=Uint8List.fromList(utf8.encode(saved.toDart));
  await ProviderRequestGate.instance.restoreCooldowns(File(_providerCooldownPath));
  return 'null'.toJS;
}
Future<JSString> providerGateMergeBridge(JSString saved) async {
  _memoryFiles[_providerCooldownPath]=Uint8List.fromList(utf8.encode(saved.toDart));
  await ProviderRequestGate.instance.restoreCooldowns(File(_providerCooldownPath));
  ProviderRequestGate.instance._saveCooldowns();
  await ProviderRequestGate.instance.flushCooldowns();
  return 'null'.toJS;
}
void providerGateRecordBridge(JSString url,JSNumber status,JSString retryAfter,JSBoolean pauseAuth) {
  ProviderRequestGate.instance.recordResponse(Uri.parse(url.toDart),status.toDartInt,
    retryAfter:retryAfter.toDart.isEmpty?null:retryAfter.toDart,
    pauseOnAuthenticationFailure:pauseAuth.toDart);
}
JSString providerGateCheckBridge(JSString url) {
  try {
    ProviderRequestGate.instance.check(Uri.parse(url.toDart));
    return 'null'.toJS;
  } on ProviderRequestBlocked catch(failure) {
    return jsonEncode({'status':failure.status,'retryAt':failure.retryAt.toIso8601String()}).toJS;
  }
}
Future<JSString> providerGateRunBridge(JSString raw,JSFunction perform,JSFunction current,JSPromise<JSAny?> cancellation) async {
  try {
    final request=objectJson(raw.toDart), uri=Uri.parse(request['url'] as String);
    final timeout=(request['totalTimeoutMs'] as num).toInt();
    final result=await ProviderRequestGate.instance.run<String>(uri,() async {
      final response=await (perform.callAsFunction(null) as JSPromise<JSString>).toDart;
      return response.toDart;
    },timeout:Duration(milliseconds:timeout),cancellation:cancellation.toDart.then<void>((_) {}),
      checkCancellation:() { if(!(current.callAsFunction(null) as JSBoolean).toDart) throw const LoadCancelledException(); });
    return result.toJS;
  } on ProviderRequestBlocked catch(failure) {
    return jsonEncode({'errorKind':'provider-blocked','status':failure.status,'retryAt':failure.retryAt.toIso8601String()}).toJS;
  } on LoadCancelledException {
    return jsonEncode({'errorKind':'cancelled','error':'Provider request cancelled.'}).toJS;
  } catch(_) {
    return jsonEncode({'errorKind':'network','error':'Provider request could not complete.'}).toJS;
  }
}
JSString pairingQrDataUriBridge(JSString link) {
  final text = link.toDart;
  if (text.isEmpty || text.length > 300) return ''.toJS;
  try {
    final image = qr.QrImage(qr.QrCode.fromData(
        data: text, errorCorrectLevel: qr.QrErrorCorrectLevel.M));
    final size = image.moduleCount + 8;
    final svg = StringBuffer('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ');
    svg.write(size.toString() + ' ' + size.toString() + '" shape-rendering="crispEdges"><rect width="' + size.toString() + '" height="' + size.toString() + '" fill="white"/><path fill="black" d="');
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (image.isDark(row, col)) svg.write('M' + (col + 4).toString() + ',' + (row + 4).toString() + 'h1v1h-1z');
      }
    }
    svg.write('"/></svg>');
    return ('data:image/svg+xml;base64,' + base64Encode(utf8.encode(svg.toString()))).toJS;
  } catch (_) {
    return ''.toJS;
  }
}
void main() {
  final api = JSObject();
  api.setProperty('parseM3u'.toJS, parseM3uBridge.toJS);
  api.setProperty('mapXtreamLive'.toJS, mapLiveBridge.toJS);
  api.setProperty('mapXtreamMedia'.toJS, mapMediaBridge.toJS);
  api.setProperty('stableM3uChannelId'.toJS, ((JSString value) => stableM3uChannelId(value.toDart).toJS).toJS);
  api.setProperty('newSourceId'.toJS, (() => newSourceId().toJS).toJS);
  api.setProperty('xtreamApiUrl'.toJS, apiUrlBridge.toJS);
  api.setProperty('resolveXtream'.toJS, resolveXtreamBridge.toJS);
  api.setProperty('resolveM3u'.toJS, resolveM3uBridge.toJS);
  api.setProperty('validateXtreamAuth'.toJS, authBridge.toJS);
  api.setProperty('mapXtreamCategories'.toJS, categoriesBridge.toJS);
  api.setProperty('networkPolicy'.toJS, networkPolicyBridge.toJS);
  api.setProperty('createSource'.toJS, createSourceBridge.toJS);
  api.setProperty('parentalRules'.toJS, parentalRulesBridge.toJS);
  api.setProperty('hashPin'.toJS, ((JSString pin) => hashProfilePinAsync(pin.toDart).then((value) => value.toJS).toJS).toJS);
  api.setProperty('verifyPin'.toJS, ((JSString pin, JSString verifier) => verifyProfilePinAsync(pin.toDart, verifier.toDart).then((value) => value.toJS).toJS).toJS);
  api.setProperty('isPinVerifier'.toJS, ((JSString value) => isProfilePinVerifier(value.toDart).toJS).toJS);
  api.setProperty('supporterActive'.toJS, supporterActiveBridge.toJS);
  api.setProperty('resumeDecision'.toJS, resumeDecisionBridge.toJS);
  api.setProperty('resumeDecisionForKind'.toJS, resumeDecisionForKindBridge.toJS);
  api.setProperty('mediaProgress'.toJS, mediaProgressBridge.toJS);
  api.setProperty('seriesProgress'.toJS, seriesProgressBridge.toJS);
  api.setProperty('mediaTrailer'.toJS, ((JSString item) => media_presentation.mediaTrailerUri(mediaFromJson(objectJson(item.toDart))).toString().toJS).toJS);
  api.setProperty('canCatchup'.toJS, canCatchupBridge.toJS);
  api.setProperty('profileNormalize'.toJS, profileNormalizeBridge.toJS);
  api.setProperty('showProfilePicker'.toJS, ((JSString mode, JSNumber count, JSBoolean locked, JSBoolean active) {
    final startup = ProfilePickerStartup.values.firstWhere((value) => value.name == mode.toDart,
        orElse: () => ProfilePickerStartup.auto);
    return shouldShowPickerAtStartup(startup, count.toDartInt,
        activeProfileLocked: locked.toDart, hasActiveProfile: active.toDart).toJS;
  }).toJS);
  api.setProperty('cloudConfig'.toJS, (() => jsonEncode({'enabled':CloudConfig.enabled,
      'configured':CloudConfig.isConfigured,'apiUrl':CloudConfig.url,'panelUrl':CloudConfig.panelUrl,
      'anonKey':CloudConfig.anonKey}).toJS).toJS);
  api.setProperty('pairingPanelLink'.toJS, ((JSString panel,JSString code,JSString language) =>
      pairingPanelLink(panel.toDart,code.toDart,language:language.toDart).toJS).toJS);
  api.setProperty('pairingQrDataUri'.toJS, pairingQrDataUriBridge.toJS);
  api.setProperty('providerGateInit'.toJS, ((JSString saved,JSFunction persist)=>providerGateInitBridge(saved,persist).toJS).toJS);
  api.setProperty('providerGateMerge'.toJS, ((JSString saved)=>providerGateMergeBridge(saved).toJS).toJS);
  api.setProperty('providerGateRecord'.toJS, providerGateRecordBridge.toJS);
  api.setProperty('retryAfterDeadline'.toJS, ((JSString value,JSNumber now)=>jsonEncode(
    ProviderRequestGate._retryAfter(value.toDart,DateTime.fromMillisecondsSinceEpoch(now.toDartInt))?.millisecondsSinceEpoch).toJS).toJS);
  api.setProperty('providerGateCheck'.toJS, providerGateCheckBridge.toJS);
  api.setProperty('providerGateRun'.toJS, ((JSString raw,JSFunction perform,JSFunction current,JSPromise<JSAny?> cancellation)=>providerGateRunBridge(raw,perform,current,cancellation).toJS).toJS);
  api.setProperty('providerCachePolicy'.toJS, (()=>jsonEncode({
    'catalogMaxAgeMs':CanonicalTvCachePolicy.catalogMaxAge.inMilliseconds,
    'epgMaxAgeMs':CanonicalTvCachePolicy._epgMaxAge.inMilliseconds,
    'epgRetryDelayMs':CanonicalTvCachePolicy.epgRetryDelay.inMilliseconds}).toJS).toJS);
  api.setProperty('appLanguages'.toJS, (() => jsonEncode(AppLanguage.values.map((language) =>
      {'code': language.code, 'name': language.name}).toList()).toJS).toJS);
  api.setProperty('translationCatalog'.toJS, (() => jsonEncode(polishMessages).toJS).toJS);
  api.setProperty('translateUi'.toJS, ((JSString english, JSString code, JSString parameters) {
    final language = AppLanguage.values.firstWhere((value) => value.code == code.toDart,
        orElse: () => AppLanguage.english);
    final raw = jsonDecode(parameters.toDart);
    final values = <String, Object>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        if (entry.value != null) values[entry.key.toString()] = entry.value as Object;
      }
    }
    return translate(english.toDart, language, values).toJS;
  }).toJS);
  canonicalApi = api;
}
''';
