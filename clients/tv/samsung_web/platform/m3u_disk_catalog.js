(function (root) {
  'use strict';

  var databaseFlight, keyFlight;
  var crypto = root.crypto, subtle = crypto && (crypto.subtle || crypto.webkitSubtle);
  var kinds = ['live', 'movie', 'series', 'season', 'episode', 'category'];
  var encoder = typeof root.TextEncoder === 'function' && new root.TextEncoder();
  var decoder = typeof root.TextDecoder === 'function' && new root.TextDecoder();

  function error(name, message) {
    var value = new Error(message);
    value.name = name;
    return value;
  }

  function open() {
    if (databaseFlight) return databaseFlight;
    databaseFlight = new Promise(function (resolve, reject) {
      if (!root.indexedDB || !root.IDBKeyRange) {
        reject(error('NotSupportedError', 'This TV does not provide disk catalogue storage.'));
        return;
      }
      var request = root.indexedDB.open('tvbro_m3u_disk_v1', 1), blocked = false;
      request.onupgradeneeded = function () {
        var db = request.result;
        db.createObjectStore('metadata');
        var rows = db.createObjectStore('rows', { keyPath: ['generation', 'kind', 'id', 'parent'] });
        rows.createIndex('kind', ['generation', 'kind', 'order', 'id', 'parent', 'search', 'category']);
        rows.createIndex('group', ['generation', 'kind', 'group', 'order', 'id', 'parent', 'search', 'category']);
      };
      request.onerror = function () { reject(request.error); };
      request.onblocked = function () {
        blocked = true;
        reject(error('InvalidStateError', 'Disk catalogue storage is busy.'));
      };
      request.onsuccess = function () {
        var db = request.result;
        if (blocked) { db.close(); return; }
        db.onversionchange = function () { db.close(); databaseFlight = keyFlight = null; };
        resolve(db);
      };
    });
    databaseFlight.catch(function () { databaseFlight = null; });
    return databaseFlight;
  }

  function transaction(db, mode, operation, metadataOnly) {
    return new Promise(function (resolve, reject) {
      var tx = db.transaction(metadataOnly ? ['metadata'] : ['metadata', 'rows'], mode), result, failure;
      tx.oncomplete = function () { resolve(result); };
      tx.onabort = function () { reject(failure || tx.error || error('AbortError', 'Disk catalogue transaction was aborted.')); };
      function abort(cause) { failure = cause; tx.abort(); }
      function on(request, handle) {
        request.onsuccess = function () {
          try { handle(request.result); } catch (cause) { abort(cause); }
        };
      }
      try {
        operation(tx.objectStore('metadata'), metadataOnly ? null : tx.objectStore('rows'), on,
          function (value) { result = value; });
      } catch (cause) { abort(cause); }
    });
  }

  function range(prefix) { return root.IDBKeyRange.bound(prefix, prefix.concat([[]]), false, true); }
  function number(value) { return typeof value === 'number' && value >= 0 && value <= 9007199254740991 && Math.floor(value) === value; }
  function checkKind(kind) {
    if (kinds.indexOf(kind) < 0) throw error('TypeError', 'Invalid disk catalogue kind.');
  }

  function getKey(db) {
    if (keyFlight) return keyFlight;
    if (!subtle || typeof subtle.generateKey !== 'function' || typeof subtle.encrypt !== 'function' ||
        typeof subtle.decrypt !== 'function' || typeof crypto.getRandomValues !== 'function') return Promise.resolve(null);
    function get(store, rows, on, done) { on(store.get('key'), done); }
    keyFlight = transaction(db, 'readonly', get, true).then(function (saved) {
      if (saved) return saved;
      return subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']).then(function (key) {
        return transaction(db, 'readwrite', function (store, rows, on, done) {
          on(store.get('key'), function (existing) {
            if (!existing) store.add(key, 'key');
            done(existing || key);
          });
        }, true);
      });
    }).catch(function (failure) {
      if (failure && (failure.name === 'DataCloneError' || failure.name === 'NotSupportedError')) return null;
      keyFlight = null;
      throw failure;
    });
    return keyFlight;
  }

  function encryptionError() { return error('NotSupportedError', 'This TV does not provide encrypted disk catalogue storage.'); }
  function encode(raw, utf8) {
    if (utf8) return encoder.encode(raw);
    var bytes = new Uint8Array(raw.length * 2);
    for (var i = 0; i < raw.length; i++) {
      var unit = raw.charCodeAt(i);
      bytes[i * 2] = unit & 255;
      bytes[i * 2 + 1] = unit >>> 8;
    }
    return bytes;
  }
  function decode(buffer, utf8) {
    if (utf8) return decoder.decode(buffer);
    var bytes = new Uint8Array(buffer), units = [], parts = [];
    for (var i = 0; i < bytes.length; i += 2) {
      units.push(bytes[i] | bytes[i + 1] << 8);
      if (units.length === 4096) { parts.push(String.fromCharCode.apply(null, units)); units.length = 0; }
    }
    parts.push(String.fromCharCode.apply(null, units));
    return parts.join('');
  }
  function algorithm(iv, domain) { return { name: 'AES-GCM', iv: iv, additionalData: encode(JSON.stringify(domain), false) }; }
  function seal(value, domain, key) {
    if (!key) return Promise.resolve({ plain: value });
    var iv = new Uint8Array(12), utf8 = !!(encoder && decoder);
    crypto.getRandomValues(iv);
    return subtle.encrypt(algorithm(iv, domain), key, encode(JSON.stringify(value), utf8)).then(function (ciphertext) {
      return { iv: iv, ciphertext: ciphertext, utf8: utf8 };
    });
  }

  root.TVBroM3uDiskCreate = function (owner, options) {
    if (typeof owner !== 'string' || !owner) throw error('TypeError', 'Disk catalogue owner is required.');
    var ownerKey = ['owner', owner], required = options && options.requireEncryption === true;

    function keyFor(db) {
      return getKey(db).then(function (key) {
        if (required && !key) throw encryptionError();
        return key;
      });
    }
    function reveal(value, domain, db) {
      if (!value.iv) {
        if (required) throw encryptionError();
        return Promise.resolve(value.plain);
      }
      return keyFor(db).then(function (key) {
        if (!key || (value.utf8 && !decoder)) throw encryptionError();
        return subtle.decrypt(algorithm(value.iv, domain), key, value.ciphertext).then(function (buffer) {
          return JSON.parse(decode(buffer, value.utf8));
        });
      });
    }

    function withOwner(db, mode, handle, metadataOnly) {
      return transaction(db, mode, function (metadata, rows, on, done) {
        on(metadata.get(ownerKey), function (state) { handle(state || {}, metadata, rows, on, done); });
      }, metadataOnly);
    }
    function draftId(args) { return Number(args.draft); }
    function requireDraft(state, generation) {
      if (!generation || state.draft !== generation) throw error('InvalidStateError', 'Disk catalogue import is no longer active.');
    }
    function deleteRows(rows, generation) { if (generation) rows.delete(range([generation])); }
    function stateInfo(db, active) {
      if (!active) return null;
      return reveal(active.header, [active.generation, 'header'], db).then(function (header) {
        return { syncedAt: active.syncedAt, counts: active.counts, header: header };
      });
    }
    function rowKey(row) { return [row.generation, row.kind, row.id, row.parent]; }
    function wrap(row, generation, key) {
      checkKind(row.kind);
      if (typeof row.id !== 'string' || !row.id || !number(row.order) ||
          (row.parentId != null && typeof row.parentId !== 'string') ||
          (row.categoryId != null && typeof row.categoryId !== 'string')) {
        throw error('TypeError', 'Invalid disk catalogue row.');
      }
      var parent = row.parentId || '', category = row.categoryId || '';
      var record = { generation: generation, kind: row.kind, id: row.id, parent: parent,
        order: row.order, search: String(row.title || row.name || '').toLowerCase(), category: category };
      if (parent) record.group = 'p:' + parent;
      else if (category) record.group = 'c:' + category;
      delete row.kind; delete row.id; delete row.order; delete row.parentId; delete row.categoryId;
      return seal(row, rowKey(record), key).then(function (payload) { record.payload = payload; return record; });
    }
    function unwrap(row, db) {
      if (!row) return Promise.resolve(null);
      return reveal(row.payload, rowKey(row), db).then(function (value) {
        value.id = row.id; value.kind = row.kind; value.order = row.order;
        if (row.parent) value.parentId = row.parent;
        if (row.category) value.categoryId = row.category;
        return value;
      });
    }

    function recordFor(rows, generation, args, id, on, done) {
      var key = [generation, args.kind, id];
      if (args.parentId != null || kinds.indexOf(args.kind) < 3) on(rows.get(key.concat(args.parentId || '')), done);
      else on(rows.openCursor(range(key)), function (cursor) { done(cursor && cursor.value); });
    }
    function page(rows, generation, args, on, done) {
      var offset = number(args.offset) ? args.offset : 0;
      var limit = number(args.limit) ? Math.min(args.limit, 512) : 100;
      var result = { items: [], count: 0, hasMore: false };
      if (!generation) { done(result); return; }
      var query = typeof args.query === 'string' ? args.query.trim().toLowerCase() : '';
      var matchCategory = args.parentId != null && args.categoryId != null;
      var scan = query || matchCategory, seen = 0;
      function take(record) {
        if (seen++ < offset) return true;
        if (result.items.length < limit) { result.items.push(record); return true; }
        result.hasMore = true;
        return false;
      }
      done(result);
      if (Array.isArray(args.ids)) {
        var next = 0;
        function readNext() {
          if (next === args.ids.length) { result.count = seen; return; }
          recordFor(rows, generation, args, args.ids[next++], on, function (row) {
            if (!row || (args.categoryId != null && row.category !== args.categoryId) ||
                (query && row.search.indexOf(query) < 0) || take(row)) readNext();
            else result.count = null;
          });
        }
        readNext();
        return;
      }
      var prefix = [generation, args.kind];
      if (args.parentId != null) prefix.push('p:' + args.parentId);
      else if (args.categoryId != null) prefix.push('c:' + args.categoryId);
      var index = rows.index(prefix.length === 2 ? 'kind' : 'group'), bounds = range(prefix);
      if (!scan) {
        on(index.count(bounds), function (count) { result.count = count; result.hasMore = count - offset > limit; });
        if (!limit) return;
      }
      var request = index.openKeyCursor(bounds);
      on(request, function (cursor) {
        if (!cursor) { if (scan) result.count = seen; return; }
        if (!scan && !seen && offset) {
          if (offset > 4294967295) return;
          seen = offset; cursor.advance(offset); return;
        }
        var key = cursor.key;
        if (scan) {
          if ((query && key[key.length - 2].indexOf(query) < 0) ||
              (matchCategory && key[key.length - 1] !== args.categoryId) || seen++ < offset) {
            cursor.continue(); return;
          }
          if (result.items.length === limit) {
            result.hasMore = true;
            if (query) result.count = null;
            else cursor.continue();
            return;
          }
        }
        on(rows.get(cursor.primaryKey), function (row) {
          result.items.push(row);
          if (scan || result.items.length < limit) cursor.continue();
        });
      });
    }

    var methods = {
      state: function (db) {
        return withOwner(db, 'readonly', function (state, metadata, rows, on, done) { done(state.active); }, true)
          .then(function (active) { return stateInfo(db, active); });
      },
      begin: function (db) {
        return keyFor(db).then(function () {
          return withOwner(db, 'readwrite', function (state, metadata, rows, on, done) {
            deleteRows(rows, state.draft); deleteRows(rows, state.retired);
            delete state.retired;
            on(metadata.get('generation'), function (generation) {
              state.draft = (generation || 0) + 1;
              metadata.put(state.draft, 'generation');
              metadata.put(state, ownerKey);
              done(String(state.draft));
            });
          });
        });
      },
      add: function (db, args) {
        var generation = draftId(args), rows = args.rows;
        if (!Array.isArray(rows)) throw error('TypeError', 'Disk catalogue rows must be an array.');
        return keyFor(db).then(function (key) {
          return Promise.all(rows.map(function (row) { return wrap(row, generation, key); }));
        }).then(function (entries) {
          return withOwner(db, 'readwrite', function (state, metadata, data) {
            requireDraft(state, generation);
            entries.forEach(function (entry) {
              if (entry.kind === 'live') { data.put(entry); return; }
              var request = data.add(entry);
              request.onerror = function (event) {
                if (request.error && request.error.name === 'ConstraintError') { event.preventDefault(); event.stopPropagation(); }
              };
            });
          });
        });
      },
      commit: function (db, args) {
        var generation = draftId(args), header = args.header || {};
        return keyFor(db).then(function (key) { return seal(header, [generation, 'header'], key); }).then(function (sealed) {
          return withOwner(db, 'readwrite', function (state, metadata, rows, on, done) {
            requireDraft(state, generation);
            var active = { generation: generation, syncedAt: Date.now(), counts: {}, header: sealed }, pending = 3;
            kinds.slice(0, 3).forEach(function (kind) {
              on(rows.index('kind').count(range([generation, kind])), function (count) {
                active.counts[kind] = count;
                if (--pending) return;
                if (state.active) state.retired = state.active.generation;
                state.active = active;
                delete state.draft;
                metadata.put(state, ownerKey);
                done({ result: { syncedAt: active.syncedAt, counts: active.counts, header: header }, retired: state.retired });
              });
            });
          });
        }).then(function (committed) {
          if (committed.retired) withOwner(db, 'readwrite', function (state, metadata, rows) {
            if (state.retired !== committed.retired) return;
            deleteRows(rows, state.retired);
            delete state.retired;
            metadata.put(state, ownerKey);
          }).catch(function () { /* The next import or removal retries cleanup. */ });
          return committed.result;
        });
      },
      abort: function (db, args) {
        return withOwner(db, 'readwrite', function (state, metadata, rows) {
          if (!state.draft || state.draft !== draftId(args)) return;
          deleteRows(rows, state.draft);
          delete state.draft;
          metadata.put(state, ownerKey);
        });
      },
      remove: function (db) {
        return withOwner(db, 'readwrite', function (state, metadata, rows) {
          deleteRows(rows, state.draft); deleteRows(rows, state.retired);
          if (state.active) deleteRows(rows, state.active.generation);
          metadata.delete(ownerKey);
        });
      },
      read: function (db, args) {
        checkKind(args.kind);
        return withOwner(db, 'readonly', function (state, metadata, rows, on, done) {
          page(rows, state.active && state.active.generation, args, on, done);
        }).then(function (result) {
          return Promise.all(result.items.map(function (row) { return unwrap(row, db); })).then(function (items) {
            result.items = items;
            return result;
          });
        });
      },
      get: function (db, args) {
        checkKind(args.kind);
        return withOwner(db, 'readonly', function (state, metadata, rows, on, done) {
          if (state.active) recordFor(rows, state.active.generation, args, args.id, on, done);
        }).then(function (row) { return unwrap(row, db); });
      }
    };

    return function (method, encoded) {
      return Promise.resolve().then(function () {
        if (!Object.prototype.hasOwnProperty.call(methods, method)) throw error('NotSupportedError', 'Unknown disk catalogue operation.');
        var args;
        try { args = encoded ? JSON.parse(encoded) : {}; }
        catch (_) { throw error('TypeError', 'Invalid disk catalogue arguments.'); }
        return open().then(function (db) { return methods[method](db, args); });
      }).then(function (result) {
        return JSON.stringify(result === undefined ? null : result);
      }, function (failure) {
        if (failure && failure.name === 'QuotaExceededError') return '{"__tvbroM3uDiskError":"storage_full"}';
        throw failure;
      });
    };
  };
}(typeof self !== 'undefined' ? self : this));
