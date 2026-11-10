'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { create } = require('../platform/avplay.js');

function createAvplayDouble() {
  const calls = [];
  let listener = null;
  let nativeState = 'NONE';
  let currentTimeMs = 0;
  let durationMs = 90000;
  let pendingSeek = null;
  let totalTracks = [
    {type:'VIDEO', index:0, extra_info:'{"Width":"1920","Height":"1080"}'},
    {type:'AUDIO', index:1, extra_info:'{"track_lang":"eng","channels":"2"}'},
    {type:'AUDIO', index:3, extra_info:'{"track_lang":"pol","channels":"2"}'},
    {type:'TEXT', index:4, extra_info:'{"track_lang":"eng"}'},
    {type:'TEXT', index:5, extra_info:'{"track_lang":"pol"}'}
  ];
  let currentTracks = [
    {type:'VIDEO', index:0, extra_info:'{}'},
    {type:'AUDIO', index:1, extra_info:'{}'},
    {type:'TEXT', index:-1, extra_info:null}
  ];
  let subtitleHidden = false;
  let playbackSpeed = 1;
  let displayMode = null;
  const avplay = {
    open(url) {
      calls.push(['open', url]);
      nativeState = 'IDLE';
    },
    close() {
      calls.push(['close']);
      nativeState = 'NONE';
    },
    stop() {
      calls.push(['stop']);
      nativeState = 'NONE';
    },
    setListener(value) {
      calls.push(['setListener', value]);
      listener = value;
    },
    setStreamingProperty(name, value) {
      calls.push(['setStreamingProperty', name, value]);
    },
    setDisplayRect(x, y, width, height) {
      calls.push(['setDisplayRect', x, y, width, height]);
    },
    prepareAsync(success) {
      calls.push(['prepareAsync']);
      success();
    },
    play() {
      calls.push(['play']);
      nativeState = 'PLAYING';
    },
    pause() {
      calls.push(['pause']);
      nativeState = 'PAUSED';
    },
    getState() { return nativeState; },
    getCurrentTime() { return currentTimeMs; },
    getDuration() { return durationMs; },
    getTotalTrackInfo() { calls.push(['getTotalTrackInfo']); return totalTracks; },
    getCurrentStreamInfo() { calls.push(['getCurrentStreamInfo']); return currentTracks; },
    setSelectTrack(type, index) {
      calls.push(['setSelectTrack', type, index]);
      currentTracks = currentTracks.filter(track => track.type !== type);
      currentTracks.push({type, index, extra_info:'{}'});
    },
    setSilentSubtitle(hidden) { calls.push(['setSilentSubtitle', hidden]); subtitleHidden = hidden; },
    setSpeed(rate) { calls.push(['setSpeed', rate]); playbackSpeed = rate; },
    setDisplayMethod(mode) { calls.push(['setDisplayMethod', mode]); displayMode = mode; },
    seekTo(milliseconds, success, failure) {
      calls.push(['seekTo', milliseconds]);
      pendingSeek = {
        success() {
          currentTimeMs = milliseconds;
          success();
        },
        failure
      };
    }
  };

  return {
    avplay,
    calls,
    listener() { return listener; },
    nativeState(value) { nativeState = value; },
    currentTimeMs(value) { currentTimeMs = value; },
    durationMs(value) { durationMs = value; },
    totalTracks(value) { totalTracks = value; },
    currentTracks(value) { currentTracks = value; },
    subtitleHidden() { return subtitleHidden; },
    playbackSpeed() { return playbackSpeed; },
    displayMode() { return displayMode; },
    pendingSeek() { return pendingSeek; }
  };
}

function flushNativeStart() {
  return new Promise((resolve) => setImmediate(resolve));
}

function createClock() {
  let time = 0, serial = 0;
  const timers = new Map();
  return {
    now: () => time,
    setTimeout(callback, delay) { const id = ++serial; timers.set(id, {callback, at:time + delay}); return id; },
    clearTimeout(id) { timers.delete(id); },
    pending: () => timers.size,
    async advance(milliseconds) {
      const target = time + milliseconds;
      for (;;) {
        const next = [...timers].filter(([, timer]) => timer.at <= target).sort((a,b) => a[1].at - b[1].at)[0];
        if (!next) break;
        time = next[1].at; timers.delete(next[0]); next[1].callback();
        await flushNativeStart();
      }
      time = target;
    }
  };
}

test('live startup uses the supported four-second gate before prepare without shortening recovery', async () => {
  const mock = createAvplayDouble();
  mock.avplay.setBufferingParam = (...args) => {
    assert.equal(mock.avplay.getState(), 'IDLE');
    mock.calls.push(['buffer', ...args]);
  };
  const adapter = create({avplay:mock.avplay});
  const opened = adapter.open('https://example.test/live.m3u8', {isLive:true});
  await flushNativeStart();
  assert.deepEqual(mock.calls.filter(call=>call[0]==='buffer'), [
    ['buffer', 'PLAYER_BUFFER_FOR_PLAY', 'PLAYER_BUFFER_SIZE_IN_SECOND', 4]
  ]);
  assert.ok(mock.calls.findIndex(call=>call[0]==='buffer') < mock.calls.findIndex(call=>call[0]==='prepareAsync'));
  mock.listener().onbufferingcomplete();
  await opened;
  await adapter.stop();
  const movie = adapter.open('https://example.test/movie.mp4', {isLive:false});
  await flushNativeStart();
  mock.listener().onbufferingcomplete();
  await movie;
  assert.equal(mock.calls.filter(call=>call[0]==='buffer').length, 1, 'VOD keeps native defaults');
  await adapter.stop();
});

