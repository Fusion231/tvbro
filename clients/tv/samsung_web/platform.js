(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory;
  else if (root.TVBroPlatformAdapters) {
    root.TVBroPlatformReady = Promise.resolve(root.TVBroPlatformAdapters.ready).then(function () {
      return (root.TVBroSamsungPlatform = factory(root, root.TVBroPlatformAdapters));
    });
    root.TVBroPlatformReady.catch(function () {});
  } else root.TVBroSamsungPlatform = factory(root);
}(typeof window !== 'undefined' ? window : this, function (environment, injected) {
  'use strict';

  environment = environment || {};
  injected = injected || {};

  var core = injected.core || environment.TVBroCanonical;
  var validation = injected.validation || environment.TVBroPanelValidation;
  var libraryModule = environment.TVBroSamsungLibrary;
  var userStateModule = environment.TVBroSamsungUserState;
  var storeModule = injected.storeModule || environment.TVBroSamsungSecureStore;
  var transportModule = environment.TVBroSamsungTransport;
  var playerModule = injected.playerModule || environment.TVBroSamsungAvplay;
  var cloudModule = environment.TVBroSamsungCloud;
  var sourceWorkerModule = environment.TVBroSamsungSourceWorker;
  var catalogStoreModule = injected.catalogStoreModule || environment.TVBroSamsungCatalogStore;
  var backupFilesModule = injected.backupFilesModule || environment.TVBroSamsungBackupFiles;
  var backupFiles = injected.backupFiles || (backupFilesModule ? backupFilesModule.create({ environment: environment }) : null);
  var backupCapabilities = backupFiles ? backupFiles.capabilities() : {};

  if (!core || !validation || !libraryModule || !userStateModule ||
      !storeModule || !transportModule || !playerModule ||
      (!sourceWorkerModule && (!injected.createSource || !injected.verifyPin || !injected.hashPin))) {
    throw new Error('Nie udało się uruchomić aplikacji TVBro.');
  }

  var store = injected.store || storeModule.create({
    environment: environment,
    tizen: environment.tizen
  });
  var userState = userStateModule.create({ store: store });
  var player = injected.player || playerModule.create({ environment: environment,
    beforeReconnect: function (url) { return transport.checkStream(url); },
    onProviderRejected: function (url, status) { transport.recordStreamRefusal(url, status); }
  });
  var cloud = cloudModule ? cloudModule.create({
    core: core,
    config: environment.TVBroSamsungConfig || {},
    userState: userState,
    XMLHttpRequest: environment.XMLHttpRequest,
    environment: environment,
    cryptoProtocol: environment.TVBroPanelCrypto,
    deviceLabel: injected.deviceLabel
  }) : null;
  var requiresHttpsProvider = injected.requiresHttpsProvider === true;
  var transport = transportModule.create(environment, { relay: cloud, core: core, userState: userState,
    requiresHttpsProvider: requiresHttpsProvider });
  var sourceWorker = sourceWorkerModule ? sourceWorkerModule.create(environment, { mergeCooldowns: transport.mergeCooldowns, epgDiskAvailable: transport.hasDiskGuides }) : null;
  var createSource = injected.createSource || (sourceWorker && sourceWorker.createSource);
  var verifyPin = injected.verifyPin || (sourceWorker && sourceWorker.verifyPin);
  var hashPin = injected.hashPin || (sourceWorker && sourceWorker.hashPin);
  if (typeof createSource !== 'function' || typeof verifyPin !== 'function' || typeof hashPin !== 'function') {
    throw new Error('Nie udało się uruchomić aplikacji TVBro.');
  }
  var listeners = [];
  var activeStreamIsLive = true;
  var playerSnapshot = null;

  function readPlayerState() {
    var current = playerSnapshot || player.getState() || {};
    var state = {};
    Object.keys(current).forEach(function (key) { state[key] = current[key]; });
    state.isLive = activeStreamIsLive;
    if (state.error) {
      state.error = {
        name: state.error.name || 'Error',
        message: validation.friendlyError(state.error)
      };
    }
    return state;
  }

  function canOpenTrailer() {
    if (typeof injected.openTrailer === 'function') return true;
    var tizen = environment.tizen;
    return !!(tizen && typeof tizen.ApplicationControl === 'function' && tizen.application &&
      typeof tizen.application.launchAppControl === 'function');
  }
  function openTrailer(url) {
    if (typeof injected.openTrailer === 'function') return injected.openTrailer(url);
    return new Promise(function (resolve, reject) {
      function unavailable() {
        var error = new Error('Could not open the trailer or YouTube.');
        error.name = 'NotSupportedError'; error.code = 'trailer_unavailable'; return error;
      }
      var parsed, Constructor = environment.URL || (typeof URL === 'function' ? URL : null);
      try {
        if (!canOpenTrailer() || typeof url !== 'string' || /\s/.test(url) || !Constructor) throw unavailable();
        parsed = new Constructor(url);
        if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password) throw unavailable();
      } catch (_) { reject(unavailable()); return; }
      var timerHost = typeof environment.setTimeout === 'function' && typeof environment.clearTimeout === 'function'
        ? environment : typeof global !== 'undefined' ? global : null;
      var timer = null, settled = false;
      function finish(failed) {
        if (settled) return; settled = true;
        if (timer !== null && timerHost) timerHost.clearTimeout(timer);
        if (failed) reject(unavailable()); else resolve();
      }
      try {
        var control = new environment.tizen.ApplicationControl('http://tizen.org/appcontrol/operation/view', parsed.href);
        if (timerHost) timer = timerHost.setTimeout(function () { finish(true); }, 10000);
        environment.tizen.application.launchAppControl(control, null, function () { finish(false); }, function () { finish(true); });
      } catch (_) { finish(true); }
    });
  }

  var library = libraryModule.create({
    core: core,
    validation: validation,
    userState: userState,
    sourceStore: store,
    player: player,
    transport: transport,
    cloud: cloud,
    canImportBackup: backupCapabilities.import === true,
    canExportBackup: backupCapabilities.export === true,
    createSource: createSource,
    verifyPin: verifyPin,
    hashPin: hashPin,
    openTrailer: canOpenTrailer() ? openTrailer : undefined,
    catalogStore: catalogStoreModule ? catalogStoreModule.create({ environment: environment, secureStore: store }) : null,
    requiresHttpsProvider: requiresHttpsProvider,
    onProgress: function () {
      if (!library) return;
      var state = publicState();
      listeners.slice().forEach(function (listener) { listener(state); });
    },
    getState: readPlayerState,
    stop: function () { return player.stop(); },
    openStream: function (stream, rect, preferences, current, context) {
      activeStreamIsLive = stream.isLive !== false;
      rect = rect || {
        x: 0,
        y: 0,
        width: environment.innerWidth || 1920,
        height: environment.innerHeight || 1080
      };
      player.setRect(rect.x, rect.y, rect.width, rect.height);
      return transport.checkStream(stream.url).then(function () {
        if (current && !current()) { var cancelled = new Error('Odtwarzanie anulowano.'); cancelled.code = 'cancelled'; throw cancelled; }
        var playerOptions = { headers: stream.headers || {}, isLive: activeStreamIsLive,
          bufferPreset: preferences && preferences.bufferPreset || 'default' };
        if (context && context.headerPolicy === 'xtream-vod-default') playerOptions.headerPolicy = context.headerPolicy;
        return player.open(stream.url, playerOptions);
      });
    },
    onError: function () {}
  });

  function friendly(error) {
    var messages = { pin_required: 'Podaj PIN.', pin_invalid: 'Nieprawidłowy PIN.',
      profile_required: 'Najpierw wybierz profil.', cloud_profile_required: 'Wybierz profil z panelu.',
      cancelled: 'Anulowano.', supporter_required: 'Wznowienie wymaga funkcji wspierającego. Możesz odtworzyć od początku.',
      configuration_required: 'Ta funkcja wymaga konfiguracji wydawcy.',
      hosted_http_blocked: 'This provider uses HTTP. This TV version needs HTTPS. Ask your provider for an HTTPS address or use TVBro on Android, Windows or Samsung.',
      cache_migration_failed: 'Saved source data could not be moved safely. The source settings were not changed.',
      trailer_unavailable: 'Could not open the trailer or YouTube.',
      epg_timeout: 'Przekroczono czas pobierania programu TV. [EPG:TIMEOUT]',
      epg_network: 'Nie można połączyć się z dostawcą programu TV. [EPG:NETWORK]',
      epg_size_limit: 'Program TV przekracza limit pamięci tego telewizora. Ustaw mniejszy plik EPG, np. tylko dla Polski, w ustawieniach źródła. [EPG:SIZE]',
      epg_invalid_data: 'Dostawca zwrócił nieprawidłowe dane programu TV. [EPG:DATA]',
      epg_http: 'Dostawca odmówił pobrania programu TV. [EPG:HTTP]',
      epg_retry_deferred: 'Pobieranie programu TV jest chwilowo wstrzymane. Spróbuj ponownie później. [EPG:RETRY]',
      epg_unsupported: 'Program TV wymaga funkcji niedostępnej na tym telewizorze. [EPG:UNSUPPORTED]',
      epg_unavailable: 'Nie udało się wczytać programu TV. [EPG:UNKNOWN]' };
    var epgStatus = error && (error.code === 'epg_http' || error.causeCode === 'epg_http') ? error.status : null;
    // A missing XMLTV/API endpoint is not an authentication refusal or a
    // channel-list failure. Use the same explanation for a saved retry cause.
    if (epgStatus === 404 || epgStatus === 410) messages.epg_http =
      'Nie znaleziono programu TV pod tym adresem. Sprawdź adres EPG w ustawieniach źródła. Kanały nadal można oglądać. [EPG:HTTP]';
    var message = error && messages[error.code] || validation.friendlyError(error);
    if (typeof epgStatus === 'number' && epgStatus % 1 === 0 && epgStatus >= 100 && epgStatus <= 599) message = message.replace('[EPG:HTTP]', '[EPG:HTTP ' + epgStatus + ']');
    var epgCauses = { epg_timeout: 'TIMEOUT', epg_network: 'NETWORK', epg_size_limit: 'SIZE',
      epg_invalid_data: 'DATA', epg_http: 'HTTP', epg_unsupported: 'UNSUPPORTED', epg_unavailable: 'UNKNOWN' };
    var epgCause = error && error.code === 'epg_retry_deferred' && Object.prototype.hasOwnProperty.call(epgCauses, error.causeCode) && epgCauses[error.causeCode];
    if (epgCause) {
      var reason = messages[error.causeCode].replace(/\s*\[EPG:[^\]]+\]$/, '');
      var delay = typeof error.retryAt === 'number' ? Math.max(0, Math.ceil((error.retryAt - Date.now()) / 60000)) : null;
      message = reason + (delay === null ? ' Pobieranie jest chwilowo wstrzymane.' : ' Ponowna próba za około ' + delay + ' min.') +
        ' [EPG:RETRY ' + epgCause + (epgCause === 'HTTP' && typeof epgStatus === 'number' ? ' ' + epgStatus : '') + ']';
    }
    if (message === 'Something went wrong.') message = 'Nie udało się wykonać operacji.';
    var result = new Error(message);
    if (error && error.name) result.name = error.name;
    if (error && error.code) result.code = error.code;
    if (epgCause) result.causeCode = error.causeCode;
    if (error && typeof error.retryAt === 'number' && isFinite(error.retryAt) && error.retryAt % 1 === 0 && error.retryAt > 0) result.retryAt = error.retryAt;
    if (typeof epgStatus === 'number' && epgStatus % 1 === 0 && epgStatus >= 100 && epgStatus <= 599) result.status = epgStatus;
    try {
      var operation = error && error.cloudOperation;
      if (operation === 'signup' || operation === 'request_pairing') result.cloudOperation = operation;
    } catch (_) {}
    try {
      var status = error && error.name === 'CloudError' ? error.status : null;
      if (typeof status === 'number' && status % 1 === 0 && status >= 100 && status <= 599) result.status = status;
    } catch (_) {}
    return result;
  }

  function publicState() {
    return library.getState();
  }

  player.onState(function (snapshot) {
    playerSnapshot = snapshot || player.getState() || {};
    library.onState(readPlayerState());
    var state = publicState();
    listeners.slice().forEach(function (listener) { listener(state); });
  });

  function syncIfEnabled(action) {
    // No background network is enabled by installing/updating the app. The
    // viewer must explicitly enable autoCloudSync in their profile settings;
    // the library separately requires an unlocked, paired cloud profile.
    return library.query('settings.get').then(function (value) {
      if (value && value.settings && value.settings.autoCloudSync === true) {
        return library.query(action);
      }
    }).catch(function () {});
  }

  if (environment.document && environment.document.addEventListener) {
    environment.document.addEventListener('visibilitychange', function () {
      if (environment.document.hidden) {
        library.query('cache.flush').catch(function () {});
        library.stopPlayback().then(function () { return syncIfEnabled('pairing.flush'); }).catch(function () {});
      } else syncIfEnabled('pairing.autoSync');
    });
  }
  if (typeof environment.addEventListener === 'function') {
    environment.addEventListener('online', function () { syncIfEnabled('pairing.autoSync'); });
  }

  if (environment.tizen && environment.tizen.tvinputdevice &&
      typeof environment.tizen.tvinputdevice.registerKey === 'function') {
    ['MediaPlayPause', 'MediaPlay', 'MediaPause', 'MediaStop', 'MediaRewind', 'MediaFastForward', 'ChannelUp', 'ChannelDown', 'Guide', 'ChannelList', 'PreviousChannel', 'Info', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'].forEach(function (key) {
      try { environment.tizen.tvinputdevice.registerKey(key); } catch (_) {}
    });
  }

  function safe(operation) {
    return Promise.resolve().then(operation).catch(function (error) { throw friendly(error); });
  }

  return {
    query: function (action, args) {
      return safe(function () {
        args = args || {};
        if (action === 'backup.files.list' || action === 'backup.import.read' || action === 'backup.export.save') {
          if (!backupFiles) { var unavailable = new Error('Backup files are unavailable.'); unavailable.code = 'backup_unavailable'; throw unavailable; }
          if (action === 'backup.files.list') return args.path ? backupFiles.listDirectory(args.path) : backupFiles.listStorages().then(function (storages) { return { storages: storages }; });
          if (action === 'backup.import.read') return backupFiles.chooseImport(args.path).then(function (bytes) { return { bytes: bytes }; });
          return backupFiles.saveExport(args.bytes, args.filename, args.directoryPath);
        }
        return library.query(action, args);
      });
    },
    getState: publicState,
    onState: function (listener) {
      if (typeof listener !== 'function') throw new TypeError('onState expects a function.');
      listeners.push(listener);
      listener(publicState());
      return function () {
        var index = listeners.indexOf(listener);
        if (index >= 0) listeners.splice(index, 1);
      };
    },
    playPause: function () { return safe(function () { return player.playPause(); }); },
    seek: function (seconds) { return safe(function () { return player.seek(seconds); }); },
    exit: function () {
      return safe(function () {
        return Promise.all([library.query('cache.flush'), library.query('playback.stop')]).then(function () {
          if (typeof injected.exit === 'function') return injected.exit();
          if (!environment.tizen || !environment.tizen.application ||
              typeof environment.tizen.application.getCurrentApplication !== 'function') {
            throw new Error('Nie można zamknąć aplikacji.');
          }
          environment.tizen.application.getCurrentApplication().exit();
        });
      });
    }
  };
}));
