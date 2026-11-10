'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { create } = require('../platform/player.js');

function addEventTarget(target) {
  const listeners = Object.create(null);
  target.addEventListener = (name, callback) => {
    (listeners[name] || (listeners[name] = [])).push(callback);
  };
  target.removeEventListener = (name, callback) => {
    if (!listeners[name]) return;
    listeners[name] = listeners[name].filter(item => item !== callback);
  };
  target.emit = (name, event = {}) => {
    (listeners[name] || []).slice().forEach(callback => callback(Object.assign({ type: name, target }, event)));
  };
  target.listenerCount = () => Object.keys(listeners).reduce((count, name) => count + listeners[name].length, 0);
  target.listenersFor = name => (listeners[name] || []).slice();
  return target;
}

function createClock() {
  let now = 0;
  let serial = 0;
  const timers = new Map();
  return {
    now: () => now,
    setTimeout(callback, delay) {
      const id = ++serial;
      timers.set(id, { callback, at: now + delay });
      return id;
    },
    clearTimeout(id) { timers.delete(id); },
    async advance(milliseconds) {
      const target = now + milliseconds;
      for (;;) {
        const next = [...timers].filter(([, timer]) => timer.at <= target).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        now = next[1].at;
        timers.delete(next[0]);
        next[1].callback();
        await new Promise(resolve => setImmediate(resolve));
      }
      now = target;
    },
    pending: () => timers.size
  };
}

function makeTrack(fields) {
  const track = addEventTarget(Object.assign({ language: '', label: '', kind: '' }, fields));
  track.activeCues = [];
  return track;
}

function createMediaDouble() {
  const calls = [];
  const audioTracks = addEventTarget([
    makeTrack({ language: 'eng', label: 'English', kind: 'main', enabled: true }),
    makeTrack({ language: 'pol', label: 'Polski', kind: 'main', enabled: false })
  ]);
  const textTracks = addEventTarget([
    makeTrack({ language: 'eng', label: 'English CC', kind: 'captions', mode: 'disabled' })
  ]);
  const video = addEventTarget({
    style: { objectFit: '', webkitObjectFit: '' },
    readyState: 0,
    duration: 60,
    paused: true,
    ended: false,
    seeking: false,
    src: '',
    hidden: true,
    firstChild: null,
    audioTracks,
    textTracks,
    playbackRate: 1,
    setAttribute(name, value) { calls.push(['attribute', name, value]); },
    removeAttribute(name) { if (name === 'src') this.src = ''; calls.push(['removeAttribute', name]); },
    removeChild() { this.firstChild = null; },
    load() {
      calls.push(['load', this.src]);
      this.readyState = this.src ? 1 : 0;
      this.currentTime = 0;
      this.seeking = false;
      if (this.src) this.emit('loadstart');
    },
    play() {
      calls.push(['play']);
      this.paused = false;
      return undefined; // webOS 3.x/Chromium 38 may not return a play() promise.
    },
    pause() {
      calls.push(['pause']);
      const changed = !this.paused;
      this.paused = true;
      if (changed) this.emit('pause');
    }
  });
  let currentTime = 0;
  Object.defineProperty(video, 'currentTime', {
    get() { return currentTime; },
    set(value) { currentTime = value; this.seeking = true; calls.push(['seek', value]); }
  });
  return { video, calls, audioTracks, textTracks };
}

function makeAdapter(media, options = {}) {
  return create(Object.assign({ video: media.video, timerHost: options.clock || globalThis,
    now: options.clock ? options.clock.now : Date.now }, options));
}

function startPlayback(adapter, video) {
  const opening = adapter.open('https://media.example/test.m3u8', { isLive: true });
  video.readyState = 4;
  video.emit('playing');
  return opening;
}