test('unsupported startup tuning keeps the native buffering policy and still starts', async () => {
  const mock = createAvplayDouble();
  mock.avplay.setBufferingParam = () => { const error=Error('Unsupported');error.name='NotSupportedError';throw error; };
  const adapter = create({avplay:mock.avplay});
  const opened = adapter.open('https://example.test/live.m3u8', {isLive:true});
  await flushNativeStart();
  mock.listener().onbufferingcomplete();
  assert.equal((await opened).playing, true);
  await adapter.stop();
});

test('opt-in stable buffering configures both native gates before preparation', async () => {
  const mock = createAvplayDouble();
  mock.avplay.setBufferingParam = (...args) => {
    assert.equal(mock.avplay.getState(), 'IDLE');
    mock.calls.push(['buffer', ...args]);
  };
  const adapter = create({avplay:mock.avplay});
  assert.deepEqual(adapter.getCapabilities().bufferPresets, ['default','stable']);
  const opening = adapter.open('https://example.test/movie.mp4', {bufferPreset:'stable'});
  await flushNativeStart();
  mock.listener().onbufferingcomplete();
  assert.equal((await opening).bufferPreset,'stable');
  assert.deepEqual(mock.calls.filter(call=>call[0]==='buffer'),[
    ['buffer','PLAYER_BUFFER_FOR_PLAY','PLAYER_BUFFER_SIZE_IN_SECOND',8],
    ['buffer','PLAYER_BUFFER_FOR_RESUME','PLAYER_BUFFER_SIZE_IN_SECOND',8]
  ]);
  assert.ok(mock.calls.findLastIndex(call=>call[0]==='buffer') < mock.calls.findIndex(call=>call[0]==='prepareAsync'));
  await adapter.stop();
});

test('buffer preferences reject unsupported settings before replacing playback', async () => {
  const mock = createAvplayDouble(), adapter = create({avplay:mock.avplay});
  assert.deepEqual(adapter.getCapabilities().bufferPresets,['default']);
  await assert.rejects(adapter.open('https://example.test/live.m3u8',{bufferPreset:'stable'}),{name:'NotSupportedError'});
  await assert.rejects(adapter.open('https://example.test/live.m3u8',{bufferPreset:'huge'}),{name:'NotSupportedError'});
  assert.equal(mock.calls.length,0);
  mock.avplay.setBufferingParam = () => { throw new Error('Rejected by firmware'); };
  const opening=adapter.open('https://example.test/live.m3u8',{bufferPreset:'stable'});
  await assert.rejects(opening,/Rejected by firmware/);
  assert.equal(mock.avplay.getState(),'NONE');
  assert.equal(adapter.getCapabilities().recording,false);
  assert.equal(adapter.getCapabilities().timeshift,false);
  assert.equal(adapter.getCapabilities().pictureInPicture,false);
  assert.equal(adapter.getCapabilities().refreshRateMatching,false);
  assert.equal(adapter.getCapabilities().qualitySelection,false);
});

test('opens through native AVPlay and maps only supported request headers', async () => {
  const mock = createAvplayDouble();
  const nativeObject = { hidden: true };
  const adapter = create({
    avplay: mock.avplay,
    document: { getElementById: () => nativeObject }
  });

  adapter.setRect(12, 24, 1280, 720);
  await assert.rejects(
    adapter.open('https://example.test/live.m3u8', { headers: { Authorization: 'Bearer secret' } }),
    { name: 'NotSupportedError' }
  );
  assert.equal(mock.calls.length, 0, 'unsupported headers fail before touching the player');

  let notified = 0;
  adapter.onState(() => { notified += 1; });
  const opened = adapter.open('https://example.test/live.m3u8', {
    headers: { Cookie: 'session=abc', 'User-Agent': 'TVBro-Test' }
  });
  await flushNativeStart();

  assert.equal(nativeObject.hidden, false);
  assert.deepEqual(
    mock.calls.filter((call) => call[0] === 'setStreamingProperty'),
    [
      ['setStreamingProperty', 'COOKIE', 'session=abc'],
      ['setStreamingProperty', 'USER_AGENT', 'TVBro-Test']
    ]
  );
  assert.deepEqual(
    mock.calls.find((call) => call[0] === 'setDisplayRect'),
    ['setDisplayRect', 12, 24, 1280, 720]
  );

  mock.listener().onbufferingcomplete();
  const snapshot = await opened;
  assert.equal(snapshot.playing, true);
  assert.equal(snapshot.buffering, false);
  assert.equal(snapshot.position, 0);
  assert.equal(snapshot.duration, 90);
  assert.equal(notified > 0, true);
});

test('toggles real AVPlay state, seeks in absolute seconds, and defers stop until seek settles', async () => {
  const mock = createAvplayDouble();
  const nativeObject = { hidden: true };
  const adapter = create({
    avplay: mock.avplay,
    document: { getElementById: () => nativeObject }
  });
  const opened = adapter.open('http://example.test/movie.mp4');
  await flushNativeStart();
  mock.listener().onbufferingcomplete();
  await opened;

  const paused = await adapter.playPause();
  assert.equal(paused.playing, false);
  assert.equal(paused.nativeState, 'PAUSED');
  const resumed = await adapter.playPause();
  assert.equal(resumed.playing, true);
  assert.equal(resumed.nativeState, 'PLAYING');

  const seekResult = adapter.seek(12.345);
  assert.deepEqual(mock.calls.find((call) => call[0] === 'seekTo'), ['seekTo', 12345]);
  const stopped = adapter.stop();
  assert.equal(mock.calls.some((call) => call[0] === 'stop'), false, 'AVPlay calls are serialized during async seek');
  mock.pendingSeek().success();
  await seekResult;
  const stoppedState = await stopped;

  assert.equal(nativeObject.hidden, true);
  assert.equal(stoppedState.nativeState, 'NONE');
  assert.equal(stoppedState.playing, false);
  assert.equal(mock.calls.some((call) => call[0] === 'stop'), true);
});

