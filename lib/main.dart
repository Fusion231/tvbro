import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_brand.dart';
import 'data/app_database.dart';
import 'data/cloud_config.dart';
import 'data/device_class.dart';
import 'data/diagnostics_log.dart';
import 'data/dvr_runtime.dart';
import 'data/parental_controls.dart';
import 'data/secure_local_storage.dart';
import 'data/source_identity_migration.dart';
import 'data/source_store.dart';
import 'dvr/dvr_scheduler.dart';
import 'l10n/app_localizations.dart';
import 'screens/language_selection_screen.dart';
import 'screens/profile_pick_screen.dart';
import 'theme.dart';

/// Decoded-image cache ceiling applied on Android (phone and TV).
///
/// Flutter's default is 100 MB / 1000 images. On a 1 GB Android TV box that is
/// a large slice of the whole heap, and browsing a poster grid fills it — the
/// resulting GC pressure shows up as dropped frames on weak silicon, and on the
/// smallest boxes as an OOM kill. Images are already decoded at display size
/// (`imageCacheSize`, DPR clamped to 3), so 32 MB is roughly four screenfuls of
/// the grid's ~180 px posters: the visible page never has to re-decode itself,
/// which is the failure mode a too-small cap would cause (continuous re-decode
/// is worse than the pressure it saves). Desktop deliberately keeps Flutter's
/// default — RAM is plentiful there and the bigger cache genuinely pays off
/// when scrolling back through a large catalogue.
const int kAndroidImageCacheBytes = 32 << 20;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.android) {
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        kAndroidImageCacheBytes;
  }
  MediaKit.ensureInitialized();
  final store = SourceStore();
  // Cloud init, opening the database and reading startup preferences are
  // independent — only the identity migration below needs the database and the
  // sources together. Starting them at once costs the longest of the
  // keychain/disk round trips instead of their sum, all of which is on the path
  // to the first frame. A failure here still aborts boot; it arrives wrapped in
  // a ParallelWaitError rather than on its own.
  // `detectDeviceClass` joins the tuple for the same reason as the rest: it is
  // one platform round trip with no dependency on the others, and it must
  // settle before the first frame because it decides the *layout* (a television
  // is the wide two-pane UI regardless of the logical width its density
  // reports — `isWideLayout`). Awaiting it ahead of this group added its
  // latency to time-to-first-frame for nothing.
  final (db, sources, _, _, _, _) = await (
    AppDatabase.open(),
    store.list(),
    detectDeviceClass(),
    _initialiseCloud(),
    AppLanguageController.instance.initialize(),
    _initialiseParentalControls(),
  ).wait;
  await migrateAllSourceIdentities(db, sources);
  DvrScheduler.instance.configureResolver(
    (schedule) => resolveScheduledRecording(schedule, db: db, store: store),
  );
  runApp(IptvApp(db: db, store: store));
  // Recovery walks saved media on disk. The initial library frame does not
  // depend on it; starting after that frame keeps a large recording library
  // from delaying every app launch. DVR entry points await the same shared
  // initialization future if the user opens them while recovery is in flight.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_initialiseDvr());
  });
}

Future<void> _initialiseParentalControls() async {
  try {
    await ParentalControlService.instance.ensureInitialized();
  } catch (_) {
    // The service fails closed; still show the library's recovery message.
    DiagnosticsLog.instance.add('parental', 'startup_policy_unavailable');
  }
}

Future<void> _initialiseDvr() async {
  try {
    await DvrScheduler.instance.ensureInitialized();
  } catch (_) {
    DiagnosticsLog.instance.add('dvr', 'schedule_startup_failed');
  }
}

/// Optional cloud source panel: only initialised when build-time Supabase
/// config is present, otherwise the app runs fully offline as before.
Future<void> _initialiseCloud() async {
  if (!CloudConfig.isConfigured) return;
  await Supabase.initialize(
    url: CloudConfig.url,
    publishableKey: CloudConfig.anonKey,
    authOptions: FlutterAuthClientOptions(localStorage: SecureLocalStorage()),
  );
}

class IptvApp extends StatelessWidget {
  final AppDatabase db;
  final SourceStore store;
  const IptvApp({super.key, required this.db, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLanguageController.instance,
      builder: (context, child) => MaterialApp(
        title: AppBrand.name,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        locale: AppLanguageController.instance.locale,
        supportedLocales: AppLanguageController.supportedLocales,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        // The picker itself decides whether to appear (startup-mode setting +
        // profile count) and silently short-circuits to HomeShell otherwise.
        home: AppLanguageController.instance.hasSelection
            ? ProfilePickScreen(db: db, store: store, bootMode: true)
            : const LanguageSelectionScreen(),
      ),
    );
  }
}
