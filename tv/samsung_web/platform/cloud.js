(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroSamsungCloud = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';

  options = options || {};
  var environment = options.environment || (typeof window !== 'undefined' ? window : null);
  var core = options.core || (environment && environment.TVBroCanonical);
  var config = options.config || {};
  var userState = options.userState;
  var Xhr = options.XMLHttpRequest || (environment && environment.XMLHttpRequest);
  var clock = options.now || function () { return Date.now(); };
  var sessionKey = 'supabase_session';
  var devicePrivateKey = 'cloud_device_priv_key';
  var devicePublicKey = 'cloud_device_pub_key';
  var profileKey = 'cloud_profile_id';
  var sourceIdsKey = 'cloud_source_ids';
  var e2eeMarksKey = 'cloud_e2ee_marks';
  var sourceSecretKeys = {mac:1, username:1, password:1, playlistUrl:1, epgUrl:1, epgUrls:1, userAgent:1};
  var metadataSecretKeys = {tmdbApiKey:1, tvdbApiKey:1, tvdbPin:1, mdblistApiKey:1};
  var sessionLoaded = false;
  var session = null;
  var refreshInFlight = null;
  var deviceKeyInFlight = null;
  var readFlights = Object.create(null), supporterRead = null;
  var pairingFlights = Object.create(null), pairingFailures = Object.create(null);
  var contentKeys = Object.create(null);
  var baseApi = '';
  var panelUrl = '';
  var anonKey = '';
  var configError = null;
  var relayConfigured = config.providerRelay === true;

  function error(name, message, status, code) {
    var result = new Error(message);
    result.name = name || 'CloudError';
    if (status != null) result.status = status;
    if (code) result.code = code;
    return result;
  }

  function plainObject(value) {
    if (!value || Object.prototype.toString.call(value) !== '[object Object]') return false;
    var proto = Object.getPrototypeOf(value);
    return proto === Object.prototype || proto === null;
  }

  function hasOwn(value, key) {
    return Object.prototype.hasOwnProperty.call(value, key);
  }

  function validateUrl(value, label, allowPath) {
    if (typeof value !== 'string') throw error('ConfigurationError', label + ' is not configured.');
    var input = value.trim();
    var match = /^https:\/\/([^/?#]+)(\/[^?#]*)?$/i.exec(input);
    if (!match || match[1].indexOf('@') !== -1 || match[1].indexOf('\\') !== -1) {
      throw error('ConfigurationError', label + ' must be a valid HTTPS URL.');
    }
    var authority = match[1].toLowerCase();
    var host = authority;
    if (host.charAt(0) === '[') host = host.slice(1, host.indexOf(']'));
    else host = host.replace(/:\d+$/, '');
    if (!host || host === 'abc.com' || host.slice(-8) === '.abc.com' ||
        host === 'example.com' || host.slice(-12) === '.example.com' ||
        host.slice(-8) === '.invalid' || host === 'localhost' || host.slice(-10) === '.localhost' ||
        host === '127.0.0.1' || host === '0.0.0.0' || host === '::1' || host.slice(-6) === '.local') {
      throw error('ConfigurationError', label + ' points to a placeholder or local host.');
    }
    if (!allowPath && match[2] && match[2] !== '/') {
      throw error('ConfigurationError', label + ' must not contain a path.');
    }
    return input.replace(/\/+$/, '');
  }

  function validateConfig() {
    if (config.enabled === false) throw error('ConfigurationError', 'Cloud sync is disabled in this build.');
    baseApi = validateUrl(config.apiUrl, 'Cloud API', true);
    panelUrl = validateUrl(config.panelUrl, 'Cloud panel', true);
    if (/\/$/.test(String(config.panelUrl || '').trim())) panelUrl += '/';
    anonKey = typeof config.anonKey === 'string' ? config.anonKey.trim() : '';
    // CloudConfig's TVBRO_API_URL path uses this public client identifier; a
    // direct Supabase project URL still requires its public anon/publishable key.
    if (!anonKey && !/\.supabase\.co(?::\d+)?$/i.test(baseApi.replace(/^https:\/\//, '').split('/')[0])) {
      anonKey = 'tvbro_public_client';
    }
    if (!anonKey || anonKey.length > 4096 || /\s/.test(anonKey)) {
      throw error('ConfigurationError', 'Cloud public client key is not configured.');
    }
    if (!userState || typeof userState.get !== 'function' || typeof userState.set !== 'function' ||
        typeof userState.remove !== 'function' || typeof userState.update !== 'function') {
      throw error('NotSupportedError', 'Samsung KeyManager user-state storage is unavailable.');
    }
    if (typeof Xhr !== 'function') throw error('NotSupportedError', 'Cloud networking is unavailable.');
  }

  try { validateConfig(); }
  catch (configFailure) { configError = configFailure; }

  function requireReady() {
    if (configError) throw configError;
  }

  function cryptoApi() {
    var provider = options.crypto || (environment && environment.crypto) ||
      (typeof crypto !== 'undefined' ? crypto : null);
    var subtle = provider && (provider.subtle || provider.webkitSubtle);
    if (!provider || !subtle || typeof subtle.importKey !== 'function' ||
        typeof subtle.deriveBits !== 'function' || typeof subtle.encrypt !== 'function' ||
        typeof subtle.decrypt !== 'function' || typeof subtle.generateKey !== 'function' ||
        typeof provider.getRandomValues !== 'function') {
      throw error('CryptoUnsupportedError', 'This Samsung browser does not provide the cryptography needed for this encrypted profile.');
    }
    return {provider:provider, subtle:subtle};
  }

  function panelCrypto() {
    var protocol = options.cryptoProtocol || (environment && environment.TVBroPanelCrypto);
    if (!protocol || typeof protocol.sourceSecretAad !== 'function' ||
        typeof protocol.metadataSecretAad !== 'function' || typeof protocol.deviceWrapAad !== 'function' ||
        typeof protocol.encryptSecretEnvelope !== 'function' ||
        typeof protocol.decryptSecretEnvelope !== 'function' || typeof protocol.decodeDeviceWrap !== 'function') {
      throw error('CryptoUnsupportedError', 'This build does not include the verified cloud encryption protocol.');
    }
    return protocol;
  }

  function decodeBase64(value) {
    if (typeof value !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
      throw error('CryptoLockedError', 'Saved cloud encryption key is malformed.');
    }
    var decode = environment && environment.atob;
    if (typeof decode !== 'function' && typeof atob === 'function') decode = atob;
    if (typeof decode !== 'function') throw error('CryptoUnsupportedError', 'Base64 decoding is unavailable in this Samsung browser.');
    var binary;
    try { binary = decode(value); }
    catch (_) { throw error('CryptoLockedError', 'Saved cloud encryption key is malformed.'); }
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  function encodeBase64(bytes) {
    var encode = environment && environment.btoa;
    if (typeof encode !== 'function' && typeof btoa === 'function') encode = btoa;
    if (typeof encode !== 'function') throw error('CryptoUnsupportedError', 'Base64 encoding is unavailable in this Samsung browser.');
    var binary = '';
    for (var i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
    try { return encode(binary); }
    catch (_) { throw error('CryptoError', 'Could not encode cloud cryptographic data.'); }
  }

  function decodeBase64Url(value) {
    if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/.test(value)) {
      throw error('CryptoLockedError', 'Saved cloud encryption key is malformed.');
    }
    var standard = value.replace(/-/g, '+').replace(/_/g, '/');
    while (standard.length % 4) standard += '=';
    return decodeBase64(standard);
  }

  function encodeBase64Url(bytes) {
    return encodeBase64(bytes).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  }

  function decodePrivateKey(privateBytes, publicBytes) {
    if (privateBytes.length !== 32 || publicBytes.length !== 65 || publicBytes[0] !== 4) {
      throw error('CryptoLockedError', 'Saved cloud encryption key is incomplete.');
    }
    return {
      kty:'EC', crv:'P-256',
      x:encodeBase64Url(publicBytes.slice(1, 33)),
      y:encodeBase64Url(publicBytes.slice(33, 65)),
      d:encodeBase64Url(privateBytes), ext:true, key_ops:['deriveBits']
    };
  }

  function generateDeviceKeyPair() {
    var subtle = cryptoApi().subtle;
    return subtle.generateKey({name:'ECDH', namedCurve:'P-256'}, true, ['deriveBits'])
      .then(function (pair) {
        return Promise.all([subtle.exportKey('raw', pair.publicKey), subtle.exportKey('jwk', pair.privateKey)]);
      }).then(function (parts) {
        var publicBytes = new Uint8Array(parts[0]);
        var privateBytes = decodeBase64Url(parts[1].d);
        if (publicBytes.length !== 65 || publicBytes[0] !== 4 || privateBytes.length !== 32) {
          throw error('CryptoError', 'Samsung browser generated an invalid P-256 key.');
        }
        return {privateKey:privateBytes, publicKey:publicBytes};
      });
  }

  function deviceKeyPair() {
    if (deviceKeyInFlight) return deviceKeyInFlight;
    var privateValue = userState.get(devicePrivateKey);
    var publicValue = userState.get(devicePublicKey);
    if (!!privateValue !== !!publicValue) {
      return Promise.reject(error('CryptoLockedError', 'This TV has an incomplete cloud encryption key. Re-pair it and send a fresh key from the panel.'));
    }
    var load = privateValue ? Promise.resolve({
      privateKey:decodeBase64(privateValue), publicKey:decodeBase64(publicValue)
    }) : generateDeviceKeyPair();
    deviceKeyInFlight = load.then(function (pair) {
      if (pair.publicKey.length !== 65 || pair.publicKey[0] !== 4 || pair.privateKey.length !== 32) {
        throw error('CryptoLockedError', 'Saved cloud encryption key is malformed.');
      }
      if (privateValue) return pair;
      return userState.update(function (state) {
        var oldPrivate = state[devicePrivateKey];
        var oldPublic = state[devicePublicKey];
        if (!!oldPrivate !== !!oldPublic) {
          throw error('CryptoLockedError', 'This TV has an incomplete cloud encryption key. Re-pair it and send a fresh key from the panel.');
        }
        if (!oldPrivate) {
          state[devicePrivateKey] = encodeBase64(pair.privateKey);
          state[devicePublicKey] = encodeBase64(pair.publicKey);
        }
      }).then(function () {
        var savedPrivate = userState.get(devicePrivateKey);
        var savedPublic = userState.get(devicePublicKey);
        return {privateKey:decodeBase64(savedPrivate), publicKey:decodeBase64(savedPublic)};
      });
    }).then(function (pair) {
      deviceKeyInFlight = null;
      return pair;
    }, function (failure) {
      deviceKeyInFlight = null;
      throw failure;
    });
    return deviceKeyInFlight;
  }

  function ecdh(privateBytes, localPublicBytes, peerPublicBytes) {
    var subtle = cryptoApi().subtle;
    var jwk = decodePrivateKey(privateBytes, localPublicBytes);
    return Promise.all([
      subtle.importKey('jwk', jwk, {name:'ECDH', namedCurve:'P-256'}, false, ['deriveBits']),
      subtle.importKey('raw', peerPublicBytes, {name:'ECDH', namedCurve:'P-256'}, false, [])
    ]).then(function (keys) {
      return subtle.deriveBits({name:'ECDH', public:keys[1]}, keys[0], 256);
    }).then(function (shared) { return new Uint8Array(shared); });
  }

  function decodeDeviceWrap(envelope, pair, profile, uid, serverVersion, watermark) {
    var protocol = panelCrypto();
    if (typeof envelope === 'string') {
      try { envelope = JSON.parse(envelope); }
      catch (_) { throw error('CryptoLockedError', 'The panel sent an invalid encryption key.'); }
    }
    if (!plainObject(envelope)) throw error('CryptoLockedError', 'The panel sent an invalid encryption key.');
    var version = Number(envelope.ckv);
    if (!isFinite(version) || Math.floor(version) !== version || version < serverVersion || version < watermark || version < 1) {
      throw error('CryptoRollbackError', 'The cloud encryption key is older than one this TV has already used. Nothing was synced.');
    }
    var aad = protocol.deviceWrapAad(profile, uid, version);
    var contentKey;
    try {
      contentKey = protocol.decodeDeviceWrap({
        envelope:envelope, devicePrivateKey:pair.privateKey, ckVersion:version, aad:aad
      }, function (privateBytes, peerPublicBytes) {
        return ecdh(privateBytes, pair.publicKey, peerPublicBytes);
      });
    } catch (failure) {
      throw error('CryptoLockedError', 'The cloud encryption key could not be verified.');
    }
    return Promise.resolve(contentKey).then(function (key) {
      contentKey = key;
      if (contentKey.length !== 32) throw error('CryptoLockedError', 'The panel sent an invalid content key.');
      return {key:contentKey, version:version};
    }).catch(function (failure) {
      if (failure && (failure.name === 'CryptoRollbackError' || failure.name === 'CryptoUnsupportedError')) throw failure;
      throw error('CryptoLockedError', 'The cloud encryption key could not be verified.');
    });
  }

  function secretAad(profile, sourceId, version) {
    var protocol = panelCrypto();
    return sourceId
      ? protocol.sourceSecretAad(profile, sourceId, version)
      : protocol.metadataSecretAad(profile, version);
  }

  function decryptSecret(envelope, cryptoState, aad) {
    var protocol = panelCrypto();
    return Promise.resolve().then(function () {
      return protocol.decryptSecretEnvelope({
        envelope:envelope, contentKey:cryptoState.key, ckVersion:cryptoState.ckVersion, aad:aad
      });
    }).then(function (secret) {
      return stringMap(secret, 'encrypted secret');
    }).catch(function (failure) {
      throw error('CryptoLockedError', 'Cloud secret authentication failed.');
    });
  }

  function encryptSecret(secret, cryptoState, aad) {
    var version = cryptoState.ckVersion;
    if (!version || !cryptoState.key || !secret || !Object.keys(secret).length) return Promise.resolve(null);
    var protocol = panelCrypto();
    Object.keys(secret).forEach(function (key) {
      if (typeof secret[key] !== 'string') throw error('CryptoError', 'Cloud secret values must be strings.');
    });
    var provider = cryptoApi().provider;
    var iv = new Uint8Array(12);
    try { provider.getRandomValues(iv); }
    catch (_) { return Promise.reject(error('CryptoUnsupportedError', 'Secure random generation is unavailable in this Samsung browser.')); }
    return Promise.resolve().then(function () {
      return protocol.encryptSecretEnvelope({
        secret:secret, contentKey:cryptoState.key, ckVersion:version, aad:aad, iv:iv
      });
    }).then(function (payload) {
      return {format:1, payload:payload};
    });
  }

  function loadSession() {
    requireReady();
    if (sessionLoaded) return session;
    var raw = userState.get(sessionKey);
    sessionLoaded = true;
    if (raw == null || raw === '') return null;
    try {
      var stored = JSON.parse(raw);
      if (!stored || typeof stored.access_token !== 'string' ||
          !stored.user || typeof stored.user.id !== 'string') {
        throw new Error('bad shape');
      }
      session = stored;
      return session;
    } catch (_) {
      throw error('SessionError', 'Saved cloud session is malformed.');
    }
  }

  function saveSession(value, previous) {
    if (!value || typeof value.access_token !== 'string' || !value.access_token ||
        !value.user || typeof value.user.id !== 'string' || !value.user.id) {
      throw error('SessionError', 'Cloud authentication returned an invalid session.');
    }
    if (!session || session.user.id !== value.user.id) {
      if (session) { pairingFailures = Object.create(null); pairingFlights = Object.create(null); }
      supporterRead = null; readFlights = Object.create(null);
    }
    var expiresIn = Number(value.expires_in);
    if (!isFinite(expiresIn) || expiresIn <= 0) expiresIn = 3600;
    var expiresAt = Number(value.expires_at);
    if (!isFinite(expiresAt) || expiresAt <= 0) expiresAt = Math.floor(clock() / 1000) + expiresIn;
    session = {
      access_token: value.access_token,
      refresh_token: typeof value.refresh_token === 'string' ? value.refresh_token : (previous && previous.refresh_token) || '',
      token_type: typeof value.token_type === 'string' ? value.token_type : 'bearer',
      expires_at: expiresAt,
      expires_in: expiresIn,
      user: {id: value.user.id}
    };
    sessionLoaded = true;
    return userState.set(sessionKey, JSON.stringify(session)).then(function () { return session; });
  }

  function jsonBody(xhr) {
    if (!xhr.responseText) return null;
    try { return JSON.parse(xhr.responseText); }
    catch (_) { return null; }
  }

  function xhrRequest(method, path, body, token, headers) {
    return new Promise(function (resolve, reject) {
      var xhr = new Xhr();
      var url = baseApi + path;
      try {
        xhr.open(method, url, true);
        xhr.timeout = 30000;
        xhr.setRequestHeader('apikey', anonKey);
        if (token) xhr.setRequestHeader('Authorization', 'Bearer ' + token);
        if (body !== undefined && body !== null) xhr.setRequestHeader('Content-Type', 'application/json');
        if (headers) Object.keys(headers).forEach(function (key) { xhr.setRequestHeader(key, headers[key]); });
      } catch (_) {
        reject(error('NetworkError', 'Could not prepare the cloud request.'));
        return;
      }
      xhr.onload = function () {
        var parsed = jsonBody(xhr);
        if (xhr.status < 200 || xhr.status >= 300) {
          var hasCode = parsed && Object.prototype.hasOwnProperty.call(parsed, 'code');
          var candidateCode = hasCode
            ? (typeof parsed.code === 'string' ? parsed.code : '')
            : (path === '/tv/provider-request' && parsed && typeof parsed.error === 'string' ? parsed.error
              : (parsed && parsed.error === 'origin_not_allowed' ? 'origin_not_allowed' : ''));
          var serverCode = (/^[a-z][a-z0-9_]{0,63}$/.test(candidateCode) ||
            candidateCode === 'PGRST202' || candidateCode === 'PGRST203' ||
            candidateCode === '42883' || candidateCode === '42501' ||
            candidateCode === 'origin_not_allowed')
            ? candidateCode : '';
          var cloudFailure = error('CloudError', 'Cloud request failed (HTTP ' + xhr.status + ').', xhr.status, serverCode);
          if (typeof xhr.getResponseHeader === 'function' && core && typeof core.retryAfterDeadline === 'function') {
            try { cloudFailure.retryAt = JSON.parse(core.retryAfterDeadline(xhr.getResponseHeader('Retry-After') || '', clock())); } catch (_) {}
          }
          if (path === '/auth/v1/signup') cloudFailure.cloudOperation = 'signup';
          else if (path === '/rest/v1/rpc/request_pairing') cloudFailure.cloudOperation = 'request_pairing';
          reject(cloudFailure);
          return;
        }
        resolve({status:xhr.status, body:parsed});
      };
      xhr.onerror = function () { reject(error('NetworkError', 'Could not connect to cloud sync.')); };
      xhr.ontimeout = function () { reject(error('TimeoutError', 'Cloud sync timed out.')); };
      xhr.onabort = function () { reject(error('AbortError', 'Cloud sync was cancelled.')); };
      try { xhr.send(body === undefined || body === null ? null : JSON.stringify(body)); }
      catch (_) { reject(error('NetworkError', 'Could not send the cloud request.')); }
    });
  }

  function authRequest(path, body) {
    requireReady();
    return xhrRequest('POST', path, body || {}, null).then(function (response) { return response.body; });
  }

  function refreshSession() {
    var current = loadSession();
    if (!current || !current.refresh_token) return Promise.reject(error('SessionError', 'Cloud session expired; pair this TV again.'));
    if (refreshInFlight) return refreshInFlight;
    refreshInFlight = authRequest('/auth/v1/token?grant_type=refresh_token', {refresh_token:current.refresh_token})
      .then(function (value) { return saveSession(value, current); })
      .catch(function () { throw error('SessionError', 'Cloud session expired; pair this TV again.'); })
      .then(function (value) { refreshInFlight = null; return value; }, function (reason) { refreshInFlight = null; throw reason; });
    return refreshInFlight;
  }

  function freshSession() {
    var current = loadSession();
    if (!current) return Promise.reject(error('SessionError', 'Pair this TV before using cloud sync.'));
    var expires = Number(current.expires_at) || 0;
    if (expires && expires * 1000 > clock() + 60000) return Promise.resolve(current);
    return refreshSession();
  }

  function request(method, path, body, headers, allowRetry) {
    if (method !== 'GET') return requestOnce(method, path, body, headers, allowRetry);
    var current = loadSession(), flights = readFlights;
    var key = JSON.stringify([current && current.user.id, path, headers]);
    if (flights[key]) return flights[key].then(function (value) { return JSON.parse(JSON.stringify(value)); });
    var pending = requestOnce(method, path, body, headers, allowRetry);
    flights[key] = pending;
    function clear() { if (flights[key] === pending) delete flights[key]; }
    pending.then(clear, clear);
    return pending.then(function (value) { return JSON.parse(JSON.stringify(value)); });
  }

  function requestOnce(method, path, body, headers, allowRetry) {
    return freshSession().then(function (current) {
      return xhrRequest(method, path, body, current.access_token, headers).then(function (response) {
        return response.body;
      }).catch(function (failure) {
        if (failure.status === 401 && allowRetry !== false && current.refresh_token) {
          return refreshSession().then(function (next) {
            return xhrRequest(method, path, body, next.access_token, headers).then(function (response) { return response.body; });
          });
        }
        throw failure;
      });
    });
  }

  function signup() {
    return authRequest('/auth/v1/signup', {data:{}}).then(function (value) {
      return saveSession(value, null);
    });
  }

  function ensureSession() {
    if (loadSession()) return freshSession();
    return signup();
  }

  function rpc(name, params) {
    return request('POST', '/rest/v1/rpc/' + encodeURIComponent(name), params || {}, null, true);
  }

  function rest(method, query, body) {
    return request(method, '/rest/v1/' + query, body,
      method === 'DELETE' ? {'Prefer':'return=minimal'} : null, true);
  }

  function validateRelayDto(value) {
    if (!plainObject(value) || value.workload !== 'stalker-json' || typeof value.url !== 'string') {
      throw error('ValidationError', 'This relay accepts Stalker JSON metadata requests only.');
    }
    var allowed = {workload:1, url:1, headers:1, maximumDecodedBytes:1, totalTimeoutMs:1, idleTimeoutMs:1};
    if (Object.keys(value).some(function (key) { return !hasOwn(allowed, key); })) {
      throw error('ValidationError', 'The Stalker metadata request is invalid.');
    }
    var match = /^https?:\/\/([^/?#]+)(\/[^?#]*)?(?:\?[^#]*)?$/i.exec(value.url);
    if (!match || match[1].indexOf('@') !== -1 || match[1].indexOf('\\') !== -1 ||
        value.url.length > 8192 || !/(?:\/portal\.php|\/load\.php)$/.test(match[2] || '/')) {
      throw error('ValidationError', 'The Stalker metadata URL is invalid.');
    }
    var headers = {};
    if (value.headers != null) {
      if (!plainObject(value.headers)) throw error('ValidationError', 'The Stalker metadata headers are invalid.');
      var permitted = {cookie:1, 'user-agent':1, referer:1, authorization:1, accept:1, 'x-user-agent':1};
      Object.keys(value.headers).forEach(function (name) {
        var lower = name.toLowerCase();
        var header = value.headers[name];
        if (!hasOwn(permitted, lower) || typeof header !== 'string' || header.length > 8192 || /[\r\n\0]/.test(header)) {
          throw error('ValidationError', 'The Stalker metadata headers are invalid.');
        }
        headers[lower] = header;
      });
    }
    var result = {workload:'stalker-json', url:value.url, headers:headers};
    ['maximumDecodedBytes', 'totalTimeoutMs', 'idleTimeoutMs'].forEach(function (key) {
      if (value[key] == null) return;
      var number = Number(value[key]);
      if (!isFinite(number) || Math.floor(number) !== number || number < 1 || number > 2147483647) {
        throw error('ValidationError', 'The Stalker metadata request limits are invalid.');
      }
      result[key] = number;
    });
    return result;
  }

  function relayProvider(requestDto) {
    try {
      requireReady();
      if (config.providerRelay !== true) {
        throw error('CloudCapabilityError', 'The provider metadata relay is not enabled for this build.');
      }
      requestDto = validateRelayDto(requestDto);
    } catch (failure) {
      return Promise.reject(failure);
    }
    return ensureSession().then(function () {
      return request('POST', '/tv/provider-request', requestDto, null, true);
    }).then(function (result) {
      if (!plainObject(result) || result.decoded !== true ||
          !isFinite(Number(result.status)) || Math.floor(Number(result.status)) !== Number(result.status) ||
          Number(result.status) < 100 || Number(result.status) > 599 ||
          typeof result.body !== 'string' || typeof result.url !== 'string' || !plainObject(result.headers)) {
        throw error('ProtocolError', 'The provider metadata relay returned an invalid response.');
      }
      var headers = {};
      Object.keys(result.headers).forEach(function (name) {
        if (typeof result.headers[name] === 'string') headers[name.toLowerCase()] = result.headers[name];
      });
      return JSON.stringify({
        status:Number(result.status), body:result.body, headers:headers, url:result.url, decoded:true
      });
    });
  }

  function rpcMissing(failure) {
    return !!failure && (failure.status === 404 || failure.code === 'PGRST202' ||
      failure.code === 'PGRST203' || failure.code === '42883' || failure.code === 'invalid_request');
  }

  function asArray(value, what) {
    if (Object.prototype.toString.call(value) !== '[object Array]') {
      throw error('ProtocolError', 'Cloud returned an invalid ' + what + ' list.');
    }
    return value;
  }

  function asObject(value, what) {
    if (!plainObject(value)) throw error('ProtocolError', 'Cloud returned invalid ' + what + ' data.');
    return value;
  }

  function uuid(value, what) {
    if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
      throw error('ValidationError', what + ' must be a UUID.');
    }
    return value;
  }

  function profileId(args) {
    var id = args && args.profileId || userState.get(profileKey);
    if (!id) throw error('CloudStateError', 'Choose a cloud profile first.');
    return uuid(id, 'Cloud profile id');
  }

  function profileShape(row) {
    if (!row || typeof row !== 'object') throw error('ProtocolError', 'Cloud returned invalid profile data.');
    return {
      id:uuid(row.id, 'Cloud profile id'), name: typeof row.name === 'string' ? row.name : '',
      position: Number(row.position) || 0,
      updated_at: row.updated_at == null ? null : String(row.updated_at),
      pin: typeof row.pin === 'string' && row.pin.trim() ? row.pin.trim() : null
    };
  }

  function ownDevice() {
    var id = loadSession() && session.user.id;
    if (!id) return Promise.resolve(null);
    return rest('GET', 'devices?select=device_uid,owner,label,active_profile_id&device_uid=eq.' + encodeURIComponent(id))
      .then(function (rows) {
        rows = asArray(rows, 'device');
        return rows.length ? rows[0] : null;
      });
  }

  function status() {
    var result = {configured:!configError, hasSession:false, paired:false, deviceId:null, profileId:null, e2eeSupported:false};
    if (configError) {
      result.error = configError.message;
      return Promise.resolve(result);
    }
    try {
      var current = loadSession();
      result.hasSession = !!current;
      result.deviceId = current ? current.user.id : null;
      result.profileId = userState.get(profileKey);
      if (!current) return Promise.resolve(result);
      return ownDevice().then(function (device) {
        result.paired = !!device;
        if (device && device.active_profile_id) result.profileId = device.active_profile_id;
        return result;
      }).catch(function () {
        result.error = 'Cloud status is unavailable.';
        return result;
      });
    } catch (failure) {
      result.error = failure.message;
      return Promise.resolve(result);
    }
  }

  function supporterStatus() {
    var free = {status:'free', supported:false, device_limit:0, valid_until:null,
      activated_devices:[], selected_devices:[], billing_ready:false};
    var current = loadSession();
    if (!current) return Promise.resolve(free);
    var owner = current.user.id, entry = supporterRead;
    if (entry && entry.owner === owner && (entry.at == null || (clock() >= entry.at && clock() - entry.at < entry.ttl))) {
      return entry.pending.then(function (value) { return JSON.parse(JSON.stringify(value)); });
    }
    entry = { owner: owner, at: null, ttl: 60000, pending: null };
    supporterRead = entry;
    entry.pending = rpc('get_supporter_status', {}).then(function (value) {
      if (Array.isArray(value)) value = value[0];
      if (!plainObject(value)) return free;
      var limit = Number(value.device_limit);
      return {
        status:typeof value.status === 'string' ? value.status : 'free',
        supported:value.supported === true,
        device_limit:isFinite(limit) && limit >= 0 && limit <= 100 ? limit : 0,
        valid_until:typeof value.valid_until === 'string' ? value.valid_until : null,
        activated_devices:Array.isArray(value.activated_devices) ? value.activated_devices : [],
        selected_devices:Array.isArray(value.selected_devices) ? value.selected_devices : [],
        billing_ready:value.billing_ready === true
      };
    }).catch(function (failure) {
      if (rpcMissing(failure)) return free;
      throw failure;
    }).then(function (value) {
      entry.at = clock(); return value;
    }, function (failure) {
      // Repeated UI reads must not hammer an unavailable API. Never turn an
      // error into a cached access grant; callers still receive the failure.
      entry.at = clock(); entry.ttl = 15000; throw failure;
    });
    return entry.pending.then(function (value) { return JSON.parse(JSON.stringify(value)); });
  }

  function panelPairingLink(code, language) {
    if (!core || typeof core.pairingPanelLink !== 'function') {
      throw error('ConfigurationError', 'The canonical TVBro cloud-link helper is unavailable.');
    }
    return core.pairingPanelLink(panelUrl, code, language || '');
  }

  function requestPairing(args) {
    args = args || {};
    var label = typeof args.label === 'string' ? args.label.trim() : (options.deviceLabel || 'Samsung TV');
    label = label.replace(/[\x00-\x1f\x7f]/g, ' ').trim();
    if (!label) label = options.deviceLabel || 'Samsung TV';
    label = label.slice(0, 64);
    var language = args.language === 'pl' ? 'pl' : 'en';
    return pairingRead('start', function () { return ensureSession().then(function () {
      return rpc('request_pairing', {p_label:label, p_language:language});
    }).then(function (response) {
      var row = Object.prototype.toString.call(response) === '[object Array]' ? response[0] : response;
      if (!row || typeof row.code !== 'string' || typeof row.expires_at !== 'string') {
        throw error('ProtocolError', 'Cloud returned an invalid pairing code.');
      }
      return {code:row.code, expiresAt:row.expires_at, panelLink:panelPairingLink(row.code, language), state:'waiting'};
    }); });
  }

  function pairingRead(key, action) {
    if (pairingFlights[key]) return pairingFlights[key];
    var previous = pairingFailures[key];
    if (previous && previous.retryAt > clock()) return Promise.reject(previous.error);
    var pending = Promise.resolve().then(action).then(function (value) {
      delete pairingFailures[key]; return value;
    }, function (failure) {
      var count = previous ? previous.count + 1 : 1;
      var retryAt = Math.max(clock() + Math.min(60000, 5000 * Math.pow(2, Math.min(4, count - 1))), Number(failure.retryAt) || 0);
      failure.retryAt = retryAt;
      pairingFailures[key] = {count:count,retryAt:retryAt,error:failure};
      throw failure;
    });
    pairingFlights[key] = pending;
    function clear() { if (pairingFlights[key] === pending) delete pairingFlights[key]; }
    pending.then(clear, clear);
    return pending;
  }

  function pairingStatus(code) {
    if (typeof code !== 'string' || !code.trim()) return Promise.resolve(false);
    if (!loadSession()) return Promise.resolve(false);
    return pairingRead('status:' + code.trim(), function () { return rpc('pairing_status', {p_code:code.trim()}).then(function (value) {
      return value === true;
    }); });
  }

  function profilesList() {
    return rest('GET', 'profiles?select=id,name,position,updated_at,pin&order=position.asc').then(function (rows) {
      return asArray(rows, 'profile').map(profileShape);
    });
  }

  function requirePaired() {
    if (!loadSession()) return Promise.reject(error('CloudStateError', 'Pair this TV before using cloud sync.'));
    return ownDevice().then(function (device) {
      if (!device) throw error('CloudStateError', 'This TV is not paired to a panel account.');
      return device;
    });
  }

  function selectProfile(id) {
    id = uuid(id, 'Cloud profile id');
    return requirePaired().then(function () {
      return rpc('set_device_profile', {p_profile_id:id});
    }).then(function () {
      return userState.set(profileKey, id).then(function () { return {profileId:id}; });
    });
  }

  function setProfilePin(id, verifier) {
    id = uuid(id, 'Cloud profile id');
    if (verifier !== null && (typeof verifier !== 'string' || !verifier.trim())) {
      return Promise.reject(error('ValidationError', 'Cloud profile PIN verifier is invalid.'));
    }
    return requirePaired().then(function () {
      return rpc('set_profile_pin', {p_profile_id:id, p_pin:verifier});
    }).then(function () { return {profileId:id}; });
  }

  function readE2eeMarks() {
    var raw = userState.get(e2eeMarksKey);
    if (!raw) return {};
    var marks;
    try { marks = JSON.parse(raw); }
    catch (_) { throw error('CryptoLockedError', 'Saved cloud encryption state is malformed; sync is locked.'); }
    if (!plainObject(marks)) throw error('CryptoLockedError', 'Saved cloud encryption state is malformed; sync is locked.');
    Object.keys(marks).forEach(function (profile) {
      var mark = marks[profile];
      if (!plainObject(mark) || (mark.seen != null && typeof mark.seen !== 'boolean') ||
          (mark.ckv != null && (!isFinite(Number(mark.ckv)) || Math.floor(Number(mark.ckv)) !== Number(mark.ckv) || Number(mark.ckv) < 0))) {
        throw error('CryptoLockedError', 'Saved cloud encryption state is malformed; sync is locked.');
      }
    });
    return marks;
  }

  function updateE2eeMark(profile, ckv) {
    return userState.update(function (state) {
      var marks = {};
      var raw = state[e2eeMarksKey];
      if (raw) {
        try { marks = JSON.parse(raw); }
        catch (_) { throw error('CryptoLockedError', 'Saved cloud encryption state is malformed; sync is locked.'); }
        if (!plainObject(marks)) throw error('CryptoLockedError', 'Saved cloud encryption state is malformed; sync is locked.');
      }
      var old = marks[profile];
      var previous = old && Number(old.ckv) > 0 ? Number(old.ckv) : 0;
      var version = ckv == null ? previous : Math.max(previous, Number(ckv) || 0);
      marks[profile] = {seen:true, ckv:version};
      state[e2eeMarksKey] = JSON.stringify(marks);
    });
  }

  function markEncrypted(profile) {
    return updateE2eeMark(profile, null);
  }

  function unlockEncryptedProfile(profile, state, mark) {
    if (!isFinite(state.ck_version) || Math.floor(state.ck_version) !== state.ck_version || state.ck_version < 1) {
      return Promise.reject(error('CryptoLockedError', 'The cloud encryption version is invalid.'));
    }
    if (state.ck_version < Number(mark && mark.ckv || 0)) {
      return Promise.reject(error('CryptoRollbackError', 'The cloud encryption key is older than one this TV has already used. Nothing was synced.'));
    }
    return deviceKeyPair().then(function (pair) {
      return rpc('set_device_public_key', {p_public_key:encodeBase64(pair.publicKey)}).then(function () { return pair; });
    }).then(function (pair) {
      return rpc('get_device_ck', {p_profile_id:profile}).then(function (value) { return {pair:pair, row:value}; });
    }).then(function (result) {
      var row = result.row;
      if (Object.prototype.toString.call(row) === '[object Array]') row = row.length ? row[0] : null;
      if (typeof row === 'string') {
        try { row = JSON.parse(row); }
        catch (_) { row = null; }
      }
      if (!plainObject(row) || row.wrapped_ck == null) {
        throw error('CryptoLockedError', 'This TV has not received the profile encryption key. Open the panel and send the key to this device.');
      }
      var rowVersion = Number(row.ck_version);
      var watermark = Number(mark && mark.ckv || 0);
      if (!isFinite(rowVersion) || Math.floor(rowVersion) !== rowVersion ||
          rowVersion < state.ck_version || rowVersion < watermark) {
        throw error('CryptoRollbackError', 'The cloud encryption key is older than one this TV has already used. Nothing was synced.');
      }
      return decodeDeviceWrap(row.wrapped_ck, result.pair, profile, session.user.id, state.ck_version, watermark)
        .then(function (decoded) {
          return updateE2eeMark(profile, decoded.version).then(function () {
            contentKeys[profile] = {key:decoded.key, ckVersion:decoded.version};
            return {enabled:true, legacy:false, ckVersion:decoded.version, key:decoded.key};
          });
        });
    }).catch(function (failure) {
      if (failure && (failure.name === 'CryptoLockedError' || failure.name === 'CryptoRollbackError' || failure.name === 'CryptoUnsupportedError')) throw failure;
      throw error('CryptoLockedError', 'The encryption key for this profile could not be opened on this TV. Nothing was synced.');
    });
  }

  function cryptoState(profile) {
    var marks = readE2eeMarks();
    var mark = marks[profile];
    return rpc('get_crypto_state', {p_profile_id:profile}).then(function (value) {
      var state = Array.isArray(value) ? value[0] : value;
      if (!plainObject(state) || typeof state.enabled !== 'boolean') {
        throw error('ProtocolError', 'Cloud returned invalid encryption status.');
      }
      if (state.enabled) {
        return markEncrypted(profile).then(function () { return unlockEncryptedProfile(profile, state, mark); });
      }
      if (mark && (mark.seen === true || Number(mark.ckv) > 0)) {
        throw error('CryptoLockedError', 'This profile was end-to-end encrypted, but the server now reports it as off. Nothing is being sent in the clear.');
      }
      return {enabled:false, ckVersion:Number(state.ck_version) || 0, legacy:false};
    }).catch(function (failure) {
      if (!rpcMissing(failure)) throw failure;
      var after = readE2eeMarks()[profile];
      if (after && (after.seen === true || Number(after.ckv) > 0)) {
        throw error('CryptoLockedError', 'Cloud encryption status disappeared; syncing is locked.');
      }
      return {enabled:false, ckVersion:0, legacy:true};
    });
  }

  function getSecretBundle(profile) {
    return rpc('get_secrets', {p_profile_id:profile}).then(function (value) {
      if (typeof value === 'string') {
        try { value = JSON.parse(value); }
        catch (_) { throw error('ProtocolError', 'Cloud returned invalid secret data.'); }
      }
      if (!plainObject(value)) throw error('ProtocolError', 'Cloud returned invalid secret data.');
      return {available:true, value:value};
    }).catch(function (failure) {
      if (rpcMissing(failure)) return {available:false, value:null};
      throw failure;
    });
  }

  function playbackPositionShape(row) {
    if (!plainObject(row)) throw error('ProtocolError', 'Cloud returned an invalid playback position.');
    var sourceId = uuid(row.source_id, 'Playback source id');
    var kind = row.kind;
    var itemId = row.item_id;
    var position = Number(row.position_ms);
    var duration = Number(row.duration_ms);
    var updatedAt = Number(row.updated_at);
    if ((kind !== 'movie' && kind !== 'episode') || typeof itemId !== 'string' ||
        itemId.length < 1 || itemId.length > 4096 ||
        !isFinite(position) || Math.floor(position) !== position || position < 0 || position > 315576000000 ||
        !isFinite(duration) || Math.floor(duration) !== duration || duration < 0 || duration > 315576000000 ||
        !isFinite(updatedAt) || Math.floor(updatedAt) !== updatedAt || updatedAt < 1 || updatedAt > 9007199254740991 ||
        typeof row.removed !== 'boolean') {
      throw error('ProtocolError', 'Cloud returned an invalid playback position.');
    }
    return {source_id:sourceId, kind:kind, item_id:itemId, position_ms:position,
      duration_ms:duration, updated_at:updatedAt, removed:row.removed};
  }

  function getLegacyPlaybackPositions(profile) {
    return rpc('get_playback_positions', {p_profile_id:profile}).then(function (value) {
      if (typeof value === 'string') {
        try { value = JSON.parse(value); }
        catch (_) { throw error('ProtocolError', 'Cloud returned invalid playback positions.'); }
      }
      var rows = asArray(value, 'playback position');
      if (rows.length > 50000) throw error('ProtocolError', 'Cloud returned too many playback positions.');
      return {available:true, value:rows.map(playbackPositionShape)};
    }).catch(function (failure) {
      if (rpcMissing(failure)) return {available:false, value:[]};
      throw failure;
    });
  }

  function getPlaybackPositions(profile, previous) {
    var scope = baseApi + '|' + session.user.id + '|' + profile;
    var initial = previous && previous.scope === scope && /^\d+$/.test(previous.cursor)
      ? Number(previous.cursor) : 0;
    if (!isFinite(initial) || initial < 0 || initial > 9007199254740991) initial = 0;
    var rows = [];
    function page(after) {
      return rpc('get_playback_delta', {p_profile_id:profile, p_after:String(after), p_limit:100}).then(function (value) {
        if (typeof value === 'string') value = JSON.parse(value);
        var next = plainObject(value) && /^\d+$/.test(value.next_cursor) ? Number(value.next_cursor) : -1;
        if (next < after || next > 9007199254740991 || (value.has_more && next <= after)) {
          throw error('ProtocolError', 'Cloud returned an invalid playback cursor.');
        }
        var pagePositions = asArray(value.positions, 'playback position');
        if (rows.length + pagePositions.length > 100000) {
          throw error('ProtocolError', 'Cloud playback changed too quickly; retry sync.');
        }
        for (var i = 0; i < pagePositions.length; i += 1) rows.push(playbackPositionShape(pagePositions[i]));
        if (value.has_more) return page(next);
        return {available:true, value:rows, sync:{scope:scope, cursor:String(next), full:initial === 0}};
      });
    }
    return page(initial).catch(function (failure) {
      if (rpcMissing(failure)) return getLegacyPlaybackPositions(profile);
      throw failure;
    });
  }

  function getSources(profile) {
    var rows = [];
    function page(offset) {
      return rest('GET', 'sources?select=id,kind,label,fields,settings,position&profile_id=eq.' +
        encodeURIComponent(profile) + '&order=position.asc,id.asc&limit=250&offset=' + offset).then(function (value) {
        var part = asArray(value, 'source');
        for (var i = 0; i < part.length; i += 1) rows.push(part[i]);
        return part.length === 250 ? page(offset + 250) : rows;
      });
    }
    return page(0);
  }

  function validatePlaybackPositions(value) {
    if (value == null) return null;
    var rows = asArray(value, 'playback position');
    if (rows.length > 50000) throw error('ValidationError', 'Too many playback positions were supplied.');
    return rows.map(playbackPositionShape);
  }

  function pushPlaybackPositions(profile, rows) {
    if (!rows || !rows.length) return Promise.resolve({available:true, count:0});
    var sent = 0;
    function sendBatch(start) {
      var end = start, bytes = 2;
      while (end < rows.length && end - start < 500) {
        var size = unescape(encodeURIComponent(JSON.stringify(rows[end]))).length + 32;
        if (end > start && bytes + size > 900000) break;
        bytes += size; end++;
      }
      var batch = rows.slice(start, end);
      return rpc('push_playback_positions', {p_profile_id:profile, p_changes:batch}).then(function () {
        sent += batch.length;
        return start + batch.length < rows.length ? sendBatch(start + batch.length) : {available:true, count:sent};
      }).catch(function (failure) {
        if (rpcMissing(failure)) return {available:false, count:sent};
        throw failure;
      });
    }
    return sendBatch(0);
  }

  function validateSecretBundle(bundle, profile, crypto) {
    if (!bundle.available) {
      if (crypto.enabled) return Promise.reject(error('CryptoLockedError', 'Encrypted secrets are unavailable from this cloud server. Nothing was synced.'));
      return Promise.resolve();
    }
    var value = bundle.value;
    var sources = value.sources == null ? {} : value.sources;
    if (!plainObject(sources)) throw error('ProtocolError', 'Cloud returned invalid source secret data.');
    var entries = Object.keys(sources).map(function (id) { return sources[id]; });
    if (value.metadata != null) entries.push(value.metadata);
    var unsupported = entries.some(function (entry) {
      return !plainObject(entry) || Number(entry.format) !== (crypto.enabled ? 1 : 0);
    });
    if (!unsupported) return Promise.resolve();
    if (!crypto.enabled) return markEncrypted(profile).then(function () {
      throw error('CryptoLockedError', 'This profile has encrypted or unsupported secrets. Nothing is being sent in the clear.');
    });
    return Promise.reject(error('CryptoLockedError', 'This profile contains a plaintext or unsupported secret. Nothing is being sent in the clear.'));
  }

  function stringMap(value, label) {
    if (value == null) return {};
    if (!plainObject(value)) throw error('ProtocolError', 'Cloud returned invalid ' + label + ' fields.');
    var result = Object.create(null);
    Object.keys(value).forEach(function (key) {
      if (value[key] == null) result[key] = '';
      else if (typeof value[key] === 'string') result[key] = value[key];
      else if (typeof value[key] === 'number' || typeof value[key] === 'boolean') result[key] = String(value[key]);
      else throw error('ProtocolError', 'Cloud returned invalid ' + label + ' fields.');
    });
    return result;
  }

  function jsonObject(value, label) {
    if (value == null) return {};
    if (!plainObject(value)) throw error('ProtocolError', 'Cloud returned invalid ' + label + ' data.');
    try { return JSON.parse(JSON.stringify(value)); }
    catch (_) { throw error('ProtocolError', 'Cloud returned invalid ' + label + ' data.'); }
  }

  function splitMetadata(fields, label) {
    fields = jsonObject(fields, label);
    var broad = Object.create(null);
    var secret = Object.create(null);
    Object.keys(fields).forEach(function (key) {
      if (hasOwn(metadataSecretKeys, key)) {
        if (fields[key] != null && typeof fields[key] !== 'string') {
          throw error('ValidationError', 'Metadata secret values must be strings.');
        }
        if (fields[key]) secret[key] = fields[key];
      } else broad[key] = fields[key];
    });
    return {broad:broad, secret:secret};
  }

  function mergeSecrets(fields, incoming, local, secretKeys) {
    Object.keys(secretKeys).forEach(function (key) {
      var value = incoming && incoming[key];
      if (typeof value === 'string' && value !== '') fields[key] = value;
      else if (local && typeof local[key] === 'string' && local[key] !== '' && !fields[key]) fields[key] = local[key];
    });
    return fields;
  }

  function secretPayload(entry, context, profile, sourceId, crypto) {
    if (!entry) return Promise.resolve({});
    if (!plainObject(entry)) return Promise.reject(error('ProtocolError', 'Cloud returned invalid ' + context + ' secret data.'));
    var format = Number(entry.format);
    if (format === 0) {
      if (crypto.enabled) return Promise.reject(error('CryptoLockedError', 'This encrypted profile returned a plaintext secret. Nothing was synced.'));
      return Promise.resolve(stringMap(entry.payload, context + ' secret'));
    }
    if (format !== 1 || !crypto.enabled) {
      if (!crypto.enabled) return markEncrypted(profile).then(function () {
        throw error('CryptoLockedError', 'Cloud returned an encrypted or unsupported ' + context + ' secret. Nothing was synced.');
      });
      return Promise.reject(error('CryptoLockedError', 'Cloud returned an unsupported ' + context + ' secret. Nothing was synced.'));
    }
    return decryptSecret(entry.payload, crypto, secretAad(profile, sourceId || null, crypto.ckVersion));
  }

  function localSourceMap(args) {
    var sources = args && args.localSources;
    var result = Object.create(null);
    if (sources == null) return result;
    asArray(sources, 'local source').forEach(function (source) {
      if (source && typeof source.id === 'string' && plainObject(source.fields)) result[source.id] = stringMap(source.fields, 'local source');
    });
    return result;
  }

  function pull(args) {
    args = args || {};
    var id = profileId(args);
    var device;
    var identity;
    return requirePaired().then(function (value) {
      device = value;
      identity = session.user.id;
      return args.deferProfileSelection === true ? null : selectProfile(id);
    }).then(function () {
      return cryptoState(id);
    }).then(function (crypto) {
      return Promise.all([
        rest('GET', 'profiles?select=id,name,position,updated_at,pin,favorites&id=eq.' + encodeURIComponent(id)),
        getSources(id),
        rest('GET', 'metadata_configs?select=config&profile_id=eq.' + encodeURIComponent(id)),
        getSecretBundle(id),
        getPlaybackPositions(id, args.playbackSync)
      ]).then(function (parts) { return {crypto:crypto, profileRows:parts[0], sourceRows:parts[1], metadataRows:parts[2], secrets:parts[3], playback:parts[4]}; });
    }).then(function (data) {
      return validateSecretBundle(data.secrets, id, data.crypto).then(function () { return data; });
    }).then(function (data) {
      var profiles = asArray(data.profileRows, 'profile');
      if (!profiles.length) throw error('CloudStateError', 'The selected cloud profile is unavailable.');
      var profile = profileShape(profiles[0]);
      var favorites = profiles[0].favorites == null ? [] : asArray(profiles[0].favorites, 'favorite');
      var secrets = data.secrets.value;
      var sourceSecrets = secrets && plainObject(secrets.sources) ? secrets.sources : {};
      var local = localSourceMap(args);
      var sourceRows = asArray(data.sourceRows, 'source');
      return Promise.all(sourceRows.map(function (row) {
        if (!plainObject(row) || typeof row.id !== 'string') throw error('ProtocolError', 'Cloud returned an invalid source.');
        var fields = stringMap(row.fields, 'source');
        var incoming = {};
        if (data.secrets.available) {
          Object.keys(sourceSecretKeys).forEach(function (key) { delete fields[key]; });
          return secretPayload(sourceSecrets[row.id], 'source', id, row.id, data.crypto).then(function (secret) {
            fields = mergeSecrets(fields, secret, local[row.id], sourceSecretKeys);
            return sourceShape(row, fields);
          });
        } else {
          Object.keys(sourceSecretKeys).forEach(function (key) {
            if (fields[key]) incoming[key] = fields[key];
            delete fields[key];
          });
        }
        fields = mergeSecrets(fields, incoming, local[row.id], sourceSecretKeys);
        return sourceShape(row, fields);
      })).then(function (sources) {
      var metadataRow = asArray(data.metadataRows, 'metadata').length ? data.metadataRows[0] : null;
    var metadata = metadataRow && plainObject(metadataRow.config) ? jsonObject(metadataRow.config, 'metadata') : null;
      var metadataPromise = Promise.resolve(null);
      if (metadata) {
        var localMetadata = args.localMetadata && plainObject(args.localMetadata) ? jsonObject(args.localMetadata, 'local metadata') : {};
        var incomingMetadata = {};
        if (data.secrets.available) {
          Object.keys(metadataSecretKeys).forEach(function (key) { delete metadata[key]; });
          metadataPromise = secretPayload(secrets.metadata, 'metadata', id, null, data.crypto).then(function (secret) {
            return mergeSecrets(metadata, secret, localMetadata, metadataSecretKeys);
          });
        } else {
          Object.keys(metadataSecretKeys).forEach(function (key) {
            if (typeof metadata[key] === 'string' && metadata[key]) incomingMetadata[key] = metadata[key];
            delete metadata[key];
          });
          metadata = mergeSecrets(metadata, incomingMetadata, localMetadata, metadataSecretKeys);
          metadataPromise = Promise.resolve(metadata);
        }
      }
      return metadataPromise.then(function (resolvedMetadata) {
        if (!session || session.user.id !== identity) throw error('CloudStateError', 'Cloud identity changed during sync.');
        var ids = sources.map(function (source) { return source.id; });
        var result = {
            profile:profile, sources:sources, metadata:resolvedMetadata, favorites:favorites,
            managedSourceIds:ids, deviceId:session.user.id,
            playbackPositions:data.playback.value, playbackPositionsAvailable:data.playback.available,
            playbackSync:data.playback.sync || null,
            activeProfileId:id, e2ee:data.crypto.enabled ? 'enabled' : 'off', serverLegacy:data.crypto.legacy,
            paired:!!device
          };
        if (args.deferProfileSelection === true) return result;
        return Promise.all([
          userState.set(sourceIdsKey, ids.join(',')),
          userState.set(profileKey, id)
        ]).then(function () { return result; });
      });
      });
    });
  }

  function sourceShape(row, fields) {
    var settings = row.settings == null ? {} : row.settings;
    if (!plainObject(settings)) throw error('ProtocolError', 'Cloud returned invalid source settings.');
    if (typeof row.kind !== 'string') throw error('ProtocolError', 'Cloud returned an invalid source kind.');
    return {
      id:uuid(row.id, 'Source id'), kind:row.kind,
      label:typeof row.label === 'string' ? row.label : '', fields:fields,
      settings:settings, position:Number(row.position) || 0
    };
  }

  function splitFields(fields, secretKeys, label) {
    fields = stringMap(fields, label);
    var broad = Object.create(null);
    var secret = Object.create(null);
    Object.keys(fields).forEach(function (key) {
      if (hasOwn(secretKeys, key)) {
        if (fields[key] !== '') secret[key] = fields[key];
      } else broad[key] = fields[key];
    });
    return {broad:broad, secret:secret};
  }

  function validateSource(source) {
    if (!plainObject(source) || typeof source.kind !== 'string' || typeof source.label !== 'string') {
      throw error('ValidationError', 'Cloud source snapshot is invalid.');
    }
    var id = uuid(source.id, 'Source id');
    var parts = splitFields(source.fields, sourceSecretKeys, 'source');
    var settings = source.settings == null ? {} : source.settings;
    if (!plainObject(settings)) throw error('ValidationError', 'Cloud source settings must be an object.');
    return {
      id:id, kind:source.kind, label:source.label, fields:parts.broad,
      secret:parts.secret, settings:settings, position:Number(source.position) || 0
    };
  }

  function buildSourcePayload(source, profile, crypto) {
    var payload = {
      id:source.id, kind:source.kind, label:source.label, fields:source.fields,
      settings:source.settings, position:source.position
    };
    if (!Object.keys(source.secret).length) return Promise.resolve(payload);
    var secret = crypto.enabled
      ? encryptSecret(source.secret, crypto, secretAad(profile, source.id, crypto.ckVersion))
      : Promise.resolve({format:0, payload:source.secret});
    return secret.then(function (element) {
      if (element) payload.secret = element;
      return payload;
    });
  }

  function validateFavorites(favorites) {
    return asArray(favorites, 'favorite').map(function (favorite) {
      if (!plainObject(favorite)) {
        throw error('ValidationError', 'Cloud favorite snapshot is invalid.');
      }
      var item = plainObject(favorite.item) ? favorite.item : null;
      var channel = plainObject(favorite.channel) ? favorite.channel : null;
      var sourceId = favorite.source_id || favorite.sourceId;
      var itemId = favorite.item_id || favorite.itemId || (item && item.id) || (channel && channel.id);
      var kind = favorite.kind || (item && item.kind) || (channel && channel.kind) || (channel ? 'live' : null);
      if (typeof kind !== 'string' || ['live', 'movie', 'series'].indexOf(kind) < 0 || typeof itemId !== 'string') {
        throw error('ValidationError', 'Cloud favorite snapshot is invalid.');
      }
      return {source_id:uuid(sourceId, 'Favorite source id'), kind:kind, item_id:itemId};
    });
  }

  function push(args) {
    args = args || {};
    var id = profileId(args);
    var sources = asArray(args.sources, 'source snapshot').map(validateSource);
    var metadata = args.metadata == null ? {} : args.metadata;
    if (!plainObject(metadata)) throw error('ValidationError', 'Metadata snapshot must be an object.');
    var metadataParts = splitMetadata(metadata, 'metadata');
    var favorites = args.favorites == null ? null : validateFavorites(args.favorites);
    var playbackPositions = validatePlaybackPositions(args.playbackPositions);
    return requirePaired().then(function () { return selectProfile(id); }).then(function () {
      return cryptoState(id);
    }).then(function (crypto) {
      var containsSecret = sources.some(function (source) { return Object.keys(source.secret).length > 0; }) || Object.keys(metadataParts.secret).length > 0;
      return getSecretBundle(id).then(function (bundle) {
        return validateSecretBundle(bundle, id, crypto).then(function () { return bundle; });
      }).then(function (bundle) {
        if (containsSecret && !bundle.available && crypto.legacy) {
          throw error('CloudCapabilityError', 'This cloud server does not support isolated credentials; push was stopped before changing the profile.');
        }
        return Promise.all(sources.map(function (source) { return buildSourcePayload(source, id, crypto); })).then(function (sourcePayload) {
          var metadataSecret = Object.keys(metadataParts.secret).length
            ? (crypto.enabled
              ? encryptSecret(metadataParts.secret, crypto, secretAad(id, null, crypto.ckVersion))
              : Promise.resolve({format:0, payload:metadataParts.secret}))
            : Promise.resolve(null);
          return metadataSecret.then(function (pSecret) {
            return rpc('push_sources', {p_sources:sourcePayload, p_profile_id:id}).then(function () {
              return rpc('push_metadata', {p_config:metadataParts.broad, p_profile_id:id, p_secret:pSecret});
            }).then(function () {
              if (favorites === null) return {favoritesSynced:false};
              return rpc('push_favorites', {p_favorites:favorites, p_profile_id:id}).then(function () { return {favoritesSynced:true}; });
            }).then(function (result) {
              var ids = sourcePayload.map(function (source) { return source.id; });
              return pushPlaybackPositions(id, playbackPositions).then(function (positionResult) {
                return Promise.all([userState.set(sourceIdsKey, ids.join(',')), userState.set(profileKey, id)]).then(function () {
                  var response = {profileId:id, sourceCount:sourcePayload.length, favoritesSynced:result.favoritesSynced,
                    e2ee:crypto.enabled ? 'enabled' : 'off'};
                  if (playbackPositions !== null) {
                    response.playbackPositionsSynced = positionResult.available && positionResult.count === playbackPositions.length;
                    response.playbackPositionCount = positionResult.count;
                  }
                  return response;
                });
              });
            });
          });
        });
      });
    });
  }

  // Automatic synchronization must never use the whole-set push endpoints.
  // Only explicit user edits reach these row/path merge RPCs.
  function pushDelta(args) {
    args=args || {};
    var id=profileId(args),favorites=asArray(args.favorites || [],'favorite changes'),settings=asArray(args.settings || [],'source setting changes');
    var added=[],removed=[],bySource=Object.create(null);
    if (favorites.length>10000 || settings.length>10000) throw error('ValidationError','Too many pending cloud changes.');
    favorites.forEach(function (row) {
      var favorite=validateFavorites([{source_id:row.sourceId,kind:row.kind,item_id:row.itemId}])[0];
      if (typeof row.add!=='boolean') throw error('ValidationError','Invalid favorite change.');
      (row.add?added:removed).push(favorite);
    });
    var allowed=['aspectMode','bufferPreset','catchupTimezone','catchupOffsetMinutes','catchupMaxDays','expiryReminderDays','streamExtension','hiddenCategories','channelOrganization'];
    settings.forEach(function (row) {
      var source=uuid(row.sourceId,'Source id'),path=row.path;
      if (!Array.isArray(path) || !path.length || path.length>8 || allowed.indexOf(path[0])<0 || path.some(function (key) {
        return typeof key!=='string' || !key || key==='__proto__' || key==='prototype' || key==='constructor';
      })) throw error('ValidationError','Invalid source setting change.');
      var patch=bySource[source] || (bySource[source]=Object.create(null));
      path.forEach(function (key,index) {if (index===path.length-1) patch[key]=row.value==null?null:JSON.parse(JSON.stringify(row.value));else patch=patch[key] || (patch[key]=Object.create(null));});
    });
    return requirePaired().then(function () {
      return favorites.length ? rpc('push_favorites_delta',{p_profile_id:id,p_added:added,p_removed:removed}) : null;
    }).then(function () {
      var changes=Object.keys(bySource).map(function (source) {return {source_id:source,changes:bySource[source]};});
      return changes.length ? rpc('push_source_settings_delta',{p_profile_id:id,p_changes:changes}) : null;
    }).then(function () {return {profileId:id,favoriteCount:favorites.length,settingCount:settings.length};});
  }

  function unpair() {
    supporterRead = null; readFlights = Object.create(null); pairingFlights = Object.create(null); pairingFailures = Object.create(null);
    var current = loadSession();
    if (!current) return Promise.resolve({paired:false, removedSourceIds:[]});
    var id = current.user.id;
    var rawIds = userState.get(sourceIdsKey) || '';
    var removed = rawIds ? rawIds.split(',').filter(function (value) { return !!value; }) : [];
    return Promise.all([
      rest('DELETE', 'devices?device_uid=eq.' + encodeURIComponent(id)),
      rest('DELETE', 'pairings?device_uid=eq.' + encodeURIComponent(id))
    ]).catch(function () {
      // Device self-unpair is best-effort just like CloudSync.unpair. The panel
      // can revoke the device if the network is down.
      return null;
    }).then(function () {
      return Promise.all([
        userState.remove(profileKey), userState.remove(sourceIdsKey), userState.remove(e2eeMarksKey),
        userState.remove('samsung_playback_sync_v1')
      ]);
    }).then(function () { return {paired:false, removedSourceIds:removed, deviceId:id}; });
  }

  function query(action, args) {
    try { requireReady(); }
    catch (failure) { return Promise.reject(failure); }
    try {
      if (action === 'status' || action === 'pairing.get') return Promise.resolve(status());
      if (action === 'pairing.start') return Promise.resolve(requestPairing(args));
      if (action === 'pairing.status') return Promise.resolve(pairingStatus(args && args.code));
      if (action === 'supporter.status') return Promise.resolve(supporterStatus());
      if (action === 'profiles.list') return Promise.resolve(profilesList());
      if (action === 'profiles.select') return Promise.resolve(selectProfile(args && args.profileId));
      if (action === 'profiles.setPin') return Promise.resolve(setProfilePin(args && args.profileId, args && args.pin));
      if (action === 'pull') return Promise.resolve(pull(args));
      if (action === 'push') return Promise.resolve(push(args));
      if (action === 'push.delta') return Promise.resolve(pushDelta(args));
      if (action === 'push.playback') {
        var playbackProfile=profileId(args),playbackRows=validatePlaybackPositions(args && args.playbackPositions);
        return requirePaired().then(function () {return pushPlaybackPositions(playbackProfile,playbackRows);});
      }
      if (action === 'unpair') return Promise.resolve(unpair());
      return Promise.reject(error('ActionError', 'Unknown cloud sync action.'));
    } catch (failure) {
      return Promise.reject(failure);
    }
  }

  return {
    configured:!configError,
    relayConfigured:!configError && relayConfigured,
    configError:configError ? configError.message : null,
    hasSession:function () { try { return !!loadSession(); } catch (_) { return false; } },
    status:status,
    relayProvider:relayProvider,
    query:query
  };
}));