test('rejects unsupported headers and buffer tuning before touching the video element', async () => {
  const media = createMediaDouble();
  const adapter = makeAdapter(media);
  await assert.rejects(adapter.open('https://media.example/test.mp4', { headers: { 'user-agent': 'VLC/3.0.20 LibVLC/3.0.20' } }), { name: 'NotSupportedError' });
  await assert.rejects(adapter.open('https://media.example/test.mp4', { headers: { Cookie: 'sid=1' } }), { name: 'NotSupportedError' });
  await assert.rejects(adapter.open('https://media.example/test.mp4', { bufferPreset: 'stable' }), { name: 'NotSupportedError' });
  assert.deepEqual(media.calls, []);
});

test('allows the canonical default user-agent only for trusted Xtream VOD and keeps direct playback lifecycle', async () => {
  const media = createMediaDouble();
  const adapter = makeAdapter(media);
  const movieUrl = 'https://media.example/movie.mp4?token=movie-secret';
  const episodeUrl = 'https://media.example/episode.mp4?token=episode-secret';
  const movieHeaders = Object.freeze({ 'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20' });
  const episodeHeaders = Object.freeze({ 'user-agent': 'VLC/3.0.20 LibVLC/3.0.20' });

  const movieOpening = adapter.open(movieUrl, {
    headers: movieHeaders,
    headerPolicy: 'xtream-vod-default',
    isLive: false
  });
  assert.equal(media.video.src, movieUrl);
  assert.equal(media.video.listenerCount(), 16);
  media.video.readyState = 4;
  media.video.emit('loadedmetadata');
  media.video.emit('playing');
  assert.equal((await movieOpening).playing, true);
  assert.deepEqual(media.calls.filter(call => call[0] === 'load').map(call => call[1]), ['', movieUrl]);

  assert.equal((await adapter.playPause()).playing, false);
  assert.equal((await adapter.playPause()).playing, true);

  const episodeOpening = adapter.open(episodeUrl, {
    headers: episodeHeaders,
    headerPolicy: 'xtream-vod-default',
    isLive: false
  });
  assert.equal(media.video.src, episodeUrl);
  assert.equal(media.video.listenerCount(), 16, 'replacing a film session removes its listeners before binding the episode');
  media.video.readyState = 4;
  media.video.emit('loadedmetadata');
  media.video.emit('playing');
  assert.equal((await episodeOpening).playing, true);
  assert.deepEqual(media.calls.filter(call => call[0] === 'load').map(call => call[1]), ['', movieUrl, '', episodeUrl]);
  assert.deepEqual(movieHeaders, { 'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20' });
  assert.deepEqual(episodeHeaders, { 'user-agent': 'VLC/3.0.20 LibVLC/3.0.20' });

  const seeking = adapter.seek(22);
  media.video.emit('seeking');
  media.video.seeking = false;
  media.video.emit('seeked');
  assert.equal((await seeking).position, 22);
  assert.equal((await adapter.playPause()).playing, false);
  assert.equal((await adapter.playPause()).playing, true);

  await adapter.stop();
  assert.equal(media.video.src, '');
  assert.equal(media.video.listenerCount(), 0);
});

test('rejects policy bypasses, live/custom headers, and mismatched Xtream user-agents before loading media', async () => {
  const canonicalAgent = 'VLC/3.0.20 LibVLC/3.0.20';
  const cases = [
    {
      name: 'canonical user-agent without trusted policy',
      options: { headers: { 'User-Agent': canonicalAgent }, isLive: false }
    },
    {
      name: 'live stream with trusted policy',
      options: { headers: { 'user-agent': canonicalAgent }, headerPolicy: 'xtream-vod-default', isLive: true }
    },
    {
      name: 'unspecified VOD status with trusted policy',
      options: { headers: { 'user-agent': canonicalAgent }, headerPolicy: 'xtream-vod-default' }
    },
    {
      name: 'extra custom header with trusted policy',
      options: { headers: { 'User-Agent': canonicalAgent, Cookie: 'sid=1' }, headerPolicy: 'xtream-vod-default', isLive: false }
    },
    {
      name: 'custom user-agent with trusted policy',
      options: { headers: { 'User-Agent': 'TVBro/1.0' }, headerPolicy: 'xtream-vod-default', isLive: false }
    },
    {
      name: 'mismatched canonical user-agent with trusted policy',
      options: { headers: { 'User-Agent': 'VLC/3.0.20' }, headerPolicy: 'xtream-vod-default', isLive: false }
    },
    {
      name: 'unknown header policy',
      options: { headers: { 'User-Agent': canonicalAgent }, headerPolicy: 'provider-default', isLive: false }
    }
  ];

  for (const item of cases) {
    const media = createMediaDouble();
    const adapter = makeAdapter(media);
    await assert.rejects(adapter.open('https://media.example/test.mp4', item.options), { name: 'NotSupportedError' }, item.name);
    assert.deepEqual(media.calls, [], item.name + ' must not load the video source');
    assert.equal(media.video.src, '', item.name + ' must not assign a source');
    assert.equal(media.video.listenerCount(), 0, item.name + ' must not attach playback listeners');
  }
});

