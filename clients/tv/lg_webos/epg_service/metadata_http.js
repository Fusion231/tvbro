'use strict';

var https = require('https');
var url = require('url');
var zlib = require('zlib');
var MAX_BODY_BYTES = 4 * 1024 * 1024;
var MAX_DECODED_BYTES = 8 * 1024 * 1024;
var MAX_TIMEOUT_MS = 45000;
var MAX_IDLE_TIMEOUT_MS = 20000;

function failure(kind, status, retryAfter) {
  var error = new Error('Metadata request failed.');
  error.kind = kind;
  if (typeof status === 'number' && status >= 100 && status <= 599) error.status = status;
  if (typeof retryAfter === 'string') error.retryAfter = retryAfter;
  return error;
}

function allowed(parsed, method) {
  var host = parsed.hostname, path = parsed.pathname;
  if (parsed.protocol !== 'https:' || parsed.auth || parsed.hash || parsed.port && parsed.port !== '443') return false;
  if (host === 'api.themoviedb.org') {
    return method === 'GET' && /^\/3\/(?:search\/(?:movie|tv)|movie\/[0-9]+|tv\/[0-9]+(?:\/season\/[0-9]+(?:\/episode\/[0-9]+)?)?)$/.test(path);
  }
  if (host === 'api4.thetvdb.com') {
    if (method === 'POST') return path === '/v4/login';
    return method === 'GET' && /^\/v4\/(?:search|movies\/[0-9]+\/extended|series\/[0-9]+\/(?:extended|episodes\/default)|seasons\/[0-9]+\/extended|episodes\/[0-9]+\/extended)$/.test(path);
  }
  if (host === 'api.mdblist.com') {
    return method === 'GET' && /^\/(?:imdb|tmdb|tvdb)\/(?:show|movie)\/(?:tt[0-9]+|[0-9]+)\/?$/.test(path);
  }
  if (host === 'api.tvmaze.com') {
    return method === 'GET' && /^\/(?:search\/shows|shows\/[0-9]+)$/.test(path);
  }
  return false;
}

function integer(value, minimum, maximum) {
  return typeof value === 'number' && isFinite(value) && Math.floor(value) === value &&
    value >= minimum && value <= maximum;
}

