(function (root, factory) {
  var exported = {create:factory};
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroWebOSEpgFiles = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';

  var SERVICE_URI = 'luna://online.tvbro.webos.epg/';
  var MAX_FILE_BYTES = 512 * 1024 * 1024;
  var MAX_METADATA_BODY_BYTES = 4 * 1024 * 1024;
  var MAX_METADATA_DECODED_BYTES = 8 * 1024 * 1024;
  var MAX_READ_BYTES = 65536;
  var MAX_SAFE_INTEGER = 9007199254740991;
  var TOKEN_PATTERN = /^epg_[A-Za-z0-9_]+\.bin$/;
  var environment = options && options.environment || (typeof window !== 'undefined' ? window : null);
  var service = environment && environment.webOS && environment.webOS.service;
  var operations = [], known = Object.create(null);

  function error(kind, status, retryAfter) {
    var names = {invalid:'TypeError', unsupported:'NotSupportedError', missing:'NotFoundError',
      storage:'IOError', network:'NetworkError', http:'NetworkError', timeout:'TimeoutError',
      cancelled:'AbortError', limit:'QuotaExceededError'};
    var messages = {invalid:'Invalid guide file request.', unsupported:'Native guide storage is unavailable.',
      missing:'Guide file is unavailable.', storage:'Guide storage operation failed.', network:'Guide download failed.',
      http:'Guide download failed.', timeout:'Guide download timed out.', cancelled:'Guide operation was cancelled.',
      limit:'Guide exceeds its storage limit.'};
    var value = new Error(messages[kind] || messages.storage);
    value.name = names[kind] || names.storage;
    if (typeof status === 'number' && status >= 100 && status <= 599) value.status = status;
    if (typeof retryAfter === 'string') value.retryAfter = retryAfter;
    return value;
  }
  function responseError(response) {
    if (!response || typeof response !== 'object') return error('storage');
    var kind = response.errorKind;
    if (kind === 'http') kind = 'http';
    else if (['invalid', 'unsupported', 'missing', 'storage', 'network', 'timeout', 'cancelled', 'limit'].indexOf(kind) < 0) kind = 'storage';
    return error(kind, response.status, response.retryAfter);
  }
  function integer(value) {
    return typeof value === 'number' && isFinite(value) && value >= 0 &&
      value <= MAX_SAFE_INTEGER && Math.floor(value) === value;
  }
  function keyValid(value) { return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value); }
  function tokenValid(value) { return typeof value === 'string' && TOKEN_PATTERN.test(value); }
  function metadata(value) {
    if (!value || typeof value !== 'object' || !tokenValid(value.token) || !integer(value.size) ||
        value.size > MAX_FILE_BYTES || !integer(value.at)) throw error('storage');
    return {token:value.token, size:value.size, at:value.at};
  }
  function available() {
    return !!(service && typeof service.request === 'function' && environment &&
      typeof environment.atob === 'function' && typeof (environment.setTimeout || setTimeout) === 'function' &&
      typeof (environment.clearTimeout || clearTimeout) === 'function');
  }
  function schedule(callback, delay) {
    var scheduleTimer = environment && environment.setTimeout || setTimeout;
    return scheduleTimer(callback, delay);
  }
  function unschedule(timer) {
    if (timer === undefined || timer === null) return;
    var clearTimer = environment && environment.clearTimeout || clearTimeout;
    clearTimer(timer);
  }
  function send(method, parameters, subscribe, timeoutMs) {
    var done = false, request = null, operation, timer;
    var resolvePromise, rejectPromise;
    var promise = new Promise(function (resolve, reject) { resolvePromise = resolve; rejectPromise = reject; });
    function remove() {
      var index = operations.indexOf(operation);
      if (index >= 0) operations.splice(index, 1);
    }
    function finish(failure, value) {
      if (done) return;
      done = true; unschedule(timer); remove();
      if ((failure || subscribe) && request && typeof request.cancel === 'function') {
        try { request.cancel(); } catch (_) {}
      }
      if (failure) rejectPromise(failure);
      else resolvePromise(value);
    }
    operation = {cancel:function () {
      if (done) return;
      done = true; unschedule(timer); remove();
      if (request && typeof request.cancel === 'function') { try { request.cancel(); } catch (_) {} }
      rejectPromise(error('cancelled'));
    }};
    operations.push(operation);
    if (!available()) { finish(error('unsupported')); return {promise:promise, cancel:operation.cancel}; }
    timer = schedule(function () { finish(error('timeout')); }, timeoutMs || 10000);
    try {
      request = service.request(SERVICE_URI, {method:method, parameters:parameters || {},
        subscribe:subscribe === true, resubscribe:false,
        onSuccess:function (response) {
          if (!response || response.returnValue !== true) { finish(responseError(response)); return; }
          finish(null, response);
        },
        onFailure:function (response) { finish(responseError(response)); }});
      if (done && subscribe && request && typeof request.cancel === 'function') {
        try { request.cancel(); } catch (_) {}
      }
    } catch (_) { finish(error('storage')); }
    return {promise:promise, cancel:operation.cancel};
  }
  function descriptorForResponse(response, action) {
    if (action === 'lookup' && response.value === null) return null;
    var value = metadata(response);
    known[value.token] = value;
    return value;
  }
  function decodeBase64(value, maximum) {
    if (typeof value !== 'string' || value.length > 4 * Math.ceil(maximum / 3) ||
        value.length % 4 !== 0 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
      throw error('storage');
    }
    var raw;
    try { raw = environment.atob(value); } catch (_) { throw error('storage'); }
    if (raw.length > maximum) throw error('storage');
    var bytes = new Uint8Array(raw.length), index;
    for (index = 0; index < raw.length; index += 1) bytes[index] = raw.charCodeAt(index);
    return bytes;
  }
  function download(request, entry, key) {
    request = request || {}; entry = entry || {};
    var maximum = request.maximumBodyBytes === undefined ? MAX_FILE_BYTES : request.maximumBodyBytes;
    var total = request.totalTimeoutMs === undefined ? 60000 : request.totalTimeoutMs;
    var idle = request.idleTimeoutMs === undefined ? 20000 : request.idleTimeoutMs;
    if (!keyValid(key) || typeof request.url !== 'string' || !/^https?:\/\//i.test(request.url) ||
        !integer(maximum) || maximum < 1 || !integer(total) || total < 1 ||
        !integer(idle) || idle < 1 || request.headers != null && (typeof request.headers !== 'object' || Array.isArray(request.headers))) {
      return Promise.reject(error('invalid'));
    }
    if (!available()) return Promise.reject(error('unsupported'));
    var params = {url:request.url, headers:request.headers || {}, key:key,
      maximumBodyBytes:Math.min(maximum, MAX_FILE_BYTES), totalTimeoutMs:total, idleTimeoutMs:idle};
    var task = send('download', params, true, total + 5000), settled = false;
    function cancel() {
      if (settled) return;
      settled = true; task.cancel();
    }
    entry.cancelNative = cancel;
    return task.promise.then(function (response) {
      if (settled || entry.done) throw error('cancelled');
      var value = metadata(response);
      known[value.token] = value;
      settled = true;
      if (entry.cancelNative === cancel) entry.cancelNative = null;
      return value;
    }, function (failure) {
      settled = true;
      if (entry.cancelNative === cancel) entry.cancelNative = null;
      throw failure;
    });
  }
  function requestMetadata(request) {
    request = request || {};
    var method = typeof request.method === 'string' ? request.method.toUpperCase() : '';
    var body = typeof request.body === 'string' ? request.body : '';
    var bodySize = environment && environment.Blob ? new environment.Blob([body]).size : body.length * 3;
    var total = request.totalTimeoutMs === undefined ? 45000 : request.totalTimeoutMs;
    var idle = request.idleTimeoutMs === undefined ? 20000 : request.idleTimeoutMs;
    var maximumBody = request.maximumBodyBytes === undefined ? MAX_METADATA_BODY_BYTES : request.maximumBodyBytes;
    var maximumDecoded = request.maximumDecodedBytes === undefined ? MAX_METADATA_DECODED_BYTES : request.maximumDecodedBytes;
    if (request.workload !== 'metadata-json' || typeof request.url !== 'string' || !/^https:\/\//i.test(request.url) ||
        ['GET', 'POST'].indexOf(method) < 0 || !integer(maximumBody) || maximumBody < 1 || maximumBody > MAX_METADATA_BODY_BYTES ||
        !integer(maximumDecoded) || maximumDecoded < 1 || maximumDecoded > MAX_METADATA_DECODED_BYTES ||
        !integer(total) || total < 1 || total > 45000 || !integer(idle) || idle < 1 || idle > 20000 ||
        bodySize > maximumBody || method === 'GET' && body.length > 0 ||
        request.headers != null && (typeof request.headers !== 'object' || Array.isArray(request.headers))) {
      return Promise.reject(error('invalid'));
    }
    var parameters = {url:request.url, method:method, body:body, headers:request.headers || {},
      maximumBodyBytes:maximumBody, maximumDecodedBytes:maximumDecoded, totalTimeoutMs:total, idleTimeoutMs:idle};
    var task = send('requestMetadata', parameters, true, total + 5000);
    return task.promise.then(function (response) {
      if (!response || typeof response.status !== 'number' || response.status < 100 || response.status > 599 ||
          typeof response.url !== 'string' || !response.headers || typeof response.headers !== 'object' ||
          typeof response.bodyBase64 !== 'string' || response.bodyBase64.length > 4 * Math.ceil(maximumDecoded / 3) ||
          response.bodyBase64.length % 4 !== 0 ||
          !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(response.bodyBase64)) {
        throw error('network');
      }
      return {status:response.status, headers:response.headers, url:response.url,
        bodyBase64:response.bodyBase64, decoded:response.decoded === true};
    });
  }
  function query(args) {
    args = args || {};
    var action = args.action;
    if (action === 'lookup') {
      if (!keyValid(args.key)) return Promise.reject(error('invalid'));
    } else if (['read', 'commit', 'discard', 'release'].indexOf(action) < 0 || !tokenValid(args.token) ||
        args.key !== undefined && !keyValid(args.key)) return Promise.reject(error('invalid'));
    if (action === 'read' && (!integer(args.offset) || !integer(args.count) || args.count < 1 || args.count > MAX_READ_BYTES)) {
      return Promise.reject(error('invalid'));
    }
    if (action === 'read' && !known[args.token]) return Promise.reject(error('missing'));
    var task = send('query', args, false, 10000);
    return task.promise.then(function (response) {
      if (action === 'lookup') return descriptorForResponse(response, action);
      if (action === 'read') {
        var file = known[args.token], maximum = Math.min(args.count, file.size - args.offset);
        if (args.offset > file.size || typeof response.eof !== 'boolean') throw error('storage');
        var bytes = decodeBase64(response.bodyBase64, maximum);
        if (bytes.length > args.count || args.offset + bytes.length > file.size ||
            bytes.length === 0 && args.offset < file.size || response.eof !== (args.offset + bytes.length === file.size)) {
          throw error('storage');
        }
        return {bodyBuffer:bytes.buffer, eof:response.eof};
      }
      if (action === 'commit') { var committed = metadata(response); known[committed.token] = committed; return committed; }
      if (response.value !== true && response.value !== false) throw error('storage');
      return response.value;
    });
  }
  function abort() {
    operations.slice().forEach(function (operation) { operation.cancel(); });
    if (!available()) return Promise.resolve();
    var task = send('abort', {}, false, 5000);
    return task.promise.then(function () {}, function () {});
  }
  return {available:available, download:download, requestMetadata:requestMetadata, query:query, abort:abort};
}));