test('opens through the HTML video element and keeps the Samsung player contract', async () => {
  const media = createMediaDouble();
  const adapter = makeAdapter(media);
  adapter.setRect(12, 24, 1280, 720);
  await adapter.setDisplayMode('PLAYER_DISPLAY_MODE_FULL_SCREEN');
  const snapshots = [];
  adapter.onState(snapshot => snapshots.push(snapshot));

  const opening = adapter.open('https://media.example/live.m3u8', { headers: {}, isLive: true });
  assert.equal(media.video.src, 'https://media.example/live.m3u8');
  assert.equal(media.video.style.left, '12px');
  assert.equal(media.video.style.top, '24px');
  assert.equal(media.video.style.width, '1280px');
  assert.equal(media.video.style.height, '720px');
  assert.equal(media.video.style.objectFit, 'fill');
  assert.equal(media.video.hidden, false);
  assert.equal(media.video.listenerCount(), 16);

  media.video.readyState = 4;
  media.video.emit('loadedmetadata');
  media.video.emit('playing');
  const opened = await opening;
  assert.equal(opened.playing, true);
  assert.equal(opened.nativeState, 'PLAYING');
  assert.equal(opened.duration, 60);
  assert.deepEqual(adapter.getCapabilities().bufferPresets, ['default']);
  assert.deepEqual(adapter.getCapabilities().playbackSpeeds, []);
  assert.equal(adapter.getCapabilities().tracks, true);
  assert.equal(adapter.getCapabilities().displayModes.length, 3);
  assert.ok(snapshots.length >= 2);

  const paused = await adapter.playPause();
  assert.equal(paused.playing, false);
  assert.equal(paused.nativeState, 'PAUSED');
  const resumed = await adapter.playPause();
  assert.equal(resumed.playing, true);
  assert.equal(resumed.nativeState, 'PLAYING');
  await assert.rejects(adapter.setSpeed(2), { name: 'NotSupportedError' });
  assert.equal((await adapter.setSpeed(1)).speed, 1);
  await adapter.stop();
});

test('creates and reuses one video element when the bootstrap has no native-player node', async () => {
  const media = createMediaDouble();
  const elements = Object.create(null);
  let created = 0;
  const document = {
    body: { appendChild(element) { elements[element.id] = element; } },
    getElementById(id) { return elements[id] || null; },
    createElement(tag) { assert.equal(tag, 'video'); created += 1; return media.video; }
  };
  const environment = { document, innerWidth: 1920, innerHeight: 1080,
    setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout };
  const adapter = create({ environment });
  adapter.getCapabilities();
  assert.equal(media.video.preload, 'none');
  assert.equal(created, 1);
  assert.equal(elements['native-player'], media.video);
  const first = await startPlayback(adapter, media.video);
  assert.equal(first.playing, true);
  assert.equal(media.video.preload, 'auto');
  assert.equal(media.video.id, 'native-player');
  await adapter.stop();
  assert.equal(media.video.preload, 'none');
  const second = await startPlayback(adapter, media.video);
  assert.equal(second.playing, true);
  assert.equal(created, 1);
  await adapter.stop();
});