test('a rejected seek leaves healthy playback state available for auto-hide and later seeking', async () => {
  const mock = createAvplayDouble(), adapter = create({avplay:mock.avplay});
  const opened = adapter.open('https://example.test/movie.mp4');
  await flushNativeStart(); mock.listener().oncurrentplaytime(10000); await opened;
  const seeking = adapter.seek(20), rejected = assert.rejects(seeking, /InvalidValuesError/);
  mock.pendingSeek().failure({name:'InvalidValuesError'}); await rejected;
  assert.equal(adapter.getState().playing, true);
  assert.equal(adapter.getState().error, null);
  const next = adapter.seek(30); mock.pendingSeek().success(); await next;
  assert.equal(adapter.getState().position, 30);
  await adapter.stop();
});

test('seek targets stay inside the native media boundaries', async () => {
  const mock = createAvplayDouble(), adapter = create({avplay:mock.avplay});
  const opened = adapter.open('https://example.test/movie.mp4');
  await flushNativeStart(); mock.listener().oncurrentplaytime(10000); await opened;
  for (const [target, milliseconds] of [[0,1],[90,89999],[100,89999]]) {
    const seeking = adapter.seek(target);
    assert.deepEqual(mock.calls.filter(call => call[0] === 'seekTo').at(-1), ['seekTo',milliseconds]);
    mock.pendingSeek().success(); await seeking;
    assert.equal(adapter.getState().position, milliseconds/1000);
  }
  await adapter.stop();
});

test('play pause waits for asynchronous seek and repeated toggles preserve parity', async () => {
  const mock=createAvplayDouble(),adapter=create({avplay:mock.avplay});
  const opened=adapter.open('https://fixture.test/episode.mp4');await flushNativeStart();mock.listener().onbufferingcomplete();await opened;
  const seeking=adapter.seek(30),paused=adapter.playPause();
  assert.equal(mock.calls.filter(x=>x[0]==='pause').length,0);
  mock.pendingSeek().success();await seeking;await paused;
  assert.equal(adapter.getState().playing,false);
  const next=adapter.seek(40),toggle1=adapter.playPause(),toggle2=adapter.playPause();
  mock.pendingSeek().success();await Promise.all([next,toggle1,toggle2]);
  assert.equal(adapter.getState().playing,false,'two queued toggles cancel each other');
  await adapter.stop();
});

test('native completion publishes the finite end position even when the last time event was early', async () => {
  const mock = createAvplayDouble();
  const adapter = create({ avplay: mock.avplay, document: { getElementById: () => ({ hidden: true }) } });
  const opened = adapter.open('https://example.test/movie.mp4');
  await flushNativeStart(); mock.listener().onbufferingcomplete(); await opened;
  mock.listener().oncurrentplaytime(70000);
  mock.listener().onstreamcompleted();
  assert.equal(adapter.getState().position, 90);
  assert.equal(adapter.getState().playing, false);
  await adapter.stop();
});

test('maps the 720p DOM viewport into the fixed Full HD AVPlay display coordinate space', async () => {
  const mock = createAvplayDouble();
  const adapter = create({ avplay: mock.avplay, environment: { innerWidth: 1280, innerHeight: 720, setTimeout, clearTimeout }, document: { getElementById: () => ({ hidden: true }) } });
  adapter.setRect(640, 72, 640, 360);
  const opened = adapter.open('https://example.test/movie.mp4');
  await flushNativeStart(); mock.listener().onbufferingcomplete(); await opened;
  assert.deepEqual(mock.calls.find((row) => row[0] === 'setDisplayRect'), ['setDisplayRect', 960, 108, 960, 540]);
  adapter.setRect(0, 0, 1280, 720);
  assert.deepEqual(mock.calls.filter((row) => row[0] === 'setDisplayRect').at(-1), ['setDisplayRect', 0, 0, 1920, 1080]);
  await adapter.stop();
});

test('preview fit uses video aspect mode and restores the requested letterbox mode at fullscreen', async () => {
  const mock = createAvplayDouble(), nativeObject = {hidden:true, style:{}};
  const adapter = create({avplay:mock.avplay,
    environment:{innerWidth:1280,innerHeight:720,setTimeout,clearTimeout},
    document:{getElementById:() => nativeObject}});
  const fit = 'PLAYER_DISPLAY_MODE_LETTER_BOX', auto = 'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO';
  await adapter.setDisplayMode(fit);
  adapter.setRect(288,80,242,136);
  const opened = adapter.open('https://example.test/preview.m3u8');
  await flushNativeStart(); mock.listener().oncurrentplaytime(0); await opened;
  assert.ok(mock.calls.some(call => call[0] === 'setDisplayMethod'));
  assert.ok(mock.calls.filter(call => call[0] === 'setDisplayMethod').every(call => call[1] === auto),
    'startup and first frame must never apply letterbox to the preview');
  assert.deepEqual(mock.calls.filter(call => call[0] === 'setDisplayRect').at(-1), ['setDisplayRect',432,120,363,204]);
  assert.equal(adapter.getState().displayMode, fit, 'the requested preference is not replaced by the effective preview mode');
  adapter.setRect(0,0,1280,720);
  assert.equal(mock.displayMode(), fit);
  assert.deepEqual(mock.calls.filter(call => call[0] === 'setDisplayRect').at(-1), ['setDisplayRect',0,0,1920,1080]);
  adapter.setRect(288,80,242,136);
  mock.listener().onevent('PLAYER_MSG_RESOLUTION_CHANGED', '1280x720');
  assert.equal(mock.displayMode(), auto);
  assert.equal(adapter.getState().displayMode, fit);
  assert.equal(mock.calls.filter(call => call[0] === 'open').length, 1);
  await adapter.stop();
});

