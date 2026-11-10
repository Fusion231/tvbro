(function (root) {
  'use strict';

  function error(name, message, code) {
    var value = new Error(message);
    value.name = name;
    if (code) value.code = code;
    return value;
  }
  function cancelled() { return error('AbortError', 'Source operation was cancelled.', 'cancelled'); }
  function errorRecord(value) {
    var record = { name: 'Error', message: 'The source operation could not be completed.' };
    if (value && typeof value.name === 'string' && /^[A-Za-z][A-Za-z0-9]{0,63}$/.test(value.name)) record.name = value.name;
    if (value && typeof value.message === 'string') record.message = value.message.slice(0, 240);
    if (value && value.code === 'cancelled') record.code = 'cancelled';
    return record;
  }
  function fromRecord(value) {
    var record = errorRecord(value);
    return error(record.name, record.message, record.code);
  }
  // 0.1.31 transfers the XHR buffer; base64 is needed only at the Dart JSON
  // boundary inside this worker. 24576 is divisible by three (no inner padding).
  function httpResponse(value) {
    if (typeof value === 'string') return value;
    if (value && value.bodyBuffer) {
      var bytes = new Uint8Array(value.bodyBuffer), chunks = [];
      for (var offset = 0; offset < bytes.length; offset += 24576) {
        chunks.push(root.btoa(String.fromCharCode.apply(null, bytes.subarray(offset, offset + 24576))));
      }
      delete value.bodyBuffer;
      value.bodyBase64 = chunks.join('');
    }
    return JSON.stringify(value);
  }

  var panelPinHash = null;
  /*__TVBRO_PANEL_PIN_BINDING__*/

  function verifyPinFast(environment, pin, verifier, fallback) {
    if (typeof pin !== 'string' || typeof verifier !== 'string') return fallback();
    if (pin.length !== 4 || !/^[0-9]{4}$/.test(pin)) return Promise.resolve(false);
    try {
      var core = environment.TVBroCanonical;
      if (!core || typeof core.isPinVerifier !== 'function') return fallback();
      if (!core.isPinVerifier(verifier)) return Promise.resolve(false);
      var crypto = environment.crypto, subtle = crypto && (crypto.subtle || crypto.webkitSubtle);
      if (!panelPinHash || !subtle || typeof subtle.importKey !== 'function' ||
          typeof subtle.deriveBits !== 'function' || typeof environment.TextEncoder !== 'function' ||
          typeof environment.atob !== 'function' || typeof environment.btoa !== 'function') return fallback();
      var parts = verifier.split('$');
      // Dart also accepts normalized/legacy encodings; leave those to its parser.
      if (!/^[0-9]+$/.test(parts[1]) ||
          !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(parts[2]) ||
          !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(parts[3])) return fallback();
      var saltText = environment.atob(parts[2]), expected = environment.atob(parts[3]);
      var salt = new Uint8Array(saltText.length), iterations = Number(parts[1]);
      if (salt.length < 8 || salt.length > 64 || expected.length !== 32 ||
          iterations < 1 || iterations > 1000000 || Math.floor(iterations) !== iterations) return fallback();
      for (var i = 0; i < salt.length; i++) salt[i] = saltText.charCodeAt(i);
      return Promise.resolve(panelPinHash(environment)(pin, salt, iterations)).then(function (derived) {
        var actual = environment.atob(derived.split('$')[3]);
        if (actual.length !== expected.length) throw error('TypeError', 'Invalid native PIN derivation.');
        var difference = 0;
        for (var i = 0; i < expected.length; i++) difference |= actual.charCodeAt(i) ^ expected.charCodeAt(i);
        return difference === 0;
      }).catch(function () { return fallback(); });
    } catch (_) { return fallback(); }
  }

  function workerMain() {
    var sources = Object.create(null), http = Object.create(null), nextHttp = 0;
    var cooldowns = Object.create(null), nextCooldown = 0;
    function reply(id, value, failure) {
      try { root.postMessage({ type: 'result', id: id, value: value, error: failure && errorRecord(failure) }); }
      catch (_) { root.postMessage({ type: 'result', id: id, error: errorRecord(error('DataCloneError', 'Source data could not be transferred.')) }); }
    }
    function disposeSource(id) {
      var source = sources[id];
      delete sources[id];
      Object.keys(http).forEach(function (key) {
        if (http[key].source !== id) return;
        http[key].reject(cancelled()); delete http[key];
      });
      if (source) Promise.resolve().then(function () { return source.dispose(); }).then(function () {}, function () {});
    }
    try {
      root.importScripts('../polyfills.js', '../pako-inflate.js', 'streaming_gzip.js', '../canonical-core.js');
      if (!root.TVBroCanonical || typeof root.TVBroCanonical.createSource !== 'function') throw error('NotSupportedError', 'The canonical source engine is unavailable.');
    } catch (_) {
      root.postMessage({ type: 'fatal', error: errorRecord(error('NotSupportedError', 'The source worker could not start.')) });
      return;
    }
    root.onmessage = function (event) {
      var message = event.data || {};
      if (message.type === 'cooldownsResult') {
        var saved = cooldowns[message.id];
        if (!saved) return;
        delete cooldowns[message.id];
        if (message.error) saved.reject(fromRecord(message.error)); else saved.resolve('null');
        return;
      }
      if (message.type === 'httpResult') {
        var waiting = http[message.id];
        if (!waiting) return;
        delete http[message.id];
        try { waiting.resolve(httpResponse(message.value)); }
        catch (_) { waiting.reject(error('NetworkError', 'The provider response could not be decoded.')); }
        return;
      }
      if (message.type === 'dispose') { disposeSource(message.source); return; }
      if (message.type === 'pin') {
        Promise.resolve().then(function () {
          if (message.method !== 'verifyPin' && message.method !== 'hashPin') throw error('NotSupportedError', 'Unknown profile PIN operation.');
          if (typeof root.TVBroCanonical[message.method] !== 'function') throw error('NotSupportedError', 'The canonical profile PIN operation is unavailable.');
          return message.method === 'verifyPin'
            ? root.TVBroCanonical.verifyPin(message.pin, message.verifier)
            : root.TVBroCanonical.hashPin(message.pin);
        }).then(function (value) {
          if (typeof value !== (message.method === 'verifyPin' ? 'boolean' : 'string')) throw error('TypeError', 'The profile PIN response is invalid.');
          // PIN jobs return a boolean or a raw verifier, never a Source JSON DTO.
          reply(message.id, value, null);
        }).catch(function () { reply(message.id, null, error('Error', 'The profile PIN operation could not be completed.')); });
        return;
      }
      if (message.type !== 'create' && message.type !== 'invoke' && message.type !== 'restoreCatalog' && message.type !== 'restoreGuide') return;
      Promise.resolve().then(function () {
        if (message.type === 'create') {
          if (sources[message.source]) throw error('InvalidStateError', 'This source already exists.');
          sources[message.source] = root.TVBroCanonical.createSource(message.config, function (request) {
            return new Promise(function (resolve, reject) {
              if (!sources[message.source]) { reject(cancelled()); return; }
              var id = ++nextHttp;
              http[id] = { source: message.source, resolve: resolve, reject: reject };
              try { root.postMessage({ type: 'http', id: id, source: message.source, request: request }); }
              catch (_) { delete http[id]; reject(error('NetworkError', 'The provider request could not be transferred.')); }
            });
          });
          return null;
        }
        var source = sources[message.source];
        if (!source) throw cancelled();
        if (message.type === 'restoreCatalog') return source.invoke('importCatalog', JSON.stringify({ scope: message.scope, snapshot: message.snapshot }));
        if (message.type === 'restoreGuide') return source.invoke('importGuide', JSON.stringify({ scope: message.scope, snapshot: message.snapshot }));
        return source.invoke(message.method, message.args);
      }).then(function (raw) {
        if (!sources[message.source]) throw cancelled();
        // Keep the full Dart JSON parse off the application's UI thread.
        reply(message.id, typeof raw === 'string' ? JSON.parse(raw) : raw, null);
      }).catch(function (failure) { reply(message.id, null, failure); });
    };
    Promise.resolve().then(function () {
      if (typeof root.TVBroCanonical.providerGateInit !== 'function') throw error('NotSupportedError', 'The provider request gate is unavailable.');
      return root.TVBroCanonical.providerGateInit('{}', function (snapshot) {
        return new Promise(function (resolve, reject) {
          var id = ++nextCooldown;
          cooldowns[id] = { resolve: resolve, reject: reject };
          try { root.postMessage({ type: 'cooldowns', id: id, snapshot: snapshot }); }
          catch (_) { delete cooldowns[id]; reject(error('Error', 'Provider cooldowns could not be saved.')); }
        });
      });
    }).then(function () { root.postMessage({ type: 'ready' }); }).catch(function () {
      root.postMessage({ type: 'fatal', error: errorRecord(error('NotSupportedError', 'The provider request gate could not start.')) });
    });
  }

  function create(environment, options) {
    environment = environment || root;
    options = options || {};
    var memoryPolicy = options.memoryPolicy;
    if (!memoryPolicy && environment.TVBroSamsungMemoryPolicy && typeof environment.TVBroSamsungMemoryPolicy.create === 'function') {
      try { memoryPolicy = environment.TVBroSamsungMemoryPolicy.create({ environment: environment }); } catch (_) {}
    }
    var current = null, nextSource = 0, nextCall = 0;
    function stop(session, failure) {
      if (current !== session) return;
      current = null;
      environment.clearTimeout(session.timer);
      session.worker.onmessage = session.worker.onerror = session.worker.onmessageerror = null;
      try { session.worker.terminate(); } catch (_) {}
      session.rejectReady(failure);
      Object.keys(session.pending).forEach(function (id) { session.pending[id].reject(failure); });
      session.pending = Object.create(null);
      Object.keys(session.sources).forEach(function (id) { session.sources[id].closed = true; });
      Object.keys(session.jobs).forEach(function (id) { session.jobs[id].closed = true; });
      session.sources = Object.create(null); session.jobs = Object.create(null); session.count = 0;
    }
    function post(session, message, buffers) {
      if (current !== session) throw cancelled();
      try { session.worker.postMessage(message, buffers || []); }
      catch (_) {
        var failure = error('DataCloneError', 'The source worker could not receive data.');
        stop(session, failure); throw failure;
      }
    }
    function start() {
      if (current) return current;
      if (typeof environment.Worker !== 'function') throw error('NotSupportedError', 'This TV does not provide a source worker.');
      var session = { worker: new environment.Worker('platform/source_worker.js'), sources: Object.create(null),
        jobs: Object.create(null), pending: Object.create(null), count: 0, ready: null, timer: null };
      session.ready = new Promise(function (resolve, reject) { session.resolveReady = resolve; session.rejectReady = reject; });
      current = session;
      session.worker.onerror = function (event) {
        if (event && event.preventDefault) event.preventDefault();
        stop(session, error('Error', 'The source worker stopped unexpectedly.'));
      };
      session.worker.onmessageerror = function () { stop(session, error('DataCloneError', 'Source data could not be transferred.')); };
      session.worker.onmessage = function (event) {
        if (current !== session) return;
        var message = event.data || {};
        if (message.type === 'ready') { environment.clearTimeout(session.timer); session.resolveReady(); return; }
        if (message.type === 'fatal') { stop(session, fromRecord(message.error)); return; }
        if (message.type === 'cooldowns') {
          Promise.resolve().then(function () {
            if (typeof options.mergeCooldowns !== 'function') throw error('NotSupportedError', 'Provider cooldown storage is unavailable.');
            return options.mergeCooldowns(message.snapshot);
          }).then(function () {
            if (current !== session) return;
            post(session, { type: 'cooldownsResult', id: message.id });
          }).catch(function () {
            if (current !== session) return;
            try { post(session, { type: 'cooldownsResult', id: message.id,
              error: errorRecord(error('Error', 'Provider cooldowns could not be saved.')) }); } catch (_) {}
          });
          return;
        }
        if (message.type === 'result') {
          var pending = session.pending[message.id];
          if (!pending) return;
          delete session.pending[message.id];
          if (message.error) pending.reject(fromRecord(message.error)); else pending.resolve(message.value);
          return;
        }
        if (message.type !== 'http') return;
        var source = session.sources[message.source];
        if (!source || source.closed) return;
        Promise.resolve().then(function () {
          if (current !== session || source.closed) throw cancelled();
          return source.transport(message.request, {binaryResponse:true});
        }).then(function (value) {
          if (current !== session || source.closed) return;
          var buffers = value && value.bodyBuffer ? [value.bodyBuffer] : [];
          post(session, { type: 'httpResult', id: message.id, value: value }, buffers);
        }).catch(function () {
          if (current !== session || source.closed) return;
          try { post(session, { type: 'httpResult', id: message.id,
            value: '{"errorKind":"network","error":"The provider transport failed."}' }); } catch (_) {}
        });
      };
      session.timer = environment.setTimeout(function () {
        stop(session, error('TimeoutError', 'The source worker did not start in time.'));
      }, 30000);
      return session;
    }
    function call(source, message) {
      return new Promise(function (resolve, reject) {
        var session = source.session;
        if (source.closed || current !== session) { reject(cancelled()); return; }
        var id = ++nextCall;
        session.pending[id] = { source: source.id, resolve: resolve, reject: reject };
        message.id = id; message.source = source.id;
        try { post(session, message); } catch (failure) { reject(failure); }
      });
    }
    function dispose(source) {
      if (source.closed) return Promise.resolve();
      source.closed = true;
      var session = source.session;
      delete session.sources[source.id]; session.count -= 1;
      Object.keys(session.pending).forEach(function (id) {
        if (session.pending[id].source !== source.id) return;
        session.pending[id].reject(cancelled()); delete session.pending[id];
      });
      if (current === session) {
        if (!session.count) stop(session, cancelled());
        else { try { post(session, { type: 'dispose', source: source.id }); } catch (_) {} }
      }
      // Back/cancel cannot wait for a CPU-bound worker to acknowledge disposal.
      return Promise.resolve();
    }
    function finishPin(job) {
      if (job.closed) return;
      job.closed = true;
      var session = job.session;
      delete session.jobs[job.id]; session.count -= 1;
      if (current === session && !session.count) stop(session, cancelled());
    }
    function pinJob(method, pin, verifier) {
      if (method !== 'verifyPin' && method !== 'hashPin') return Promise.reject(error('NotSupportedError', 'Unknown profile PIN operation.'));
      if (typeof pin !== 'string' || (method === 'verifyPin' && typeof verifier !== 'string')) {
        return Promise.reject(new TypeError('Profile PIN arguments must be strings.'));
      }
      var session;
      try { session = start(); } catch (failure) { return Promise.reject(failure); }
      var job = { id: ++nextSource, session: session, closed: false };
      session.jobs[job.id] = job; session.count += 1;
      return session.ready.then(function () {
        return call(job, { type: 'pin', method: method, pin: pin, verifier: verifier });
      }).then(function (value) {
        finishPin(job); return value;
      }, function (failure) {
        finishPin(job); throw failure;
      });
    }
    return { createSource: function (config, transport) {
      if (typeof config !== 'string' || typeof transport !== 'function') throw new TypeError('Source configuration and transport are required.');
      var session = start(), source = { id: ++nextSource, session: session, transport: transport, closed: false };
      session.sources[source.id] = source; session.count += 1;
      var created = session.ready.then(function () { return call(source, { type: 'create', config: config }); });
      created.then(function () {}, function () {});
      function catalogCall(method, args) {
        if (source.closed) return Promise.reject(cancelled());
        return created.then(function () {
          return call(source, { type: 'invoke', method: method, args: JSON.stringify(args || {}) });
        });
      }
      return {
        invoke: function (method, args) {
          if (source.closed) return Promise.reject(cancelled());
          return created.then(function () {
            if (method === 'epg' || method === 'epgCached') {
              var values = JSON.parse(args || '{}');
              var maximum = 32 * 1024 * 1024;
              if (memoryPolicy) {
                try { maximum = memoryPolicy.sample().maximumEpgBytes; } catch (_) {}
              }
              values._tvEpgMaximumBytes = maximum;
              values._tvEpgDisk = typeof options.epgDiskAvailable === 'function' && options.epgDiskAvailable();
              args = JSON.stringify(values);
            }
            return call(source, { type: 'invoke', method: method, args: args });
          });
        },
        restoreCatalog: function (scope, snapshot) {
          if (source.closed) return Promise.reject(cancelled());
          return created.then(function () { return call(source, { type: 'restoreCatalog', scope: scope, snapshot: snapshot }); });
        },
        restoreGuide: function (scope, snapshot) {
          if (source.closed) return Promise.reject(cancelled());
          return created.then(function () { return call(source, { type: 'restoreGuide', scope: scope, snapshot: snapshot }); });
        },
        catalogState: function () { return catalogCall('catalogState'); },
        prepareCatalog: function (kind, refreshKey, forceRefresh) {
          return catalogCall('prepareCatalog', { kind: kind, refreshKey: refreshKey, forceRefresh: forceRefresh === true });
        },
        beginCatalogExport: function (scope) { return catalogCall('beginCatalogExport', { scope: scope }); },
        exportCatalogPart: function (index) { return catalogCall('exportCatalogPart', { index: index }); },
        beginCatalogImport: function (scope, manifest) {
          return catalogCall('beginCatalogImport', { scope: scope, manifest: manifest });
        },
        importCatalogPart: function (index, raw, checksum) {
          return catalogCall('importCatalogPart', { index: index, raw: raw, checksum: checksum });
        },
        commitCatalogImport: function () { return catalogCall('commitCatalogImport'); },
        abortCatalogImport: function () { return catalogCall('abortCatalogImport'); },
        dispose: function () { return dispose(source); }
      };
    },
      verifyPin: function (pin, verifier) {
        return verifyPinFast(environment, pin, verifier, function () { return pinJob('verifyPin', pin, verifier); });
      },
      hashPin: function (pin) { return pinJob('hashPin', pin); }
    };
  }

  if (typeof root.importScripts === 'function' && !root.document) workerMain();
  else if (typeof module === 'object' && module.exports) module.exports = { create: create };
  else root.TVBroSamsungSourceWorker = { create: create };
}(typeof self !== 'undefined' ? self : this));