test('reuses the bootstrap native-player node and never creates a second video', async () => {
  const media = createMediaDouble();
  const elements = { 'native-player': media.video };
  media.video.id = 'native-player';
  let created = 0;
  const document = {
    body: { appendChild() { throw new Error('the existing player should be reused'); } },
    getElementById(id) { return elements[id] || null; },
    createElement() { created += 1; throw new Error('the existing video should be reused'); }
  };
  const environment = { document, innerWidth: 1920, innerHeight: 1080,
    setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout };
  const adapter = create({ environment });
  adapter.getCapabilities();
  const opened = await startPlayback(adapter, media.video);
  assert.equal(opened.playing, true);
  assert.equal(created, 0);
  assert.equal(Object.keys(elements).length, 1);
  await adapter.stop();
  const reopened = await startPlayback(adapter, media.video);
  assert.equal(reopened.playing, true);
  assert.equal(created, 0);
  assert.equal(Object.keys(elements).length, 1);
  await adapter.stop();
});

test('seeking resolves from seeked and track APIs report and change only available selections', async () => {
  const media = createMediaDouble();
  const adapter = makeAdapter(media);
  await startPlayback(adapter, media.video);

  const seeking = adapter.seek(30);
  assert.equal(media.video.currentTime, 30);
  assert.equal(media.video.seeking, true);
  media.video.emit('seeking');
  media.video.seeking = false;
  media.video.emit('seeked');
  assert.equal((await seeking).position, 30);

  const before = adapter.getTracks();
  assert.equal(before.find(track => track.type === 'AUDIO' && track.index === 0).selected, true);
  assert.equal(before.find(track => track.type === 'TEXT' && track.index === 0).selected, false);
  const audio = await adapter.selectTrack('AUDIO', 1);
  assert.equal(audio.find(track => track.type === 'AUDIO' && track.index === 1).selected, true);
  const text = await adapter.selectTrack('TEXT', 0);
  assert.equal(text.find(track => track.type === 'TEXT' && track.index === 0).selected, true);
  await adapter.setSubtitlesEnabled(false);
  assert.equal(media.textTracks[0].mode, 'disabled');
  await adapter.setSubtitlesEnabled(true);
  assert.equal(media.textTracks[0].mode, 'showing');

  const subtitles = [];
  adapter.onSubtitle(event => subtitles.push(event));
  media.textTracks[0].activeCues = [{ text: 'Hello', startTime: 0, endTime: 2 }];
  media.textTracks[0].emit('cuechange');
  assert.deepEqual(subtitles, [{ durationMs: 2000, text: 'Hello', dataType: 'text', attributes: [] }]);
  await assert.rejects(adapter.selectTrack('AUDIO', 9), { name: 'NotFoundError' });
  await assert.rejects(adapter.seek(-1), { name: 'TypeError' });
  await adapter.stop();
});

test('replacement aborts pending open and seek and makes late events from the old session inert', async () => {
  const media = createMediaDouble();
  const adapter = makeAdapter(media);
  const first = adapter.open('https://media.example/first.m3u8');
  const firstRejects = assert.rejects(first, { name: 'AbortError' });
  const oldPlayingListener = media.video.listenersFor('playing')[0];
  const second = adapter.open('https://media.example/second.m3u8');
  await firstRejects;

  let secondSettled = false;
  second.then(() => { secondSettled = true; });
  oldPlayingListener({ type: 'playing', target: media.video });
  await Promise.resolve();
  assert.equal(secondSettled, false);
  assert.equal(media.video.src, 'https://media.example/second.m3u8');
  media.video.readyState = 4;
  media.video.emit('playing');
  assert.equal((await second).playing, true);

  const seeking = adapter.seek(12);
  const seekRejects = assert.rejects(seeking, { name: 'AbortError' });
  const third = adapter.open('https://media.example/third.m3u8');
  await seekRejects;
  let thirdSettled = false;
  third.then(() => { thirdSettled = true; });
  await Promise.resolve();
  assert.equal(thirdSettled, false);
  assert.equal(media.video.src, 'https://media.example/third.m3u8');
  media.video.readyState = 4;
  media.video.emit('playing');
  assert.equal((await third).playing, true);
  await adapter.stop();
});