for (const mode of ['PLAYER_DISPLAY_MODE_FULL_SCREEN', 'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO']) {
  test('preview fit leaves the requested ' + mode + ' unchanged in preview and fullscreen', async () => {
    const mock = createAvplayDouble();
    const adapter = create({avplay:mock.avplay,
      environment:{innerWidth:1280,innerHeight:720,setTimeout,clearTimeout}});
    await adapter.setDisplayMode(mode); adapter.setRect(288,80,242,136);
    const opened = adapter.open('https://example.test/preview.m3u8');
    await flushNativeStart(); mock.listener().oncurrentplaytime(0); await opened;
    assert.equal(mock.displayMode(), mode); assert.equal(adapter.getState().displayMode, mode);
    adapter.setRect(0,0,1280,720);
    assert.equal(mock.displayMode(), mode); assert.equal(adapter.getState().displayMode, mode);
    assert.ok(mock.calls.filter(call => call[0] === 'setDisplayMethod').every(call => call[1] === mode));
    await adapter.stop();
  });
}

test('preview fit applies a newly requested mode before committing the preference', async () => {
  const mock = createAvplayDouble(), fit = 'PLAYER_DISPLAY_MODE_LETTER_BOX';
  const fill = 'PLAYER_DISPLAY_MODE_FULL_SCREEN', auto = 'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO';
  const adapter = create({avplay:mock.avplay,
    environment:{innerWidth:1280,innerHeight:720,setTimeout,clearTimeout}});
  await adapter.setDisplayMode(fill); adapter.setRect(288,80,242,136);
  const opened = adapter.open('https://example.test/preview.m3u8');
  await flushNativeStart(); mock.listener().oncurrentplaytime(0); await opened;
  let from = mock.calls.length;
  await adapter.setDisplayMode(fit);
  assert.deepEqual(mock.calls.slice(from).filter(call => call[0] === 'setDisplayMethod'), [['setDisplayMethod',auto]]);
  assert.equal(mock.displayMode(), auto); assert.equal(adapter.getState().displayMode, fit);
  from = mock.calls.length;
  await adapter.setDisplayMode(fill);
  assert.deepEqual(mock.calls.slice(from).filter(call => call[0] === 'setDisplayMethod'), [['setDisplayMethod',fill]]);
  assert.equal(adapter.getState().displayMode, fill);
  const setDisplayMethod = mock.avplay.setDisplayMethod;
  mock.avplay.setDisplayMethod = function (mode) { if (mode === auto) throw new Error('native mode refused'); setDisplayMethod(mode); };
  await assert.rejects(adapter.setDisplayMode(fit), /native mode refused/);
  assert.equal(adapter.getState().displayMode, fill, 'a failed native change cannot save the requested preference');
  mock.avplay.setDisplayMethod = setDisplayMethod;
  await adapter.stop();
});

test('retains the preview area when decoder preparation, playback and video metadata replace the surface', async () => {
  const mock = createAvplayDouble(), nativeObject = {hidden:true, style:{}};
  let physicalRect = null, prepared;
  const setRect = mock.avplay.setDisplayRect, play = mock.avplay.play;
  mock.avplay.setDisplayRect = function (...rect) {
    physicalRect = rect; setRect.apply(this, rect);
  };
  mock.avplay.prepareAsync = function (success) { prepared = success; };
  mock.avplay.play = function () { physicalRect = [0,0,1920,1080]; play.call(this); };
  const adapter = create({
    avplay:mock.avplay,
    environment:{innerWidth:1280, innerHeight:720, setTimeout, clearTimeout},
    document:{getElementById:() => nativeObject}
  });
  adapter.setRect(288,80,242,136);
  const opened = adapter.open('https://example.test/preview.m3u8');
  await flushNativeStart();
  const expected = [432,120,363,204];
  assert.deepEqual(physicalRect, expected);
  assert.deepEqual(nativeObject.style, {left:'288px',top:'80px',width:'242px',height:'136px'});

  physicalRect = [0,0,1920,1080];
  prepared();
  assert.deepEqual(physicalRect, expected, 'the playing surface must retain the requested preview area');
  physicalRect = [0,0,1920,1080];
  mock.listener().oncurrentplaytime(0);
  await opened;
  assert.deepEqual(physicalRect, expected, 'first decoded frame must retain the preview area');

  physicalRect = [0,0,1920,1080];
  mock.listener().onevent('PLAYER_MSG_RESOLUTION_CHANGED', '1920x1080');
  assert.deepEqual(physicalRect, expected, 'adaptive metadata must not expand a preview to fullscreen');
  adapter.setRect(0,0,1280,720);
  physicalRect = [1,1,1,1];
  mock.listener().onevent('PLAYER_MSG_RESOLUTION_CHANGED', '1280x720');
  assert.deepEqual(physicalRect, [0,0,1920,1080], 'surface restoration must use the current fullscreen area');

  adapter.setRect(288,80,242,136);
  mock.avplay.setDisplayMethod = function () { physicalRect = [0,0,1920,1080]; };
  await adapter.setDisplayMode('PLAYER_DISPLAY_MODE_LETTER_BOX');
  assert.deepEqual(physicalRect, expected, 'changing aspect mode must not resize the preview surface');
  assert.equal(mock.calls.filter(call => call[0] === 'open').length, 1, 'surface updates must not reopen the stream');
  await adapter.stop();
});

