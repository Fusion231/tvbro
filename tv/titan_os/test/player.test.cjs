'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { create } = require('../platform/player.js');
const shared = require('../../lg_webos/platform/player.js');

function media() {
  const listeners = new Map();
  const timers = new Map();
  let timerId = 0;
  const video = {
    style: { objectFit: '' }, readyState: 0, currentTime: 0, duration: 90,
    paused: true, ended: false, seeking: false, src: '', firstChild: null,
    setAttribute() {},
    removeAttribute(name) { if (name === 'src') this.src = ''; },
    addEventListener(name, callback) {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(callback);
    },
    removeEventListener(name, callback) { if (listeners.has(name)) listeners.get(name).delete(callback); },
    emit(name) { for (const callback of [...listeners.get(name) || []]) callback({ type: name, target: this }); },
    load() { this.readyState = this.src ? 1 : 0; this.currentTime = 0; },
    play() { this.paused = false; return Promise.resolve(); },
    pause() { this.paused = true; },
    listenerCount() { return [...listeners.values()].reduce((count, rows) => count + rows.size, 0); }
  };
  const timerHost = {
    setTimeout(callback, delay) { timers.set(++timerId, { callback, delay }); return timerId; },
    clearTimeout(id) { timers.delete(id); }
  };
  return { video, timerHost, timers };
}

async function ready(adapter, video, url, options) {
  const opening = adapter.open(url, options);
  video.readyState = 4;
  video.emit('loadedmetadata');
  video.emit('playing');
  return opening;
}

test('Titan reuses the HTML5 lifecycle for direct live/VOD and preview/fullscreen rectangles', async () => {
  const boundary = media();
  const adapter = create(boundary);
  const snapshots = [];
  adapter.onState(state => snapshots.push(state));
  adapter.setRect(36, 72, 640, 360);
  await adapter.setDisplayMode('PLAYER_DISPLAY_MODE_LETTER_BOX');
  const live = 'https://media.example/live.m3u8';
  assert.equal((await ready(adapter, boundary.video, live, { isLive: true })).playing, true);
  assert.equal(boundary.video.src, live);
  assert.equal(boundary.video.style.left, '36px');
  assert.equal(boundary.video.style.width, '640px');
  assert.equal(boundary.video.style.objectFit, 'contain');
  adapter.setRect(0, 0, 1920, 1080);
  assert.equal(boundary.video.style.width, '1920px');
  assert.equal((await adapter.playPause()).playing, false);
  assert.equal((await adapter.playPause()).playing, true);

  const movie = 'https://media.example/movie.mp4';
  assert.equal((await ready(adapter, boundary.video, movie, { isLive: false })).playing, true);
  assert.equal(boundary.video.src, movie);
  const seeked = await adapter.seek(20);
  assert.equal(seeked.position, 20);
  assert.ok(snapshots.some(state => state.nativeState === 'PLAYING'));
  await adapter.stop();
  assert.equal(boundary.video.src, '');
  assert.equal(boundary.video.listenerCount(), 0);
  assert.equal(boundary.timers.size, 0);
});

test('Titan keeps the trusted Xtream VOD default-UA exception without altering provider requests', async () => {
  const boundary = media();
  const adapter = create(boundary);
  const headers = Object.freeze({ 'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20' });
  const url = 'https://media.example/movie.mp4?token=provider-token';
  await ready(adapter, boundary.video, url, { headers, headerPolicy: 'xtream-vod-default', isLive: false });
  assert.equal(boundary.video.src, url);
  assert.deepEqual(headers, { 'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20' });
  await adapter.stop();
});

test('Titan rejects custom headers and native buffer tuning before starting a media session', async () => {
  const boundary = media();
  const adapter = create(boundary);
  for (const options of [
    { headers: { Cookie: 'session=private' } },
    { headers: { 'User-Agent': 'Custom/1.0' }, headerPolicy: 'xtream-vod-default', isLive: false },
    { headers: { 'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20' }, headerPolicy: 'xtream-vod-default', isLive: true },
    { bufferPreset: 'stable' }
  ]) {
    await assert.rejects(adapter.open('https://media.example/live.m3u8', options), error => {
      assert.equal(error.name, 'NotSupportedError');
      assert.match(error.message, /Titan OS/);
      assert.doesNotMatch(error.message, /webOS/);
      return true;
    });
  }
  assert.equal(boundary.video.src, '');
  assert.equal(boundary.video.listenerCount(), 0);
  assert.equal(boundary.timers.size, 0);
});

test('Titan exposes only media capabilities actually available on the HTML5 boundary', async () => {
  const boundary = media();
  const adapter = create(boundary);
  const capabilities = adapter.getCapabilities();
  assert.equal(capabilities.audioTrackSelection, false);
  assert.equal(capabilities.subtitleTrackSelection, false);
  assert.equal(capabilities.qualitySelection, false);
  assert.equal(capabilities.recording, false);
  assert.equal(capabilities.pictureInPicture, false);
  assert.deepEqual(capabilities.bufferPresets, ['default']);
  assert.deepEqual(capabilities.playbackSpeeds, []);
  await assert.rejects(adapter.setSpeed(2), { name: 'NotSupportedError' });
  await ready(adapter, boundary.video, 'https://media.example/stream.mpd', { isLive: false });
  await assert.rejects(adapter.selectTrack('AUDIO', 0), { name: 'NotSupportedError' });
  await adapter.stop();
});

test('replacing or stopping pending Titan playback cancels observers and startup waits', async () => {
  const boundary = media();
  const adapter = create(boundary);
  const cancelled = adapter.open('https://media.example/first.m3u8', { isLive: true });
  const cancellation = assert.rejects(cancelled, { name: 'AbortError' });
  const replacement = ready(adapter, boundary.video, 'https://media.example/second.m3u8', { isLive: true });
  await cancellation;
  await replacement;
  await adapter.stop();
  assert.equal(boundary.video.listenerCount(), 0);
  assert.equal(boundary.timers.size, 0);
});

test('the shared player retains the default LG platform label', async () => {
  const adapter = shared.create(media());
  await assert.rejects(adapter.setSpeed(2), error => {
    assert.match(error.message, /webOS/);
    assert.doesNotMatch(error.message, /Titan OS/);
    return true;
  });
});