test('stop cancels pending operations, removes listeners and releases the source', async () => {
  const media = createMediaDouble();
  const adapter = makeAdapter(media);
  const opening = adapter.open('https://media.example/live.m3u8');
  const openRejects = assert.rejects(opening, { name: 'AbortError' });
  await adapter.stop();
  await openRejects;
  assert.equal(media.video.src, '');
  assert.equal(media.video.hidden, true);
  assert.equal(media.video.listenerCount(), 0);
  assert.equal(adapter.getState().nativeState, 'NONE');

  const opened = await startPlayback(adapter, media.video);
  assert.equal(opened.playing, true);
  const seeking = adapter.seek(20);
  const seekRejects = assert.rejects(seeking, { name: 'AbortError' });
  await adapter.stop();
  await seekRejects;
  assert.equal(media.video.src, '');
  assert.equal(media.video.listenerCount(), 0);
  assert.equal(media.calls.filter(call => call[0] === 'load').length, 6);
});

test('startup timeout reports a terminal error and releases the media source', async () => {
  const media = createMediaDouble();
  const clock = createClock();
  const adapter = makeAdapter(media, { clock, startTimeoutMs: 4000 });
  const opening = adapter.open('https://media.example/slow.m3u8');
  const rejected = assert.rejects(opening, { name: 'TimeoutError' });
  await clock.advance(4000);
  await rejected;
  assert.equal(adapter.getState().nativeState, 'ERROR');
  assert.equal(media.video.src, '');
  assert.equal(media.video.listenerCount(), 0);
});

test('a media element error rejects startup, preserves its code and tears down listeners', async () => {
  const media = createMediaDouble();
  const adapter = makeAdapter(media);
  const opening = adapter.open('https://media.example/bad-codec.mp4');
  const rejected = assert.rejects(opening, error => error.name === 'DecodeError' && error.code === 3);
  media.video.error = { code: 3, message: 'Decoder rejected the stream.' };
  media.video.emit('error');
  await rejected;
  assert.equal(adapter.getState().error.name, 'DecodeError');
  assert.equal(adapter.getState().error.code, 3);
  assert.equal(media.video.src, '');
  assert.equal(media.video.listenerCount(), 0);
});

test('VOD progress never arms live-stall recovery or resets the play position', async () => {
  const media = createMediaDouble();
  const clock = createClock();
  let checks = 0;
  const adapter = makeAdapter(media, {
    clock,
    stallTimeoutMs: 1000,
    beforeReconnect: () => { checks += 1; }
  });
  const url = 'https://media.example/movie.mp4';
  const opening = adapter.open(url, { isLive: false });
  media.video.readyState = 4;
  media.video.emit('playing');
  await opening;
  media.video.currentTime = 45;
  media.video.seeking = false;
  media.video.emit('timeupdate');
  const loadsBeforeDeadline = media.calls.filter(call => call[0] === 'load').length;
  assert.equal(clock.pending(), 0, 'VOD does not retain a live recovery timer');

  await clock.advance(60000);
  assert.equal(checks, 0);
  assert.equal(media.calls.filter(call => call[0] === 'load').length, loadsBeforeDeadline);
  assert.equal(media.video.src, url);
  assert.equal(adapter.getState().position, 45);
  await adapter.stop();
});