test('fullscreen requested during a seek is restored after either native seek outcome', async () => {
  const mock = createAvplayDouble(), nativeObject = {hidden:true, style:{}};
  const adapter = create({avplay:mock.avplay,
    environment:{innerWidth:1280,innerHeight:720,setTimeout,clearTimeout},
    document:{getElementById:() => nativeObject}});
  await adapter.setDisplayMode('PLAYER_DISPLAY_MODE_LETTER_BOX');
  adapter.setRect(288,80,242,136);
  const opened = adapter.open('https://example.test/movie.mp4');
  await flushNativeStart(); mock.listener().oncurrentplaytime(0); await opened;
  assert.equal(mock.displayMode(), 'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO');
  const seeking = adapter.seek(15);
  const rectCalls = mock.calls.filter(call => call[0] === 'setDisplayRect').length;
  const modeCalls = mock.calls.filter(call => call[0] === 'setDisplayMethod').length;
  adapter.setRect(0,0,1280,720);
  await assert.rejects(adapter.setDisplayMode('PLAYER_DISPLAY_MODE_FULL_SCREEN'), {name:'InvalidStateError'});
  assert.equal(nativeObject.style.width, '1280px');
  assert.equal(mock.calls.filter(call => call[0] === 'setDisplayRect').length, rectCalls,
    'no native API is called during async seek');
  assert.equal(mock.calls.filter(call => call[0] === 'setDisplayMethod').length, modeCalls);
  assert.equal(adapter.getState().displayMode, 'PLAYER_DISPLAY_MODE_LETTER_BOX');
  mock.pendingSeek().success(); await seeking;
  assert.equal(mock.displayMode(), 'PLAYER_DISPLAY_MODE_LETTER_BOX');
  assert.deepEqual(mock.calls.filter(call => call[0] === 'setDisplayRect').at(-1), ['setDisplayRect',0,0,1920,1080]);
  const failedSeek = adapter.seek(20), rejected = assert.rejects(failedSeek, /cannot seek/);
  adapter.setRect(288,80,242,136);
  mock.pendingSeek().failure(Error('cannot seek')); await rejected;
  assert.equal(mock.displayMode(), 'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO');
  assert.deepEqual(mock.calls.filter(call => call[0] === 'setDisplayRect').at(-1), ['setDisplayRect',432,120,363,204]);
  assert.equal(mock.calls.filter(call => call[0] === 'open').length, 1);
  await adapter.stop();
});

test('a missing seek callback releases queued channel replacement and late callbacks cannot settle a new seek', async () => {
  const mock = createAvplayDouble(), clock = createClock();
  const adapter = create({avplay:mock.avplay,environment:clock,now:clock.now});
  const opened = adapter.open('https://example.test/first.mp4');
  await flushNativeStart(); mock.listener().oncurrentplaytime(0); await opened;
  const seeking = adapter.seek(10), rejected = assert.rejects(seeking, {name:'TimeoutError'});
  const oldSeek = mock.pendingSeek();
  const replacement = adapter.open('https://example.test/second.mp4');
  await clock.advance(10000); await rejected;
  mock.listener().oncurrentplaytime(0); await replacement;
  assert.equal(mock.calls.filter(call => call[0] === 'open').length, 2);
  const newSeek = adapter.seek(20), currentSeek = mock.pendingSeek();
  oldSeek.success();
  await assert.rejects(adapter.seek(30), /already pending/);
  currentSeek.success(); await newSeek;
  await adapter.stop(); assert.equal(clock.pending(), 0);
});

test('25 minutes of live progress retain one stream and an inactivity deadline without per-frame native polling', async () => {
  const mock = createAvplayDouble(), clock = createClock();
  let nativeReads = 0;
  const currentTime = mock.avplay.getCurrentTime;
  mock.avplay.getCurrentTime = () => { nativeReads += 1; return currentTime(); };
  mock.durationMs(0);
  const adapter = create({avplay:mock.avplay,environment:clock,now:clock.now});
  const opened = adapter.open('https://example.test/live.ts', {isLive:true});
  await flushNativeStart(); mock.listener().oncurrentplaytime(0); await opened;
  for (let second = 1; second <= 1500; second += 1) {
    mock.currentTimeMs(second * 1000); mock.listener().oncurrentplaytime(second * 1000);
    await clock.advance(1000);
  }
  assert.equal(mock.calls.filter(call => call[0] === 'open').length, 1);
  assert.ok(nativeReads < 80, `native reads stay bounded: ${nativeReads}`);
  assert.equal(clock.pending(), 1, 'only one inactivity deadline is retained');
  await adapter.stop(); assert.equal(clock.pending(), 0);
});

test('a silent live stall gets two guarded recoveries preserving headers and the latest fullscreen rectangle', async () => {
  const mock = createAvplayDouble(), clock = createClock(), guarded = [];
  mock.avplay.setBufferingParam=(...args)=>mock.calls.push(['buffer',...args]);
  mock.durationMs(0);
  const adapter = create({avplay:mock.avplay,
    environment:{...clock,innerWidth:1280,innerHeight:720},now:clock.now,
    beforeReconnect:url => guarded.push(url)});
  adapter.setRect(288,80,242,136);
  const url = 'https://example.test/live.ts';
  const opened = adapter.open(url, {isLive:true,bufferPreset:'stable',headers:{'User-Agent':'TVBro-Test',Cookie:'a=b'}});
  await flushNativeStart(); const oldListener = mock.listener(); oldListener.oncurrentplaytime(0); await opened;
  adapter.setRect(0,0,1280,720);
  for (let recovery = 1; recovery <= 2; recovery += 1) {
    await clock.advance(30000);
    assert.equal(mock.calls.filter(call => call[0] === 'open').length, recovery + 1);
    assert.deepEqual(mock.calls.filter(call => call[0] === 'setDisplayRect').at(-1), ['setDisplayRect',0,0,1920,1080]);
    mock.listener().oncurrentplaytime(0);
  }
  oldListener.onerror('stale connection error');
  assert.equal(adapter.getState().error, null);
  assert.deepEqual(guarded, [url,url]);
  assert.equal(mock.calls.filter(call => call[0] === 'setStreamingProperty' && call[1] === 'COOKIE' && call[2] === 'a=b').length, 3);
  assert.equal(mock.calls.filter(call=>call[0]==='buffer'&&call[1]==='PLAYER_BUFFER_FOR_RESUME'&&call[3]===8).length,3);
  await clock.advance(30000);
  assert.equal(mock.calls.filter(call => call[0] === 'open').length, 3, 'retries do not continue forever');
  assert.equal(adapter.getState().error.name, 'TimeoutError');
  assert.equal(adapter.getState().playing, false);
  assert.equal(clock.pending(), 0);
});

