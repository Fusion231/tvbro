import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/channel_organization.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_organization_screen.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

class _ChannelsDb implements AppDatabase {
  @override
  Future<List<Channel>> readChannels(String sourceId) async => const [
    Channel(id: 'a', name: 'Provider A'),
    Channel(id: 'b', name: 'Provider B'),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'small display can reorder, hide and rename while preserving settings',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 720);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const config = SourceConfig(
        id: 'source',
        kind: SourceKind.demo,
        label: 'Demo',
        fields: {},
      );
      final store = SourceStore();
      await store.save(config.copyWith(settings: {'bufferPreset': 'large'}));
      await tester.pumpWidget(
        MaterialApp(
          home: ChannelOrganizationScreen(
            db: _ChannelsDb(),
            store: store,
            config: config,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();
      expect((await store.list()).single.channelOrganization.order, ['b', 'a']);
      await tester.tap(find.byTooltip('Hide channel').first);
      await tester.pumpAndSettle();
      final saved = (await store.list()).single;
      expect(saved.channelOrganization.hidden, {'b'});
      expect(saved.settings['bufferPreset'], 'large');
      expect(find.text('Hidden'), findsOneWidget);
      await tester.tap(find.text('Provider A'));
      await tester.pumpAndSettle();
      final nameField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TvTextField),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(nameField, 'My channel');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      // Persisted rename begins after the dialog's exit transition completes.
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('My channel'), findsOneWidget);
      expect((await store.list()).single.channelOrganization.names, {
        'a': 'My channel',
      });
      expect(tester.takeException(), isNull);
    },
  );
}