test('stalled playback reconnects at most twice through the provider gate', async () => {
  const media = createMediaDouble();
  const clock = createClock();
  const baseLoad = media.video.load;
  let sourceLoads = 0;
  media.video.load = function () {
    if (this.src) {
      if (sourceLoads > 0) {
        this.audioTracks.forEach((track, index) => { track.enabled = index === 0; });
        this.textTracks.forEach(track => { track.mode = 'disabled'; });
      }
      sourceLoads += 1;
    }
    return baseLoad.call(this);
  };
  let checks = 0;
  const adapter = makeAdapter(media, {
    clock,
    stallTimeoutMs: 1000,
    startTimeoutMs: 5000,
    beforeReconnect: () => { checks += 1; }
  });
  await startPlayback(adapter, media.video);
  await adapter.setDisplayMode('PLAYER_DISPLAY_MODE_FULL_SCREEN');
  await adapter.selectTrack('AUDIO', 1);
  await adapter.selectTrack('TEXT', 0);
  await adapter.setSubtitlesEnabled(false);
  assert.equal(adapter.getState().subtitlesEnabled, false);
  await clock.advance(1000);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(checks, 1);
  assert.equal(media.video.src, 'https://media.example/test.m3u8');
  assert.equal(adapter.getState().displayMode, 'PLAYER_DISPLAY_MODE_FULL_SCREEN');
  assert.equal(media.video.style.objectFit, 'fill', 'live recovery reapplies the retained aspect preference');
  assert.equal(adapter.getState().subtitlesEnabled, true, 'live recovery follows Samsung restart state for subtitles');
  const tracksAfterRecovery = adapter.getTracks();
  assert.equal(tracksAfterRecovery.find(track => track.type === 'AUDIO' && track.index === 0).selected, true);
  assert.equal(tracksAfterRecovery.find(track => track.type === 'AUDIO' && track.index === 1).selected, false,
    'track selections are not replayed after source recovery, matching Samsung reopen behavior');
  assert.equal(tracksAfterRecovery.find(track => track.type === 'TEXT' && track.index === 0).selected, false);
  media.video.readyState = 4;
  media.video.emit('playing');

  await clock.advance(1000);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(checks, 2);
  media.video.readyState = 4;
  media.video.emit('playing');

  await clock.advance(1000);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(checks, 2);
  assert.equal(adapter.getState().nativeState, 'ERROR');
  assert.match(adapter.getState().error.message, /two recovery attempts/);
  assert.equal(media.video.src, '');
});

test('live stall recovery checks the media clock when timeupdate callbacks are missing', async () => {
  const media = createMediaDouble();
  const clock = createClock();
  let checks = 0;
  const adapter = makeAdapter(media, {
    clock,
    stallTimeoutMs: 1000,
    beforeReconnect: () => { checks += 1; }
  });
  await startPlayback(adapter, media.video);
  media.video.currentTime = 5;
  media.video.seeking = false;

  await clock.advance(1000);
  assert.equal(checks, 0);
  assert.equal(media.calls.filter(call => call[0] === 'load' && call[1]).length, 1);
  assert.equal(adapter.getState().playing, true);
  await adapter.stop();
});

test('repeated playing events do not postpone recovery while the media clock is stuck', async () => {
  const media = createMediaDouble();
  const clock = createClock();
  let checks = 0;
  const adapter = makeAdapter(media, {
    clock,
    stallTimeoutMs: 1000,
    beforeReconnect: () => { checks += 1; }
  });
  await startPlayback(adapter, media.video);
  await clock.advance(900);
  media.video.emit('playing');

  await clock.advance(100);
  assert.equal(checks, 1);
  assert.equal(media.calls.filter(call => call[0] === 'load' && call[1]).length, 2);
  await adapter.stop();
});

test('30 seconds of steady live progress replenishes the bounded recovery budget', async () => {
  const media = createMediaDouble();
  const clock = createClock();
  let checks = 0;
  const adapter = makeAdapter(media, {
    clock,
    stallTimeoutMs: 1000,
    beforeReconnect: () => { checks += 1; }
  });
  await startPlayback(adapter, media.video);

  for (let incident = 1; incident <= 3; incident += 1) {
    await clock.advance(1000);
    assert.equal(checks, incident);
    assert.equal(media.calls.filter(call => call[0] === 'load' && call[1]).length, incident + 1);
    if (incident === 3) break;

    media.video.readyState = 4;
    media.video.emit('playing');
    for (let tick = 1; tick <= 62; tick += 1) {
      await clock.advance(500);
      media.video.currentTime = tick / 2;
      media.video.seeking = false;
      media.video.emit('timeupdate');
    }
  }

  assert.equal(adapter.getState().buffering, true);
  assert.equal(adapter.getState().error, null);
  assert.equal(media.video.src, 'https://media.example/test.m3u8');
  await adapter.stop();
});