for (const signal of ['onerror','display']) test('long live playback recovers a lost native state from '+signal+' without a terminal InvalidStateError', async () => {
  const mock=createAvplayDouble(),clock=createClock();mock.durationMs(0);
  const adapter=create({avplay:mock.avplay,environment:clock,now:clock.now});
  adapter.setRect(0,0,1280,720);
  const opened=adapter.open('https://example.test/live.ts',{isLive:true,headers:{Cookie:'fixture=1'}});
  await flushNativeStart();mock.listener().oncurrentplaytime(0);await opened;
  const oldListener=mock.listener();
  const stop=mock.avplay.stop;
  mock.avplay.stop=()=>{
    if(mock.avplay.getState()==='NONE')throw Object.assign(Error('stop from NONE'),{name:'InvalidStateError'});
    return stop();
  };
  mock.nativeState('NONE');
  if(signal==='onerror') {
    oldListener.onerror('PLAYER_ERROR_INVALID_STATE');
    oldListener.onerrormsg('PLAYER_ERROR_INVALID_STATE','InvalidStateError');
  } else {
    const setRect=mock.avplay.setDisplayRect;
    mock.avplay.setDisplayRect=(...args)=>{if(mock.avplay.getState()==='NONE')throw Object.assign(Error('Invalid native state'),{name:'InvalidStateError'});return setRect(...args);};
    oldListener.onbufferingcomplete();
  }
  await flushNativeStart();
  assert.equal(mock.calls.filter(call=>call[0]==='open').length,2,'one guarded reconnect replaces the lost session');
  mock.listener().oncurrentplaytime(0);
  assert.equal(adapter.getState().error,null);assert.equal(adapter.getState().playing,true);
  assert.equal(mock.calls.filter(call=>call[0]==='setStreamingProperty'&&call[1]==='COOKIE').length,2);
  oldListener.onerror('PLAYER_ERROR_INVALID_STATE');await flushNativeStart();
  assert.equal(mock.calls.filter(call=>call[0]==='open').length,2,'obsolete callbacks cannot replace the new stream');
  await adapter.stop();assert.equal(clock.pending(),0);
});

test('sustained live progress restores recovery budget between separate long-session failures',async()=>{
  const mock=createAvplayDouble(),clock=createClock();mock.durationMs(0);
  const adapter=create({avplay:mock.avplay,environment:clock,now:clock.now});
  const opened=adapter.open('https://example.test/live.ts',{isLive:true});
  await flushNativeStart();mock.listener().onbufferingcomplete();mock.listener().oncurrentplaytime(0);await opened;
  for(let incident=0;incident<3;incident++) {
    for(let second=1;second<=31;second++) {
      await clock.advance(1000);mock.currentTimeMs(second*1000);mock.listener().oncurrentplaytime(second*1000);
    }
    mock.listener().onerror('PLAYER_ERROR_INVALID_STATE');await flushNativeStart();
    assert.equal(mock.calls.filter(call=>call[0]==='open').length,incident+2);
    mock.currentTimeMs(0);mock.listener().onbufferingcomplete();mock.listener().oncurrentplaytime(0);
    assert.equal(adapter.getState().error,null);assert.equal(adapter.getState().playing,true);
  }
  await adapter.stop();assert.equal(clock.pending(),0);
});

test('a live inactivity deadline checks the native clock before reopening when callbacks are missing', async () => {
  const mock = createAvplayDouble(), clock = createClock();
  const adapter = create({avplay:mock.avplay,environment:clock,now:clock.now});
  const opened = adapter.open('https://example.test/live.ts', {isLive:true});
  await flushNativeStart(); mock.listener().oncurrentplaytime(0); await opened;
  mock.currentTimeMs(30000); await clock.advance(30000);
  assert.equal(mock.calls.filter(call => call[0] === 'open').length, 1);
  await adapter.stop(); assert.equal(clock.pending(), 0);
});

test('pause and stop cancel live recovery, including an outstanding provider admission check', async () => {
  const mock = createAvplayDouble(), clock = createClock();
  let admit, checks = 0;
  const adapter = create({avplay:mock.avplay,environment:clock,now:clock.now,
    beforeReconnect:() => { checks += 1; return new Promise(resolve => { admit = resolve; }); }});
  const opened = adapter.open('https://example.test/live.ts', {isLive:true});
  await flushNativeStart(); mock.listener().oncurrentplaytime(0); await opened;
  await adapter.playPause(); await clock.advance(90000);
  assert.equal(checks, 0); assert.equal(clock.pending(), 0);
  await adapter.playPause(); await clock.advance(30000);
  assert.equal(checks, 1);
  await adapter.stop(); admit(); await flushNativeStart();
  assert.equal(mock.calls.filter(call => call[0] === 'open').length, 1);
  assert.equal(clock.pending(), 0);
});

test('pausing or resumed native progress cancels an admitted recovery before a new stream opens', async () => {
  for (const resolution of ['pause','progress']) {
    const mock = createAvplayDouble(), clock = createClock();
    let admit, checks=0;
    const adapter = create({avplay:mock.avplay,environment:clock,now:clock.now,
      beforeReconnect:() => ++checks===1 ? new Promise(resolve => { admit = resolve; }) : undefined});
    const opened = adapter.open('https://example.test/live.ts', {isLive:true});
    await flushNativeStart(); mock.listener().oncurrentplaytime(0); await opened;
    await clock.advance(30000);
    if (resolution === 'pause') await adapter.playPause();
    else { mock.currentTimeMs(31000); mock.listener().oncurrentplaytime(31000); }
    admit(); await flushNativeStart();
    assert.equal(mock.calls.filter(call => call[0] === 'open').length, 1, resolution);
    assert.equal(adapter.getState().buffering, false, resolution);
    if(resolution==='pause')await adapter.playPause();
    await clock.advance(30000);
    assert.equal(mock.calls.filter(call => call[0] === 'open').length,2,'cancelling one recovery must leave the next genuine stall recoverable');
    await adapter.stop(); assert.equal(clock.pending(), 0);
  }
});

