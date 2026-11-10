(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroSamsungAvplay = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';

  options = options || {};

  var environment = options.environment || (typeof window !== 'undefined' ? window : null);
  var timerHost = environment || (typeof global !== 'undefined' ? global : null);
  var document = options.document || (environment && environment.document);
  var avplay = options.avplay || (environment && environment.webapis && environment.webapis.avplay);
  var defaultAvplay = avplay, managedNative = false;
  var startTimeoutMs = typeof options.startTimeoutMs === 'number' && options.startTimeoutMs > 0
    ? options.startTimeoutMs
    : 25000;
  var stallTimeoutMs = typeof options.stallTimeoutMs === 'number' && options.stallTimeoutMs > 0
    ? options.stallTimeoutMs : 30000;
  var seekTimeoutMs = typeof options.seekTimeoutMs === 'number' && options.seekTimeoutMs > 0
    ? options.seekTimeoutMs : 10000;
  var now = typeof options.now === 'function' ? options.now : Date.now;
  var sessionGeneration = 0;
  var currentSession = null;
  var pendingOpen = null;
  var nativeOpen = false;
  var nativeObject = null;
  var seekPending = false;
  var seekWaiters = [];
  var pauseIntent = null;
  var stateListener = typeof options.onState === 'function' ? options.onState : null;
  var rectangle = null;
  var domRectangle = null;
  var state = {
    playing: false,
    position: null,
    duration: null,
    buffering: false,
    completed: false,
    error: null,
    nativeState: 'NONE',
    speed: 1,
    displayMode: null,
    bufferPreset: 'default',
    subtitlesEnabled: true
  };
  var subtitleListener = null;
  var displayMode = null;
  var screenSaverDesired = null;
  var screenSaverRequested = null;
  var screenSaverPending = false;
  var screenSaverRequestGeneration = 0;
  var screenSaverAttempts = 0;
  var screenSaverError = null;

  function syncScreenSaver(playing, force) {
    if (screenSaverDesired !== !playing || force) {
      screenSaverDesired = !playing;
      screenSaverAttempts = 0;
    }
    var appcommon = options.appcommon || (environment && environment.webapis && environment.webapis.appcommon);
    if (!appcommon || typeof appcommon.setScreenSaver !== 'function' || !appcommon.AppCommonScreenSaverState ||
        (!force && (screenSaverPending || screenSaverRequested === screenSaverDesired)) || screenSaverAttempts >= 2) return;
    var requested = screenSaverDesired;
    var requestGeneration = ++screenSaverRequestGeneration;
    var values = appcommon.AppCommonScreenSaverState;
    screenSaverRequested = requested;
    screenSaverPending = true;
    screenSaverAttempts += 1;
    var settled = false;
    function complete(failed) {
      if (settled || requestGeneration !== screenSaverRequestGeneration) return;
      settled = true;
      screenSaverPending = false;
      screenSaverError = failed ? { name: 'ScreenSaverError', message: 'Samsung screen protection could not be changed.' } : null;
      if (failed) screenSaverRequested = null;
      // Only the latest request may update status; older callbacks can arrive out of order.
      // A failed change gets one retry on the next player update, never a tight loop.
      if (screenSaverDesired !== requested) syncScreenSaver(!screenSaverDesired);
    }
    try {
      appcommon.setScreenSaver(requested ? values.SCREEN_SAVER_ON : values.SCREEN_SAVER_OFF,
        function () { complete(false); }, function () { complete(true); });
    } catch (_) { complete(true); }
  }

  function makeError(name, message, nativeError) {
    var error = new Error(message);
    error.name = name;
    if (nativeError !== undefined) error.nativeError = nativeError;
    return error;
  }

  function asNativeError(value) {
    if (value instanceof Error) return value;
    var message = '';
    var nativeName = '';
    var nativeCode = '';
    if (value && typeof value === 'object') {
      nativeName = value.name || '';
      nativeCode = value.errorCode || value.errorType || value.code || '';
      message = value.message || value.errorMessage || value.name || value.errorType || value.errorCode || '';
    } else if (value !== undefined && value !== null) {
      message = String(value);
    }
    var error = makeError('NativePlaybackError', message || 'Samsung AVPlay reported an error.', value);
    if (nativeName) error.nativeName = String(nativeName);
    if (nativeCode) error.nativeCode = String(nativeCode);
    return error;
  }

  function cloneState() {
    var error = null;
    if (state.error) {
      error = {
        name: state.error.nativeName || state.error.name || 'Error',
        message: state.error.message || String(state.error)
      };
      if (state.error.nativeCode || state.error.code) error.code = String(state.error.nativeCode || state.error.code);
    }
    return {
      playing: state.playing,
      position: state.position,
      duration: state.duration,
      buffering: state.buffering,
      completed: state.completed,
      error: error,
      nativeState: state.nativeState,
      speed: state.speed,
      displayMode: state.displayMode,
      bufferPreset: state.bufferPreset,
      subtitlesEnabled: state.subtitlesEnabled,
      screenSaverError: screenSaverError
    };
  }

  function publishState(useSnapshot) {
    var snapshot;
    try {
      snapshot = useSnapshot ? cloneState() : getState();
    } catch (_) {
      snapshot = cloneState();
    }
    // Give the video plane back only after native stop/close has completed.
    // Tizen 3 can finish HLS buffering before prepareAsync completes.
    if (currentSession || (!nativeOpen && !managedNative)) syncScreenSaver(!!currentSession && !currentSession.ended && !currentSession.failed &&
      (snapshot.playing || (currentSession.isLiveHls && currentSession.wantsPlayback)));
    if (!stateListener) return;
    try { stateListener(snapshot); } catch (_) { /* Observer errors must not interrupt AVPlay cleanup. */ }
  }

  function hasApi(name) {
    if (!avplay && environment && environment.webapis) avplay = defaultAvplay = environment.webapis.avplay;
    return !!avplay && typeof avplay[name] === 'function';
  }

  function requiredApi(name) {
    if (!hasApi(name)) {
      throw makeError('NotSupportedError', 'Samsung AVPlay does not provide ' + name + '().');
    }
    return avplay[name];
  }

  function validUrl(url) {
    return typeof url === 'string' && /^https?:\/\//i.test(url);
  }

  function normalizeHeaders(headers) {
    var properties = [];
    var seen = {};
    if (headers === undefined || headers === null) return properties;
    if (typeof headers !== 'object' || Object.prototype.toString.call(headers) === '[object Array]' ||
        typeof headers.forEach === 'function' || typeof headers.entries === 'function') {
      throw makeError('TypeError', 'Playback headers must be a plain header map.');
    }

    Object.keys(headers).forEach(function (name) {
      var normalized = String(name).toLowerCase();
      var property;
      if (normalized === 'cookie') property = 'COOKIE';
      else if (normalized === 'user-agent') property = 'USER_AGENT';
      else throw makeError('NotSupportedError', 'Samsung AVPlay cannot set the request header: ' + name);
      if (seen[property]) throw makeError('TypeError', 'Playback header was provided more than once: ' + name);
      if (typeof headers[name] !== 'string') {
        throw makeError('TypeError', 'Playback header values must be strings: ' + name);
      }
      seen[property] = true;
      properties.push({ name: property, value: headers[name] });
    });

    return properties;
  }

  function deferred() {
    var resolve;
    var reject;
    var promise = new Promise(function (resolvePromise, rejectPromise) {
      resolve = resolvePromise;
      reject = rejectPromise;
    });
    return { promise: promise, resolve: resolve, reject: reject, settled: false };
  }

  function resolveDeferred(value) {
    if (value && !value.settled) {
      value.settled = true;
      value.resolve(arguments.length > 1 ? arguments[1] : undefined);
    }
  }

  function rejectDeferred(value, error) {
    if (value && !value.settled) {
      value.settled = true;
      value.reject(error);
    }
  }

  function clearStartTimer(session) {
    if (session && session.timer !== null) {
      if (timerHost && typeof timerHost.clearTimeout === 'function') timerHost.clearTimeout(session.timer);
      session.timer = null;
    }
  }

  function clearStallTimer(session) {
    if (session && session.stallTimer !== null) {
      timerHost.clearTimeout(session.stallTimer);
      session.stallTimer = null;
    }
  }

  function armStallTimer(session) {
    if (!isCurrent(session) || !session.isLive || !session.wantsPlayback || session.ended ||
        session.failed || session.stallTimer !== null || seekPending) return;
    session.stallTimer = timerHost.setTimeout(function () {
      session.stallTimer = null;
      if (!isCurrent(session) || !session.wantsPlayback || session.ended || session.failed || seekPending) return;
      var remaining = stallTimeoutMs - (now() - session.lastProgressAt);
      if (remaining > 0) { armStallTimer(session); return; }
      // A missing time callback alone does not prove a stalled decoder. Inspect
      // the native clock only at the inactivity deadline, not on every tick.
      try {
        if (requiredApi('getState').call(avplay) === 'PAUSED') return;
        var positionMs = Number(requiredApi('getCurrentTime').call(avplay));
        if (isFinite(positionMs) && positionMs >= 0 && session.lastProgressMs !== null && positionMs !== session.lastProgressMs) {
          session.lastProgressMs = positionMs;
          session.lastProgressAt = now();
          armStallTimer(session);
          return;
        }
      } catch (_) { /* A lost native session follows the same bounded recovery. */ }
      recoverStalledSession(session);
    }, Math.max(1, stallTimeoutMs - (now() - session.lastProgressAt)));
    if (session.stallTimer && typeof session.stallTimer.unref === 'function') session.stallTimer.unref();
  }

  function recoverStalledSession(session, lostState) {
    if (!isCurrent(session) || session.recoveryPending) return;
    if (session.recoveryAttempts >= 2) {
      failSession(session, makeError('TimeoutError', 'Samsung AVPlay stopped advancing after two recovery attempts.'));
      return;
    }
    session.recoveryPending = true;
    clearStallTimer(session);
    state.buffering = true;
    state.playing = false;
    publishState(true);
    Promise.resolve().then(function () {
      if (!isCurrent(session) || !session.wantsPlayback || seekPending) { session.recoveryPending = false; return; }
      return typeof options.beforeReconnect === 'function' ? options.beforeReconnect(session.url) : undefined;
    }).then(function () {
      if (!isCurrent(session) || !session.wantsPlayback || seekPending) { session.recoveryPending = false; return; }
      if (!lostState && now() - session.lastProgressAt < stallTimeoutMs) {
        session.recoveryPending = false;
        state.buffering = false;
        publishState();
        armStallTimer(session);
        return;
      }
      var generation = ++sessionGeneration;
      clearStartTimer(session);
      currentSession = null;
      var reopened = deferred();
      // Reconnect is observed through state events; always consume its internal
      // startup rejection so an unavailable stream cannot leak a rejection.
      reopened.promise.catch(function () {});
      pendingOpen = reopened;
      return releaseNative().then(function () {
        start(session.url, session.properties, generation, reopened, true, session.recoveryAttempts + 1, session.bufferPreset);
      }, function (error) {
        if (generation !== sessionGeneration) return;
        pendingOpen = null;
        state.error = asNativeError(error);
        rejectDeferred(reopened, error);
        publishState();
      });
    }).catch(function (error) { if (isCurrent(session) && session.wantsPlayback) failSession(session, error); });
  }

  function rejectPendingOpen(error) {
    var pending = pendingOpen;
    pendingOpen = null;
    if (pending) rejectDeferred(pending, error);
  }

  function runAfterSeek(action) {
    if (!seekPending) {
      try { return Promise.resolve(action()); }
      catch (error) { return Promise.reject(error); }
    }
    return new Promise(function (resolve, reject) {
      seekWaiters.push({ action: action, resolve: resolve, reject: reject });
    });
  }

  function flushSeekWaiters() {
    var waiters = seekWaiters;
    seekWaiters = [];
    waiters.forEach(function (waiter) {
      var result;
      try { result = waiter.action(); }
      catch (error) { waiter.reject(error); return; }
      Promise.resolve(result).then(waiter.resolve, waiter.reject);
    });
  }

  function updateNativeSnapshot() {
    if (!nativeOpen || seekPending || !currentSession) return;
    state.nativeState = requiredApi('getState').call(avplay);
    state.playing = state.nativeState === 'PLAYING' && !currentSession.ended && !currentSession.failed;
    if (state.nativeState === 'READY' || state.nativeState === 'PLAYING' || state.nativeState === 'PAUSED') {
      var positionMs = Number(requiredApi('getCurrentTime').call(avplay));
      var durationMs = Number(requiredApi('getDuration').call(avplay));
      state.position = isFinite(positionMs) && positionMs >= 0 ? positionMs / 1000 : null;
      state.duration = isFinite(durationMs) && durationMs > 0 ? durationMs / 1000 : null;
      if (state.duration !== null && state.position !== null) {
        state.position = currentSession.ended ? state.duration : Math.min(state.position, state.duration);
      }
    }
  }

  function getState() {
    updateNativeSnapshot();
    return cloneState();
  }

  function markOpenStarted(session) {
    if (!isCurrent(session) || !session.started) return;
    clearStartTimer(session);
    if (pendingOpen === session.openDeferred) {
      pendingOpen = null;
      resolveDeferred(session.openDeferred, safeSnapshot());
    }
  }

  function safeSnapshot() {
    try { return getState(); }
    catch (_) { return cloneState(); }
  }

  function isCurrent(session) {
    return !!session && currentSession === session && session.generation === sessionGeneration;
  }

  function applyDisplayArea(mode) {
    if (nativeObject && nativeObject.style && domRectangle) {
      nativeObject.style.left = domRectangle[0] + 'px';
      nativeObject.style.top = domRectangle[1] + 'px';
      nativeObject.style.width = domRectangle[2] + 'px';
      nativeObject.style.height = domRectangle[3] + 'px';
    }
    if (nativeOpen && !seekPending) {
      mode = mode || displayMode;
      // Tizen 3 can render a black subscreen in LETTER_BOX. Keep the user's
      // fullscreen preference; the preview uses the video's DAR/PAR instead.
      if (mode === 'PLAYER_DISPLAY_MODE_LETTER_BOX' && rectangle &&
          (rectangle[0] !== 0 || rectangle[1] !== 0 || rectangle[2] !== 1920 || rectangle[3] !== 1080)) {
        mode = 'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO';
      }
      if (mode) requiredApi('setDisplayMethod').call(avplay, mode);
      if (rectangle) requiredApi('setDisplayRect').apply(avplay, rectangle);
    }
  }

  function restoreDisplayArea(session) {
    if (!isCurrent(session)) return false;
    if (seekPending) return true;
    try { applyDisplayArea(); return true; }
    catch (error) { failSession(session, error); return false; }
  }

  function failSession(session, nativeError) {
    if (!session || session.generation !== sessionGeneration) return;
    var error = asNativeError(nativeError);
    var refusal = /\bHTTP(?:\/\d(?:\.\d)?)?\s*(?:error\s*)?(401|403|429)\b/i.exec(error.message);
    if (refusal && !session.refusalRecorded && typeof options.onProviderRejected === 'function') {
      session.refusalRecorded = true;
      try { options.onProviderRejected(session.url, Number(refusal[1])); } catch (_) {}
    }
    // Some firmware reports the generic onerror before the HTTP onerrormsg.
    if (!isCurrent(session)) return;
    if (!refusal && session.isLive && session.started && session.wantsPlayback && !session.ended &&
        /InvalidStateError|PLAYER_ERROR_INVALID_STATE/i.test([error.name, error.nativeName, error.nativeCode, error.message].join(' '))) {
      recoverStalledSession(session, true);
      return;
    }
    session.failed = true;
    state.completed = false;
    currentSession = null;
    state.error = error;
    state.playing = false;
    state.buffering = false;
    clearStartTimer(session);
    clearStallTimer(session);
    if (pendingOpen === session.openDeferred) {
      pendingOpen = null;
      rejectDeferred(session.openDeferred, error);
    }
    publishState();
    releaseNative().catch(function () { publishState(); });
  }

  function nativeListener(session) {
    return {
      onbufferingstart: function () {
        if (!isCurrent(session)) return;
        session.healthySinceAt = null;
        state.buffering = true;
        publishState();
      },
      onbufferingcomplete: function () {
        if (!isCurrent(session)) return;
        state.buffering = false;
        if (session.started && !restoreDisplayArea(session)) return;
        markOpenStarted(session);
        publishState();
      },
      oncurrentplaytime: function (milliseconds) {
        if (!isCurrent(session)) return;
        if (session.timeSecond === null && !restoreDisplayArea(session)) return;
        var positionMs = Number(milliseconds);
        var observedAt = now();
        if (state.playing && !state.buffering && session.lastProgressMs !== null && positionMs > session.lastProgressMs &&
            observedAt > session.lastProgressAt && observedAt - session.lastProgressAt <= 2000) {
          if (session.healthySinceAt === null) session.healthySinceAt = session.lastProgressAt;
          if (observedAt - session.healthySinceAt >= 30000) session.recoveryAttempts = 0;
        } else session.healthySinceAt = null;
        if (isFinite(positionMs) && positionMs >= 0 && positionMs !== session.lastProgressMs) {
          session.lastProgressMs = positionMs;
          session.lastProgressAt = observedAt;
        }
        if (!seekPending) state.position = isFinite(positionMs) && positionMs >= 0 ? positionMs / 1000 : null;
        markOpenStarted(session);
        var second = state.position === null ? -1 : Math.floor(state.position);
        if (second === session.timeSecond) return;
        var useSnapshot = session.timeSecond !== null && state.playing;
        session.timeSecond = second;
        publishState(useSnapshot);
      },
      onstreamcompleted: function () {
        if (!isCurrent(session) || !session.started || session.failed || session.ended || seekPending) return;
        session.ended = true;
        state.completed = true;
        clearStallTimer(session);
        state.playing = false;
        state.buffering = false;
        if (state.duration > 0) state.position = state.duration;
        markOpenStarted(session);
        publishState();
      },
      onerror: function (nativeError) {
        failSession(session, nativeError);
      },
      onerrormsg: function (nativeError, message) {
        failSession(session, { errorType: nativeError, message: message });
      },
      onevent: function (eventType) {
        if (eventType === 'PLAYER_MSG_RESOLUTION_CHANGED' && isCurrent(session)) restoreDisplayArea(session);
      },
      onsubtitlechange: function (duration, subtitles, type, attributes) {
        if (!isCurrent(session) || !subtitleListener) return;
        var event = {
          durationMs: Number(duration),
          text: subtitles == null ? '' : String(subtitles),
          dataType: String(type) === '0' ? 'text' : String(type) === '1' ? 'image' : 'unknown',
          attributes: normalizeSubtitleAttributes(attributes)
        };
        if (!isFinite(event.durationMs) || event.durationMs < 0) event.durationMs = null;
        try { subtitleListener(event); } catch (_) { /* UI observers must not interrupt playback. */ }
      }
    };
  }

  function finiteNumber(value) {
    var number = Number(value);
    return isFinite(number) ? number : null;
  }

  function normalizeSubtitleAttributes(attributes) {
    if (Object.prototype.toString.call(attributes) !== '[object Array]') return [];
    return attributes.map(function (attribute) {
      if (!attribute || typeof attribute !== 'object') return null;
      return {
        type: attribute.attr_type == null ? null : String(attribute.attr_type),
        startMs: finiteNumber(attribute.start_pos),
        stopMs: finiteNumber(attribute.stop_pos)
      };
    }).filter(function (attribute) { return attribute !== null; });
  }

  function releaseNative() {
    if (!nativeOpen && !managedNative) return Promise.resolve();

    var firstError = null;
    if (nativeOpen) {
      try { requiredApi('setListener').call(avplay, {}); }
      catch (listenerError) { firstError = listenerError; }
      try { requiredApi('stop').call(avplay); }
      // Lost native sessions can already be stopped; close must still succeed.
      catch (stopError) { if (!firstError && stopError.name !== 'InvalidStateError') firstError = stopError; }
    }
    try {
      requiredApi('close').call(avplay);
      nativeOpen = false;
      if (managedNative) { managedNative = false; avplay = defaultAvplay; }
    } catch (closeError) {
      if (!firstError) firstError = closeError;
    }

    if (!nativeOpen && !managedNative) {
      state.nativeState = 'NONE';
      state.playing = false;
      state.position = null;
      state.duration = null;
      state.buffering = false;
      if (nativeObject) nativeObject.hidden = true;
      if (!currentSession) syncScreenSaver(false);
    }
    if (firstError) return Promise.reject(firstError);
    return Promise.resolve();
  }

  function findOrCreateNativeObject() {
    if (!document) return null;
    var object = typeof document.getElementById === 'function'
      ? document.getElementById('native-player')
      : null;
    if (object) return object;
    if (typeof document.createElement !== 'function' || !document.body ||
        typeof document.body.appendChild !== 'function') {
      throw makeError('NotSupportedError', 'The Samsung AVPlay object cannot be attached to the document.');
    }
    object = document.createElement('object');
    object.id = 'native-player';
    object.type = 'application/avplayer';
    object.className = 'native-media';
    object.hidden = true;
    if (typeof object.setAttribute === 'function') object.setAttribute('aria-hidden', 'true');
    document.body.appendChild(object);
    return object;
  }

  function stop() {
    state.completed = false;
    sessionGeneration += 1;
    clearStartTimer(currentSession);
    clearStallTimer(currentSession);
    currentSession = null;
    rejectPendingOpen(makeError('AbortError', 'Playback was stopped before AVPlay started.'));
    state.playing = false;
    state.position = null;
    state.duration = null;
    state.buffering = false;
    state.error = null;
    publishState();
    return runAfterSeek(releaseNative).then(function () {
      publishState();
      return getState();
    }, function (error) {
      state.error = asNativeError(error);
      publishState();
      throw error;
    });
  }

  function start(url, properties, generation, openDeferred, isLive, recoveryAttempts, bufferPreset) {
    if (generation !== sessionGeneration) {
      rejectDeferred(openDeferred, makeError('AbortError', 'Playback was replaced by a newer request.'));
      return;
    }

    var session = {
      url: url,
      properties: properties,
      bufferPreset: bufferPreset || 'default',
      isLive: isLive,
      isLiveHls: isLive && /\.m3u8(?:[?#]|$)/i.test(url),
      recoveryAttempts: recoveryAttempts || 0,
      wantsPlayback: true,
      lastProgressAt: now(),
      lastProgressMs: null,
      healthySinceAt: null,
      stallTimer: null,
      generation: generation,
      openDeferred: openDeferred,
      started: false,
      ended: false,
      failed: false,
      timeSecond: null,
      timer: null
    };
    currentSession = session;
    state.error = null;
    state.buffering = true;
    state.position = null;
    state.duration = null;

    try {
      nativeObject = findOrCreateNativeObject();
      if (nativeObject) nativeObject.hidden = false;
      // Tizen 3 needs screensaver OFF before reopening a live HLS decoder.
      if (session.isLiveHls) syncScreenSaver(true, true);
      avplay = defaultAvplay;
      var store = session.isLiveHls && !options.avplay && environment && environment.webapis && environment.webapis.avplaystore;
      if (store && typeof store.getPlayer === 'function') {
        try { avplay = store.getPlayer(); managedNative = true; }
        catch (allocationError) {
          if (allocationError.name !== 'NotSupportedError') throw allocationError;
        }
      }
      requiredApi('open').call(avplay, url);
      nativeOpen = true;
      requiredApi('setListener').call(avplay, nativeListener(session));
      if (session.bufferPreset === 'stable') {
        // Both values are above Samsung's four-second minimum. Configure only
        // in IDLE; this opt-in policy never changes an active native buffer.
        requiredApi('setBufferingParam').call(avplay, 'PLAYER_BUFFER_FOR_PLAY', 'PLAYER_BUFFER_SIZE_IN_SECOND', 8);
        requiredApi('setBufferingParam').call(avplay, 'PLAYER_BUFFER_FOR_RESUME', 'PLAYER_BUFFER_SIZE_IN_SECOND', 8);
      } else if (isLive && hasApi('setBufferingParam')) {
        // AVPlay defaults to roughly ten seconds before startup. Four is the
        // documented minimum; keep its deeper rebuffer policy unchanged.
        try { avplay.setBufferingParam('PLAYER_BUFFER_FOR_PLAY', 'PLAYER_BUFFER_SIZE_IN_SECOND', 4); }
        catch (_) { /* Older firmware retains its supported native defaults. */ }
      }
      properties.forEach(function (property) {
        // Samsung's enum reference uses USER_AGENT; an example on that page spells it USERAGENT.
        requiredApi('setStreamingProperty').call(avplay, property.name, property.value);
      });
      applyDisplayArea();
      state.speed = 1;
      state.displayMode = displayMode;
      state.bufferPreset = session.bufferPreset;
      state.subtitlesEnabled = true;
      session.timer = timerHost.setTimeout(function () {
        if (!isCurrent(session) || openDeferred.settled) return;
        var timeoutError = makeError('TimeoutError', 'Samsung AVPlay did not report playback start before timeout.');
        state.error = timeoutError;
        state.playing = false;
        state.buffering = false;
        clearStartTimer(session);
        clearStallTimer(session);
        currentSession = null;
        pendingOpen = null;
        rejectDeferred(openDeferred, timeoutError);
        publishState();
        releaseNative().catch(function (releaseError) {
          state.error = asNativeError(releaseError);
          publishState();
        });
      }, startTimeoutMs);
      requiredApi('prepareAsync').call(avplay, function () {
        if (!isCurrent(session)) return;
        try {
          session.started = true;
          // Older decoders can replace their video surface while preparing.
          // Restore both the DOM object and AVPlay area before showing frames.
          applyDisplayArea();
          requiredApi('play').call(avplay);
          session.wantsPlayback = true;
          session.lastProgressAt = now();
          armStallTimer(session);
          applyDisplayArea();
          publishState();
        } catch (error) {
          session.started = false;
          failSession(session, error);
        }
      }, function (error) {
        failSession(session, error);
      });
      publishState();
    } catch (error) {
      state.error = asNativeError(error);
      state.buffering = false;
      clearStartTimer(session);
      clearStallTimer(session);
      currentSession = null;
      if (pendingOpen === openDeferred) pendingOpen = null;
      rejectDeferred(openDeferred, state.error);
      publishState();
      releaseNative().catch(function (releaseError) {
        state.error = asNativeError(releaseError);
        publishState();
      });
    }
  }

  function open(url, requestOptions) {
    state.completed = false;
    if (!validUrl(url)) return Promise.reject(makeError('TypeError', 'Playback URL must use HTTP or HTTPS.'));

    var properties;
    try { properties = normalizeHeaders(requestOptions && requestOptions.headers); }
    catch (error) { return Promise.reject(error); }
    var bufferPreset = requestOptions && requestOptions.bufferPreset || 'default';
    if (bufferPreset !== 'default' && bufferPreset !== 'stable') {
      return Promise.reject(makeError('NotSupportedError', 'Samsung AVPlay buffer preset must be default or stable.'));
    }
    if (bufferPreset !== 'default' && !hasApi('setBufferingParam')) {
      return Promise.reject(makeError('NotSupportedError', 'Samsung AVPlay does not provide buffer configuration.'));
    }

    var generation = ++sessionGeneration;
    clearStartTimer(currentSession);
    clearStallTimer(currentSession);
    currentSession = null;
    rejectPendingOpen(makeError('AbortError', 'Playback was replaced by a newer request.'));
    state.playing = false;
    state.position = null;
    state.duration = null;
    state.buffering = false;
    state.error = null;

    var openDeferred = deferred();
    pendingOpen = openDeferred;
    runAfterSeek(releaseNative).then(function () {
      if (generation !== sessionGeneration) {
        rejectDeferred(openDeferred, makeError('AbortError', 'Playback was replaced by a newer request.'));
        return;
      }
      start(url, properties, generation, openDeferred, !!(requestOptions && requestOptions.isLive), 0, bufferPreset);
    }, function (error) {
      if (pendingOpen === openDeferred) pendingOpen = null;
      state.error = asNativeError(error);
      rejectDeferred(openDeferred, error);
      publishState();
    });
    publishState();
    return openDeferred.promise;
  }

  function playPause() {
    if (seekPending) {
      if (pauseIntent && pauseIntent.generation === sessionGeneration) { pauseIntent.flips++; return pauseIntent.promise; }
      var intent = { generation: sessionGeneration, flips: 1 };
      pauseIntent = intent;
      intent.promise = runAfterSeek(function () {
        if (intent.generation !== sessionGeneration) throw makeError('AbortError', 'Playback was replaced before the control completed.');
        return intent.flips % 2 ? playPause() : getState();
      });
      function clearIntent() { if (pauseIntent === intent) pauseIntent = null; }
      intent.promise.then(clearIntent, clearIntent);
      return intent.promise;
    }
    if (!nativeOpen) return Promise.reject(makeError('InvalidStateError', 'There is no open Samsung AVPlay session.'));

    try {
      var nativeState = requiredApi('getState').call(avplay);
      if (nativeState === 'PLAYING') requiredApi('pause').call(avplay);
      else if (nativeState === 'PAUSED' || nativeState === 'READY') requiredApi('play').call(avplay);
      else return Promise.reject(makeError('InvalidStateError', 'AVPlay cannot toggle playback from ' + nativeState + '.'));
      if (currentSession) {
        currentSession.wantsPlayback = nativeState !== 'PLAYING';
        if (!currentSession.wantsPlayback) state.buffering = false;
        clearStallTimer(currentSession);
        currentSession.lastProgressAt = now();
        armStallTimer(currentSession);
      }
      applyDisplayArea();
      publishState();
      return Promise.resolve(getState());
    } catch (error) {
      state.error = asNativeError(error);
      publishState();
      return Promise.reject(error);
    }
  }

  function seek(seconds) {
    var target = seconds;
    if (typeof target !== 'number' || !isFinite(target) || target < 0) return Promise.reject(makeError('TypeError', 'Seek position must be a non-negative number of seconds.'));
    if (!nativeOpen || !currentSession) return Promise.reject(makeError('InvalidStateError', 'There is no open Samsung AVPlay session.'));
    if (seekPending) return Promise.reject(makeError('InvalidStateError', 'An AVPlay seek is already pending.'));

    var nativeState;
    try { nativeState = requiredApi('getState').call(avplay); }
    catch (error) { return Promise.reject(error); }
    if (nativeState !== 'READY' && nativeState !== 'PLAYING' && nativeState !== 'PAUSED') {
      return Promise.reject(makeError('InvalidStateError', 'AVPlay cannot seek from ' + nativeState + '.'));
    }

    var seekDeferred = deferred();
    // AVPlay rejects the exact start/end on some firmware. Stay within the
    // finite media range even when repeated remote input reaches an edge.
    var positionMs = Math.max(1, Math.round(target * 1000));
    if (state.duration > 0) positionMs = Math.min(positionMs, Math.max(1, Math.floor(state.duration * 1000) - 1));
    target = positionMs / 1000;
    var session = currentSession;
    var finished = false;
    var seekTimer = null;
    seekPending = true;
    clearStallTimer(session);

    function finish(error, timedOut) {
      if (finished) return;
      finished = true;
      if (seekTimer !== null) timerHost.clearTimeout(seekTimer);
      seekPending = false;
      if (!timedOut) {
        try { applyDisplayArea(); } catch (displayError) { if (!error) error = displayError; }
      }
      if (error) {
        var seekError = asNativeError(error);
        // A failed operation can leave the movie playing. Only session
        // failures (including the timeout below) belong in playback state.
        rejectDeferred(seekDeferred, seekError);
      } else {
        state.position = target;
        try { resolveDeferred(seekDeferred, getState()); }
        catch (stateError) { rejectDeferred(seekDeferred, stateError); }
      }
      publishState();
      if (timedOut && isCurrent(session)) failSession(session, error);
      flushSeekWaiters();
      armStallTimer(currentSession);
    }

    try {
      seekTimer = timerHost.setTimeout(function () {
        finish(makeError('TimeoutError', 'Samsung AVPlay did not complete the seek before timeout.'), true);
      }, seekTimeoutMs);
      requiredApi('seekTo').call(avplay, positionMs, function () { finish(null); }, function (error) { finish(error); });
    } catch (error) {
      finish(error);
    }
    return seekDeferred.promise;
  }

  function requireTrackReady() {
    if (!nativeOpen || !currentSession) {
      throw makeError('InvalidStateError', 'There is no open Samsung AVPlay session.');
    }
    if (seekPending) {
      throw makeError('InvalidStateError', 'AVPlay cannot inspect or change tracks while a seek is pending.');
    }
    var nativeState = requiredApi('getState').call(avplay);
    // This adapter uses prepareAsync(); Samsung only documents READY track
    // enumeration for synchronous prepare. Query after actual playback starts.
    if (nativeState !== 'PLAYING' && nativeState !== 'PAUSED') {
      throw makeError('InvalidStateError', 'AVPlay track information is unavailable in ' + nativeState + '.');
    }
    return nativeState;
  }

  function parseExtraInfo(value) {
    if (value == null || value === '') return {};
    if (typeof value === 'object') return value;
    if (typeof value !== 'string') return {};
    try {
      var parsed = JSON.parse(value);
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch (_) {
      return {};
    }
  }

  function normalizeTrack(track, allowInvalidIndex) {
    var index = track && Number(track.index);
    var minimum = allowInvalidIndex ? -1 : 0;
    if (!track || typeof track !== 'object' || typeof track.type !== 'string' ||
        !isFinite(index) || Math.floor(index) !== index || index < minimum) {
      throw makeError('UnknownError', 'Samsung AVPlay returned invalid track information.');
    }
    return {
      type: track.type.toUpperCase(),
      index: index,
      extraInfo: parseExtraInfo(track.extra_info)
    };
  }

  function getTracks() {
    requireTrackReady();
    var total = requiredApi('getTotalTrackInfo').call(avplay);
    var current = requiredApi('getCurrentStreamInfo').call(avplay);
    if (Object.prototype.toString.call(total) !== '[object Array]' ||
        Object.prototype.toString.call(current) !== '[object Array]') {
      throw makeError('UnknownError', 'Samsung AVPlay returned invalid track information.');
    }
    var selected = {};
    current.forEach(function (track) {
      var normalized = normalizeTrack(track, true);
      if (normalized.index >= 0) selected[normalized.type] = normalized.index;
    });
    return total.map(function (track) {
      var normalized = normalizeTrack(track, false);
      normalized.selected = selected[normalized.type] === normalized.index;
      return normalized;
    });
  }

  function selectTrack(type, index) {
    var normalizedType = typeof type === 'string' ? type.toUpperCase() : '';
    if (normalizedType !== 'AUDIO' && normalizedType !== 'TEXT') {
      return Promise.reject(makeError('TypeError', 'Track type must be AUDIO or TEXT.'));
    }
    if (typeof index !== 'number' || !isFinite(index) || Math.floor(index) !== index || index < 0) {
      return Promise.reject(makeError('TypeError', 'Track index must be a non-negative integer.'));
    }
    var tracks;
    try {
      var nativeState = requireTrackReady();
      if (nativeState !== 'PLAYING' && nativeState !== 'PAUSED') {
        throw makeError('InvalidStateError', 'AVPlay track selection requires active playback.');
      }
      tracks = getTracks();
      if (!tracks.some(function (track) { return track.type === normalizedType && track.index === index; })) {
        throw makeError('NotFoundError', 'The requested AVPlay track is unavailable.');
      }
      requiredApi('setSelectTrack').call(avplay, normalizedType, index);
      if (normalizedType === 'TEXT' && !state.subtitlesEnabled) {
        requiredApi('setSilentSubtitle').call(avplay, false);
        state.subtitlesEnabled = true;
      }
      publishState();
      return Promise.resolve(getTracks());
    } catch (error) {
      return Promise.reject(error);
    }
  }

  function setSubtitlesEnabled(enabled) {
    if (typeof enabled !== 'boolean') {
      return Promise.reject(makeError('TypeError', 'Subtitle visibility must be a boolean.'));
    }
    try {
      requireTrackReady();
      requiredApi('setSilentSubtitle').call(avplay, !enabled);
      state.subtitlesEnabled = enabled;
      publishState();
      return Promise.resolve(getState());
    } catch (error) {
      return Promise.reject(error);
    }
  }

  function setSpeed(rate) {
    if (typeof rate !== 'number' || !isFinite(rate)) {
      return Promise.reject(makeError('TypeError', 'Playback speed must be a finite number.'));
    }
    // AVPlay's documented HTTP/HTTPS forward speeds are discrete 1x/2x/4x/8x.
    // Fractional speeds are rejected instead of being rounded or simulated.
    if ([1, 2, 4, 8].indexOf(rate) < 0) {
      return Promise.reject(makeError('NotSupportedError', 'Samsung AVPlay supports only its documented discrete forward rates: 1x, 2x, 4x, and 8x.'));
    }
    try {
      requireTrackReady();
      requiredApi('setSpeed').call(avplay, rate);
      state.speed = rate;
      publishState();
      return Promise.resolve(getState());
    } catch (error) {
      return Promise.reject(error);
    }
  }

  function setDisplayMode(mode) {
    var modes = [
      'PLAYER_DISPLAY_MODE_LETTER_BOX',
      'PLAYER_DISPLAY_MODE_FULL_SCREEN',
      'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO'
    ];
    if (modes.indexOf(mode) < 0) {
      return Promise.reject(makeError('NotSupportedError', 'Samsung AVPlay display mode is unsupported.'));
    }
    if (!hasApi('setDisplayMethod')) {
      return Promise.reject(makeError('NotSupportedError', 'Samsung AVPlay does not provide setDisplayMethod().'));
    }
    if (seekPending) {
      return Promise.reject(makeError('InvalidStateError', 'AVPlay cannot change display mode while a seek is pending.'));
    }
    if (!nativeOpen || !currentSession) {
      displayMode = mode;
      state.displayMode = mode;
      return Promise.resolve(mode);
    }
    try {
      applyDisplayArea(mode);
      displayMode = mode;
      state.displayMode = mode;
      publishState();
      return Promise.resolve(mode);
    } catch (error) {
      return Promise.reject(error);
    }
  }

  function getCapabilities() {
    return {
      tracks: hasApi('getTotalTrackInfo') && hasApi('getCurrentStreamInfo'),
      audioTrackSelection: hasApi('setSelectTrack'),
      subtitleTrackSelection: hasApi('setSelectTrack'),
      subtitleVisibility: hasApi('setSilentSubtitle'),
      subtitleEvents: hasApi('setListener'),
      playbackSpeeds: hasApi('setSpeed') ? [1, 2, 4, 8] : [],
      bufferPresets: hasApi('setBufferingParam') ? ['default', 'stable'] : ['default'],
      qualitySelection: false,
      refreshRateMatching: false,
      pictureInPicture: false,
      recording: false,
      timeshift: false,
      displayModes: hasApi('setDisplayMethod') ? [
        'PLAYER_DISPLAY_MODE_LETTER_BOX',
        'PLAYER_DISPLAY_MODE_FULL_SCREEN',
        'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO'
      ] : []
    };
  }

  function onSubtitle(callback) {
    if (callback !== null && typeof callback !== 'function') {
      throw makeError('TypeError', 'onSubtitle expects a function or null.');
    }
    subtitleListener = callback;
  }

  function setRect(x, y, width, height) {
    var values = [x, y, width, height];
    var rect = [];
    values.forEach(function (value) {
      if (typeof value !== 'number' || !isFinite(value)) {
        throw makeError('TypeError', 'AVPlay display rectangle values must be finite numbers.');
      }
      rect.push(Math.round(value));
    });
    if (rect[0] < 0 || rect[1] < 0 || rect[2] <= 0 || rect[3] <= 0) {
      throw makeError('RangeError', 'AVPlay display rectangle must have non-negative origin and positive size.');
    }
    // AVPlay always uses a 1920x1080 coordinate space, including a 1280x720
    // application viewport. The DOM object itself retains CSS coordinates.
    var viewportWidth = environment && environment.innerWidth || 1920;
    var viewportHeight = environment && environment.innerHeight || 1080;
    domRectangle = rect.slice();
    rectangle = [Math.round(rect[0] * 1920 / viewportWidth), Math.round(rect[1] * 1080 / viewportHeight),
      Math.round(rect[2] * 1920 / viewportWidth), Math.round(rect[3] * 1080 / viewportHeight)];
    applyDisplayArea();
    publishState();
    return rectangle.slice();
  }

  function onState(callback) {
    if (callback !== null && typeof callback !== 'function') {
      throw makeError('TypeError', 'onState expects a function or null.');
    }
    stateListener = callback;
    if (stateListener) publishState();
  }

  return {
    open: open,
    stop: stop,
    playPause: playPause,
    seek: seek,
    getTracks: getTracks,
    selectTrack: selectTrack,
    setSubtitlesEnabled: setSubtitlesEnabled,
    setSpeed: setSpeed,
    setDisplayMode: setDisplayMode,
    getCapabilities: getCapabilities,
    onSubtitle: onSubtitle,
    getState: getState,
    setRect: setRect,
    onState: onState
  };
}));
