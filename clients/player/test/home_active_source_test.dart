import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/source_identity_migration.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/home_shell.dart';
import 'package:iptvs/screens/sources_screen.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  late SupabaseClient client;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('tvbro_home_active');
    db = await AppDatabase.openAt('${directory.path}/library.db');
    client = SupabaseClient('https://example.invalid', 'test');
  });

  tearDown(() async {
    await client.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  testWidgets('stale source load leaves the newer provider usable', (
    tester,
  ) async {
    late _TrackedConfig initial;
    late _GatedStore store;
    await tester.runAsync(() async {
      initial = _TrackedConfig('Initial');
      store = _GatedStore(initial);
      await migrateSourceIdentity(db, initial);
      await db.replaceLibrary(initial.id, initial.label, const [], const [
        Channel(id: 'channel', name: 'Fixture channel'),
      ], completeCatalog: true);
      for (final kind in [ContentKind.movie, ContentKind.series]) {
        await db.replaceMediaLibrary(
          initial.id,
          kind,
          const [],
          const [],
          completeCatalog: true,
        );
      }
      await db.replaceEpg(initial.id, const []);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            db: db,
            store: store,
            sync: CloudSync(client: client),
          ),
        ),
      );
      await initial.built.future.timeout(const Duration(seconds: 5));
    });
    await tester.runAsync(() => tester.pump());
    final refresh = tester
        .widget<ChannelListScreen>(find.byType(ChannelListScreen))
        .onRefreshSource!;

    late Completer<SourceConfig?> staleRead;
    Future<void>? staleLoad;
    await tester.runAsync(() async {
      staleRead = Completer<SourceConfig?>();
      store.nextRead = staleRead;
      staleLoad = refresh();
      await store.readStarted.future.timeout(const Duration(seconds: 5));
      store.config = _TrackedConfig('Current');
      await refresh();
    });
    await tester.runAsync(() => tester.pump());
    final currentRepository = tester
        .widget<ChannelListScreen>(find.byType(ChannelListScreen))
        .repo;

    await tester.runAsync(() async {
      staleRead.complete(initial);
      await staleLoad;
      final stream = await currentRepository.resolve(
        const Channel(id: 'channel', name: 'Fixture channel'),
      );
      expect(stream.url, 'https://example.invalid/Current');
    });
    await tester.runAsync(() => tester.pump());
    expect(
      tester.widget<ChannelListScreen>(find.byType(ChannelListScreen)).repo,
      same(currentRepository),
    );
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
  });

  testWidgets('missing credentials keep source management available', (
    tester,
  ) async {
    final store = _GatedStore(
      const SourceConfig(
        id: 'locked-source',
        kind: SourceKind.xtream,
        label: 'Locked source',
        fields: {'host': 'https://example.invalid', 'username': 'fixture'},
      ),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            db: db,
            store: store,
            sync: CloudSync(client: client),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.runAsync(() => tester.pump());
    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ChannelListScreen), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.text('Add a source'));
      await tester.pumpAndSettle();
    });
    expect(find.byType(SourcesScreen), findsOneWidget);
    await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
  });
}

class _GatedStore extends SourceStore {
  _GatedStore(this.config);

  SourceConfig config;
  Completer<SourceConfig?>? nextRead;
  final readStarted = Completer<void>();

  @override
  Future<List<SourceConfig>> list() async => [config];

  @override
  Future<SourceConfig?> activeConfig() async {
    final pending = nextRead;
    nextRead = null;
    if (pending == null) return config;
    readStarted.complete();
    return pending.future;
  }
}

class _TrackedConfig extends SourceConfig {
  _TrackedConfig(String label)
    : super(id: 'demo', kind: SourceKind.demo, label: label, fields: const {});

  final built = Completer<void>();

  @override
  Source build() {
    if (!built.isCompleted) built.complete();
    return _TrackedSource(label);
  }
}

class _TrackedSource extends DemoSource {
  _TrackedSource(String name) : super(displayName: name);

  bool _disposed = false;

  @override
  Future<void> connect() async {
    if (_disposed) throw StateError('Provider client is closed');
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    await connect();
    return StreamInfo(url: 'https://example.invalid/$name');
  }

  @override
  Future<void> dispose() async => _disposed = true;
}