test('provider cooldowns reject stall recovery and VOD never starts a live recovery deadline', async () => {
  const mock = createAvplayDouble(), clock = createClock();
  const adapter = create({avplay:mock.avplay,environment:clock,now:clock.now,
    beforeReconnect:() => Promise.reject(Error('Provider cooldown'))});
  const opened = adapter.open('https://example.test/live.ts', {isLive:true});
  await flushNativeStart(); mock.listener().oncurrentplaytime(0); await opened;
  await clock.advance(30000);
  assert.equal(mock.calls.filter(call => call[0] === 'open').length, 1);
  assert.equal(adapter.getState().error.message, 'Provider cooldown');
  assert.equal(clock.pending(), 0);
  const movie = adapter.open('https://example.test/movie.mp4', {isLive:false});
  await flushNativeStart(); mock.listener().oncurrentplaytime(0); await movie;
  await clock.advance(180000);
  assert.equal(mock.calls.filter(call => call[0] === 'open').length, 2);
  assert.equal(clock.pending(), 0);
  await adapter.stop();
});

test('rejects an actual prepare failure and exposes its native error', async () => {
  const mock = createAvplayDouble();
  mock.avplay.prepareAsync = function (_success, failure) {
    failure({ name: 'InvalidAccessError', message: 'Network unavailable' });
  };
  const adapter = create({ avplay: mock.avplay });
  const opened = adapter.open('https://example.test/broken.m3u8');
  const rejected = assert.rejects(opened, (error) => {
    assert.equal(error.name, 'NativePlaybackError');
    assert.equal(error.nativeError.message, 'Network unavailable');
    return true;
  });
  await flushNativeStart();

  await rejected;
  assert.equal(adapter.getState().error.message, 'Network unavailable');
});

test('reports native audio and subtitle tracks, selects them, toggles subtitles, and forwards native captions', async () => {
  const mock = createAvplayDouble();
  const adapter = create({avplay:mock.avplay});
  const nativeMode = 'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO';
  await adapter.setDisplayMode(nativeMode);
  const opened = adapter.open('https://example.test/multi-track.m3u8');
  await flushNativeStart();
  mock.listener().onbufferingcomplete();
  await opened;

  const tracks = adapter.getTracks();
  assert.deepEqual(tracks.filter(track => track.type === 'AUDIO').map(track => ({
    index:track.index, language:track.extraInfo.track_lang, selected:track.selected
  })), [
    {index:1, language:'eng', selected:true},
    {index:3, language:'pol', selected:false}
  ]);
  assert.equal(tracks.find(track => track.type === 'TEXT' && track.index === 4).selected, false);
  await adapter.selectTrack('AUDIO', 3);
  await adapter.selectTrack('TEXT', 5);
  assert.deepEqual(mock.calls.filter(call => call[0] === 'setSelectTrack'), [
    ['setSelectTrack', 'AUDIO', 3], ['setSelectTrack', 'TEXT', 5]
  ]);
  assert.equal(adapter.getTracks().find(track => track.type === 'TEXT' && track.index === 5).selected, true);
  await adapter.setSubtitlesEnabled(false);
  assert.equal(mock.subtitleHidden(), true);
  await adapter.setSubtitlesEnabled(true);
  assert.equal(mock.subtitleHidden(), false);

  const captions = [];
  adapter.onSubtitle(event => captions.push(event));
  mock.listener().onsubtitlechange('1250', 'Wiadomość', '0', [
    {attr_type:'color:white', start_pos:'10', stop_pos:'1000'}
  ]);
  assert.deepEqual(captions, [{
    durationMs:1250, text:'Wiadomość', dataType:'text',
    attributes:[{type:'color:white', startMs:10, stopMs:1000}]
  }]);
  assert.equal(mock.displayMode(), nativeMode);
  assert.equal(adapter.getState().displayMode, nativeMode);
});

test('exposes only documented discrete native speeds and native display modes', async () => {
  const mock = createAvplayDouble();
  const adapter = create({avplay:mock.avplay});
  assert.deepEqual(adapter.getCapabilities().playbackSpeeds, [1, 2, 4, 8]);
  assert.deepEqual(adapter.getCapabilities().displayModes, [
    'PLAYER_DISPLAY_MODE_LETTER_BOX',
    'PLAYER_DISPLAY_MODE_FULL_SCREEN',
    'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO'
  ]);
  await assert.rejects(adapter.setSpeed(0.5), {name:'NotSupportedError'});
  await assert.rejects(adapter.setDisplayMode('Stretch'), {name:'NotSupportedError'});

  const opened = adapter.open('https://example.test/movie.mp4');
  await flushNativeStart();
  mock.listener().onbufferingcomplete();
  await opened;
  const state = await adapter.setSpeed(2);
  assert.equal(mock.playbackSpeed(), 2);
  assert.equal(state.speed, 2);
});

