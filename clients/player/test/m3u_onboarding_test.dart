import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/diagnostics_log.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/home_shell.dart';
import 'package:iptvs/screens/sources_screen.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/library_preload_progress.dart';

void main() {
  testWidgets(
    'oversized M3U onboarding reports one actionable import failure',
    (tester) async {
      ProviderRequestGate.instance.debugReset();
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final requestStarted = Completer<void>();
      final releaseResponse = Completer<void>();
      final requests = <String>[];
      const advertisedBytes = 600 * 1024 * 1024;
      final fixture = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'm3u_oversized',
        );
        final db = await AppDatabase.openAt('${directory.path}/library.db');
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requests.add(request.uri.path);
          if (!requestStarted.isCompleted) requestStarted.complete();
          await releaseResponse.future;
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Length: $advertisedBytes\r\n'
            'Connection: close\r\n\r\n',
          );
          await socket.flush();
          await socket.close();
        });
        final store = SourceStore();
        await store.save(
          SourceConfig(
            id: 'large-m3u',
            kind: SourceKind.m3u,
            label: 'Large M3U fixture',
            fields: {
              'playlistUrl': 'http://127.0.0.1:${server.port}/list',
              'epgUrl': 'http://127.0.0.1:${server.port}/guide',
            },
          ),
        );
        return (directory: directory, db: db, server: server, store: store);
      }))!;

      await HttpOverrides.runWithHttpOverrides(() async {
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: HomeShell(db: fixture.db, store: fixture.store),
            ),
          );
          await _until(tester, () => requestStarted.isCompleted);
          await tester.pump();
          final guide = find.text('Program guide (EPG)');
          final guideShownDuringImport = guide.evaluate().isNotEmpty;
          final playlistShownDuringImport = find
              .text('Downloading and saving the M3U playlist…')
              .evaluate()
              .isNotEmpty;

          releaseResponse.complete();
          await _until(
            tester,
            () => find.text('Back and edit source').evaluate().isNotEmpty,
          );
          await tester.pumpAndSettle();

          final error = tester
              .widgetList<Text>(find.byType(Text))
              .map((text) => text.data ?? '')
              .where(
                (text) => text.contains('more data') || text.contains('600 MB'),
              )
              .single;
          expect(error.split('\n'), hasLength(1));
          expect(error, contains('600 MB'));
          expect(error, contains('512 MB'));
          expect(error, contains('smaller playlist'));
          expect(playlistShownDuringImport, isTrue);
          expect(guideShownDuringImport, isFalse);
          expect(guide, findsNothing);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.text('Try again'), findsNothing);
          expect(requests, ['/list']);

          await tester.tap(find.text('Back and edit source'));
          await tester.pumpAndSettle();
          expect(find.byType(EditSourceScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          if (!releaseResponse.isCompleted) releaseResponse.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await fixture.db.epgIngest.cancelAndWait();
            await fixture.server.close(force: true);
            await fixture.db.close();
            await fixture.directory.delete(recursive: true);
          });
        }
      }, _RealHttpOverrides());
    },
  );

  for (final includeLive in [true, false]) {
    testWidgets(
      'M3U onboarding opens a ${includeLive ? 'mixed' : 'VOD-only'} library with one download',
      (tester) async {
        ProviderRequestGate.instance.debugReset();
        FlutterSecureStorage.setMockInitialValues({});
        DiagnosticsLog.instance.clear();
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Future<T> read<T>(Future<T> Function() operation) async =>
            (await tester.runAsync(operation)) as T;
        final directory = await read(
          () => Directory.systemTemp.createTemp('m3u_onboarding'),
        );
        final db = await read(
          () => AppDatabase.openAt('${directory.path}/library.db'),
        );
        final server = await read(
          () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        );
        var requests = 0;
        await tester.runAsync(() async {
          server.listen((request) async {
            requests++;
            request.response.write(
              '#EXTM3U\n'
              '${includeLive ? '#EXTINF:-1 group-title="TV",Live fixture\nhttps://example.invalid/live/1.ts\n' : ''}'
              '#EXTINF:-1 group-title="Films",Movie fixture\nhttps://example.invalid/movie/2.mp4\n'
              '#EXTINF:-1 group-title="Shows",Show fixture S01 E01\nhttps://example.invalid/series/3.mp4\n',
            );
            await request.response.close();
          });
        });
        final store = SourceStore();
        await read(
          () => store.save(
            SourceConfig(
              id: 'm3u-setup',
              kind: SourceKind.m3u,
              label: 'M3U fixture',
              fields: {'playlistUrl': 'http://127.0.0.1:${server.port}/list'},
            ),
          ),
        );
        await HttpOverrides.runWithHttpOverrides(() async {
          try {
            await tester.pumpWidget(
              MaterialApp(
                home: HomeShell(db: db, store: store),
              ),
            );
            await _until(
              tester,
              () => DiagnosticsLog.instance.entries.any(
                (e) => e.message == 'onboarding preload completed',
              ),
            );
            await tester.pump();
            expect(find.byType(LibraryPreloadProgress), findsNothing);
            expect(
              await read(() => db.readChannels('m3u-setup')),
              hasLength(includeLive ? 1 : 0),
            );
            expect(
              await read(
                () => db.countMediaItems('m3u-setup', ContentKind.movie),
              ),
              1,
            );
            expect(
              await read(
                () => db.countMediaItems('m3u-setup', ContentKind.series),
              ),
              1,
            );
            expect(requests, 1);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() async {
              await db.epgIngest.cancelAndWait();
              await server.close(force: true);
              await db.close();
              await directory.delete(recursive: true);
            });
          }
        }, _RealHttpOverrides());
      },
    );
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('M3U onboarding did not complete');
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
}

class _RealHttpOverrides extends HttpOverrides {}