test('a lost live media state reconnects through provider admission', async () => {
  const media = createMediaDouble();
  let checks = 0;
  const adapter = makeAdapter(media, {
    beforeReconnect: () => { checks += 1; }
  });
  await startPlayback(adapter, media.video);
  media.video.error = Object.assign(new Error('The native media session is gone.'), { name: 'InvalidStateError' });
  media.video.emit('error');
  media.video.emit('error');
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(checks, 1);
  assert.equal(media.calls.filter(call => call[0] === 'load' && call[1]).length, 2);
  assert.equal(media.video.src, 'https://media.example/test.m3u8');
  assert.equal(adapter.getState().error, null);
  media.video.readyState = 4;
  media.video.emit('playing');
  assert.equal(adapter.getState().playing, true);
  await adapter.stop();
});

test('pause or replacement while provider admission is pending cancels live recovery', async () => {
  for (const action of ['pause', 'replace']) {
    const media = createMediaDouble();
    const clock = createClock();
    let admit;
    const adapter = makeAdapter(media, {
      clock,
      stallTimeoutMs: 1000,
      beforeReconnect: () => new Promise(resolve => { admit = resolve; })
    });
    await startPlayback(adapter, media.video);
    await clock.advance(1000);
    assert.equal(typeof admit, 'function');
    if (action === 'pause') await adapter.playPause();
    else {
      const replacement = adapter.open('https://media.example/replacement.m3u8', { isLive: true });
      media.video.readyState = 4;
      media.video.emit('playing');
      await replacement;
    }
    admit();
    await new Promise(resolve => setImmediate(resolve));

    assert.equal(media.calls.filter(call => call[0] === 'load' && call[1]).length, action === 'pause' ? 1 : 2);
    assert.equal(media.video.src, action === 'pause' ? 'https://media.example/test.m3u8' : 'https://media.example/replacement.m3u8');
    await adapter.stop();
  }
});

test('unsupported and provider refusal errors do not start live recovery', async () => {
  for (const error of [
    Object.assign(new Error('Unsupported codec.'), { name: 'NotSupportedError' }),
    Object.assign(new Error('HTTP 401 Unauthorized'), { name: 'NetworkError' })
  ]) {
    const media = createMediaDouble();
    let checks = 0;
    const rejected = [];
    const adapter = makeAdapter(media, {
      beforeReconnect: () => { checks += 1; },
      onProviderRejected: (_url, status) => rejected.push(status)
    });
    await startPlayback(adapter, media.video);
    media.video.error = error;
    media.video.emit('error');

    assert.equal(checks, 0);
    assert.equal(media.calls.filter(call => call[0] === 'load' && call[1]).length, 1);
    assert.equal(adapter.getState().nativeState, 'ERROR');
    assert.deepEqual(rejected, error.message.includes('401') ? [401] : []);
    await adapter.stop();
  }
});

test('provider cooldown rejection stops live recovery without reopening the source', async () => {
  const media = createMediaDouble();
  const clock = createClock();
  let checks = 0;
  const adapter = makeAdapter(media, {
    clock,
    stallTimeoutMs: 1000,
    beforeReconnect: () => {
      checks += 1;
      return Promise.reject(new Error('Provider cooldown'));
    }
  });
  await startPlayback(adapter, media.video);
  await clock.advance(1000);

  assert.equal(checks, 1);
  assert.equal(adapter.getState().error.message, 'Provider cooldown');
  assert.equal(adapter.getState().nativeState, 'ERROR');
  assert.equal(media.calls.filter(call => call[0] === 'load' && call[1]).length, 1);
  assert.equal(media.video.src, '');
  assert.equal(clock.pending(), 0);
});