test('reports unavailable optional track controls instead of simulating them', async () => {
  const mock = createAvplayDouble();
  mock.avplay.getTotalTrackInfo = undefined;
  mock.avplay.setSpeed = undefined;
  mock.avplay.setDisplayMethod = undefined;
  const adapter = create({avplay:mock.avplay});
  assert.equal(adapter.getCapabilities().tracks, false);
  assert.deepEqual(adapter.getCapabilities().playbackSpeeds, []);
  assert.deepEqual(adapter.getCapabilities().displayModes, []);

  const opened = adapter.open('https://example.test/movie.mp4');
  await flushNativeStart();
  mock.listener().onbufferingcomplete();
  await opened;
  assert.throws(() => adapter.getTracks(), {name:'NotSupportedError'});
  await assert.rejects(adapter.setSpeed(2), {name:'NotSupportedError'});
  await assert.rejects(adapter.setDisplayMode('PLAYER_DISPLAY_MODE_FULL_SCREEN'), {name:'NotSupportedError'});
});

test('controls the screensaver during playback without requiring a UI observer', async () => {
  const mock = createAvplayDouble();
  const screensaver = [];
  const adapter = create({avplay:mock.avplay, appcommon:{
    AppCommonScreenSaverState:{SCREEN_SAVER_ON:1,SCREEN_SAVER_OFF:0},
    setScreenSaver(value, success) { screensaver.push(value); success(); }
  }});
  const opened = adapter.open('https://example.test/movie.mp4');
  await flushNativeStart();
  mock.listener().onbufferingcomplete();
  await opened;
  assert.equal(screensaver.at(-1),0);
  await adapter.playPause();
  assert.equal(screensaver.at(-1),1);
  await adapter.playPause();
  assert.equal(screensaver.at(-1),0);
  mock.listener().onstreamcompleted();
  assert.equal(screensaver.at(-1),1);
  await adapter.stop();
  assert.deepEqual(screensaver,[1,0,1,0,1]);
});

test('a pending screensaver change is reconciled with stop and native failure', async () => {
  const mock = createAvplayDouble();
  const calls = [];
  const adapter = create({avplay:mock.avplay,appcommon:{
    AppCommonScreenSaverState:{SCREEN_SAVER_ON:1,SCREEN_SAVER_OFF:0},
    setScreenSaver(value,success,failure) { calls.push({value,success,failure}); }
  }});
  const opened = adapter.open('https://example.test/movie.mp4');
  await flushNativeStart();
  mock.listener().onbufferingcomplete();
  await opened;
  assert.deepEqual(calls.map(call=>call.value),[1]);
  calls[0].success();
  assert.deepEqual(calls.map(call=>call.value),[1,0]);
  await adapter.stop();
  calls[1].success();
  assert.deepEqual(calls.map(call=>call.value),[1,0,1]);
  calls[1].failure(new Error('late duplicate'));
  assert.equal(calls.length,3);
  calls[2].failure(new Error('firmware failure'));
  assert.equal(adapter.getState().screenSaverError.name,'ScreenSaverError');
  adapter.setRect(0,0,1280,720);
  assert.equal(calls.length,4,'a transient failure receives one retry on the next update');
  calls[3].failure(new Error('firmware still unavailable'));
  adapter.setRect(0,0,1280,720);
  assert.equal(calls.length,4,'persistent native errors do not create repeated retry requests');
});

test('an unavailable or throwing screensaver API does not prevent media cleanup', async () => {
  const mock = createAvplayDouble();
  const adapter = create({avplay:mock.avplay,appcommon:{
    AppCommonScreenSaverState:{SCREEN_SAVER_ON:1,SCREEN_SAVER_OFF:0},
    setScreenSaver() { throw new Error('not supported by firmware'); }
  }});
  const opened = adapter.open('https://example.test/movie.mp4');
  await flushNativeStart();
  mock.listener().onbufferingcomplete();
  await opened;
  mock.listener().onerror('PLAYER_ERROR_CONNECTION_FAILED');
  await flushNativeStart();
  assert.equal(adapter.getState().playing,false);
  assert.equal(mock.calls.some(call=>call[0]==='close'),true);
});

test('AVPlay HTTP refusal reaches the account guard before cleanup', async () => {
  const mock = createAvplayDouble();
  const refusals = [];
  const adapter = create({ avplay: mock.avplay, onProviderRejected: (url,status) => refusals.push([url,status]) });
  const opening = adapter.open('https://refusal.test/one.ts');
  const rejected = assert.rejects(opening, /HTTP error 403/);
  await flushNativeStart();
  mock.listener().onerrormsg('PLAYER_ERROR_CONNECTION_FAILED', 'HTTP error 403');
  await rejected;
  assert.deepEqual(refusals, [['https://refusal.test/one.ts',403]]);
  assert.equal(mock.calls.filter(call=>call[0]==='open').length, 1);
});

test('only native EOF from the active started session publishes completed state',async()=>{
  const mock=createAvplayDouble(),adapter=create({avplay:mock.avplay});
  const opening=adapter.open('https://example.test/episode.mp4');await flushNativeStart();mock.listener().onbufferingcomplete();await opening;
  const old=mock.listener();assert.equal(adapter.getState().completed,false);
  old.onstreamcompleted();assert.equal(adapter.getState().completed,true);
  await adapter.stop();assert.equal(adapter.getState().completed,false);
  old.onstreamcompleted();assert.equal(adapter.getState().completed,false);
});

test('late HTTP detail after generic AVPlay error still pauses the provider once', async () => {
  const mock = createAvplayDouble(), refusals = [];
  const adapter = create({ avplay: mock.avplay, onProviderRejected: (url,status) => refusals.push([url,status]) });
  const opening = adapter.open('https://refusal.test/late.ts');
  const rejected = assert.rejects(opening);
  await flushNativeStart();
  const listener = mock.listener();
  listener.onerror('PLAYER_ERROR_CONNECTION_FAILED');
  listener.onerrormsg('PLAYER_ERROR_CONNECTION_FAILED', 'HTTP error 429');
  listener.onerrormsg('PLAYER_ERROR_CONNECTION_FAILED', 'HTTP error 429');
  await rejected;
  assert.deepEqual(refusals, [['https://refusal.test/late.ts',429]]);
});
