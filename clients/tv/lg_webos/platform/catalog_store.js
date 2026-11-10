(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroWebOSCatalogStore = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';
  options = options || {};
  var environment = options.environment || (typeof window !== 'undefined' ? window : {});
  var secure = options.secureStore, database = null, flight = null, tail = Promise.resolve();
  var maximumFileBytes = 32 * 1024 * 1024, maximumPartBytes = 1024 * 1024, maximumStoreBytes = 64 * 1024 * 1024;
  var maximumGuaranteedUtf8Chars = Math.floor(maximumFileBytes / 3);
  var maximumEntries = 128, maximumSafeInteger = 9007199254740991;

  function error(name, message) { var value = new Error(message); value.name = name; return value; }
  function validateKey(key) {
    if (typeof key !== 'string' || !/^[0-9a-f]{64}$/.test(key)) throw error('TypeError', 'Catalog cache key must be a 64-character lowercase hexadecimal string.');
  }
  function validNumber(value) { return typeof value === 'number' && isFinite(value) && value >= 0 && value <= maximumSafeInteger && Math.floor(value) === value; }
  function open() {
    if (flight) return flight;
    flight = new Promise(function (resolve, reject) {
      var request, settled = false;
      try {
        if (!secure || typeof secure.encrypt !== 'function' || typeof secure.decrypt !== 'function' ||
            !environment.indexedDB || typeof environment.indexedDB.open !== 'function') throw error('NotSupportedError', 'Encrypted catalog storage is unavailable.');
        request = environment.indexedDB.open('tvbro_webos_catalog_v1', 1);
        request.onupgradeneeded = function () {
          request.result.createObjectStore('metadata');
          request.result.createObjectStore('payloads');
        };
        request.onerror = function () { settled = true; reject(request.error || error('IOError', 'Catalog storage could not open.')); };
        request.onblocked = function () { settled = true; reject(error('InvalidStateError', 'Catalog storage upgrade is blocked.')); };
        request.onsuccess = function () {
          if (settled) { request.result.close(); return; }
          database = request.result;
          database.onversionchange = function () { database.close(); database = null; flight = null; };
          resolve();
        };
      } catch (reason) { reject(reason); }
    });
    return flight;
  }
  function transaction(mode, operation) {
    return new Promise(function (resolve, reject) {
      var tx, result, failure;
      try {
        if (!database) throw error('InvalidStateError', 'Catalog storage is closed.');
        tx = database.transaction(['metadata', 'payloads'], mode);
        tx.oncomplete = function () { resolve(result); };
        tx.onabort = function () { reject(failure || tx.error || error('AbortError', 'Catalog transaction was aborted.')); };
        operation(tx.objectStore('metadata'), tx.objectStore('payloads'), function (value) { result = value; });
      } catch (reason) {
        failure = reason;
        if (tx) { try { tx.abort(); } catch (_) { reject(reason); } } else reject(reason);
      }
    });
  }
  function serialize(operation) {
    var result = tail.then(function () { return open().then(operation); });
    tail = result.then(function () {}, function () {}); return result;
  }
  function validMetadata(value, id) {
    return value && typeof value.key === 'string' && /^[0-9a-f]{64}$/.test(value.key) &&
      typeof value.token === 'string' && /^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$/.test(value.token) &&
      id === value.key + ':' + value.token && validNumber(value.timestamp) && validNumber(value.counter) &&
      value.token === String(value.timestamp) + '-' + String(value.counter) &&
      validNumber(value.bytes) && value.bytes >= 16 && value.bytes <= maximumStoreBytes &&
      (value.kind === undefined || value.kind === 'catalog' || value.kind === 'guide' || value.kind === 'metadata') &&
      (value.format === undefined || value.format === 'batch' && validNumber(value.partCount) && value.partCount <= 4096);
  }
  // Cursor over tiny metadata records only. Large encrypted catalogs are read
  // one at a time; getAll() would duplicate every source and guide in memory.
  function entries(store, callback) {
    var rows = [], request = store.openCursor();
    request.onsuccess = function () {
      var cursor = request.result;
      if (!cursor) { callback(rows); return; }
      if (!validMetadata(cursor.value, cursor.key) || rows.length >= maximumEntries) {
        // A malformed index cannot justify unbounded scans or unsafe budgets.
        throw error('DataError', 'Catalog metadata is invalid or exceeds its entry limit.');
      }
      rows.push(cursor.value); cursor.continue();
    };
  }
  function newest(left, right) { return right.timestamp - left.timestamp || right.counter - left.counter; }
  function kindOf(row) { return row.kind === 'guide' ? 'guide' : row.kind === 'metadata' ? 'metadata' : 'catalog'; }
  function id(row) { return row.key + ':' + row.token; }
  function partId(row, index) { return id(row) + ':part:' + index; }
  function erase(metadata, payloads, row) {
    metadata.delete(id(row)); payloads.delete(id(row));
    if (row.format === 'batch') for (var i = 0; i < row.partCount; i++) payloads.delete(partId(row, i));
  }
  function removeRecord(row) {
    return transaction('readwrite', function (metadata, payloads) { erase(metadata, payloads, row); });
  }
  function markNow(key, kind) {
    return transaction('readwrite', function (metadata, payloads, done) {
      entries(metadata, function (rows) {
        var matches = rows.filter(function (row) { return row.key === key; });
        matches.forEach(function (row) {
          if (kindOf(row) !== kind) metadata.put(Object.assign({}, row, { kind: kind }), id(row));
        });
        done(matches.length > 0);
      });
    });
  }
  function readNow(key) {
    return transaction('readonly', function (metadata, payloads, done) {
      entries(metadata, function (rows) { done(rows.filter(function (row) { return row.key === key && row.format !== 'batch'; }).sort(newest).slice(0, 2)); });
    }).then(function (rows) {
      var position = 0;
      function next() {
        if (position >= rows.length) return null;
        var row = rows[position++];
        return transaction('readonly', function (metadata, payloads, done) {
          var request = payloads.get(id(row)); request.onsuccess = function () { done(request.result); };
        }).then(function (sealed) {
          if (!sealed || !sealed.ciphertext || sealed.ciphertext.byteLength !== row.bytes) throw error('DataError', 'Catalog payload is incomplete.');
          return secure.decrypt(sealed, 'catalog:' + id(row));
        }).then(function (raw) {
          if (typeof raw !== 'string' || !raw.length || raw.length > maximumFileBytes) throw error('DataError', 'Catalog payload is invalid.');
          return { raw: raw, token: row.token };
        }).catch(function () { return removeRecord(row).then(next, next); });
      }
      return next();
    });
  }
  function validManifest(value) {
    if (!value || value.schema !== 1 || !Array.isArray(value.parts) || value.parts.length > 4096) return false;
    var seen = Object.create(null);
    return value.parts.every(function (part, index) {
      if (!part || part.index !== index || !validNumber(part.index) || seen[part.index]) return false;
      seen[part.index] = true; return true;
    });
  }
  function batchDomain(row, index) { return 'catalog-batch:' + id(row) + (index === null ? ':manifest' : ':part:' + index); }
  function readBatchNow(key) {
    return transaction('readonly', function (metadata, payloads, done) {
      entries(metadata, function (rows) {
        done(rows.filter(function (row) { return row.key === key && row.format === 'batch'; }).sort(newest).slice(0, 2));
      });
    }).then(function (rows) {
      var position = 0;
      function next() {
        if (position >= rows.length) return null;
        var row = rows[position++];
        return transaction('readonly', function (metadata, payloads, done) {
          var request = payloads.get(id(row)); request.onsuccess = function () { done(request.result); };
        }).then(function (sealed) {
          if (!sealed || !sealed.ciphertext || sealed.ciphertext.byteLength < 16 || sealed.ciphertext.byteLength > maximumPartBytes * 2 + 16) {
            throw error('DataError', 'Catalog batch manifest is incomplete.');
          }
          return secure.decrypt(sealed, batchDomain(row, null));
        }).then(function (raw) {
          var manifest;
          try { manifest = JSON.parse(raw); } catch (_) { throw error('DataError', 'Catalog batch manifest is invalid.'); }
          if (typeof raw !== 'string' || measure(raw) > maximumPartBytes || !validManifest(manifest) || manifest.parts.length !== row.partCount) {
            throw error('DataError', 'Catalog batch manifest is invalid.');
          }
          return { manifest: manifest, token: row.token, count: row.partCount };
        }).catch(function () { return removeRecord(row).then(next, next); });
      }
      return next();
    });
  }
  function readBatchPartNow(key, token, index) {
    var rowId = key + ':' + token, row;
    return transaction('readonly', function (metadata, payloads, done) {
      var request = metadata.get(rowId); request.onsuccess = function () { row = request.result; done(row); };
    }).then(function (value) {
      row = value;
      if (!validMetadata(row, rowId) || row.format !== 'batch' || !validNumber(index) || index >= row.partCount) {
        throw error('DataError', 'Catalog batch part is unavailable.');
      }
      return transaction('readonly', function (metadata, payloads, done) {
        var request = payloads.get(partId(row, index)); request.onsuccess = function () { done(request.result); };
      });
    }).then(function (sealed) {
      if (!sealed || !sealed.ciphertext || sealed.ciphertext.byteLength < 16 || sealed.ciphertext.byteLength > maximumPartBytes * 2 + 16) {
        throw error('DataError', 'Catalog batch part is incomplete.');
      }
      return secure.decrypt(sealed, batchDomain(row, index));
    }).then(function (raw) {
      if (typeof raw !== 'string' || measure(raw) > maximumPartBytes) throw error('DataError', 'Catalog batch part is invalid.');
      return raw;
    });
  }
  function measure(raw) {
    if (raw.length > maximumFileBytes) return maximumFileBytes + 1;
    var bytes = 0;
    for (var i = 0; i < raw.length; i++) {
      var code = raw.charCodeAt(i);
      if (code < 128) bytes++; else if (code < 2048) bytes += 2;
      else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < raw.length && raw.charCodeAt(i + 1) >= 0xDC00 && raw.charCodeAt(i + 1) <= 0xDFFF) { bytes += 4; i++; }
      else bytes += 3;
      if (bytes > maximumFileBytes) return bytes;
    }
    return bytes;
  }
  function exceedsFileLimit(raw) {
    if (raw.length > maximumFileBytes) return true;
    // UTF-8 needs at most three bytes per UTF-16 code unit; surrogate pairs
    // use four bytes for two code units. This accepts ordinary catalogs without
    // a full synchronous Blob conversion or JavaScript character scan.
    if (raw.length <= maximumGuaranteedUtf8Chars) return false;
    return measure(raw) > maximumFileBytes;
  }
  function writeNow(key, raw, kind) {
    return transaction('readonly', function (metadata, payloads, done) { entries(metadata, done); }).then(function (rows) {
      var same = rows.filter(function (row) { return row.key === key; }).sort(newest), timestamp = Math.max(0, Math.floor(Date.now())), counter = 0;
      if (same.length && timestamp <= same[0].timestamp) { timestamp = same[0].timestamp; counter = same[0].counter + 1; }
      if (!validNumber(timestamp) || !validNumber(counter)) throw error('RangeError', 'Catalog generation is outside the safe range.');
      var token = String(timestamp) + '-' + String(counter), next = { key: key, token: token, timestamp: timestamp, counter: counter, bytes: 0, kind: kind };
      return secure.encrypt(raw, 'catalog:' + id(next)).then(function (sealed) {
        var bytes = sealed && sealed.ciphertext && sealed.ciphertext.byteLength;
        if (!validNumber(bytes) || bytes < 16 || bytes > maximumStoreBytes) return false;
        next.bytes = bytes;
        return transaction('readwrite', function (metadata, payloads, done) {
          // Recompute the budget inside the write transaction, so another app
          // instance cannot race a quota calculation or lose a committed value.
          entries(metadata, function (current) {
            if (current.some(function (row) { return id(row) === id(next); })) { done(false); return; }
            var remove = [], kept = [], own = current.filter(function (row) { return row.key === key; }).sort(newest);
            current.forEach(function (row) {
              if (row.key === key && row !== own[0]) remove.push(row); else kept.push(row);
            });
            var total = kept.reduce(function (sum, row) { return sum + row.bytes; }, 0);
            // Guides are optional derived data: they may replace their own
            // generation but cannot evict a primary catalog to fit.
            var victims = kept.filter(function (row) { return row.key === key; });
            if (kind === 'catalog') {
              var oldest = function (a, b) { return newest(b, a); };
              victims = victims.concat(kept.filter(function (row) {
                return row.key !== key && kindOf(row) !== 'catalog';
              }).sort(oldest), kept.filter(function (row) {
                return row.key !== key && kindOf(row) === 'catalog';
              }).sort(oldest));
            }
            while ((total + bytes > maximumStoreBytes || kept.length + 1 > maximumEntries) && victims.length) {
              var victim = victims.shift(); remove.push(victim); kept.splice(kept.indexOf(victim), 1); total -= victim.bytes;
            }
            if (total + bytes > maximumStoreBytes || kept.length + 1 > maximumEntries) { done(false); return; }
            remove.forEach(function (row) { erase(metadata, payloads, row); });
            payloads.add(sealed, id(next)); metadata.add(next, id(next)); done(true);
          });
        });
      });
    });
  }
  function writeBatchNow(key, manifest, readPart) {
    return transaction('readonly', function (metadata, payloads, done) { entries(metadata, done); }).then(function (rows) {
      var same = rows.filter(function (row) { return row.key === key; }).sort(newest), timestamp = Math.max(0, Math.floor(Date.now())), counter = 0;
      if (same.length && timestamp <= same[0].timestamp) { timestamp = same[0].timestamp; counter = same[0].counter + 1; }
      if (!validNumber(timestamp) || !validNumber(counter)) throw error('RangeError', 'Catalog generation is outside the safe range.');
      var next = { key: key, token: String(timestamp) + '-' + String(counter), timestamp: timestamp,
        counter: counter, bytes: 0, kind: 'catalog', format: 'batch', partCount: manifest.parts.length };
      var encryptedParts = [], bytes = 0, position = 0, manifestSealed = null;
      function encryptNext() {
        if (position >= manifest.parts.length) return encryptManifest();
        var descriptor = manifest.parts[position], index = position++;
        return Promise.resolve().then(function () { return readPart(descriptor); }).then(function (value) {
          var raw = typeof value === 'string' ? value : value && value.raw;
          if (typeof raw !== 'string' || measure(raw) > maximumPartBytes) throw error('DataError', 'Catalog cache part is invalid or too large.');
          var checksum = value && typeof value === 'object' && value.checksum;
          if (typeof checksum !== 'string' || !/^[a-f0-9]{64}$/i.test(checksum)) throw error('DataError', 'Catalog cache part checksum is invalid.');
          descriptor.bytes = measure(raw);
          descriptor.checksum = checksum;
          return secure.encrypt(raw, batchDomain(next, index));
        }).then(function (part) {
          var size = part && part.ciphertext && part.ciphertext.byteLength;
          if (!validNumber(size) || size < 16 || size > maximumPartBytes * 2 + 16 || bytes + size > maximumStoreBytes) {
            throw error('QuotaExceededError', 'Catalog batch exceeds the encrypted cache limit.');
          }
          bytes += size; encryptedParts.push(part); return encryptNext();
        });
      }
      function encryptManifest() {
        var manifestRaw = JSON.stringify(manifest);
        if (typeof manifestRaw !== 'string' || measure(manifestRaw) > maximumPartBytes) throw error('DataError', 'Catalog batch manifest is too large.');
        return secure.encrypt(manifestRaw, batchDomain(next, null)).then(function (sealed) {
          var size = sealed && sealed.ciphertext && sealed.ciphertext.byteLength;
          if (!validNumber(size) || size < 16 || size > maximumPartBytes * 2 + 16 || bytes + size > maximumStoreBytes) {
            throw error('QuotaExceededError', 'Catalog batch exceeds the encrypted cache limit.');
          }
          manifestSealed = sealed; bytes += size; return commit();
        });
      }
      function commit() {
        next.bytes = bytes;
        return transaction('readwrite', function (metadata, payloads, done) {
          entries(metadata, function (current) {
            if (current.some(function (row) { return id(row) === id(next); })) { done(false); return; }
            var remove = [], kept = [], own = current.filter(function (row) { return row.key === key; }).sort(newest);
            current.forEach(function (row) {
              if (row.key === key && row !== own[0]) remove.push(row); else kept.push(row);
            });
            var total = kept.reduce(function (sum, row) { return sum + row.bytes; }, 0);
            var victims = kept.filter(function (row) { return row.key === key; });
            if (kindOf(next) === 'catalog') {
              var oldest = function (a, b) { return newest(b, a); };
              victims = victims.concat(kept.filter(function (row) {
                return row.key !== key && kindOf(row) !== 'catalog';
              }).sort(oldest), kept.filter(function (row) {
                return row.key !== key && kindOf(row) === 'catalog';
              }).sort(oldest));
            }
            while ((total + bytes > maximumStoreBytes || kept.length + 1 > maximumEntries) && victims.length) {
              var victim = victims.shift(); remove.push(victim); kept.splice(kept.indexOf(victim), 1); total -= victim.bytes;
            }
            if (total + bytes > maximumStoreBytes || kept.length + 1 > maximumEntries) { done(false); return; }
            remove.forEach(function (row) { erase(metadata, payloads, row); });
            payloads.add(manifestSealed, id(next));
            encryptedParts.forEach(function (part, index) { payloads.add(part, partId(next, index)); });
            metadata.add(next, id(next)); done(true);
          });
        });
      }
      return encryptNext();
    });
  }
  return {
    mark: function (key, kind) {
      try {
        validateKey(key);
        if (kind !== 'catalog' && kind !== 'guide' && kind !== 'metadata') throw error('TypeError', 'Catalog cache kind must be catalog, guide or metadata.');
      } catch (reason) { return Promise.reject(reason); }
      return serialize(function () { return markNow(key, kind); }).catch(function () { return false; });
    },
    read: function (key) {
      try { validateKey(key); } catch (reason) { return Promise.reject(reason); }
      return serialize(function () { return readNow(key); }).catch(function () { return null; });
    },
    write: function (key, raw, kind) {
      try { validateKey(key); } catch (reason) { return Promise.reject(reason); }
      kind = kind || 'catalog';
      if (kind !== 'catalog' && kind !== 'guide' && kind !== 'metadata') return Promise.reject(error('TypeError', 'Catalog cache kind must be catalog, guide or metadata.'));
      if (typeof raw !== 'string' || !raw.length || exceedsFileLimit(raw)) return Promise.resolve(false);
      return serialize(function () { return writeNow(key, raw, kind); }).catch(function () { return false; });
    },
    writeBatch: function (key, manifest, readPart) {
      var snapshot, raw;
      try {
        validateKey(key);
        if (typeof readPart !== 'function') throw error('TypeError', 'Catalog batch requires a part reader.');
        raw = JSON.stringify(manifest); snapshot = raw && JSON.parse(raw);
        if (!validManifest(snapshot) || measure(raw) > maximumPartBytes) throw error('TypeError', 'Catalog batch manifest is invalid or too large.');
      } catch (reason) { return Promise.reject(reason); }
      return serialize(function () { return writeBatchNow(key, snapshot, readPart); }).catch(function () { return false; });
    },
    readBatch: function (key) {
      try { validateKey(key); } catch (reason) { return Promise.reject(reason); }
      return serialize(function () { return readBatchNow(key); }).catch(function () { return null; });
    },
    readBatchPart: function (key, token, index) {
      try {
        validateKey(key);
        if (typeof token !== 'string' || !/^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$/.test(token) || !validNumber(index)) {
          throw error('TypeError', 'Catalog batch generation or index is invalid.');
        }
      } catch (reason) { return Promise.reject(reason); }
      return serialize(function () { return readBatchPartNow(key, token, index); });
    },
    discardBatch: function (key, token) {
      try {
        validateKey(key);
        if (typeof token !== 'string' || !/^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$/.test(token)) throw error('TypeError', 'Catalog batch generation token is invalid.');
      } catch (reason) { return Promise.reject(reason); }
      return serialize(function () {
        var rowId = key + ':' + token;
        return transaction('readonly', function (metadata, payloads, done) {
          var request = metadata.get(rowId); request.onsuccess = function () { done(request.result); };
        }).then(function (row) {
          if (!validMetadata(row, rowId) || row.format !== 'batch') return false;
          return removeRecord(row).then(function () { return true; });
        });
      }).catch(function () { return false; });
    },
    discard: function (key, token) {
      try {
        validateKey(key);
        if (typeof token !== 'string' || !/^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$/.test(token)) throw error('TypeError', 'Catalog generation token is invalid.');
      } catch (reason) { return Promise.reject(reason); }
      return serialize(function () { return removeRecord({ key: key, token: token }).then(function () { return true; }); }).catch(function () { return false; });
    },
    remove: function (key) {
      try { validateKey(key); } catch (reason) { return Promise.reject(reason); }
      return serialize(function () {
        return transaction('readwrite', function (metadata, payloads, done) {
          entries(metadata, function (rows) { rows.filter(function (row) { return row.key === key; }).forEach(function (row) { erase(metadata, payloads, row); }); done(true); });
        });
      }).catch(function () { return false; });
    }
  };
}));
