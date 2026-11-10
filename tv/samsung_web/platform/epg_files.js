(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroSamsungEpgFiles = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';

  var environment = options && options.environment || (typeof window !== 'undefined' ? window : null);
  var directoryName = 'tvbro_epg_v1', directoryPath = 'wgt-private/' + directoryName;
  var maximumFileBytes = 512 * 1024 * 1024, maximumCacheBytes = 768 * 1024 * 1024;
  var maximumEntries = 8, maximumRead = 65536, maximumMarkerBytes = 192;
  var maximumSafeInteger = 9007199254740991, generation = 0, sequence = 0, timestamp = 0;
  var records = Object.create(null), downloads = [], streams = [], waiting = [], directoryFlight = null;
  var tail = Promise.resolve(), tokenPattern = /^epg_(0|[1-9][0-9]*)_(0|[1-9][0-9]*)\.bin$/;

  function error(name) {
    var messages = { TypeError: 'Invalid guide file request.', NotSupportedError: 'Native guide storage is unavailable.',
      NotFoundError: 'Guide file is unavailable.', IOError: 'Guide storage operation failed.',
      NetworkError: 'Guide download failed.', TimeoutError: 'Guide download timed out.',
      AbortError: 'Guide operation was cancelled.', QuotaExceededError: 'Guide exceeds its storage limit.' };
    var value = new Error(messages[name] || messages.IOError);
    value.name = name; value.epgSafe = true; return value;
  }

  function safeError(value) { return value && value.epgSafe ? value : error('IOError'); }
  function integer(value) {
    return typeof value === 'number' && isFinite(value) && value >= 0 &&
      value <= maximumSafeInteger && Math.floor(value) === value;
  }
  function now() { return (environment && environment.Date || Date).now(); }
  function schedule(callback, delay) { return (environment && environment.setTimeout || setTimeout)(callback, delay); }
  function unschedule(timer) { (environment && environment.clearTimeout || clearTimeout)(timer); }
  function check(expected) { if (expected !== generation) throw error('AbortError'); }
  function keyIsValid(key) { return typeof key === 'string' && /^[0-9a-f]{64}$/.test(key); }
  function tokenParts(token) {
    var parts = typeof token === 'string' && tokenPattern.exec(token);
    if (!parts || !integer(Number(parts[1])) || !integer(Number(parts[2]))) return null;
    return { at: Number(parts[1]), counter: Number(parts[2]) };
  }
  function metadata(record) { return { token: record.token, size: record.size, at: record.at }; }
  function serialize(operation) {
    var result = tail.then(operation);
    tail = result.then(function () {}, function () {}); return result;
  }

  function available() {
    var tizen = environment && environment.tizen;
    if (!tizen || !tizen.filesystem || typeof tizen.filesystem.resolve !== 'function' ||
        typeof tizen.DownloadRequest !== 'function' || !tizen.download ||
        typeof tizen.download.start !== 'function' || typeof tizen.download.cancel !== 'function') return false;
    try {
      if (tizen.systeminfo && typeof tizen.systeminfo.getCapability === 'function' &&
          tizen.systeminfo.getCapability('http://tizen.org/feature/download') === false) return false;
    } catch (_) {}
    return true;
  }

  function close(stream) {
    var index = streams.indexOf(stream); if (index >= 0) streams.splice(index, 1);
    try { stream.close(); } catch (_) {}
  }
  function nativeCall(expected, operation, late) {
    return new Promise(function (resolve, reject) {
      var done = false;
      function finish(failure, value) {
        if (done) { if (!failure && late) late(value); return; }
        done = true;
        var index = waiting.indexOf(cancel); if (index >= 0) waiting.splice(index, 1);
        if (failure) reject(safeError(failure));
        else if (expected !== generation) { if (late) late(value); reject(error('AbortError')); }
        else resolve(value);
      }
      function cancel() { finish(error('AbortError')); }
      waiting.push(cancel);
      try {
        operation(function (value) { finish(null, value); }, function () { finish(error('IOError')); });
      } catch (_) { finish(error('IOError')); }
    });
  }
  function withStream(file, mode, expected, operation) {
    return nativeCall(expected, function (resolve, reject) {
      file.openStream(mode, resolve, reject, 'UTF-8');
    }, close).then(function (stream) {
      streams.push(stream);
      try {
        check(expected);
        if (typeof stream.close !== 'function') throw error('NotSupportedError');
        var result = operation(stream);
        stream.close(); streams.splice(streams.indexOf(stream), 1); return result;
      } catch (failure) { close(stream); throw safeError(failure); }
    });
  }
  function sizeOf(file) {
    var size = file && file.fileSize;
    if (!file || file.isDirectory === true || !integer(size)) throw error('IOError');
    return size;
  }
  function resolveFile(directory, token) {
    var file;
    try { file = directory.resolve(token); } catch (_) { throw error('NotFoundError'); }
    if (!file || file.name !== token || file.isDirectory === true) throw error('NotFoundError');
    return file;
  }
  function list(directory) {
    return nativeCall(generation, function (resolve, reject) {
      directory.listFiles(resolve, reject);
    });
  }
  function removeNames(directory, names) {
    var work = Promise.resolve(true);
    names.forEach(function (name) {
      work = work.then(function (success) {
        return new Promise(function (resolve) {
          try { directory.deleteFile(directoryPath + '/' + name,
            function () { resolve(success); }, function (failure) {
              resolve(success && failure && (failure.name === 'NotFoundError' || failure.errorType === 'NotFoundError'));
            }); } catch (failure) { resolve(false); }
        });
      });
    });
    return work;
  }
  function removeRecord(directory, record) {
    return removeNames(directory, [record.token, record.token + '.ok', record.token + '.tmp']).then(function (success) {
      delete records[record.token]; return success;
    });
  }
  function order(left, right) {
    if (left.at !== right.at) return right.at - left.at;
    var a = tokenParts(left.token), b = tokenParts(right.token);
    return b.at - a.at || b.counter - a.counter;
  }
  function prune(directory, keep) {
    var seen = Object.create(null), bytes = 0, count = 0, chain = Promise.resolve();
    Object.keys(records).map(function (token) { return records[token]; }).filter(function (record) {
      return record.committed;
    }).sort(function (left, right) {
      if (left.token === keep) return -1; if (right.token === keep) return 1; return order(left, right);
    }).forEach(function (record) {
      if (record.leases > 0 || !seen[record.key] && count < maximumEntries && bytes + record.size <= maximumCacheBytes) {
        seen[record.key] = true; bytes += record.size; count += 1; return;
      }
      chain = chain.then(function () { return removeRecord(directory, record); });
    });
    return chain;
  }
  function readMarker(file, expected) {
    var size = sizeOf(file);
    if (size < 1 || size > maximumMarkerBytes) return Promise.resolve(null);
    return withStream(file, 'r', expected, function (stream) {
      var bytes = stream.readBytes(size);
      if (!bytes || bytes.length !== size) return null;
      var raw = String.fromCharCode.apply(null, bytes), value;
      try { value = JSON.parse(raw); } catch (_) { return null; }
      if (!value || Object.keys(value).length !== 3 || !keyIsValid(value.key) ||
          !integer(value.at) || !integer(value.size) || value.size > maximumFileBytes) return null;
      return value;
    });
  }
  function initialize(directory, expected) {
    return list(directory).then(function (files) {
      var names = Object.create(null), work = Promise.resolve(), remove = [];
      files.forEach(function (file) {
        if (!file || file.isDirectory || typeof file.name !== 'string') return;
        names[file.name] = file;
        var parts = tokenParts(file.name);
        if (parts && (parts.at > timestamp || parts.at === timestamp && parts.counter >= sequence)) {
          timestamp = parts.at; sequence = parts.counter + 1;
        }
      });
      Object.keys(names).forEach(function (name) {
        if (!tokenParts(name)) {
          if (tokenParts(name.slice(0, -4)) && name.slice(-4) === '.tmp' ||
              tokenParts(name.slice(0, -3)) && name.slice(-3) === '.ok' && !names[name.slice(0, -3)]) remove.push(name);
          return;
        }
        work = work.then(function () {
          if (!names[name + '.ok']) { remove.push(name); return; }
          return readMarker(names[name + '.ok'], expected).then(function (value) {
            if (!value || sizeOf(names[name]) !== value.size) { remove.push(name, name + '.ok'); return; }
            records[name] = { token: name, key: value.key, size: value.size, at: value.at, committed: true, leases: 0 };
          }, function (failure) {
            if (failure.name === 'AbortError') throw failure;
            remove.push(name, name + '.ok');
          });
        });
      });
      return work.then(function () { check(expected); return removeNames(directory, remove); })
        .then(function () { return prune(directory); });
    });
  }
  function getDirectory() {
    if (directoryFlight) return directoryFlight;
    if (!available()) return Promise.reject(error('NotSupportedError'));
    var expected = generation;
    directoryFlight = nativeCall(expected, function (resolve, reject) {
      environment.tizen.filesystem.resolve('wgt-private', resolve, reject, 'rw');
    }).then(function (root) {
      check(expected);
      var directory;
      try { directory = root.resolve(directoryName); }
      catch (failure) {
        if (!failure || failure.name !== 'NotFoundError' && failure.errorType !== 'NotFoundError') throw error('IOError');
        root.createDirectory(directoryName); directory = root.resolve(directoryName);
      }
      if (!directory || directory.isDirectory !== true) throw error('IOError');
      return initialize(directory, expected).then(function () { return directory; });
    }).catch(function (failure) { directoryFlight = null; throw safeError(failure); });
    return directoryFlight;
  }
  function nextToken() {
    var current = Math.floor(now());
    if (!integer(current)) throw error('IOError');
    if (current > timestamp) { timestamp = current; sequence = 0; }
    if (!integer(sequence)) throw error('IOError');
    return 'epg_' + timestamp + '_' + sequence++ + '.bin';
  }

  function download(request, entry, key) {
    request = request || {}; entry = entry || {};
    var limit = request.maximumBodyBytes === undefined ? maximumFileBytes : request.maximumBodyBytes;
    var total = request.totalTimeoutMs === undefined ? 60000 : request.totalTimeoutMs;
    var idle = request.idleTimeoutMs === undefined ? 20000 : request.idleTimeoutMs;
    if (!keyIsValid(key) || typeof request.url !== 'string' || !/^https?:\/\//i.test(request.url) ||
        !integer(limit) || limit < 1 || !integer(total) || total < 1 || !integer(idle) || idle < 1) {
      return Promise.reject(error('TypeError'));
    }
    if (!available()) return Promise.reject(error('NotSupportedError'));
    limit = Math.min(limit, maximumFileBytes);
    var expected = generation, deadline = now() + total;
    var job = { done: false, id: null, record: null, directory: null, completing: false };
    var totalTimer, idleTimer, resolveResult, rejectResult, received = 0;
    var promise = new Promise(function (resolve, reject) { resolveResult = resolve; rejectResult = reject; });
    downloads.push(job);
    function detach() {
      unschedule(totalTimer); unschedule(idleTimer);
      var index = downloads.indexOf(job); if (index >= 0) downloads.splice(index, 1);
      if (entry.cancelNative === cancel) entry.cancelNative = null;
    }
    function cleanup() {
      return serialize(function () {
        if (!job.record || !job.directory || job.record.committed) return;
        return removeRecord(job.directory, job.record);
      });
    }
    function fail(failure, cancelNative) {
      if (job.done) return;
      job.done = true; detach();
      if (cancelNative && job.id !== null && job.id >= 0) {
        try { environment.tizen.download.cancel(job.id); } catch (_) {}
      }
      cleanup().then(function () {}, function () {});
      rejectResult(safeError(failure));
    }
    function cancel() { fail(error('AbortError'), true); }
    job.cancel = cancel; entry.cancelNative = cancel;
    function current() {
      check(expected);
      if (entry.done) throw error('AbortError');
      if (now() >= deadline) throw error('TimeoutError');
    }
    function resetIdle() {
      unschedule(idleTimer); idleTimer = schedule(function () { fail(error('TimeoutError'), true); }, idle);
    }
    totalTimer = schedule(function () { fail(error('TimeoutError'), true); }, total);
    serialize(function () {
      if (job.done) return;
      return getDirectory().then(function (directory) {
        if (job.done) return;
        current();
        if (Object.keys(records).filter(function (token) { return !records[token].committed; }).length >= maximumEntries) {
          throw error('QuotaExceededError');
        }
        job.directory = directory;
        job.record = { token: nextToken(), key: key, size: null, at: now(), committed: false, leases: 1 };
        records[job.record.token] = job.record;
        var callbacks = {
          onprogress: function (id, loaded, advertised) {
            if (job.done) return;
            try {
              current();
              if (!integer(loaded)) throw error('NetworkError');
              if (loaded > limit || typeof advertised === 'number' && advertised > limit) throw error('QuotaExceededError');
              if (loaded > received) { received = loaded; resetIdle(); }
            } catch (failure) { fail(failure, true); }
          },
          onpaused: function () {},
          oncanceled: cancel,
          onfailed: function (id, failure) {
            var value = error('NetworkError');
            var match = failure && typeof failure.message === 'string' &&
              /\bHTTP(?:\/\d+(?:\.\d+)?)?\s*(?:status\s*)?[:=]?\s*(401|403|429)\b/i.exec(
                failure.message.replace(/https?:\/\/\S+/gi, ''));
            if (match) value.status = Number(match[1]);
            fail(value, false);
          },
          oncompleted: function () {
            // SDK paths are untrusted: reopen only our requested filename in our directory.
            if (job.done) { if (job.record && !job.record.committed) cleanup(); return; }
            if (job.completing) return;
            job.completing = true;
            serialize(function () {
              if (job.done) return;
              current();
              var size = sizeOf(resolveFile(directory, job.record.token));
              if (size > limit) throw error('QuotaExceededError');
              job.record.size = size; job.record.at = now();
              job.done = true; detach(); resolveResult(metadata(job.record));
            }).catch(function (failure) { fail(failure, true); });
          }
        };
        resetIdle();
        var nativeRequest = new environment.tizen.DownloadRequest(request.url, directoryPath,
          job.record.token, 'ALL', request.headers || {});
        try { job.id = environment.tizen.download.start(nativeRequest, callbacks); }
        catch (_) { throw error('NetworkError'); }
        if (!integer(job.id)) throw error('NetworkError');
        if (job.done) { try { environment.tizen.download.cancel(job.id); } catch (_) {} }
      });
    }).catch(function (failure) { fail(failure, true); });
    return promise;
  }

  function commit(directory, record, expected) {
    if (record.committed) return Promise.resolve(metadata(record));
    var token = record.token, raw = JSON.stringify({ key: record.key, at: record.at, size: record.size });
    if (sizeOf(resolveFile(directory, token)) !== record.size) return Promise.reject(error('IOError'));
    var file = directory.createFile(token + '.tmp');
    return withStream(file, 'w', expected, function (stream) {
      var bytes = [], index;
      for (index = 0; index < raw.length; index += 1) bytes.push(raw.charCodeAt(index));
      stream.writeBytes(bytes);
    }).then(function () {
      check(expected);
      return nativeCall(expected, function (resolve, reject) {
        directory.moveTo(directoryPath + '/' + token + '.tmp', directoryPath + '/' + token + '.ok', false, resolve, reject);
      }, function () { if (!record.committed) removeRecord(directory, record); });
    }).then(function () {
      check(expected); record.committed = true;
      return prune(directory, token).then(function () { return metadata(record); });
    }).catch(function (failure) {
      return removeRecord(directory, record).then(function () { throw safeError(failure); });
    });
  }

  function query(args) {
    args = args || {};
    var action = args.action, expected = generation;
    if (action === 'lookup' ? !keyIsValid(args.key) :
        ['read', 'commit', 'discard', 'release'].indexOf(action) < 0 || !tokenParts(args.token) ||
        args.key !== undefined && !keyIsValid(args.key)) return Promise.reject(error('TypeError'));
    if (action === 'read' && (!integer(args.offset) || !integer(args.count) || args.count < 1 || args.count > maximumRead)) {
      return Promise.reject(error('TypeError'));
    }
    return serialize(function () {
      check(expected);
      return getDirectory().then(function (directory) {
        check(expected);
        if (action === 'lookup') {
          var candidates = Object.keys(records).map(function (token) { return records[token]; }).filter(function (record) {
            return record.key === args.key && record.committed;
          }).sort(order);
          if (!candidates.length) return null;
          var found = candidates[0];
          try { if (sizeOf(resolveFile(directory, found.token)) !== found.size) return null; }
          catch (_) { return null; }
          found.leases += 1;
          return metadata(found);
        }
        var record = records[args.token];
        if (!record || record.size === null) throw error('NotFoundError');
        if (args.key !== undefined && record.key !== args.key) throw error('TypeError');
        if (action === 'discard') return record.committed ? false : removeRecord(directory, record);
        if (action === 'release') {
          record.leases = Math.max(0, record.leases - 1);
          return prune(directory).then(function () { return true; });
        }
        if (action === 'commit') return commit(directory, record, expected);
        var file = resolveFile(directory, record.token);
        if (sizeOf(file) !== record.size || args.offset > record.size) throw error('IOError');
        var count = Math.min(args.count, record.size - args.offset);
        if (!count) return { bodyBuffer: new ArrayBuffer(0), eof: true };
        return withStream(file, 'r', expected, function (stream) {
          stream.position = args.offset;
          var bytes = stream.readBytes(count);
          if (!bytes || bytes.length !== count) throw error('IOError');
          return { bodyBuffer: new Uint8Array(bytes).buffer, eof: args.offset + bytes.length === record.size };
        });
      });
    }).catch(function (failure) { throw safeError(failure); });
  }

  function abort() {
    generation += 1;
    streams.slice().forEach(close);
    waiting.slice().forEach(function (cancel) { cancel(); });
    downloads.slice().forEach(function (job) { job.cancel(); });
    return serialize(function () {
      if (!directoryFlight) return;
      return directoryFlight.then(function (directory) {
        var chain = Promise.resolve();
        Object.keys(records).forEach(function (token) {
          var record = records[token];
          record.leases = 0;
          if (!record.committed) chain = chain.then(function () { return removeRecord(directory, record); });
        });
        return chain.then(function () { return prune(directory); });
      }, function () {});
    });
  }

  return { available: available, download: download, query: query, abort: abort };
}));
