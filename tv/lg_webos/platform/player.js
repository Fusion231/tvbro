(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroLgWebosPlayer = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';

  options = options || {};

  var platformName = options.platformName || 'webOS';
  var environment = options.environment || (typeof window !== 'undefined' ? window : null);
  var document = options.document || (environment && environment.document);
  var timerHost = options.timerHost || environment || (typeof global !== 'undefined' ? global : null);
  var startTimeoutMs = typeof options.startTimeoutMs === 'number' && options.startTimeoutMs > 0
    ? options.startTimeoutMs : 25000;
  var seekTimeoutMs = typeof options.seekTimeoutMs === 'number' && options.seekTimeoutMs > 0
    ? options.seekTimeoutMs : 10000;
  var stallTimeoutMs = typeof options.stallTimeoutMs === 'number' && options.stallTimeoutMs > 0
    ? options.stallTimeoutMs : 30000;
  var now = typeof options.now === 'function' ? options.now : Date.now;
  var video = options.video || null;
  var videoConfigured = false;
  var sessionGeneration = 0;
  var currentSession = null;
  var pendingOpen = null;
  var pendingSeek = null;
  var rectangle = null;
  var displayMode = null;
  var subtitleListener = null;
  var selectedSubtitleIndex = null;
  var stateListener = typeof options.onState === 'function' ? options.onState : null;
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

  function makeError(name, message, nativeError) {
    var error = new Error(message.replace(/webOS/gi, platformName));
    error.name = name;
    if (nativeError !== undefined) error.nativeError = nativeError;
    return error;
  }

  function asPlaybackError(value) {
    if (value instanceof Error) return value;
    var mediaError = value && value.target && value.target.error || value;
    var code = mediaError && typeof mediaError.code === 'number' ? mediaError.code : 0;
    var names = { 1: 'AbortError', 2: 'NetworkError', 3: 'DecodeError', 4: 'NotSupportedError' };
    var message = mediaError && (mediaError.message || mediaError.errorMessage);
    var error = makeError(names[code] || 'PlaybackError', message || 'The webOS video element could not play this stream.', mediaError);
    if (code) error.code = code;
    return error;
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

  function resolveDeferred(value, result) {
    if (!value || value.settled) return;
    value.settled = true;
    value.resolve(result);
  }

  function rejectDeferred(value, error) {
    if (!value || value.settled) return;
    value.settled = true;
    value.reject(error);
  }

  function clearTimer(timer) {
    if (timer !== null && timer !== undefined && timerHost && typeof timerHost.clearTimeout === 'function') {
      try { timerHost.clearTimeout(timer); } catch (_) {}
    }
  }

  function numberOrNull(value, positiveOnly) {
    var number = Number(value);
    if (!isFinite(number) || number < 0 || positiveOnly && number <= 0) return null;
    return number;
  }

  function cloneError(error) {
    if (!error) return null;
    var result = {
      name: error.name || 'Error',
      message: error.message || String(error)
    };
    if (error.code !== undefined && error.code !== null) result.code = error.code;
    return result;
  }

  function updateSnapshot() {
    if (!currentSession || !video) return;
    try {
      state.position = numberOrNull(video.currentTime, false);
      state.duration = numberOrNull(video.duration, true);
    } catch (_) {
      state.position = null;
      state.duration = null;
    }
    if (video.ended || state.completed) {
      state.nativeState = 'ENDED';
      state.playing = false;
      state.buffering = false;
    } else if (video.paused === true) {
      state.nativeState = video.readyState > 0 ? 'PAUSED' : 'CONNECTING';
      state.playing = false;
    } else if (state.buffering) {
      state.nativeState = 'BUFFERING';
      state.playing = false;
    } else if (typeof video.readyState === 'number' && video.readyState < 3) {
      state.nativeState = 'BUFFERING';
      state.playing = false;
    } else {
      state.nativeState = 'PLAYING';
      if (typeof video.readyState === 'number' && video.readyState >= 3) state.playing = true;
    }
  }

  function getStateWithoutVideo() {
    return {
      playing: state.playing,
      position: state.position,
      duration: state.duration,
      buffering: state.buffering,
      completed: state.completed,
      error: cloneError(state.error),
      nativeState: state.nativeState,
      speed: state.speed,
      displayMode: state.displayMode,
      bufferPreset: state.bufferPreset,
      subtitlesEnabled: state.subtitlesEnabled
    };
  }

  function getState() {
    updateSnapshot();
    return getStateWithoutVideo();
  }

  function publishState() {
    if (!stateListener) return;
    var snapshot;
    try { snapshot = getState(); }
    catch (_) { snapshot = getStateWithoutVideo(); }
    try { stateListener(snapshot); } catch (_) { /* Observers must not interrupt media cleanup. */ }
  }

  function configureVideo(element) {
    if (!element || videoConfigured && element === video) return;
    if (!element.style) throw makeError('NotSupportedError', 'The webOS video element has no style object.');
    element.autoplay = false;
    element.controls = false;
    element.preload = 'none';
    element.loop = false;
    element.playsInline = true;
    element.hidden = true;
    element.style.position = 'absolute';
    element.style.left = '0px';
    element.style.top = '0px';
    element.style.width = '100%';
    element.style.height = '100%';
    element.style.zIndex = '0';
    element.style.backgroundColor = 'black';
    element.style.visibility = 'hidden';
    if (typeof element.setAttribute === 'function') {
      element.setAttribute('aria-hidden', 'true');
      element.setAttribute('playsinline', '');
      element.setAttribute('webkit-playsinline', '');
    }
    if (!rectangle) rectangle = [0, 0, environment && environment.innerWidth || 1920, environment && environment.innerHeight || 1080];
    if (!videoConfigured || element !== video) applyRectangle(element);
    videoConfigured = true;
  }

  function ensureVideo() {
    if (video) {
      configureVideo(video);
      return video;
    }
    if (!document || typeof document.createElement !== 'function') return null;
    if (typeof document.getElementById === 'function') video = document.getElementById('native-player');
    if (!video) {
      if (!document.body || typeof document.body.appendChild !== 'function') return null;
      video = document.createElement('video');
      video.id = 'native-player';
      video.className = 'native-media';
      document.body.appendChild(video);
    }
    configureVideo(video);
    return video;
  }

  function currentVideo() {
    try { return video || ensureVideo(); }
    catch (_) { return video; }
  }

  function validUrl(url) {
    return typeof url === 'string' && /^https?:\/\//i.test(url);
  }

  function validateHeaders(headers, headerPolicy, isLive) {
    if (headers === undefined || headers === null) return;
    if (typeof headers !== 'object' || Object.prototype.toString.call(headers) === '[object Array]' ||
        typeof headers.forEach === 'function' || typeof headers.entries === 'function') {
      throw makeError('TypeError', 'Playback headers must be a plain header map.');
    }
    var names = Object.keys(headers);
    if (!names.length) return;
    if (headerPolicy === 'xtream-vod-default' && isLive === false && names.length === 1 &&
        names[0].toLowerCase() === 'user-agent' && headers[names[0]] === 'VLC/3.0.20 LibVLC/3.0.20') return;
    throw makeError('NotSupportedError', 'HTML5 video on webOS cannot set custom playback request headers: ' + names[0]);
  }

  function supportsEventTarget(target) {
    return !!target && typeof target.addEventListener === 'function' && typeof target.removeEventListener === 'function';
  }

  function hasObjectFit(element) {
    var style = element && element.style;
    return !!style && ('objectFit' in style || 'webkitObjectFit' in style);
  }

  function applyRectangle(element) {
    element = element || video;
    if (!element || !element.style || !rectangle) return;
    element.style.position = 'absolute';
    element.style.left = rectangle[0] + 'px';
    element.style.top = rectangle[1] + 'px';
    element.style.width = rectangle[2] + 'px';
    element.style.height = rectangle[3] + 'px';
  }

  function applyDisplayMode(mode, element) {
    element = element || video;
    if (!element || !element.style || !hasObjectFit(element)) {
      throw makeError('NotSupportedError', 'The webOS video element does not expose object-fit display modes.');
    }
    var fit = mode === 'PLAYER_DISPLAY_MODE_FULL_SCREEN' ? 'fill' : 'contain';
    if ('objectFit' in element.style) element.style.objectFit = fit;
    if ('webkitObjectFit' in element.style) element.style.webkitObjectFit = fit;
  }

  function clearVideoSource() {
    if (!video) return null;
    var firstError = null;
    try { if (typeof video.pause === 'function') video.pause(); }
    catch (pauseError) { firstError = pauseError; }
    try {
      if (typeof video.removeAttribute === 'function') video.removeAttribute('src');
      else video.src = '';
    } catch (sourceError) { if (!firstError) firstError = sourceError; }
    try {
      while (video.firstChild && typeof video.removeChild === 'function') video.removeChild(video.firstChild);
    } catch (childError) { if (!firstError) firstError = childError; }
    try { video.preload = 'none'; } catch (_) {}
    try { if (typeof video.load === 'function') video.load(); }
    catch (loadError) { if (!firstError) firstError = loadError; }
    try {
      video.hidden = true;
      if (video.style) video.style.visibility = 'hidden';
    } catch (_) {}
    return firstError;
  }

  function isCurrent(session) {
    return !!session && session === currentSession && session.generation === sessionGeneration;
  }

  function removeListener(target, name, callback) {
    try { target.removeEventListener(name, callback, false); } catch (_) {}
  }

  function detachSession(session) {
    if (!session) return;
    clearTimer(session.startTimer);
    clearTimer(session.stallTimer);
    clearTimer(session.reconnectTimer);
    session.startTimer = null;
    session.stallTimer = null;
    session.reconnectTimer = null;
    (session.listeners || []).forEach(function (entry) { removeListener(entry.target, entry.name, entry.callback); });
    session.listeners = [];
  }

  function bindSessionEvent(session, target, name, callback) {
    if (!supportsEventTarget(target)) return false;
    var listener = function (event) { if (isCurrent(session)) callback(event); };
    target.addEventListener(name, listener, false);
    session.listeners.push({ target: target, name: name, callback: listener });
    return true;
  }

  function rejectPendingOpen(error) {
    var pending = pendingOpen;
    pendingOpen = null;
    if (pending) rejectDeferred(pending, error);
  }

  function finishSeek(session, error) {
    if (!pendingSeek || pendingSeek.session !== session || pendingSeek.finished) return;
    var pending = pendingSeek;
    pending.finished = true;
    pendingSeek = null;
    clearTimer(pending.timer);
    pending.timer = null;
    if (error) {
      if (isCurrent(session) && error.name !== 'AbortError') state.error = asPlaybackError(error);
      rejectDeferred(pending.deferred, error);
    } else if (isCurrent(session)) {
      state.position = numberOrNull(video.currentTime, false);
      state.buffering = false;
      publishState();
      resolveDeferred(pending.deferred, getState());
      armStallTimer(session);
    } else {
      rejectDeferred(pending.deferred, makeError('AbortError', 'Playback was replaced before the seek completed.'));
    }
  }

  function cancelSeek(error) {
    if (pendingSeek) finishSeek(pendingSeek.session, error);
  }

  function trackListFor(type) {
    if (!video) return null;
    try {
      if (type === 'AUDIO') return video.audioTracks || null;
      if (type === 'TEXT') return video.textTracks || null;
    } catch (_) {}
    return null;
  }

  function listLength(list) {
    return list && typeof list.length === 'number' && list.length >= 0 ? list.length : 0;
  }

  function trackAt(list, index) {
    if (!list) return null;
    var item = null;
    try { item = list[index]; } catch (_) {}
    if (!item && typeof list.item === 'function') {
      try { item = list.item(index); } catch (_) {}
    }
    return item || null;
  }

  function bindSubtitleTrack(session, track) {
    if (!track || !subtitleListener || !supportsEventTarget(track)) return;
    session.cueListeners = session.cueListeners || [];
    for (var i = 0; i < session.cueListeners.length; i += 1) {
      if (session.cueListeners[i].track === track) return;
    }
    var listener = function () {
      if (!isCurrent(session) || !subtitleListener) return;
      var text = [];
      var duration = null;
      var cues = null;
      try { cues = track.activeCues; } catch (_) {}
      for (var cueIndex = 0; cues && cueIndex < cues.length; cueIndex += 1) {
        var cue = cues[cueIndex];
        if (!cue) continue;
        try { text.push(String(cue.text || '')); } catch (_) {}
        if (duration === null) {
          var start = Number(cue.startTime);
          var end = Number(cue.endTime);
          if (isFinite(start) && isFinite(end) && end >= start) duration = (end - start) * 1000;
        }
      }
      try {
        subtitleListener({ durationMs: duration, text: text.join('\n'), dataType: 'text', attributes: [] });
      } catch (_) { /* Subtitle observers must not interrupt playback. */ }
    };
    track.addEventListener('cuechange', listener, false);
    session.cueListeners.push({ track: track, name: 'cuechange', callback: listener });
    session.listeners.push({ target: track, name: 'cuechange', callback: listener });
  }

  function attachTrackListeners(session) {
    if (!isCurrent(session) || !video) return;
    var textTracks = trackListFor('TEXT');
    var audioTracks = trackListFor('AUDIO');
    session.trackListsBound = session.trackListsBound || {};
    [['TEXT', textTracks], ['AUDIO', audioTracks]].forEach(function (entry) {
      var kind = entry[0];
      var list = entry[1];
      if (list && supportsEventTarget(list) && !session.trackListsBound[kind]) {
        session.trackListsBound[kind] = true;
        bindSessionEvent(session, list, 'addtrack', function () { attachTrackListeners(session); });
      }
    });
    for (var i = 0; i < listLength(textTracks); i += 1) bindSubtitleTrack(session, trackAt(textTracks, i));
  }

  function getTracks() {
    if (!currentSession || !video || !(video.readyState > 0)) {
      throw makeError('InvalidStateError', 'There is no ready webOS playback session.');
    }
    var rows = [];
    ['AUDIO', 'TEXT'].forEach(function (type) {
      var list = trackListFor(type);
      for (var i = 0; i < listLength(list); i += 1) {
        var track = trackAt(list, i);
        if (!track) continue;
        var language = '';
        var label = '';
        var kind = '';
        try { language = track.language == null ? '' : String(track.language); } catch (_) {}
        try { label = track.label == null ? '' : String(track.label); } catch (_) {}
        try { kind = track.kind == null ? '' : String(track.kind); } catch (_) {}
        var extraInfo = {};
        if (language) extraInfo.track_lang = language;
        if (kind) extraInfo.kind = kind;
        var selected = false;
        try { selected = type === 'AUDIO' ? track.enabled === true : track.mode === 'showing' || track.mode === 'hidden'; } catch (_) {}
        rows.push({ type: type, index: i, id: i, label: label, title: label, language: language,
          extraInfo: extraInfo, selected: selected });
      }
    });
    return rows;
  }

  function requireTrackList(type) {
    var list = trackListFor(type);
    if (!list || typeof list.length !== 'number') {
      throw makeError('NotSupportedError', 'The webOS video element does not expose ' + type.toLowerCase() + ' tracks.');
    }
    return list;
  }

  function failSession(session, playbackError) {
    if (!isCurrent(session)) return;
    var error = asPlaybackError(playbackError);
    var refusal = /\bHTTP(?:\/\d(?:\.\d)?)?\s*(?:error\s*)?(401|403|429)\b/i.exec(error.message);
    if (refusal && typeof options.onProviderRejected === 'function') {
      try { options.onProviderRejected(session.url, Number(refusal[1])); } catch (_) {}
    }
    var nativeError = error.nativeError || playbackError && playbackError.target && playbackError.target.error;
    if (!refusal && session.isLive && session.started && session.wantsPlayback && !state.completed && !pendingSeek &&
        /InvalidStateError|PLAYER_ERROR_INVALID_STATE/i.test([
          error.name, error.nativeName, error.nativeCode, error.message,
          nativeError && nativeError.name, nativeError && nativeError.nativeName,
          nativeError && nativeError.nativeCode, nativeError && nativeError.message
        ].join(' '))) {
      if (recoverStalledSession(session, true) || session.recovering || !isCurrent(session)) return;
    }
    currentSession = null;
    state.playing = false;
    state.buffering = false;
    state.completed = false;
    state.error = error;
    state.nativeState = 'ERROR';
    detachSession(session);
    if (pendingOpen === session.openDeferred) {
      pendingOpen = null;
      rejectDeferred(session.openDeferred, error);
    }
    if (pendingSeek && pendingSeek.session === session) cancelSeek(error);
    publishState();
    clearVideoSource();
  }

  function armStallTimer(session) {
    if (!isCurrent(session) || !session.isLive || !session.started || !session.wantsPlayback || session.recovering ||
        pendingSeek || !video || video.paused) return;
    clearTimer(session.stallTimer);
    session.stallTimer = timerHost.setTimeout(function () {
      session.stallTimer = null;
      if (!isCurrent(session) || !session.isLive || !session.started || !session.wantsPlayback || session.recovering || pendingSeek || video.paused) return;
      var remaining = stallTimeoutMs - (now() - session.lastProgressAt);
      if (remaining > 0) {
        session.stallTimer = timerHost.setTimeout(function () { armStallTimer(session); }, remaining);
        return;
      }
      var position = null;
      try { position = numberOrNull(video.currentTime, false); } catch (_) {}
      if (position !== null && session.lastProgressPosition !== null && position !== session.lastProgressPosition) {
        recordProgress(session);
        return;
      }
      recoverStalledSession(session);
    }, Math.max(1, stallTimeoutMs - (now() - session.lastProgressAt)));
  }

  function recordProgress(session) {
    if (!isCurrent(session)) return;
    var position = numberOrNull(video.currentTime, false);
    if (position === null || position === session.lastProgressPosition) return;
    var observedAt = now();
    if (state.playing && !state.buffering && session.lastProgressPosition !== null &&
        position > session.lastProgressPosition && observedAt > session.lastProgressAt &&
        observedAt - session.lastProgressAt <= 2000) {
      if (session.healthySinceAt === null) session.healthySinceAt = session.lastProgressAt;
      if (observedAt - session.healthySinceAt >= 30000) session.recoveryAttempts = 0;
    } else session.healthySinceAt = null;
    session.lastProgressPosition = position;
    session.lastProgressAt = observedAt;
    armStallTimer(session);
  }

  function restartSession(session) {
    if (!isCurrent(session) || !session.wantsPlayback) return;
    detachSession(session);
    var releaseError = clearVideoSource();
    if (releaseError) { failSession(session, releaseError); return; }
    session.listeners = [];
    session.cueListeners = [];
    session.trackListsBound = {};
    session.timeSecond = null;
    session.sourceRevision += 1;
    session.started = false;
    session.recovering = false;
    session.healthySinceAt = null;
    session.lastProgressAt = now();
    session.lastProgressPosition = null;
    state.playing = false;
    state.position = null;
    state.duration = null;
    state.buffering = true;
    state.completed = false;
    state.error = null;
    state.nativeState = 'CONNECTING';
    state.displayMode = displayMode;
    state.subtitlesEnabled = true;
    selectedSubtitleIndex = null;
    try {
      attachMediaEvents(session);
      if (rectangle) applyRectangle(video);
      if (displayMode) applyDisplayMode(displayMode, video);
      video.preload = 'auto';
      video.hidden = false;
      video.style.visibility = 'visible';
      session.reconnectTimer = timerHost.setTimeout(function () {
        session.reconnectTimer = null;
        if (isCurrent(session) && !session.started) {
          failSession(session, makeError('TimeoutError', 'The webOS video element did not resume after reconnect.'));
        }
      }, startTimeoutMs);
      video.src = session.url;
      video.load();
      var playResult = video.play();
      var sourceRevision = session.sourceRevision;
      if (playResult && typeof playResult.then === 'function') {
        playResult.then(function () {
          if (!isCurrent(session) || session.sourceRevision !== sourceRevision) return;
        }, function (error) {
          if (isCurrent(session) && session.sourceRevision === sourceRevision) failSession(session, error);
        });
      }
      publishState();
    } catch (error) { failSession(session, error); }
  }

  function recoverStalledSession(session, lostState) {
    if (!isCurrent(session) || !session.isLive || !session.wantsPlayback || session.recovering || pendingSeek) return false;
    if (session.recoveryAttempts >= 2) {
      failSession(session, makeError('TimeoutError', 'The webOS video element stopped advancing after two recovery attempts.'));
      return true;
    }
    session.recovering = true;
    var recoveryRevision = ++session.recoveryRevision;
    state.playing = false;
    state.buffering = true;
    publishState();
    Promise.resolve().then(function () {
      if (!isCurrent(session) || !session.wantsPlayback || !session.recovering ||
          session.recoveryRevision !== recoveryRevision) return false;
      if (pendingSeek) { session.recovering = false; return false; }
      return Promise.resolve(typeof options.beforeReconnect === 'function' ? options.beforeReconnect(session.url) : undefined)
        .then(function () { return true; });
    }).then(function (admitted) {
      if (isCurrent(session) && session.recoveryRevision === recoveryRevision && pendingSeek) {
        session.recovering = false;
        return;
      }
      if (admitted === false || !isCurrent(session) || !session.wantsPlayback || !session.recovering ||
          session.recoveryRevision !== recoveryRevision || pendingSeek) return;
      session.recovering = false;
      if (!lostState && now() - session.lastProgressAt < stallTimeoutMs) {
        markPlaying(session);
        return;
      }
      session.recoveryAttempts += 1;
      restartSession(session);
    }).catch(function (error) {
      if (isCurrent(session) && session.wantsPlayback && session.recoveryRevision === recoveryRevision) failSession(session, error);
    });
    return true;
  }

  function markPlaying(session) {
    if (!isCurrent(session)) return;
    var firstStart = !session.started;
    session.started = true;
    session.wantsPlayback = true;
    session.recovering = false;
    if (firstStart) {
      session.lastProgressAt = now();
      session.lastProgressPosition = numberOrNull(video.currentTime, false);
      session.healthySinceAt = null;
    }
    clearTimer(session.reconnectTimer);
    session.reconnectTimer = null;
    state.playing = true;
    state.buffering = false;
    state.completed = false;
    state.error = null;
    state.nativeState = 'PLAYING';
    attachTrackListeners(session);
    if (pendingOpen === session.openDeferred) {
      clearTimer(session.startTimer);
      session.startTimer = null;
      pendingOpen = null;
      resolveDeferred(session.openDeferred, getState());
    }
    armStallTimer(session);
    publishState();
  }

  function attachMediaEvents(session) {
    bindSessionEvent(session, video, 'loadstart', function () {
      state.completed = false;
      state.error = null;
      state.playing = false;
      state.buffering = true;
      state.nativeState = 'CONNECTING';
      publishState();
    });
    bindSessionEvent(session, video, 'loadedmetadata', function () {
      attachTrackListeners(session);
      updateSnapshot();
      publishState();
    });
    bindSessionEvent(session, video, 'durationchange', function () { updateSnapshot(); publishState(); });
    bindSessionEvent(session, video, 'loadeddata', function () {
      attachTrackListeners(session);
      updateSnapshot();
      publishState();
    });
    bindSessionEvent(session, video, 'canplay', function () {
      attachTrackListeners(session);
      if (video.paused) state.buffering = false;
      updateSnapshot();
      publishState();
    });
    bindSessionEvent(session, video, 'play', function () {
      state.buffering = true;
      state.completed = false;
      updateSnapshot();
      publishState();
    });
    bindSessionEvent(session, video, 'playing', function () {
      markPlaying(session);
    });
    bindSessionEvent(session, video, 'pause', function () {
      if (state.completed) return;
      session.wantsPlayback = false;
      session.recoveryRevision += 1;
      session.recovering = false;
      session.healthySinceAt = null;
      clearTimer(session.stallTimer);
      session.stallTimer = null;
      state.playing = false;
      state.buffering = false;
      updateSnapshot();
      publishState();
    });
    bindSessionEvent(session, video, 'waiting', function () {
      if (video.paused) return;
      session.healthySinceAt = null;
      state.playing = false;
      state.buffering = true;
      state.nativeState = 'BUFFERING';
      publishState();
    });
    bindSessionEvent(session, video, 'stalled', function () {
      if (video.paused) return;
      session.healthySinceAt = null;
      state.playing = false;
      state.buffering = true;
      state.nativeState = 'BUFFERING';
      publishState();
    });
    bindSessionEvent(session, video, 'timeupdate', function () {
      var previousSecond = session.timeSecond;
      recordProgress(session);
      updateSnapshot();
      var second = state.position === null ? -1 : Math.floor(state.position);
      if (second !== previousSecond) {
        session.timeSecond = second;
        publishState();
      }
    });
    bindSessionEvent(session, video, 'seeking', function () {
      if (pendingSeek && pendingSeek.session === session) pendingSeek.seeking = true;
      state.buffering = true;
      publishState();
    });
    bindSessionEvent(session, video, 'seeked', function () {
      if (pendingSeek && pendingSeek.session === session && pendingSeek.seeking) finishSeek(session, null);
      else if (!pendingSeek || pendingSeek.session !== session) {
        state.buffering = false;
        updateSnapshot();
        publishState();
      }
    });
    bindSessionEvent(session, video, 'ended', function () {
      state.completed = true;
      state.playing = false;
      state.buffering = false;
      state.nativeState = 'ENDED';
      state.duration = numberOrNull(video.duration, true);
      state.position = state.duration;
      publishState();
    });
    bindSessionEvent(session, video, 'error', function (event) { failSession(session, event); });
    bindSessionEvent(session, video, 'emptied', function () {
      if (video.src) return;
      state.playing = false;
      state.position = null;
      state.duration = null;
      state.buffering = false;
      publishState();
    });
  }

  function emitSubtitle(session) {
    if (subtitleListener && isCurrent(session)) attachTrackListeners(session);
  }

  function open(url, requestOptions) {
    requestOptions = requestOptions || {};
    if (!validUrl(url)) return Promise.reject(makeError('TypeError', 'Playback URL must use HTTP or HTTPS.'));
    try { validateHeaders(requestOptions.headers, requestOptions.headerPolicy, requestOptions.isLive); }
    catch (headerError) { return Promise.reject(headerError); }
    var bufferPreset = requestOptions.bufferPreset || 'default';
    if (bufferPreset !== 'default') {
      return Promise.reject(makeError('NotSupportedError', 'The webOS HTML5 player supports only the default buffering policy.'));
    }

    try {
      video = ensureVideo();
      if (!video || !supportsEventTarget(video) || typeof video.play !== 'function' ||
          typeof video.pause !== 'function' || typeof video.load !== 'function') {
        throw makeError('NotSupportedError', 'A webOS HTML5 video element is unavailable.');
      }
    } catch (videoError) { return Promise.reject(videoError); }

    var generation = ++sessionGeneration;
    var previousSession = currentSession;
    currentSession = null;
    rejectPendingOpen(makeError('AbortError', 'Playback was replaced by a newer request.'));
    cancelSeek(makeError('AbortError', 'Playback was replaced before the seek completed.'));
    detachSession(previousSession);
    var releaseError = clearVideoSource();
    state.playing = false;
    state.position = null;
    state.duration = null;
    state.buffering = false;
    state.completed = false;
    state.error = null;
    state.nativeState = 'CONNECTING';
    state.speed = 1;
    state.bufferPreset = 'default';
    state.subtitlesEnabled = true;
    selectedSubtitleIndex = null;
    if (releaseError) {
      state.error = asPlaybackError(releaseError);
      state.nativeState = 'ERROR';
      publishState();
      return Promise.reject(releaseError);
    }

    var openDeferred = deferred();
    var session = {
      generation: generation,
      url: url,
      isLive: requestOptions.isLive === true,
      openDeferred: openDeferred,
      startTimer: null,
      stallTimer: null,
      reconnectTimer: null,
      listeners: [],
      cueListeners: [],
      trackListsBound: {},
      timeSecond: null,
      started: false,
      wantsPlayback: true,
      recovering: false,
      recoveryAttempts: 0,
      recoveryRevision: 0,
      healthySinceAt: null,
      sourceRevision: 0,
      lastProgressAt: now(),
      lastProgressPosition: null
    };
    currentSession = session;
    pendingOpen = openDeferred;

    try {
      attachMediaEvents(session);
      if (rectangle) applyRectangle(video);
      if (displayMode) applyDisplayMode(displayMode, video);
      video.preload = 'auto';
      video.hidden = false;
      video.style.visibility = 'visible';
      if (!timerHost || typeof timerHost.setTimeout !== 'function') {
        throw makeError('NotSupportedError', 'The webOS video start timer is unavailable.');
      }
      session.startTimer = timerHost.setTimeout(function () {
        if (!isCurrent(session) || openDeferred.settled) return;
        failSession(session, makeError('TimeoutError', 'The webOS video element did not begin playback before timeout.'));
      }, startTimeoutMs);
      video.src = url;
      video.load();
      var playResult = video.play();
      var sourceRevision = session.sourceRevision;
      if (playResult && typeof playResult.then === 'function') {
        playResult.then(function () {
          if (!isCurrent(session) || session.sourceRevision !== sourceRevision) return;
          if (video.readyState >= 3 && video.paused === false) markPlaying(session);
        }, function (playError) {
          if (isCurrent(session) && session.sourceRevision === sourceRevision) failSession(session, playError);
        });
      }
      publishState();
    } catch (startError) { failSession(session, startError); }
    return openDeferred.promise;
  }

  function stop() {
    sessionGeneration += 1;
    var session = currentSession;
    currentSession = null;
    rejectPendingOpen(makeError('AbortError', 'Playback was stopped before the webOS video element started.'));
    cancelSeek(makeError('AbortError', 'Playback was stopped before the seek completed.'));
    detachSession(session);
    var releaseError = clearVideoSource();
    state.playing = false;
    state.position = null;
    state.duration = null;
    state.buffering = false;
    state.completed = false;
    state.error = null;
    state.nativeState = 'NONE';
    state.speed = 1;
    state.bufferPreset = 'default';
    state.subtitlesEnabled = true;
    selectedSubtitleIndex = null;
    if (releaseError) {
      state.error = asPlaybackError(releaseError);
      state.nativeState = 'ERROR';
    }
    publishState();
    if (releaseError) return Promise.reject(releaseError);
    return Promise.resolve(getState());
  }

  function playPause() {
    if (!currentSession || !video) return Promise.reject(makeError('InvalidStateError', 'There is no open webOS video session.'));
    var session = currentSession;
    var sourceRevision = session.sourceRevision;
    try {
      if (video.paused || video.ended) {
        if (video.ended) video.currentTime = 0;
        session.wantsPlayback = true;
        session.lastProgressAt = now();
        state.completed = false;
        state.error = null;
        state.buffering = true;
        var playResult = video.play();
        publishState();
        if (playResult && typeof playResult.then === 'function') {
          return Promise.resolve(playResult).then(function () {
            if (!isCurrent(session) || session.sourceRevision !== sourceRevision) {
              throw makeError('AbortError', 'Playback was replaced before the control completed.');
            }
            if (video.readyState >= 3 && video.paused === false) markPlaying(session);
            return getState();
          }, function (error) {
            if (!isCurrent(session) || session.sourceRevision !== sourceRevision) {
              throw makeError('AbortError', 'Playback was replaced before the control completed.');
            }
            state.error = asPlaybackError(error);
            state.buffering = false;
            publishState();
            throw error;
          });
        }
        if (video.readyState >= 3 && video.paused === false) markPlaying(session);
      } else {
        session.wantsPlayback = false;
        session.recoveryRevision += 1;
        session.recovering = false;
        session.healthySinceAt = null;
        clearTimer(session.stallTimer);
        session.stallTimer = null;
        video.pause();
        state.playing = false;
        state.buffering = false;
        state.nativeState = 'PAUSED';
      }
      publishState();
      return Promise.resolve(getState());
    } catch (error) {
      state.error = asPlaybackError(error);
      publishState();
      return Promise.reject(error);
    }
  }

  function seek(seconds) {
    if (typeof seconds !== 'number' || !isFinite(seconds) || seconds < 0) {
      return Promise.reject(makeError('TypeError', 'Seek position must be a non-negative number of seconds.'));
    }
    if (!currentSession || !video || !(video.readyState > 0)) {
      return Promise.reject(makeError('InvalidStateError', 'There is no ready webOS playback session.'));
    }
    if (pendingSeek) return Promise.reject(makeError('InvalidStateError', 'A webOS seek is already pending.'));

    var target = seconds;
    var duration = numberOrNull(video.duration, true);
    if (duration !== null) target = Math.min(target, duration);
    var session = currentSession;
    var seekDeferred = deferred();
    pendingSeek = { session: session, deferred: seekDeferred, timer: null, finished: false, seeking: false };
    clearTimer(session.stallTimer);
    session.stallTimer = null;
    try {
      if (!video.seeking && numberOrNull(video.currentTime, false) === target) {
        finishSeek(session, null);
        return seekDeferred.promise;
      }
      pendingSeek.timer = timerHost.setTimeout(function () {
        var error = makeError('TimeoutError', 'The webOS video element did not complete the seek before timeout.');
        finishSeek(session, error);
        if (isCurrent(session)) failSession(session, error);
      }, seekTimeoutMs);
      video.currentTime = target;
      if (!video.seeking && numberOrNull(video.currentTime, false) === target) finishSeek(session, null);
    } catch (error) { finishSeek(session, error); }
    return seekDeferred.promise;
  }

  function selectTrack(type, index) {
    var normalizedType = typeof type === 'string' ? type.toUpperCase() : '';
    if (normalizedType !== 'AUDIO' && normalizedType !== 'TEXT') {
      return Promise.reject(makeError('TypeError', 'Track type must be AUDIO or TEXT.'));
    }
    if (typeof index !== 'number' || !isFinite(index) || Math.floor(index) !== index || index < 0) {
      return Promise.reject(makeError('TypeError', 'Track index must be a non-negative integer.'));
    }
    if (!currentSession || !video || !(video.readyState > 0)) {
      return Promise.reject(makeError('InvalidStateError', 'There is no ready webOS playback session.'));
    }
    try {
      var list = requireTrackList(normalizedType);
      var selectedTrack = trackAt(list, index);
      if (index >= listLength(list) || !selectedTrack) {
        throw makeError('NotFoundError', 'The requested webOS media track is unavailable.');
      }
      for (var i = 0; i < listLength(list); i += 1) {
        var track = trackAt(list, i);
        if (!track) continue;
        if (normalizedType === 'AUDIO') {
          if (typeof track.enabled !== 'boolean') throw makeError('NotSupportedError', 'The webOS audio track cannot be selected.');
          track.enabled = i === index;
        } else {
          if (typeof track.mode !== 'string') throw makeError('NotSupportedError', 'The webOS text track cannot be selected.');
          track.mode = i === index ? 'showing' : 'disabled';
        }
      }
      if (normalizedType === 'AUDIO' && selectedTrack.enabled !== true ||
          normalizedType === 'TEXT' && selectedTrack.mode !== 'showing') {
        throw makeError('NotSupportedError', 'The webOS media track selection did not take effect.');
      }
      if (normalizedType === 'TEXT') {
        selectedSubtitleIndex = index;
        state.subtitlesEnabled = true;
        attachTrackListeners(currentSession);
      }
      publishState();
      return Promise.resolve(getTracks());
    } catch (error) { return Promise.reject(error); }
  }

  function setSubtitlesEnabled(enabled) {
    if (typeof enabled !== 'boolean') return Promise.reject(makeError('TypeError', 'Subtitle visibility must be a boolean.'));
    if (!currentSession || !video || !(video.readyState > 0)) {
      return Promise.reject(makeError('InvalidStateError', 'There is no ready webOS playback session.'));
    }
    try {
      var list = requireTrackList('TEXT');
      var target = selectedSubtitleIndex;
      if (enabled && (target === null || target >= listLength(list))) {
        target = -1;
        for (var i = 0; i < listLength(list); i += 1) {
          var candidate = trackAt(list, i);
          if (candidate && (candidate.mode === 'showing' || candidate.mode === 'hidden')) { target = i; break; }
        }
        if (target < 0 && listLength(list)) target = 0;
      }
      for (var trackIndex = 0; trackIndex < listLength(list); trackIndex += 1) {
        var track = trackAt(list, trackIndex);
        if (!track) continue;
        if (typeof track.mode !== 'string') throw makeError('NotSupportedError', 'The webOS text track visibility cannot be changed.');
        track.mode = enabled && trackIndex === target ? 'showing' : 'disabled';
      }
      if (enabled && target >= 0) selectedSubtitleIndex = target;
      state.subtitlesEnabled = enabled;
      publishState();
      return Promise.resolve(getState());
    } catch (error) { return Promise.reject(error); }
  }

  function setSpeed(rate) {
    if (typeof rate !== 'number' || !isFinite(rate)) {
      return Promise.reject(makeError('TypeError', 'Playback speed must be a finite number.'));
    }
    if (rate !== 1) return Promise.reject(makeError('NotSupportedError', 'webOS TV streaming playback supports only normal 1x speed.'));
    state.speed = 1;
    if (video && typeof video.playbackRate === 'number') {
      try { video.playbackRate = 1; } catch (_) {}
    }
    publishState();
    return Promise.resolve(getState());
  }

  function setDisplayMode(mode) {
    var modes = [
      'PLAYER_DISPLAY_MODE_LETTER_BOX',
      'PLAYER_DISPLAY_MODE_FULL_SCREEN',
      'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO'
    ];
    if (modes.indexOf(mode) < 0) return Promise.reject(makeError('NotSupportedError', 'The webOS display mode is unsupported.'));
    try {
      var target = ensureVideo();
      if (!hasObjectFit(target)) throw makeError('NotSupportedError', 'The webOS video element does not expose object-fit display modes.');
      applyDisplayMode(mode, target);
      displayMode = mode;
      state.displayMode = mode;
      publishState();
      return Promise.resolve(mode);
    } catch (error) { return Promise.reject(error); }
  }

  function trackListSupported(type) {
    var list = trackListFor(type);
    if (!list || typeof list.length !== 'number') return false;
    if (!listLength(list)) return true;
    var track = trackAt(list, 0);
    if (!track) return false;
    return type === 'AUDIO' ? typeof track.enabled === 'boolean' : typeof track.mode === 'string';
  }

  function getCapabilities() {
    var element = currentVideo();
    var oldVideo = video;
    if (element) video = element;
    var audioTracks = trackListSupported('AUDIO');
    var textTracks = trackListSupported('TEXT');
    video = oldVideo || element;
    var aspect = hasObjectFit(element);
    return {
      tracks: audioTracks || textTracks,
      audioTrackSelection: audioTracks,
      subtitleTrackSelection: textTracks,
      subtitleVisibility: textTracks,
      subtitleEvents: !!(textTracks && supportsEventTarget(trackListFor('TEXT'))),
      playbackSpeeds: [],
      bufferPresets: ['default'],
      qualitySelection: false,
      refreshRateMatching: false,
      pictureInPicture: false,
      recording: false,
      timeshift: false,
      displayModes: aspect ? [
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
    if (callback && currentSession) emitSubtitle(currentSession);
  }

  function setRect(x, y, width, height) {
    var values = [x, y, width, height];
    var rect = [];
    values.forEach(function (value) {
      if (typeof value !== 'number' || !isFinite(value)) {
        throw makeError('TypeError', 'WebOS video rectangle values must be finite numbers.');
      }
      rect.push(Math.round(value));
    });
    if (rect[0] < 0 || rect[1] < 0 || rect[2] <= 0 || rect[3] <= 0) {
      throw makeError('RangeError', 'WebOS video rectangle must have non-negative origin and positive size.');
    }
    rectangle = rect;
    var element = currentVideo();
    if (element) applyRectangle(element);
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
