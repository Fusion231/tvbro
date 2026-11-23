(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = { create: factory };
  if (root) root.TVBroSamsungTransport = { create: factory };
}(typeof window !== 'undefined' ? window : this, function (environment, options) {
  'use strict';
  var pending = [];
  options = options || {};
  var relay = options.relay, generation = 0, agentDirty = false;
  var core = options.core || environment.TVBroCanonical, userState = options.userState;
  var gateReady = null, cooldownKey = 'provider_cooldowns_v1';
  var requiresHttpsProvider = options.requiresHttpsProvider === true;
  var hostedHttpMessage = 'This provider uses HTTP. This TV version needs HTTPS. Ask your provider for an HTTPS address or use TVBro on Android, Windows or Samsung.';
  var agentTail = Promise.resolve();
  var originalAgent = environment.navigator && environment.navigator.userAgent;
  var privileged = environment.TVBroSamsungNativeHttp;
  var epgFiles = options.epgFiles || (environment.TVBroSamsungEpgFiles && environment.TVBroSamsungEpgFiles.create({environment:environment}));
  function hasDiskGuides() { return !!(epgFiles && epgFiles.available()); }
  function result(errorKind, error) { return JSON.stringify({ errorKind: errorKind, error: error }); }
  function ready() {
    if (!gateReady) gateReady = Promise.resolve().then(function () {
      if (!core || typeof core.providerGateInit !== 'function' || typeof core.providerGateRun !== 'function' ||
          typeof core.providerGateRecord !== 'function' || typeof core.providerGateMerge !== 'function' ||
          !userState || typeof userState.get !== 'function' || typeof userState.set !== 'function') {
        throw new Error('Kanoniczna ochrona zapytań dostawcy jest niedostępna.');
      }
      return core.providerGateInit(userState.get(cooldownKey) || '{}', function (snapshot) {
        return userState.set(cooldownKey, snapshot).then(function () { return 'null'; });
      });
    });
    return gateReady;
  }
  function recordResponse(request, response) {
    if (!response || typeof response.status !== 'number' || response.status <= 0) return;
    var headers = response.headers || {}, retryAfter = '';
    Object.keys(headers).some(function (name) {
      if (name.toLowerCase() !== 'retry-after') return false;
      retryAfter = String(headers[name]); return true;
    });
    core.providerGateRecord(request.url, response.status, retryAfter, request.pauseOnAuthenticationFailure !== false);
    if (response.url && response.url !== request.url) {
      core.providerGateRecord(response.url, response.status, retryAfter, request.pauseOnAuthenticationFailure !== false);
    }
  }
  function setAgent(value) {
    return new Promise(function (resolve, reject) {
      var setting = environment.tizen && environment.tizen.websetting;
      if (!setting || typeof setting.setUserAgentString !== 'function') {
        reject(new Error('Ten telewizor nie udostępnia własnego User-Agent dla zapytań.')); return;
      }
      try { setting.setUserAgentString(value, resolve, reject); } catch (error) { reject(error); }
    });
  }
  function canStreamPlaylist() {
    return typeof environment.fetch === 'function' && typeof environment.AbortController === 'function' &&
      typeof environment.Response === 'function' && 'body' in environment.Response.prototype;
  }
  function reportDownload(entry, status) {
    if (entry.importProgress && typeof status === 'number' && status >= 200 && status < 300) {
      entry.importProgress('downloading');
    }
  }
  function fetchPlaylist(request, entry) {
    return new Promise(function (resolve) {
      var controller = new environment.AbortController(), timer, ended = false, failure = null;
      var headers = {}, reader, response;
      function finish(value, reason) {
        if (ended) return;
        ended = true; failure = reason;
        clearTimeout(timer); entry.cancelNative = null;
        if (reason || !reader) controller.abort();
        resolve(value);
      }
      function fail(name, message) {
        var reason = new Error(message); reason.name = name;
        finish(result(name === 'AbortError' ? 'cancelled' : 'network', message), reason);
      }
      function idle() {
        timer = setTimeout(function () { fail('TimeoutError', 'Przekroczono czas oczekiwania.'); }, request.idleTimeoutMs || 20000);
      }
      entry.cancelNative = function () { fail('AbortError', 'Zapytanie zostało anulowane.'); };
      Object.keys(request.headers || {}).forEach(function (name) {
        if (name.toLowerCase() !== 'user-agent') headers[name] = request.headers[name];
      });
      idle();
      Promise.resolve().then(function () {
        if (ended) return;
        if (entry.importProgress) entry.importProgress('waiting');
        if (ended) return;
        return environment.fetch(request.url, {method:request.method || 'GET',headers:headers,
          body:request.body == null ? undefined : request.body,signal:controller.signal});
      }).then(function (incoming) {
        if (ended) return;
        clearTimeout(timer);
        var receivedHeaders = {};
        incoming.headers.forEach(function (value, name) { receivedHeaders[name] = value; });
        response = {status:incoming.status,headers:receivedHeaders,url:incoming.url || request.url,decoded:true};
        recordResponse(request, response);
        if (!incoming.ok || !incoming.body) { finish(JSON.stringify(response)); return; }
        reportDownload(entry, response.status);
        if (ended) return;
        reader = incoming.body.getReader();
        var metadata = JSON.stringify(response);
        response.bodyStream = {
          next: function () {
            if (ended) return failure ? Promise.reject(failure) : Promise.resolve(null);
            idle();
            return reader.read().then(function (chunk) {
              clearTimeout(timer);
              if (failure) throw failure;
              if (chunk.done) { finish(metadata); return null; }
              return chunk.value;
            }, function () {
              fail('NetworkError', 'Połączenie z dostawcą nie powiodło się.');
              throw failure;
            });
          },
          close: entry.cancelNative
        };
        // Keep the provider gate occupied until the consumer closes the body.
        entry.deliver(response);
      }).catch(function () { fail('NetworkError', 'Połączenie z dostawcą nie powiodło się.'); });
    });
  }
  function physical(request, entry, binaryResponse, headersOnlyMethod) {
    if (requiresHttpsProvider && typeof request.url === 'string' && /^http:/i.test(request.url)) {
      return Promise.resolve(result('hosted-http-blocked', hostedHttpMessage));
    }
    var playlistBlob = binaryResponse && request.workload === 'playlist';
    var streamPlaylist = playlistBlob && request.streamPlaylist === true;
    if (streamPlaylist && canStreamPlaylist()) return fetchPlaylist(request, entry);
    return new Promise(function (resolve) {
      var xhr = new environment.XMLHttpRequest();
      var timer = null, finished = false, headersRecorded = false;
      entry.xhr = xhr;
      function finish(value) {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        if (entry.xhr === xhr) entry.xhr = null;
        resolve(binaryResponse && value && (value.bodyBuffer || value.bodyBlob) ? value : typeof value === 'string' ? value : JSON.stringify(value));
      }
      function idle() {
        clearTimeout(timer);
        timer = setTimeout(function () { finish(result('network', 'Przekroczono czas oczekiwania.')); xhr.abort(); }, request.idleTimeoutMs || 20000);
      }
      try {
        xhr.open(headersOnlyMethod || request.method || 'GET', request.url, true);
        // XMLTV may be a gzip file without HTTP Content-Encoding. responseText
        // irreversibly replaces binary bytes before the canonical gzip parser.
        if (request.workload === 'epg' && !headersOnlyMethod) xhr.responseType = 'arraybuffer';
        if (playlistBlob) xhr.responseType = 'blob';
        xhr.timeout = streamPlaylist ? 0 : Math.max(1, request.totalTimeoutMs || 60000);
        Object.keys(request.headers || {}).forEach(function (name) {
          if (name.toLowerCase() !== 'user-agent') xhr.setRequestHeader(name, request.headers[name]);
        });
      } catch (_) { finish(result('capability', 'Telewizor nie może wysłać wymaganych nagłówków.')); return; }
      xhr.onreadystatechange = function () {
        if (xhr.readyState !== 2 || finished || headersRecorded) return;
        try {
          if (xhr.status > 0) {
            if (streamPlaylist) idle();
            recordResponse(request, { status: xhr.status, url: xhr.responseURL || request.url,
              headers: { 'retry-after': xhr.getResponseHeader('Retry-After') || '' } });
            headersRecorded = true;
            if (xhr.status >= 200 && xhr.status < 300) {
              var lengthHeader = xhr.getResponseHeader('Content-Length');
              var encoding = xhr.getResponseHeader('Content-Encoding');
              var advertised = typeof lengthHeader === 'string' && /^\s*[0-9]+\s*$/.test(lengthHeader) ? Number(lengthHeader) : 0;
              var bodyLimit = Number(request.maximumBodyBytes), decodedLimit = Number(request.maximumDecodedBytes);
              // Content-Length describes transferred bytes. A compressed length
              // cannot be compared with the decoded ceiling; progress/load still
              // enforce that ceiling once XHR has decoded the response.
              if (isFinite(advertised) && advertised > 0 &&
                  (isFinite(bodyLimit) && bodyLimit > 0 && advertised > bodyLimit ||
                   (!encoding || /^\s*identity\s*$/i.test(encoding)) && isFinite(decodedLimit) && decodedLimit > 0 && advertised > decodedLimit)) {
                finish(result('limit', 'Odpowiedź przekracza limit TVBro.')); xhr.abort();
              } else if (!headersOnlyMethod) reportDownload(entry, xhr.status);
            }
            if (headersOnlyMethod && !finished) {
              var responseHeaders = {};
              if (typeof xhr.getAllResponseHeaders === 'function') xhr.getAllResponseHeaders().split(/\r?\n/).forEach(function (line) {
                var separator = line.indexOf(':');
                if (separator > 0) responseHeaders[line.slice(0,separator).toLowerCase()] = line.slice(separator+1).trim();
              });
              finish({status:xhr.status,headers:responseHeaders,url:xhr.responseURL || request.url}); xhr.abort();
            }
          }
        } catch (_) {}
      };
      xhr.onprogress = function (event) {
        idle();
        if (event.loaded > request.maximumDecodedBytes || playlistBlob && event.loaded > request.maximumBodyBytes) {
          finish(result('limit', 'Odpowiedź przekracza limit TVBro.')); xhr.abort();
        }
      };
      xhr.onload = function () {
        if (finished) return;
        var bytes = request.workload === 'epg' ? new Uint8Array(xhr.response || new ArrayBuffer(0)) : null;
        var blob = playlistBlob ? xhr.response : null;
        var body = bytes || playlistBlob ? null : xhr.responseText || '';
        var size = playlistBlob ? blob && blob.size || 0 : bytes ? bytes.length : environment.Blob ? new environment.Blob([body]).size : body.length;
        if (size > request.maximumDecodedBytes || playlistBlob && size > request.maximumBodyBytes) {
          finish(result('limit', 'Odpowiedź przekracza limit TVBro.')); return;
        }
        var headers = {};
        if (typeof xhr.getAllResponseHeaders === 'function') {
          xhr.getAllResponseHeaders().split(/\r?\n/).forEach(function (line) {
            var separator = line.indexOf(':');
            if (separator > 0) headers[line.slice(0, separator).toLowerCase()] = line.slice(separator + 1).trim();
          });
        }
        var response = { status: xhr.status, body: body, headers: headers, url: xhr.responseURL || request.url, decoded: true };
        if (blob) { response.bodyBlob = blob; delete response.body; }
        if (bytes) {
          if (binaryResponse) response.bodyBuffer = bytes.buffer;
          else {
            var chunks = [];
            for (var offset = 0; offset < bytes.length; offset += 8192) {
              chunks.push(String.fromCharCode.apply(null, bytes.subarray(offset, offset + 8192)));
            }
            response.bodyBase64 = environment.btoa(chunks.join(''));
          }
          delete response.body;
        }
        try { if (!headersRecorded) recordResponse(request, response); }
        catch (_) { finish(result('capability', 'Nie można zapisać odmowy dostawcy.')); return; }
        if (!headersOnlyMethod) reportDownload(entry, response.status);
        finish(response);
      };
      xhr.onerror = function () { finish(result('network', 'Połączenie z dostawcą nie powiodło się.')); };
      xhr.ontimeout = function () { finish(result('network', 'Przekroczono czas oczekiwania.')); };
      xhr.onabort = function () { finish(result('network', 'Zapytanie zostało anulowane.')); };
      if (entry.importProgress) entry.importProgress('waiting');
      if (entry.done) return;
      idle();
      try { if (request.body == null) xhr.send(); else xhr.send(request.body); }
      catch (_) { finish(result('network', 'Nie można połączyć się z dostawcą.')); }
    });
  }
  function request(raw, responseOptions) {
    var input = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (input.epgFile) return Promise.resolve().then(function () {
      if (!hasDiskGuides()) return result('capability', 'Pliki programu TV są niedostępne.');
      return epgFiles.query(input.epgFile);
    }).then(function (value) {
      if (value && value.bodyBuffer && responseOptions && responseOptions.binaryResponse) return value;
      return typeof value === 'string' ? value : JSON.stringify(value);
    }).catch(function () { return result('network', 'Nie można odczytać pliku programu TV.'); });
    var diskMode = input.workload === 'epg' && input.epgDiskKey != null;
    if (diskMode && (!hasDiskGuides() || typeof input.epgDiskKey !== 'string' || !/^[a-f0-9]{64}$/.test(input.epgDiskKey))) {
      return Promise.resolve(result('capability', 'Dysk programu TV jest niedostępny.'));
    }
    var binaryResponse = !!(responseOptions && responseOptions.binaryResponse && (input.workload === 'epg' || input.workload === 'playlist'));
    var expected = generation, timeoutMs = Number(input.totalTimeoutMs);
    if (!isFinite(timeoutMs)) timeoutMs = 60000;
    var deadline = Date.now() + timeoutMs, resolveResult;
    var response = new Promise(function (resolve) { resolveResult = resolve; });
    var streamPlaylist = binaryResponse && input.workload === 'playlist' && input.streamPlaylist === true;
    var entry = { done: false, xhr: null, timer: null, cancel: null, deliver: resolveResult };
    var cancellation = new Promise(function (resolve) { entry.cancel = resolve; });
    function isCurrent() { return !entry.done && expected === generation && (entry.transferring || Date.now() < deadline); }
    var onImportProgress = responseOptions && responseOptions.onImportProgress, importStage;
    if (input.importProgress === true && typeof onImportProgress === 'function') {
      entry.importProgress = function (stage) {
        if (!isCurrent() || stage === importStage || (stage === 'waiting' && importStage)) return;
        importStage = stage;
        try { onImportProgress(stage); } catch (_) {}
      };
    }
    function inactive() {
      return !entry.transferring && Date.now() >= deadline
        ? result('network', 'Przekroczono czas oczekiwania.')
        : result('cancelled', 'Zapytanie anulowano.');
    }
    function finish(value) {
      if (entry.done) return;
      entry.done = true; clearTimeout(entry.timer);
      var index = pending.indexOf(entry);
      if (index >= 0) pending.splice(index, 1);
      resolveResult(value);
    }
    function cancel() {
      entry.cancel(); finish(inactive());
      try { if (entry.xhr) entry.xhr.abort(); } catch (_) {}
      try { if (entry.cancelNative) entry.cancelNative(); } catch (_) {}
    }
    entry.stop = cancel;
    pending.push(entry);
    entry.timer = setTimeout(cancel, Math.max(1, deadline - Date.now()));
    function gated(perform) {
      return ready().then(function () {
        if (!isCurrent()) return inactive();
        var remaining = {};
        Object.keys(input).forEach(function (key) { if (key !== 'importProgress') remaining[key] = input[key]; });
        remaining.totalTimeoutMs = Math.max(1, deadline - Date.now());
        var binaryValue = null, metadata = null;
        return core.providerGateRun(JSON.stringify(remaining), function () {
          if (!isCurrent()) return Promise.resolve(inactive());
          remaining.totalTimeoutMs = Math.max(1, deadline - Date.now());
          return Promise.resolve(perform(remaining)).then(function (value) {
            if (!binaryResponse || !value || !(value.bodyBuffer || value.bodyBlob)) return value;
            binaryValue = value;
            metadata = JSON.stringify({status:value.status,headers:value.headers,url:value.url,decoded:value.decoded});
            return metadata;
          });
        }, isCurrent, cancellation).then(function (value) {
          if (!binaryValue || value !== metadata) return value;
          return isCurrent() ? binaryValue : inactive();
        });
      });
    }
    function delegated(perform) {
      return gated(function (descriptor) {
        return Promise.resolve().then(function () {
          if (entry.importProgress) entry.importProgress('waiting');
          if (!isCurrent()) return inactive();
          return perform(descriptor);
        }).then(function (value) {
          var providerResponse = typeof value === 'string' ? JSON.parse(value) : value;
          recordResponse(descriptor, providerResponse);
          if (!diskMode && providerResponse) reportDownload(entry, providerResponse.status);
          if (!isCurrent()) return inactive();
          return typeof value === 'string' ? value : JSON.stringify(value);
        });
      });
    }
    var names = Object.keys(input.headers || {});
    var forbidden = names.some(function (name) { return /^(cookie|referer|origin|host)$/i.test(name); });
    var agentName = names.filter(function (name) { return name.toLowerCase() === 'user-agent'; })[0];
    var agent = agentName && input.headers[agentName];
    var setting = environment.tizen && environment.tizen.websetting;
    var operation;
    if (input.workload === 'metadata-json' && epgFiles && typeof epgFiles.requestMetadata === 'function') {
      operation = delegated(function (descriptor) { return epgFiles.requestMetadata(descriptor); });
    } else if (!streamPlaylist && privileged && typeof privileged.request === 'function') {
      operation = delegated(function (descriptor) { return privileged.request(JSON.stringify(descriptor)); });
    } else if ((forbidden || (agent && !(setting && typeof setting.setUserAgentString === 'function'))) && relay && relay.relayConfigured && input.workload === 'stalker-json') {
      operation = delegated(function (descriptor) { return relay.relayProvider(descriptor); });
    } else if (forbidden) {
      operation = Promise.resolve(result('capability', 'Portal wymaga transportu nagłówków niedostępnego w przeglądarce TV.'));
    } else {
      // The WebSetting user agent is application-wide. Serialize every physical
      // GET so another source cannot inherit a previous source's custom agent.
      operation = agentTail.then(function () {
        if (!isCurrent()) return inactive();
        var clean = agentDirty ? setAgent(originalAgent || '').then(function () { agentDirty = false; }) : Promise.resolve();
        function sendPhysical() {
          return gated(function (descriptor) {
            if (streamPlaylist) {
              entry.transferring = true;
              clearTimeout(entry.timer);
            }
            return physical(descriptor, entry, binaryResponse, diskMode ? 'HEAD' : null);
          }).then(function (value) {
            var inspected = diskMode && typeof value === 'string' ? JSON.parse(value) : value;
            if (diskMode && inspected && (inspected.status === 405 || inspected.status === 501)) {
              return gated(function (descriptor) { return physical(descriptor, entry, false, 'GET'); });
            }
            return value;
          });
        }
        return clean.then(function () {
          if (!isCurrent()) return inactive();
          if (!agent) return sendPhysical();
          return setAgent(agent).then(function () {
            agentDirty = true;
            return isCurrent() ? sendPhysical() : inactive();
          }).then(function (value) {
            return setAgent(originalAgent || '').then(function () { agentDirty = false; return value; });
          }, function (failure) {
            return setAgent(originalAgent || '').then(function () { agentDirty = false; throw failure; });
          });
        });
      });
      agentTail = operation.then(function () {}, function () {});
    }
    if (diskMode) operation = operation.then(function (value) {
      var inspected = typeof value === 'string' ? JSON.parse(value) : value;
      if (!isCurrent() || !inspected || inspected.status !== 200) return value;
      return gated(function (descriptor) {
        reportDownload(entry, inspected.status);
        if (!isCurrent()) return inactive();
        return epgFiles.download(descriptor, entry, input.epgDiskKey).then(function (file) {
          return JSON.stringify({status:200,headers:inspected.headers || {},url:inspected.url || input.url,decoded:true,bodyFile:file});
        }, function (failure) {
          if (failure && [401,403,429].indexOf(failure.status) >= 0) {
            var refusal = {status:failure.status,headers:failure.retryAfter ? {'retry-after':failure.retryAfter} : {},url:input.url}; recordResponse(input, refusal); return JSON.stringify(refusal);
          }
          return result(failure && failure.name === 'QuotaExceededError' ? 'limit' : failure && failure.name === 'AbortError' ? 'cancelled' : 'network', 'Pobieranie programu TV na dysk nie powiodło się.');
        });
      });
    });
    operation.then(finish, function () { finish(result('capability', 'Nie można wykonać chronionego zapytania dostawcy.')); });
    return response;
  }
  return {
    request: request,
    hasDiskGuides: hasDiskGuides,
    checkStream: function (url) { return ready().then(function () {
      var rejection = JSON.parse(core.providerGateCheck(url));
      if (rejection) throw new Error('HTTP ' + rejection.status + ' — ' + rejection.retryAt);
    }); },
    recordStreamRefusal: function (url, status) {
      core.providerGateRecord(url, status, '', true);
    },
    mergeCooldowns: function (snapshot) { return ready().then(function () { return core.providerGateMerge(snapshot); }); },
    abort: function () { ++generation; pending.slice().forEach(function (entry) { entry.stop(); }); if (epgFiles) epgFiles.abort(); },
    capabilities: function () { return {
      cookies: !!(privileged && privileged.request) || !!(relay && relay.relayConfigured),
      userAgent: !!(privileged && privileged.request) || !!(environment.tizen && environment.tizen.websetting)
    }; }
  };
}));
