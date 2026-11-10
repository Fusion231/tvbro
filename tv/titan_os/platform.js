/* Titan OS system bindings for the existing shared Samsung TV client. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = { create: factory };
  else root.TVBroPlatformAdapters = factory(root);
}(typeof window !== 'undefined' ? window : this, function (environment) {
  'use strict';
  var storeModule = environment.TVBroWebOSSecureStore;
  var store = storeModule.create({ environment: environment });
  // Reuse the encrypted browser stores and conservative EPG budget. Titan does
  // not expose Samsung's KeyManager/PMS APIs to the hosted application.
  environment.TVBroSamsungMemoryPolicy = environment.TVBroWebOSMemoryPolicy;
  var options = {
    storeModule: storeModule,
    store: store,
    playerModule: environment.TVBroTitanPlayer,
    catalogStoreModule: environment.TVBroWebOSCatalogStore,
    backupFilesModule: environment.TVBroWebOSBackupFiles,
    deviceLabel: 'Titan OS TV',
    requiresHttpsProvider: true,
    confirmExit: true,
    normalizeKey: function (key) {
      if (key === 8 || key === 461) return 10009;
      return key === 179 ? 10252 : key;
    },
    exit: function () {
      var api = environment.SmartTvA_API;
      if (api && typeof api.exit === 'function') return api.exit();
      // Titan documents window.close as a fallback. Ordinary browser tabs may
      // ignore it, so only report success if their closed flag confirms it.
      if (typeof environment.close === 'function') {
        environment.close();
        if (environment.closed === true) return;
      }
      var error = new Error('Nie można zamknąć aplikacji.');
      error.name = 'NotSupportedError';
      throw error;
    }
  };
  options.ready = Promise.resolve().then(function () { return store.initialize(); });
  // Storage failures reach the shared startup error; never replace saved
  // profiles with an empty or plaintext fallback.
  options.ready.catch(function () {});
  return options;
}));
