// Opt-in native companion to provider_user_journey_test.dart. Run its own target
// with the existing low_end_tv_driver, a separate LOW_END_TV_RESULTS_DIR,
// --profile --flavor development --dart-define=DISTRIBUTION_CHANNEL=development
// --dart-define=TVBRO_CLOUD_ENABLED=false. No provider or account data is used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_config.dart';
import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/data/distribution_channel.dart';
import 'package:iptvs/data/provider_image_cache.dart';
import 'package:iptvs/data/provider_request_gate.dart';
import 'package:iptvs/dvr/dvr_scheduler.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/main.dart' as application;
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/language_selection_screen.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/screens/profile_pick_screen.dart';
import 'package:iptvs/screens/sources_screen.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';
import 'package:iptvs/widgets/tv_text_field.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite/sqflite.dart' as native_sqlite;

const _seriesId = '50001';
const _seasonId = '$_seriesId:season:1';
const _seasonKey = ValueKey('media.season.$_seasonId');
const _moreKey = ValueKey('media.season:$_seasonId.loadMore');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('original Android TV app: explicit Stalker episode pages', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    expect(CloudConfig.enabled, isFalse);
    expect(DistributionConfig.channel, DistributionChannel.development);
    final oldPaths = PathProviderPlatform.instance;
    final oldStorage = FlutterSecureStoragePlatform.instance;
    final oldHttp = HttpOverrides.current;
    final oldDatabasePath = await native_sqlite.getDatabasesPath();
    final directory = await Directory.systemTemp.createTemp(
      'tvbro_portal_journey_',
    );
    final fixture = await _PortalFixture.start();
    final network = _LoopbackOnlyHttp();
    final rendered = _RenderedState(binding);
    final input = _NativeTextInput(binding.defaultBinaryMessenger);
    final phases = <Map<String, Object?>>[];
    final metrics = <String, Object?>{
      'schema': 1,
      'status': 'running',
      'entrypoint': 'original package:iptvs/main.dart main()',
      'providerTransport': 'real HTTP to synthetic loopback Stalker portal',
      'databaseBackend': 'native Android sqflite',
      'storage': 'fresh temporary paths and empty in-memory secure storage',
      'textInput': 'actual native IME client ID; synthetic editing events',
      'seasons': 2,
      'episodesPerSeason': 10,
      'episodesPerProviderPage': 5,
      'playback': 'excluded',
      'phases': phases,
    };
    binding.reportData = {'stalker_user_journey': metrics};
    AppDatabase? database;
    PathProviderPlatform.instance = _IsolatedPaths(directory.path);
    FlutterSecureStoragePlatform.instance = _MemorySecureStorage();
    await native_sqlite.databaseFactory.setDatabasesPath(directory.path);
    HttpOverrides.global = network;

    Future<void> measure(String phase, Future<void> Function() action) async {
      fixture.phase = phase;
      final before = Map<String, int>.from(fixture.counts);
      final watch = Stopwatch()..start();
      var completed = false;
      try {
        await action();
        expect(tester.takeException(), isNull, reason: phase);
        completed = true;
      } finally {
        watch.stop();
        final result = <String, Object?>{
          'phase': phase,
          'status': completed ? 'completed' : 'failed',
          'actionElapsedMs': watch.elapsedMilliseconds,
          'requests': fixture.delta(before),
        };
        phases.add(result);
        // ignore: avoid_print
        print('TVBRO_STALKER_PHASE ${jsonEncode(result)}');
      }
    }

    Future<void> activate(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
    }

    Future<void> expandFirstSeason(int count) async {
      await activate(
        find.descendant(
          of: find.byKey(_seasonKey),
          matching: find.text('Season 1'),
        ),
      );
      await rendered.waitFor(
        () => tester.any(find.text('Episodes: $count')),
        'first season episodes',
      );
    }

    Future<void> closeDetails() async {
      await tester.tap(find.byKey(const ValueKey('media.details.close')));
      await rendered.waitFor(
        () => !tester.any(find.byType(MediaDetailsSheet)),
        'details closed',
      );
    }

    try {
      await measure('fresh_boot_and_original_stalker_source_form', () async {
        await application.main();
        await rendered.waitFor(
          () => tester.any(find.byType(LanguageSelectionScreen)),
          'language onboarding',
        );
        expect(isTelevision, isTrue);
        database = tester
            .widget<application.IptvApp>(find.byType(application.IptvApp))
            .db;
        await tester.tap(find.text('English'));
        await rendered.waitFor(
          () =>
              tester.any(find.byType(ProfilePickScreen)) &&
              tester.any(find.text('Skip')),
          'profile picker',
        );
        await tester.tap(find.text('Skip'));
        await rendered.waitFor(
          () => tester.any(find.text('Add a source')),
          'fresh home',
        );
        await tester.tap(find.text('Add a source'));
        await rendered.waitFor(
          () => tester.any(find.text('Add source')),
          'source list',
        );
        await tester.tap(find.text('Add source'));
        await rendered.waitFor(
          () =>
              tester.any(find.byType(EditSourceScreen)) &&
              tester.any(find.widgetWithText(TvTextField, 'Portal URL')),
          'Stalker source form',
        );
        for (final field in <String, String>{
          'Label (optional)': 'Synthetic paged portal',
          'Portal URL': '${fixture.base}/',
          'MAC address': '00:1A:79:00:00:01',
        }.entries) {
          await _enterField(
            tester,
            rendered,
            input,
            find.widgetWithText(TvTextField, field.key),
            field.value,
          );
        }
        await activate(find.text('Save source'));
        await rendered.waitFor(
          () =>
              !tester.any(find.byType(EditSourceScreen)) &&
              tester.any(find.text('Synthetic paged portal')),
          'saved portal',
        );
        await binding.handlePopRoute();
        await rendered.waitFor(
          () =>
              tester.any(find.byType(ChannelListScreen)) &&
              tester.any(find.byKey(const ValueKey('home-series'))),
          'portal catalog import',
        );
        final screen = tester.widget<ChannelListScreen>(
          find.byType(ChannelListScreen),
        );
        await screen.repo.pendingEpgRefresh;
      });
      await measure('cold_series_and_seasons', () async {
        await tester.tap(find.byKey(const ValueKey('home-series')));
        await rendered.waitFor(
          () =>
              tester.any(find.byKey(const ValueKey('media.featured.primary'))),
          'original series browser',
        );
        await tester.tap(find.byKey(const ValueKey('media.featured.primary')));
        await rendered.waitFor(
          () =>
              tester.any(find.byKey(_seasonKey)) &&
              tester.any(find.text('Seasons: 2')),
          'two original season headers',
        );
        expect(fixture.counts['episodes.1.1'] ?? 0, 0);
        expect(fixture.counts['episodes.2.1'] ?? 0, 0);
      });
      await measure('selected_season_first_page_only', () async {
        await expandFirstSeason(5);
        expect(find.byKey(_moreKey), findsOneWidget);
        expect(find.text('Load page 2'), findsOneWidget);
        expect(fixture.counts['episodes.1.1'], 1);
        expect(fixture.counts['episodes.1.2'] ?? 0, 0);
        expect(fixture.counts['episodes.2.1'] ?? 0, 0);
      });
      await measure('dpad_page_control_and_explicit_second_page', () async {
        final more = find.byKey(_moreKey);
        await tester.ensureVisible(more);
        final moreFocus = tester.widget<FilledButton>(more).focusNode!;
        moreFocus.requestFocus();
        await tester.pump();
        await _key(
          tester,
          LogicalKeyboardKey.arrowUp,
          PhysicalKeyboardKey.arrowUp,
        );
        expect(
          focusRouteKey(FocusManager.instance.primaryFocus),
          'media.episode.list.$_seasonId',
        );
        await _key(
          tester,
          LogicalKeyboardKey.arrowUp,
          PhysicalKeyboardKey.arrowUp,
        );
        final firstHeader = FocusManager.instance.primaryFocus;
        expect(firstHeader, isNotNull);
        moreFocus.requestFocus();
        await tester.pump();
        await _key(
          tester,
          LogicalKeyboardKey.arrowUp,
          PhysicalKeyboardKey.arrowUp,
        );
        await _key(
          tester,
          LogicalKeyboardKey.arrowDown,
          PhysicalKeyboardKey.arrowDown,
        );
        expect(FocusManager.instance.primaryFocus, same(moreFocus));
        await _key(tester, LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter);
        await rendered.waitFor(
          () =>
              tester.any(find.text('Episodes: 10')) &&
              !tester.any(find.byKey(_moreKey)),
          'second episode page',
        );
        await rendered.waitFor(
          () => identical(FocusManager.instance.primaryFocus, firstHeader),
          'focus restored to the selected season after the last page',
        );
        expect(fixture.counts['episodes.1.1'], 1);
        expect(fixture.counts['episodes.1.2'], 1);
        expect(fixture.counts['episodes.2.1'] ?? 0, 0);
      });
      final cached = Map<String, int>.from(fixture.counts);
      await measure('collapse_reopen_uses_all_loaded_pages', () async {
        await activate(
          find.descendant(
            of: find.byKey(_seasonKey),
            matching: find.text('Season 1'),
          ),
        );
        await rendered.waitFor(
          () => !tester.any(find.text('Episodes: 10')),
          'season collapsed',
        );
        await expandFirstSeason(10);
        expect(find.byKey(_moreKey), findsNothing);
        expect(fixture.delta(cached), isEmpty);
      });
      await measure('reopen_details_uses_persisted_child_cache', () async {
        await closeDetails();
        await tester.tap(find.byKey(const ValueKey('media.featured.primary')));
        await rendered.waitFor(
          () => tester.any(find.byKey(_seasonKey)),
          'cached seasons',
        );
        await expandFirstSeason(10);
        expect(find.byKey(_moreKey), findsNothing);
        expect(fixture.delta(cached), isEmpty);
        expect(fixture.counts['episodes.2.1'] ?? 0, 0);
        await closeDetails();
        await tester.tap(find.byTooltip('Home').hitTestable());
        await rendered.waitFor(
          () => tester.any(find.byKey(const ValueKey('home-series'))),
          'return home',
        );
      });
      expect(fixture.counts['details'], 1);
      expect(fixture.counts['seasons.1'], 1);
      expect(fixture.unexpected, isEmpty);
      expect(network.deniedHosts, isEmpty);
      metrics['status'] = 'succeeded';
    } catch (error) {
      metrics['status'] = 'failed';
      metrics['failure'] = '$error';
      metrics['failureUi'] = _uiSnapshot(tester);
      // ignore: avoid_print
      print('TVBRO_STALKER_FAILURE_UI ${jsonEncode(metrics['failureUi'])}');
      rethrow;
    } finally {
      rendered.close();
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        await DvrScheduler.instance.close();
        await DvrService.instance.close();
        await ProviderRequestGate.instance.flushCooldowns();
        await providerImageCache.dispose();
        await database?.close();
        metrics['cleanupCompleted'] = true;
      } finally {
        metrics['requestCounts'] = Map<String, int>.from(fixture.counts);
        metrics['requests'] = fixture.requests;
        metrics['unexpectedRequests'] = fixture.unexpected;
        metrics['deniedOutboundHosts'] = network.deniedHosts.toList();
        await fixture.close();
        network.close();
        input.close();
        HttpOverrides.global = oldHttp;
        PathProviderPlatform.instance = oldPaths;
        FlutterSecureStoragePlatform.instance = oldStorage;
        await native_sqlite.databaseFactory.setDatabasesPath(oldDatabasePath);
        if (await directory.exists()) await directory.delete(recursive: true);
        // ignore: avoid_print
        print('TVBRO_STALKER_JOURNEY ${jsonEncode(metrics)}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey logical,
  PhysicalKeyboardKey physical,
) async {
  await tester.sendKeyEvent(
    logical,
    physicalKey: physical,
    platform: 'android',
  );
  await tester.pump();
}

Future<void> _enterField(
  WidgetTester tester,
  _RenderedState rendered,
  _NativeTextInput input,
  Finder cell,
  String value,
) async {
  await tester.ensureVisible(cell);
  await tester.pump();
  await tester.tap(cell);
  final field = find.descendant(of: cell, matching: find.byType(TextField));
  await rendered.waitFor(
    () => tester.widget<TextField>(field).focusNode!.hasFocus,
    'field edit',
  );
  await input.enterText(value);
  await tester.pump();
  expect(tester.widget<TextField>(field).controller!.text, value);
  await _key(tester, LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape);
  await rendered.waitFor(
    () => !tester.widget<TextField>(field).focusNode!.hasFocus,
    'field committed',
  );
  expect(tester.widget<TextField>(field).controller!.text, value);
}

Map<String, Object?> _uiSnapshot(WidgetTester tester) => {
  'editingSource': tester.any(find.byType(EditSourceScreen)),
  'fields': [
    for (final field in tester.widgetList<TvTextField>(
      find.byType(TvTextField),
    ))
      {
        'label': field.label,
        'hint': field.hintText,
        'characters': field.controller.text.length,
        'error': field.errorText,
      },
  ],
  'text': [
    for (final text in tester.widgetList<Text>(find.byType(Text)).take(30))
      if (text.data?.isNotEmpty == true) text.data,
  ],
  'focusedRoute': focusRouteKey(FocusManager.instance.primaryFocus),
  'viewInsetsBottom': tester.view.viewInsets.bottom,
};

class _PortalFixture {
  _PortalFixture(this.server) {
    _subscription = server.listen(_serve);
  }
  static Future<_PortalFixture> start() async =>
      _PortalFixture(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final HttpServer server;
  late final StreamSubscription<HttpRequest> _subscription;
  final counts = <String, int>{};
  final requests = <Map<String, Object?>>[];
  final unexpected = <String>[];
  String phase = 'setup';
  String get base => 'http://127.0.0.1:${server.port}';
  Map<String, int> delta(Map<String, int> before) => {
    for (final entry in counts.entries)
      if (entry.value != (before[entry.key] ?? 0))
        entry.key: entry.value - (before[entry.key] ?? 0),
  };

  Future<void> _serve(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final action = params['action'] ?? '';
    final type = params['type'] ?? '';
    final season = params['season_id'];
    final page = int.tryParse(params['p'] ?? '') ?? 1;
    final key = action != 'get_ordered_list'
        ? action == 'get_movie_details'
              ? 'details'
              : '$type.$action'
        : season != null
        ? 'episodes.$season.$page'
        : params['movie_id'] != null
        ? 'seasons.$page'
        : 'catalog.$type.$page';
    counts.update(key, (value) => value + 1, ifAbsent: () => 1);
    requests.add({'phase': phase, 'action': key});
    try {
      if (request.uri.path != '/portal.php') {
        throw StateError('Unexpected portal path');
      }
      if (!request.headers
          .value(HttpHeaders.cookieHeader)!
          .contains('mac=00:1A:79:00:00:01')) {
        throw StateError('Expected synthetic MAC only');
      }
      if (action != 'handshake' &&
          request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer fixture-token') {
        throw StateError('Missing synthetic handshake');
      }
      final Object js = switch (action) {
        'handshake' => {'token': 'fixture-token'},
        'get_profile' => {
          'id': '1',
          'status': 1,
          'timezone': 'UTC',
          'expire_billing_date': '2099-12-31',
        },
        'get_main_info' => {'end_date': '2099-12-31'},
        'get_genres' => [
          {'id': '1', 'title': 'Fixture Live'},
        ],
        'get_all_channels' => {
          'data': [
            {
              'id': '1',
              'name': 'Fixture Channel',
              'number': 1,
              'tv_genre_id': '1',
              'cmd': 'ffmpeg $base/live.ts',
            },
          ],
        },
        'get_epg_info' => <String, Object?>{},
        'get_categories' => [
          {
            'id': '1',
            'title': type == 'series' ? 'Fixture Series' : 'Fixture Movies',
          },
        ],
        'get_movie_details' => {
          'description': 'Synthetic paged series details',
        },
        'get_ordered_list' => _ordered(type, params['movie_id'], season, page),
        _ => throw UnsupportedError('Unexpected fixture action $type.$action'),
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'js': js}));
      await request.response.close();
    } catch (error) {
      unexpected.add('$key: ${error.runtimeType}');
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  Map<String, Object> _ordered(
    String type,
    String? movie,
    String? season,
    int page,
  ) {
    final rows = season != null
        ? [
            for (var i = (page - 1) * 5 + 1; i <= page * 5; i++)
              {
                'id': '${60000 + int.parse(season) * 1000 + i}',
                'episode_id': '${60000 + int.parse(season) * 1000 + i}',
                'name': 'Portal Episode ${i.toString().padLeft(2, '0')}',
                'episode_number': i,
                'season_number': int.parse(season),
                'cmd': 'ffmpeg $base/episode.ts',
              },
          ]
        : movie != null
        ? [
            for (var i = 1; i <= 2; i++)
              {
                'id': '$i',
                'season_id': '$i',
                'season_number': i,
                'name': 'Season $i',
                'movie_id': _seriesId,
              },
          ]
        : [
            {
              'id': type == 'series' ? _seriesId : '10001',
              'name': type == 'series' ? 'Portal Paged Series' : 'Portal Movie',
              'category_id': '1',
              'is_series': type == 'series' ? 1 : 0,
            },
          ];
    return {
      'data': rows,
      'total_items': season != null ? 10 : rows.length,
      'max_page_items': season != null ? 5 : rows.length,
    };
  }

  Future<void> close() async {
    await server.close(force: true);
    await _subscription.cancel();
  }
}

class _RenderedState {
  _RenderedState(this.binding) {
    binding.addPersistentFrameCallback((_) {
      if (_closed || _ready == null) return;
      binding.addPostFrameCallback((_) {
        if (!_closed && (_ready?.call() ?? false)) {
          _complete!.complete();
          _ready = null;
          _complete = null;
        }
      });
    });
  }
  final LiveTestWidgetsFlutterBinding binding;
  bool _closed = false;
  bool Function()? _ready;
  Completer<void>? _complete;

  Future<void> waitFor(
    bool Function() ready,
    String description, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (ready()) return Future<void>.value();
    if (_ready != null) throw StateError('Only one UI observer may be active.');
    final complete = Completer<void>();
    _ready = ready;
    _complete = complete;
    binding.scheduleFrame();
    return complete.future.timeout(
      timeout,
      onTimeout: () {
        _ready = null;
        _complete = null;
        throw StateError('No rendered readiness: $description');
      },
    );
  }

  void close() => _closed = true;
}

class _IsolatedPaths extends PathProviderPlatform {
  _IsolatedPaths(this.path);
  final String path;
  @override
  Future<String> getApplicationSupportPath() async => path;
  @override
  Future<String> getTemporaryPath() async => path;
  @override
  Future<String> getLibraryPath() async => path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;
  @override
  Future<String> getApplicationCachePath() async => path;
  @override
  Future<String> getExternalStoragePath() async => path;
  @override
  Future<List<String>> getExternalCachePaths() async => [path];
  @override
  Future<List<String>> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => [path];
  @override
  Future<String> getDownloadsPath() async => path;
}

class _MemorySecureStorage extends FlutterSecureStoragePlatform {
  final _values = <String, String>{};
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => _values[key] = value;
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => _values[key];
  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => _values.containsKey(key);
  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => _values.remove(key);
  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => Map.of(_values);
  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      _values.clear();
}

class _LoopbackOnlyHttp extends HttpOverrides {
  final deniedHosts = <String>{};
  final _clients = <HttpClient>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (uri.host != '127.0.0.1' &&
          uri.host != 'localhost' &&
          uri.host != '::1') {
        deniedHosts.add(uri.host);
        throw StateError('Only synthetic device-loopback HTTP is allowed.');
      }
      return Socket.startConnect(uri.host, uri.port);
    };
    _clients.add(client);
    return client;
  }

  void close() {
    for (final client in _clients) {
      client.close(force: true);
    }
  }
}

class _NativeTextInput {
  _NativeTextInput(this.messenger) {
    messenger.setMockMessageHandler(SystemChannels.textInput.name, (message) {
      final call = SystemChannels.textInput.codec.decodeMethodCall(message!);
      if (call.method == 'TextInput.setClient') {
        _client = (call.arguments as List).first as int;
      } else if (call.method == 'TextInput.clearClient') {
        _client = null;
      }
      return messenger.delegate.send(SystemChannels.textInput.name, message);
    });
  }
  final TestDefaultBinaryMessenger messenger;
  int? _client;

  Future<void> enterText(String text) async {
    final client = _client;
    if (client == null) throw StateError('No active native IME client.');
    final value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    await messenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingState', [
          client,
          value.toJSON(),
        ]),
      ),
      (_) {},
    );
    // Keep the real keyboard's own state synchronized with the injected edit.
    await messenger.delegate.send(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInput.setEditingState', value.toJSON()),
      ),
    );
  }

  void close() =>
      messenger.setMockMessageHandler(SystemChannels.textInput.name, null);
}