function create(options) {
  options = options || {};
  var client = options.https || https;

  function request(payload) {
    payload = payload || {};
    var method = typeof payload.method === 'string' ? payload.method.toUpperCase() : 'GET';
    var target = typeof payload.url === 'string' ? payload.url : '';
    var headers = payload.headers && typeof payload.headers === 'object' && !Array.isArray(payload.headers)
      ? payload.headers : {};
    var body = typeof payload.body === 'string' ? payload.body : '';
    var maximumBody = integer(payload.maximumBodyBytes, 1, MAX_BODY_BYTES) ? payload.maximumBodyBytes : MAX_BODY_BYTES;
    var maximumDecoded = integer(payload.maximumDecodedBytes, 1, MAX_DECODED_BYTES) ? payload.maximumDecodedBytes : MAX_DECODED_BYTES;
    var totalTimeout = integer(payload.totalTimeoutMs, 1, MAX_TIMEOUT_MS) ? payload.totalTimeoutMs : MAX_TIMEOUT_MS;
    var idleTimeout = integer(payload.idleTimeoutMs, 1, MAX_IDLE_TIMEOUT_MS) ? payload.idleTimeoutMs : MAX_IDLE_TIMEOUT_MS;
    var parsed;
    try { parsed = url.parse(target); } catch (_) { parsed = null; }
    if (!parsed || !allowed(parsed, method) || Buffer.byteLength(body, 'utf8') > maximumBody ||
        method === 'GET' && body.length > 0 || method === 'POST' &&
        (!headers['content-type'] && !headers['Content-Type'] || !/^application\/json(?:\s*;|$)/i.test(headers['content-type'] || headers['Content-Type']))) {
      return {promise:Promise.reject(failure('invalid')), cancel:function () {}};
    }
    var normalizedHeaders = Object.create(null), invalidHeader = false;
    Object.keys(headers).forEach(function (name) {
      var key = name.toLowerCase(), value = String(headers[name]);
      if (['accept', 'authorization', 'content-type', 'user-agent'].indexOf(key) < 0 ||
          /[\r\n]/.test(name + value)) invalidHeader = true;
      else normalizedHeaders[key] = value;
    });
    if (invalidHeader) return {promise:Promise.reject(failure('invalid')), cancel:function () {}};
    normalizedHeaders['accept-encoding'] = 'identity';

    var settled = false, active = null, timer = null, idleTimer = null;
    var resolvePromise, rejectPromise;
    var promise = new Promise(function (resolve, reject) { resolvePromise = resolve; rejectPromise = reject; });
    function clear() { if (timer !== null) clearTimeout(timer); if (idleTimer !== null) clearTimeout(idleTimer); }
    function finish(error, value) {
      if (settled) return;
      settled = true; clear();
      if (error) rejectPromise(error); else resolvePromise(value);
    }
    function abort() {
      if (settled) return;
      finish(failure('cancelled'));
      try { if (active && typeof active.abort === 'function') active.abort(); } catch (_) {}
    }
    function resetIdle() {
      if (settled) return;
      if (idleTimer !== null) clearTimeout(idleTimer);
      idleTimer = setTimeout(function () { abortWith('timeout'); }, idleTimeout);
    }
    function abortWith(kind) {
      if (settled) return;
      finish(failure(kind));
      try { if (active && typeof active.abort === 'function') active.abort(); } catch (_) {}
    }
    timer = setTimeout(function () { abortWith('timeout'); }, totalTimeout);

    function send(currentUrl, currentMethod, currentHeaders, currentBody) {
      var current = url.parse(currentUrl), requestOptions, request;
      if (settled) return;
      if (!allowed(current, currentMethod)) { finish(failure('invalid')); return; }
      requestOptions = {protocol:'https:', hostname:current.hostname, port:current.port || 443,
        path:current.path || '/', method:currentMethod, headers:currentHeaders};
      if (currentMethod === 'POST') currentHeaders['content-length'] = String(Buffer.byteLength(currentBody, 'utf8'));
      try {
        request = client.request(requestOptions, function (response) {
          resetIdle();
          var chunks = [], received = 0, decoded = 0, stream = response;
          var status = Number(response.statusCode) || 0, responseHeaders = response.headers || {};
          var redirect = status >= 300 && status < 400 && typeof responseHeaders.location === 'string';
          var advertised = Number(responseHeaders['content-length']);
          var retryAfter = typeof responseHeaders['retry-after'] === 'string' ? responseHeaders['retry-after'] : undefined;
          var encoding = String(responseHeaders['content-encoding'] || 'identity').toLowerCase();
          if (advertised > maximumBody) { abortWith('limit'); return; }
          if (encoding === 'gzip') {
            try { stream = response.pipe(zlib.createGunzip()); }
            catch (_) { abortWith('network'); return; }
          } else if (encoding !== 'identity' && encoding !== '') { abortWith('network'); return; }
          response.on('data', function (chunk) {
            received += chunk.length;
            if (received > maximumBody) { abortWith('limit'); return; }
            resetIdle();
          });
          if (stream !== response) response.on('data', resetIdle);
          stream.on('data', function (chunk) {
            if (settled) return;
            decoded += chunk.length;
            if (decoded > maximumDecoded) { abortWith('limit'); return; }
            if (!redirect) chunks.push(chunk);
            resetIdle();
          });
          stream.on('end', function () {
            if (settled) return;
            var safeHeaders = {};
            ['content-type', 'retry-after', 'location'].forEach(function (name) {
              if (typeof responseHeaders[name] === 'string') safeHeaders[name] = responseHeaders[name];
            });
            finish(null, {status:status, headers:safeHeaders, url:currentUrl,
              bodyBase64:redirect ? '' : Buffer.concat(chunks).toString('base64'), decoded:true});
          });
          stream.on('error', function () { abortWith('network'); });
          resetIdle();
        });
        active = request;
        request.on('socket', function (socket) {
          resetIdle();
          if (socket && typeof socket.on === 'function') {
            ['lookup', 'connect', 'secureConnect', 'data'].forEach(function (event) {
              socket.on(event, resetIdle);
            });
          }
        });
        request.on('finish', resetIdle);
        request.on('error', function () { abortWith('network'); });
        if (currentMethod === 'POST') request.write(currentBody, 'utf8');
        request.end();
      } catch (_) { abortWith('network'); }
    }

    resetIdle();
    send(target, method, normalizedHeaders, body);
    return {promise:promise, cancel:abort};
  }

  return {request:request};
}

module.exports = {create:create, allowed:allowed};
