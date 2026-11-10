'use strict';

var fs = require('fs');
var path = require('path');
var http = require('http');
var https = require('https');
var url = require('url');

var DEFAULT_DIRECTORY = '/media/internal/online.tvbro.webos.epg';
var MAX_FILE_BYTES = 512 * 1024 * 1024;
var MAX_CACHE_BYTES = 768 * 1024 * 1024;
var MAX_ENTRIES = 8;
var MAX_READ_BYTES = 65536;
var MAX_REDIRECTS = 5;
// shortcut: unfinished guide parses expire after one day; raise if a TV can resume one later.
var MAX_PENDING_AGE_MS = 24 * 60 * 60 * 1000;
// shortcut: abandoned readers retain files for one day; raise if a TV can keep a parse live longer.
var MAX_LEASE_AGE_MS = 24 * 60 * 60 * 1000;
var MAX_SAFE_INTEGER = 9007199254740991;
var TOKEN_PATTERN = /^epg_(0|[1-9][0-9]*)_(0|[1-9][0-9]*)\.bin$/;
var RETRY_AFTER_DATE = /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-9]{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$/;

function create(options) {
  options = options || {};
  var directory = options.directory || DEFAULT_DIRECTORY;
  var records = Object.create(null);
  var jobs = Object.create(null);
  var initFlight = null;
  var queue = Promise.resolve();
  var sequence = 0;
  var lastTimestamp = 0;

  function now() { return typeof options.now === 'function' ? options.now() : Date.now(); }
  function makeError(kind, status, retryAfter) {
    var names = {invalid:'TypeError', unsupported:'NotSupportedError', missing:'NotFoundError',
      storage:'IOError', network:'NetworkError', timeout:'TimeoutError', cancelled:'AbortError', limit:'QuotaExceededError'};
    var messages = {invalid:'Invalid guide file request.', unsupported:'Guide storage is unavailable.',
      missing:'Guide file is unavailable.', storage:'Guide storage operation failed.',
      network:'Guide download failed.', timeout:'Guide download timed out.',
      cancelled:'Guide operation was cancelled.', limit:'Guide exceeds its storage limit.'};
    var error = new Error(messages[kind] || messages.storage);
    error.name = names[kind] || names.storage;
    error.kind = kind;
    if (typeof status === 'number' && status >= 100 && status <= 599) error.status = status;
    if (typeof retryAfter === 'string') error.retryAfter = retryAfter;
    return error;
  }
  function safeError(error) {
    if (error && error.kind) return error;
    if (error && (error.code === 'ENOSPC' || error.code === 'EDQUOT' || error.code === 'EFBIG')) return makeError('limit');
    return makeError('storage');
  }
  function integer(value) {
    return typeof value === 'number' && isFinite(value) && value >= 0 &&
      value <= MAX_SAFE_INTEGER && Math.floor(value) === value;
  }
  function keyValid(key) { return typeof key === 'string' && /^[a-f0-9]{64}$/.test(key); }
  function tokenValid(token) { return typeof token === 'string' && TOKEN_PATTERN.test(token); }
  function tokenOrder(left, right) {
    if (left.at !== right.at) return right.at - left.at;
    var leftParts = TOKEN_PATTERN.exec(left.token), rightParts = TOKEN_PATTERN.exec(right.token);
    return Number(rightParts[2]) - Number(leftParts[2]);
  }
  function metadata(record) { return {token:record.token, size:record.size, at:record.at}; }
  function enqueue(operation) {
    var result = queue.then(operation);
    queue = result.then(function () {}, function () {});
    return result;
  }
  function unlink(file) {
    return new Promise(function (resolve, reject) {
      fs.unlink(file, function (error) {
        if (!error || error.code === 'ENOENT') resolve();
        else reject(safeError(error));
      });
    });
  }
  function unlinkNames(names) {
    var work = Promise.resolve();
    names.forEach(function (name) {
      work = work.then(function () { return unlink(path.join(directory, name)); });
    });
    return work;
  }
  function recordFiles(token) {
    return [token + '.part', token, token + '.pending', token + '.ok', token + '.lease',
      token + '.pending.tmp', token + '.ok.tmp', token + '.lease.tmp'];
  }
  function removeRecord(record) {
    return unlinkNames(recordFiles(record.token)).then(function () { delete records[record.token]; });
  }
  function ensureDirectory() {
    return new Promise(function (resolve, reject) {
      fs.mkdir(directory, function (error) {
        if (error && error.code !== 'EEXIST') { reject(safeError(error)); return; }
        fs.stat(directory, function (statError, stat) {
          if (statError || !stat || !stat.isDirectory()) { reject(makeError('storage')); return; }
          resolve();
        });
      });
    });
  }
  function readSmall(file, maximum) {
    return new Promise(function (resolve, reject) {
      fs.stat(file, function (statError, stat) {
        if (statError || !stat || stat.size < 1 || stat.size > maximum) { resolve(null); return; }
        fs.readFile(file, 'utf8', function (readError, value) {
          if (readError) { resolve(null); return; }
          resolve(value);
        });
      });
    });
  }
  function parseMetadata(raw) {
    var value;
    try { value = JSON.parse(raw); } catch (_) { return null; }
    if (!value || typeof value !== 'object' || Array.isArray(value) ||
        Object.keys(value).length !== 3 || !keyValid(value.key) || !integer(value.at) ||
        !integer(value.size) || value.size > MAX_FILE_BYTES) return null;
    return {key:value.key, at:value.at, size:value.size};
  }
  function parseLease(raw) {
    var value;
    try { value = JSON.parse(raw); } catch (_) { return null; }
    if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== 2 ||
        !integer(value.count) || value.count < 1 || value.count > MAX_ENTRIES || !integer(value.until)) return null;
    return {count:value.count, until:value.until};
  }
  function markerWrite(token, suffix, value) {
    var temporary = token + '.' + suffix + '.tmp';
    var target = token + '.' + suffix;
    var raw = JSON.stringify(value);
    if (raw.length > 192) return Promise.reject(makeError('storage'));
    return new Promise(function (resolve, reject) {
      fs.writeFile(path.join(directory, temporary), raw, 'utf8', function (writeError) {
        if (writeError) { reject(safeError(writeError)); return; }
        fs.rename(path.join(directory, temporary), path.join(directory, target), function (renameError) {
          if (renameError) { reject(safeError(renameError)); return; }
          resolve();
        });
      });
    });
  }
  function markerRemove(token, suffix) { return unlink(path.join(directory, token + '.' + suffix)); }
  function statSize(token) {
    return new Promise(function (resolve, reject) {
      fs.stat(path.join(directory, token), function (error, stat) {
        if (error || !stat || !stat.isFile() || !integer(stat.size)) { reject(makeError('missing')); return; }
        resolve(stat.size);
      });
    });
  }
  function applyLease(record, lease) {
    if (!lease || lease.until <= now()) return Promise.resolve(false);
    record.leases = lease.count;
    record.leaseUntil = lease.until;
    return Promise.resolve(true);
  }
  function prune() {
    var expire = Promise.resolve();
    Object.keys(records).forEach(function (token) {
      var record = records[token];
      if (record.committed && record.leases > 0 && record.leaseUntil > 0 && record.leaseUntil <= now()) {
        record.leases = 0; record.leaseUntil = 0;
        expire = expire.then(function () { return markerRemove(token, 'lease'); });
      }
    });
    var values = Object.keys(records).map(function (token) { return records[token]; })
      .filter(function (record) { return record.committed; }).sort(tokenOrder);
    var seen = Object.create(null), keep = Object.create(null), bytes = 0, count = 0;
    values.forEach(function (record) {
      var firstForKey = !seen[record.key];
      seen[record.key] = true;
      if (record.leases > 0 || firstForKey && count < MAX_ENTRIES && bytes + record.size <= MAX_CACHE_BYTES) {
        keep[record.token] = true; bytes += record.size; count += 1;
      }
    });
    var work = Promise.resolve();
    values.forEach(function (record) {
      if (!keep[record.token]) work = work.then(function () { return removeRecord(record); });
    });
    return expire.then(function () { return work; });
  }
  function initialize() {
    if (initFlight) return initFlight;
    initFlight = ensureDirectory().then(function () {
      return new Promise(function (resolve, reject) {
        fs.readdir(directory, function (error, names) {
          if (error) { reject(safeError(error)); return; }
          resolve(names);
        });
      });
    }).then(function (names) {
      var found = Object.create(null), junk = [], work = Promise.resolve();
      names.forEach(function (name) {
        var token = null, suffix = '';
        if (name.slice(-8) === '.pending') { token = name.slice(0, -8); suffix = 'pending'; }
        else if (name.slice(-3) === '.ok') { token = name.slice(0, -3); suffix = 'ok'; }
        else if (name.slice(-6) === '.lease') { token = name.slice(0, -6); suffix = 'lease'; }
        else if (name.slice(-5) === '.part') { token = name.slice(0, -5); suffix = 'part'; }
        else if (name.slice(-12) === '.pending.tmp') { token = name.slice(0, -12); suffix = 'pending.tmp'; }
        else if (name.slice(-6) === '.ok.tmp') { token = name.slice(0, -6); suffix = 'ok.tmp'; }
        else if (name.slice(-9) === '.lease.tmp') { token = name.slice(0, -9); suffix = 'lease.tmp'; }
        else if (TOKEN_PATTERN.test(name)) { token = name; suffix = 'bin'; }
        if (!token || !TOKEN_PATTERN.test(token)) return;
        if (!found[token]) found[token] = Object.create(null);
        found[token][suffix] = true;
        if (suffix === 'part' || suffix.slice(-4) === '.tmp') junk.push(name);
      });
      if (junk.length) work = work.then(function () { return unlinkNames(junk); });
      Object.keys(found).forEach(function (token) {
        var files = found[token];
        if (!files.bin || (!files.ok && !files.pending)) {
          work = work.then(function () { return unlinkNames(recordFiles(token)); });
          return;
        }
        var marker = files.ok ? token + '.ok' : token + '.pending';
        work = work.then(function () { return readSmall(path.join(directory, marker), 192); }).then(function (raw) {
          var value = raw && parseMetadata(raw);
          return statSize(token).then(function (size) {
            if (!value || size !== value.size || !files.ok && now() - value.at > MAX_PENDING_AGE_MS) {
              return unlinkNames(recordFiles(token));
            }
            var record = {token:token, key:value.key, size:value.size, at:value.at,
              committed:!!files.ok, leases:files.ok ? 0 : 1, leaseUntil:0};
            records[token] = record;
            var tokenParts = TOKEN_PATTERN.exec(token);
            var tokenAt = Number(tokenParts[1]), tokenCounter = Number(tokenParts[2]);
            if (tokenAt > lastTimestamp || tokenAt === lastTimestamp && tokenCounter >= sequence) {
              lastTimestamp = tokenAt; sequence = tokenCounter + 1;
            }
            if (!record.committed) {
              return files.lease ? markerRemove(token, 'lease') : Promise.resolve();
            }
            var cleanPending = files.pending ? markerRemove(token, 'pending') : Promise.resolve();
            return cleanPending.then(function () {
              if (!files.lease) return;
              return readSmall(path.join(directory, token + '.lease'), 192).then(function (leaseRaw) {
                var lease = leaseRaw && parseLease(leaseRaw);
                return applyLease(record, lease).then(function (valid) {
                  if (!valid) return markerRemove(token, 'lease');
                });
              });
            });
          }, function (failure) {
            if (failure.name === 'NotFoundError') return unlinkNames(recordFiles(token));
            throw failure;
          });
        });
      });
      return work.then(function () { return prune(); });
    }).catch(function (error) {
      initFlight = null;
      throw safeError(error);
    });
    return initFlight;
  }
  function nextToken() {
    var timestamp = Math.floor(now());
    if (!integer(timestamp)) throw makeError('storage');
    if (timestamp > lastTimestamp) { lastTimestamp = timestamp; sequence = 0; }
    if (!integer(sequence)) throw makeError('storage');
    return 'epg_' + lastTimestamp + '_' + sequence++ + '.bin';
  }
  function validateRequest(request, key) {
    request = request || {};
    if (!keyValid(key) || typeof request.url !== 'string' || request.url.length > 8192 ||
        !/^https?:\/\//i.test(request.url) || /[\r\n\0]/.test(request.url)) throw makeError('invalid');
    var maximum = request.maximumBodyBytes === undefined ? MAX_FILE_BYTES : request.maximumBodyBytes;
    var total = request.totalTimeoutMs === undefined ? 60000 : request.totalTimeoutMs;
    var idle = request.idleTimeoutMs === undefined ? 20000 : request.idleTimeoutMs;
    if (!integer(maximum) || maximum < 1 || !integer(total) || total < 1 || total > 30 * 60 * 1000 ||
        !integer(idle) || idle < 1 || idle > 2 * 60 * 1000) throw makeError('invalid');
    var headers = request.headers || {}, names = Object.keys(headers), bytes = 0, cleaned = {};
    if (!headers || typeof headers !== 'object' || Array.isArray(headers) || names.length > 64) throw makeError('invalid');
    names.forEach(function (name) {
      var value = headers[name];
      if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(name) || typeof value !== 'string' || /[\r\n\0]/.test(value)) {
        throw makeError('invalid');
      }
      bytes += name.length + value.length;
      if (bytes > 32768) throw makeError('invalid');
      if (!/^(host|content-length|connection|transfer-encoding|proxy-authorization)$/i.test(name)) cleaned[name] = value;
    });
    return {url:request.url, headers:cleaned, maximum:Math.min(maximum, MAX_FILE_BYTES),
      total:total, idle:idle};
  }
  function parseHttpUrl(raw) {
    var parsed;
    try { parsed = url.parse(raw); } catch (_) { throw makeError('invalid'); }
    if (!parsed || (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') || !parsed.hostname ||
        parsed.hash || parsed.href.length > 8192) throw makeError('invalid');
    return parsed;
  }
  function sameOrigin(left, right) {
    var leftPort = left.port || (left.protocol === 'https:' ? '443' : '80');
    var rightPort = right.port || (right.protocol === 'https:' ? '443' : '80');
    return left.protocol === right.protocol && left.hostname.toLowerCase() === right.hostname.toLowerCase() && leftPort === rightPort;
  }
  function headersForRedirect(headers) {
    var result = {};
    Object.keys(headers).forEach(function (name) {
      if (/^(accept|accept-encoding|user-agent)$/i.test(name)) result[name] = headers[name];
    });
    return result;
  }
  function safeRetryAfter(value) {
    if (typeof value !== 'string') return undefined;
    value = value.trim();
    if (/^[0-9]{1,6}$/.test(value) || RETRY_AFTER_DATE.test(value)) return value;
    return undefined;
  }
  function uncommittedBytes() {
    return Object.keys(records).reduce(function (total, token) {
      var record = records[token];
      return total + (record.committed || record.size === null ? 0 : record.size);
    }, 0);
  }
  function deleteJobRecord(job) {
    if (!job.record) return Promise.resolve();
    return unlinkNames(recordFiles(job.record.token)).then(function () { delete records[job.record.token]; });
  }
  function download(request, key, operationId) {
    var checked;
    try { checked = validateRequest(request, key); }
    catch (error) { return Promise.reject(safeError(error)); }
    var id = typeof operationId === 'string' && operationId.length > 0 && operationId.length <= 128
      ? operationId : 'local_' + now() + '_' + (++sequence);
    if (jobs[id]) return Promise.reject(makeError('invalid'));
    var job = {id:id, done:false, cancelled:false, request:null, response:null, output:null, record:null,
      totalTimer:null, idleTimer:null, received:0, expectedLength:null, finalizing:false};
    var settleResolve, settleReject;
    var promise = new Promise(function (resolve, reject) { settleResolve = resolve; settleReject = reject; });
    jobs[id] = job;
    function clearTimers() {
      clearTimeout(job.totalTimer); clearTimeout(job.idleTimer);
    }
    function detach() { clearTimers(); delete jobs[id]; }
    function cleanup() {
      if (job.request) { try { job.request.destroy(); } catch (_) {} }
      if (job.response) { try { job.response.destroy(); } catch (_) {} }
      if (!job.output || job.outputClosed) return deleteJobRecord(job);
      return new Promise(function (resolve) {
        job.output.once('close', function () { job.outputClosed = true; resolve(); });
        try { job.output.destroy(); } catch (_) { job.outputClosed = true; resolve(); }
      }).then(function () { return deleteJobRecord(job); });
    }
    function fail(error) {
      if (job.done) return job.cleanupPromise || Promise.resolve();
      job.done = true; detach();
      job.cleanupPromise = cleanup().then(function () { settleReject(safeError(error)); }, function () { settleReject(safeError(error)); });
      return job.cleanupPromise;
    }
    function succeed() {
      if (job.done) return;
      job.done = true; detach(); settleResolve(metadata(job.record));
    }
    function checkCurrent() {
      if (job.cancelled) throw makeError('cancelled');
      if (job.done) throw makeError('cancelled');
    }
    function resetIdle() {
      clearTimeout(job.idleTimer);
      job.idleTimer = setTimeout(function () { fail(makeError('timeout')); }, checked.idle);
    }
    function reserve() {
      return enqueue(function () {
        checkCurrent();
        var active = Object.keys(records).filter(function (token) { return !records[token].committed; }).length;
        if (active >= MAX_ENTRIES) throw makeError('limit');
        var token = nextToken();
        var record = {token:token, key:key, size:null, at:now(), committed:false, leases:1, leaseUntil:0};
        records[token] = record; job.record = record;
      });
    }
    function completeFile(expectedLength) {
      if (job.finalizing || job.done) return;
      job.finalizing = true;
      checkCurrent();
      if (expectedLength !== null && expectedLength !== job.received) { fail(makeError('network')); return; }
      fs.rename(path.join(directory, job.record.token + '.part'), path.join(directory, job.record.token), function (error) {
        if (error) { fail(safeError(error)); return; }
        if (job.done) { deleteJobRecord(job); return; }
        job.record.size = job.received; job.record.at = now();
        markerWrite(job.record.token, 'pending', {key:key, at:job.record.at, size:job.record.size}).then(function () {
          if (job.done) deleteJobRecord(job); else succeed();
        }, fail);
      });
    }
    function get(current, currentHeaders, redirects) {
      checkCurrent(); resetIdle();
      var client = current.protocol === 'https:' ? https : http;
      var requestOptions = {protocol:current.protocol, hostname:current.hostname, port:current.port || undefined,
        path:(current.pathname || '/') + (current.search || ''), method:'GET', headers:currentHeaders};
      if (current.auth) requestOptions.auth = current.auth;
      try { job.request = client.get(requestOptions, function (response) {
        job.response = response; resetIdle();
        var status = response.statusCode;
        if (status >= 300 && status < 400) {
          var location = response.headers.location;
          response.resume();
          if (redirects >= MAX_REDIRECTS || typeof location !== 'string' || !location || /[\r\n\0]/.test(location)) {
            fail(makeError('network')); return;
          }
          var target;
          try { target = parseHttpUrl(url.resolve(current.href, location)); }
          catch (_) { fail(makeError('network')); return; }
          var nextHeaders = currentHeaders;
          if (!sameOrigin(current, target)) { target.auth = null; nextHeaders = headersForRedirect(currentHeaders); }
          else target.auth = current.auth;
          get(target, nextHeaders, redirects + 1); return;
        }
        if (status !== 200) {
          var retryAfter = safeRetryAfter(response.headers['retry-after']);
          response.resume();
          fail(makeError('http', status, retryAfter)); return;
        }
        var advertised = response.headers['content-length'];
        if (advertised !== undefined) {
          if (!/^[0-9]+$/.test(String(advertised)) || !integer(Number(advertised))) {
            response.resume(); fail(makeError('network')); return;
          }
          job.expectedLength = Number(advertised);
          if (job.expectedLength > checked.maximum || job.expectedLength > MAX_FILE_BYTES) {
            response.resume(); fail(makeError('limit')); return;
          }
        }
        try { job.output = fs.createWriteStream(path.join(directory, job.record.token + '.part'), {flags:'wx'}); }
        catch (_) { response.resume(); fail(makeError('storage')); return; }
        var outputFinished = false, outputClosed = false;
        function maybeComplete() { if (outputFinished && outputClosed && !job.done) completeFile(job.expectedLength); }
        job.output.on('error', function (error) { fail(safeError(error)); });
        job.output.on('finish', function () { outputFinished = true; maybeComplete(); });
        job.output.on('close', function () { outputClosed = true; job.outputClosed = true; maybeComplete(); });
        response.on('data', function (chunk) {
          if (job.done) return;
          resetIdle();
          job.received += chunk.length;
          if (job.received > checked.maximum || job.received > MAX_FILE_BYTES ||
              job.expectedLength !== null && job.received > job.expectedLength) {
            fail(makeError('limit')); return;
          }
          job.record.size = job.received;
          if (uncommittedBytes() > MAX_FILE_BYTES) { fail(makeError('limit')); return; }
          if (!job.output.write(chunk)) {
            response.pause();
            job.output.once('drain', function () { if (!job.done) { resetIdle(); response.resume(); } });
          }
        });
        response.on('end', function () { if (!job.done) job.output.end(); });
        response.on('aborted', function () { fail(makeError('network')); });
        response.on('error', function () { fail(makeError('network')); });
      }); } catch (_) { fail(makeError('network')); return; }
      job.request.on('error', function () { fail(makeError('network')); });
    }
    job.cancel = function () {
      if (job.done) return job.cleanupPromise || Promise.resolve();
      job.cancelled = true;
      return fail(makeError('cancelled'));
    };
    job.totalTimer = setTimeout(function () { fail(makeError('timeout')); }, checked.total);
    initialize().then(reserve).then(function () {
      if (job.done) return;
      var initial;
      try { initial = parseHttpUrl(checked.url); }
      catch (error) { fail(error); return; }
      get(initial, checked.headers, 0);
    }).catch(fail);
    return promise;
  }
  function cancel(operationId) {
    var job = jobs[operationId];
    return job && typeof job.cancel === 'function' ? job.cancel() : Promise.resolve();
  }
  function read(record, args) {
    if (!integer(args.offset) || !integer(args.count) || args.count < 1 || args.count > MAX_READ_BYTES ||
        args.offset > record.size) return Promise.reject(makeError('invalid'));
    var count = Math.min(args.count, record.size - args.offset);
    if (count === 0) return Promise.resolve({bodyBase64:'', eof:true});
    return new Promise(function (resolve, reject) {
      fs.open(path.join(directory, record.token), 'r', function (openError, descriptor) {
        if (openError) { reject(makeError('missing')); return; }
        var buffer = typeof Buffer.alloc === 'function' ? Buffer.alloc(count) : new Buffer(count);
        fs.read(descriptor, buffer, 0, count, args.offset, function (readError, bytesRead) {
          fs.close(descriptor, function () {});
          if (readError || bytesRead !== count) { reject(makeError('storage')); return; }
          resolve({bodyBase64:buffer.toString('base64'), eof:args.offset + bytesRead === record.size});
        });
      });
    });
  }
  function writeLease(record) {
    return markerWrite(record.token, 'lease', {count:record.leases, until:record.leaseUntil});
  }
  function lookup(key) {
    if (!keyValid(key)) return Promise.reject(makeError('invalid'));
    var candidates = Object.keys(records).map(function (token) { return records[token]; })
      .filter(function (record) { return record.key === key && record.committed; }).sort(tokenOrder);
    if (!candidates.length) return Promise.resolve(null);
    var record = candidates[0];
    if (record.leaseUntil > 0 && record.leaseUntil <= now()) { record.leases = 0; record.leaseUntil = 0; }
    return statSize(record.token).then(function (size) {
      if (size !== record.size) return removeRecord(record).then(function () { return null; });
      record.leases += 1;
      record.leaseUntil = now() + MAX_LEASE_AGE_MS;
      return writeLease(record).then(function () { return metadata(record); }, function (error) {
        record.leases -= 1; throw error;
      });
    }, function (error) {
      if (error.name === 'NotFoundError') return removeRecord(record).then(function () { return null; });
      throw error;
    });
  }
  function commit(record) {
    if (record.committed) return Promise.resolve(metadata(record));
    return statSize(record.token).then(function (size) {
      if (size !== record.size) throw makeError('storage');
      record.leaseUntil = now() + MAX_LEASE_AGE_MS;
      return writeLease(record).then(function () {
        return new Promise(function (resolve, reject) {
          fs.rename(path.join(directory, record.token + '.pending'), path.join(directory, record.token + '.ok'), function (error) {
            if (error) { reject(safeError(error)); return; }
            record.committed = true;
            prune().then(function () { resolve(metadata(record)); }, reject);
          });
        });
      });
    });
  }
  function query(args) {
    args = args || {};
    var action = args.action;
    if (action === 'lookup') {
      if (!keyValid(args.key)) return Promise.reject(makeError('invalid'));
      return enqueue(function () { return initialize().then(function () { return lookup(args.key); }); });
    }
    if (['read', 'commit', 'discard', 'release'].indexOf(action) < 0 || !tokenValid(args.token) ||
        args.key !== undefined && !keyValid(args.key)) return Promise.reject(makeError('invalid'));
    return enqueue(function () {
      return initialize().then(function () {
        var record = records[args.token];
        if (!record || record.size === null) throw makeError('missing');
        if (args.key !== undefined && record.key !== args.key) throw makeError('invalid');
        if (action === 'read') return read(record, args);
        if (action === 'commit') return commit(record);
        if (action === 'discard') {
          if (record.committed) return false;
          return removeRecord(record).then(function () { return true; });
        }
        if (record.leaseUntil > 0 && record.leaseUntil <= now()) { record.leases = 0; record.leaseUntil = 0; }
        record.leases = Math.max(0, record.leases - 1);
        if (record.leases === 0) {
          record.leaseUntil = 0;
          return markerRemove(record.token, 'lease').then(function () { return prune(); }).then(function () { return true; });
        }
        record.leaseUntil = now() + MAX_LEASE_AGE_MS;
        return writeLease(record).then(function () { return prune(); }).then(function () { return true; });
      });
    }).catch(function (failure) { throw safeError(failure); });
  }
  function abort() {
    var stopping = Object.keys(jobs).map(function (id) { return cancel(id); });
    return Promise.all(stopping).then(function () { return enqueue(function () {
      return initialize().then(function () {
        var work = Promise.resolve();
        Object.keys(records).forEach(function (token) {
          var record = records[token];
          if (!record.committed) work = work.then(function () { return removeRecord(record); });
          else {
            record.leases = 0; record.leaseUntil = 0;
            work = work.then(function () { return markerRemove(token, 'lease'); });
          }
        });
        return work.then(function () { return prune(); });
      });
    }); });
  }
  return {available:function () { return !!directory; }, download:download, query:query,
    cancel:cancel, abort:abort};
}

module.exports = {create:create};
