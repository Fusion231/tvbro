/* webOS system boundaries for the shared TV client. No source/profile rules. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = { create: factory };
  else root.TVBroPlatformAdapters = factory(root);
}(typeof window !== 'undefined' ? window : this, function (environment) {
  'use strict';
  var storeModule = environment.TVBroWebOSSecureStore;
  environment.TVBroSamsungEpgFiles = environment.TVBroWebOSEpgFiles;
  var store = storeModule.create({ environment: environment });
  // Source parsing still runs in the shared worker. Keep the existing worker's
  // memory-policy binding, with LG's conservative policy in place of Tizen PMS.
  environment.TVBroSamsungMemoryPolicy = environment.TVBroWebOSMemoryPolicy;
  var options = {
    storeModule: storeModule,
    store: store,
    playerModule: environment.TVBroLgWebosPlayer,
    catalogStoreModule: environment.TVBroWebOSCatalogStore,
    backupFilesModule: environment.TVBroWebOSBackupFiles,
    deviceLabel: 'LG TV',
    normalizeKey: function (key) { return key === 461 ? 10009 : key; },
    exit: function () {
      if (environment.webOS && typeof environment.webOS.platformBack === 'function') {
        environment.webOS.platformBack();
      } else if (typeof environment.close === 'function') environment.close();
      else throw new Error('Nie można zamknąć aplikacji.');
    }
  };
  options.ready = Promise.resolve().then(function () { return store.initialize(); });
  // A rejected initialization is shown by the shared startup UI, never replaced
  // by an empty or plaintext store. Attach immediately during script loading.
  options.ready.catch(function () {});
  var webOS = environment.webOS;
  if (webOS && webOS.platform && webOS.platform.tv && webOS.service &&
      typeof webOS.service.request === 'function') {
    options.openTrailer = function (url) {
      return new Promise(function (resolve, reject) {
        var parsed, timer = null, request = null, settled = false;
        function unavailable() {
          var error = new Error('Could not open the trailer or YouTube.');
          error.name = 'NotSupportedError'; error.code = 'trailer_unavailable'; return error;
        }
        function finish(failed) {
          if (settled) return; settled = true;
          if (timer !== null) environment.clearTimeout(timer);
          if (failed && request && typeof request.cancel === 'function') {
            try { request.cancel(); } catch (_) {}
          }
          if (failed) reject(unavailable()); else resolve();
        }
        try {
          if (typeof url !== 'string' || /\s/.test(url)) throw unavailable();
          parsed = new environment.URL(url);
          if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password) throw unavailable();
          timer = environment.setTimeout(function () { finish(true); }, 10000);
          request = webOS.service.request('luna://com.webos.applicationManager', {
            method: 'launch', parameters: { id: 'com.webos.app.browser', params: { target: parsed.href } },
            onSuccess: function () { finish(false); }, onFailure: function () { finish(true); }
          });
        } catch (_) { finish(true); }
      });
    };
  }
  return options;
}));
