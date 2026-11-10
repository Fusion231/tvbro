(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroWebOSSecureStore = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';
  options = options || {};
  var environment = options.environment || (typeof window !== 'undefined' ? window : {});
  var database = null, key = null, flight = null, ready = false, initializationGeneration = 0;
  var snapshots = { sources: '[]', user: '{}' }, writeTail = Promise.resolve();
  var crypto = environment.crypto, subtle = crypto && (crypto.subtle || crypto.webkitSubtle);
  var api;

  function error(name, message) { var value = new Error(message); value.name = name; return value; }
  function unsupported() { return error('NotSupportedError', 'Protected storage requires IndexedDB and persistent non-extractable AES-GCM keys on this TV.'); }
  function plain(value) {
    if (!value || Object.prototype.toString.call(value) !== '[object Object]') return false;
    var prototype = Object.getPrototypeOf(value);
    return prototype === Object.prototype || prototype === null;
  }
  function json(value, ancestors) {
    if (value === null || typeof value === 'string' || typeof value === 'boolean') return;
    if (typeof value === 'number' && isFinite(value)) return;
    if (typeof value !== 'object' || ancestors.indexOf(value) !== -1) throw error('TypeError', 'Storage accepts only acyclic JSON data.');
    ancestors.push(value);
    if (Object.prototype.toString.call(value) === '[object Array]') {
      for (var i = 0; i < value.length; i++) {
        if (!Object.prototype.hasOwnProperty.call(value, i)) throw error('TypeError', 'Sparse arrays cannot be stored.');
        json(value[i], ancestors);
      }
    } else {
      if (!plain(value)) throw error('TypeError', 'Storage requires plain JSON objects.');
      Object.keys(value).forEach(function (name) { json(value[name], ancestors); });
    }
    ancestors.pop();
  }
  function validateSources(value) {
    if (Object.prototype.toString.call(value) !== '[object Array]') throw error('TypeError', 'Source storage expects an array.');
    value.forEach(function (source) {
      if (!plain(source) || typeof source.id !== 'string' || typeof source.kind !== 'string' ||
          typeof source.label !== 'string' || !plain(source.fields) ||
          source.settings !== undefined && !plain(source.settings)) throw error('TypeError', 'Invalid saved source.');
      Object.keys(source.fields).forEach(function (name) {
        if (typeof source.fields[name] !== 'string') throw error('TypeError', 'Source fields must be strings.');
      });
    });
    json(value, []);
  }
  function validateUser(value) {
    if (!plain(value)) throw error('TypeError', 'User state must be a string-keyed object.');
    Object.keys(value).forEach(function (name) {
      if (!name || typeof value[name] !== 'string') throw error('TypeError', 'User state values must be strings.');
    });
  }
  // UTF-16LE preserves JSON strings on older engines without TextEncoder.
  // The encoding is versioned with the sealed record.
  function encode(raw) {
    var result = new Uint8Array(raw.length * 2);
    for (var i = 0; i < raw.length; i++) { var code = raw.charCodeAt(i); result[i * 2] = code & 255; result[i * 2 + 1] = code >>> 8; }
    return result;
  }
  function next(callback) {
    if (typeof environment.setTimeout === 'function') environment.setTimeout(callback, 0);
    else setTimeout(callback, 0);
  }
  function encodeAsync(raw) {
    if (raw.length <= 65536) return Promise.resolve(encode(raw));
    return new Promise(function (resolve, reject) {
      var result, position = 0;
      try { result = new Uint8Array(raw.length * 2); } catch (reason) { reject(reason); return; }
      function run() {
        try {
          var end = Math.min(raw.length, position + 65536);
          while (position < end) {
            var code = raw.charCodeAt(position); result[position * 2] = code & 255; result[position * 2 + 1] = code >>> 8; position++;
          }
          if (position === raw.length) resolve(result); else next(run);
        } catch (reason) { reject(reason); }
      }
      run();
    });
  }
  function decode(buffer) {
    return new Promise(function (resolve, reject) {
      var bytes = new Uint8Array(buffer), chunks = [], position = 0;
      if (bytes.length % 2) { reject(error('SecurityError', 'Protected storage data is malformed.')); return; }
      function run() {
        try {
          var end = Math.min(bytes.length, position + 131072);
          var codeUnits = [];
          while (position < end) {
            codeUnits.push(bytes[position] | bytes[position + 1] << 8); position += 2;
            if (codeUnits.length === 8192) {
              chunks.push(String.fromCharCode.apply(null, codeUnits)); codeUnits.length = 0;
            }
          }
          if (codeUnits.length) chunks.push(String.fromCharCode.apply(null, codeUnits));
          if (position === bytes.length) resolve(chunks.join('')); else next(run);
        } catch (reason) { reject(reason); }
      }
      run();
    });
  }
  function validKey(value) {
    return value && value.type === 'secret' && value.extractable === false && value.algorithm &&
      value.algorithm.name === 'AES-GCM' && value.algorithm.length === 256 && value.usages &&
      Array.prototype.indexOf.call(value.usages, 'encrypt') !== -1 && Array.prototype.indexOf.call(value.usages, 'decrypt') !== -1;
  }
  function transaction(mode, operation) {
    return new Promise(function (resolve, reject) {
      var tx, result, failure;
      try {
        if (!database) throw unsupported();
        tx = database.transaction(['values'], mode);
        tx.oncomplete = function () { resolve(result); };
        tx.onabort = function () { reject(failure || tx.error || error('AbortError', 'Protected storage transaction was aborted.')); };
        operation(tx.objectStore('values'), function (value) { result = value; }, function (reason) { failure = reason; tx.abort(); });
      } catch (reason) {
        if (tx) { failure = reason; try { tx.abort(); } catch (_) { reject(reason); } }
        else reject(reason);
      }
    });
  }
  function get(name) {
    return transaction('readonly', function (store, done) {
      var request = store.get(name); request.onsuccess = function () { done(request.result); };
    });
  }
  function open() {
    if (database) return Promise.resolve();
    return new Promise(function (resolve, reject) {
      var request, settled = false;
      try {
        if (!environment.indexedDB || typeof environment.indexedDB.open !== 'function' || !subtle ||
            typeof subtle.generateKey !== 'function' || typeof subtle.encrypt !== 'function' ||
            typeof subtle.decrypt !== 'function' || !crypto || typeof crypto.getRandomValues !== 'function') throw unsupported();
        request = environment.indexedDB.open('tvbro_webos_protected_v1', 1);
        request.onupgradeneeded = function () { request.result.createObjectStore('values'); };
        request.onblocked = function () { settled = true; reject(error('InvalidStateError', 'Protected storage upgrade is blocked by another app instance.')); };
        request.onerror = function () { settled = true; reject(request.error || unsupported()); };
        request.onsuccess = function () {
          if (settled) { request.result.close(); return; }
          var openedDatabase = request.result;
          database = openedDatabase;
          openedDatabase.onversionchange = function () {
            openedDatabase.close();
            if (database !== openedDatabase) return;
            database = null;
            key = null;
            ready = false;
            initializationGeneration += 1;
            flight = null;
          };
          resolve();
        };
      } catch (reason) { reject(reason); }
    });
  }
  function domain(value) {
    if (typeof value !== 'string' || !value || value.length > 200) throw error('TypeError', 'Protected storage requires a record domain.');
    return encode('TVBro:webOS:v1:' + value);
  }
  function seal(raw, name) {
    return Promise.resolve().then(function () {
      if (!validKey(key)) throw unsupported();
      if (typeof raw !== 'string') throw error('TypeError', 'Protected storage requires a string.');
      var iv = new Uint8Array(12); crypto.getRandomValues(iv);
      var algorithm = { name: 'AES-GCM', iv: iv, additionalData: domain(name), tagLength: 128 };
      return encodeAsync(raw).then(function (bytes) { return subtle.encrypt(algorithm, key, bytes); }).then(function (ciphertext) {
        return { version: 1, iv: iv.buffer, ciphertext: ciphertext };
      });
    });
  }
  function unseal(value, name) {
    return Promise.resolve().then(function () {
      if (!validKey(key)) throw unsupported();
      if (!value || value.version !== 1 || Object.prototype.toString.call(value.iv) !== '[object ArrayBuffer]' ||
          value.iv.byteLength !== 12 || Object.prototype.toString.call(value.ciphertext) !== '[object ArrayBuffer]' ||
          value.ciphertext.byteLength < 16) throw error('SecurityError', 'Protected storage data is malformed.');
      return subtle.decrypt({ name: 'AES-GCM', iv: new Uint8Array(value.iv), additionalData: domain(name), tagLength: 128 }, key, value.ciphertext).then(decode);
    });
  }
  function ensureKey() {
    return transaction('readonly', function (store, done) {
      var keys = ['key', 'sources', 'user'], values = {};
      keys.forEach(function (name) { var request = store.get(name); request.onsuccess = function () { values[name] = request.result; }; });
      done(values);
    }).then(function (values) {
      if (values.key !== undefined) {
        if (!validKey(values.key)) throw error('SecurityError', 'The protected storage key is invalid.');
        key = values.key; return;
      }
      if (values.sources !== undefined || values.user !== undefined) throw error('SecurityError', 'The protected storage key is missing.');
      return subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']).then(function (generated) {
        if (!validKey(generated)) throw unsupported();
        return transaction('readwrite', function (store, done, abort) {
          var request = store.get('key');
          request.onsuccess = function () {
            if (request.result !== undefined) {
              if (!validKey(request.result)) { abort(error('SecurityError', 'The protected storage key is invalid.')); return; }
              done(request.result);
            } else { store.add(generated, 'key'); done(generated); }
          };
        });
      }).then(function () {
        // Early TV engines may not clone CryptoKey. Read it back; never export
        // the key or substitute plaintext if persistence is unavailable.
        return get('key');
      }).then(function (stored) { if (!validKey(stored)) throw unsupported(); key = stored; });
    });
  }
  function initialize() {
    if (flight) return flight;
    var generation = initializationGeneration;
    var attempt = open().then(ensureKey).then(function () {
      return seal('TVBro key verification', 'probe').then(function (sealed) { return unseal(sealed, 'probe'); });
    }).then(function (probe) {
      if (probe !== 'TVBro key verification') throw unsupported();
      return Promise.all(['sources', 'user'].map(function (name) {
        return get(name).then(function (value) {
          if (value === undefined) return name === 'sources' ? '[]' : '{}';
          return unseal(value, name);
        }).then(function (raw) {
          var value;
          try { value = JSON.parse(raw); (name === 'sources' ? validateSources : validateUser)(value); }
          catch (_) { throw error('SecurityError', 'Protected storage data is malformed.'); }
          snapshots[name] = JSON.stringify(value);
        });
      }));
    }).then(function () {
      if (generation !== initializationGeneration) throw error('InvalidStateError', 'Protected storage changed during initialization.');
      ready = true;
      return api;
    });
    var pending;
    pending = attempt.then(function (result) { return result; }, function (reason) {
      if (flight === pending) { flight = null; ready = false; }
      throw reason;
    });
    flight = pending;
    return pending;
  }
  function requireReady() { if (!ready) throw error('InvalidStateError', 'Protected storage has not initialized.'); }
  function read(name) { requireReady(); return JSON.parse(snapshots[name]); }
  function write(name, value) {
    var raw;
    try { requireReady(); (name === 'sources' ? validateSources : validateUser)(value); raw = JSON.stringify(value); }
    catch (reason) { return Promise.reject(reason); }
    var result = writeTail.then(function () {
      return seal(raw, name).then(function (sealed) {
        return transaction('readwrite', function (store) { store.put(sealed, name); });
      }).then(function () { snapshots[name] = raw; });
    });
    writeTail = result.then(function () {}, function () {}); return result;
  }
  api = {
    initialize: initialize,
    read: function () { return read('sources'); },
    write: function (value) { return write('sources', value); },
    remove: function () { return write('sources', []); },
    readUserState: function () { return read('user'); },
    writeUserState: function (value) { return write('user', value); },
    removeUserState: function () { return write('user', {}); },
    encrypt: function (raw, name) { try { requireReady(); } catch (reason) { return Promise.reject(reason); } return seal(raw, name); },
    decrypt: function (value, name) { try { requireReady(); } catch (reason) { return Promise.reject(reason); } return unseal(value, name); },
    capabilities: function () { return { ready: ready, encrypted: ready, hardwareBacked: false, protection: 'origin-bound non-extractable WebCrypto key in IndexedDB' }; }
  };
  return api;
}));
