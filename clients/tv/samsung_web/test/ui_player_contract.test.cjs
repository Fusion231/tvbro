'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');

const source = fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8');
const declarations = acorn.parse(source, {ecmaVersion:2022}).body[0].expression.callee.body.body;
const names = ['playContent', 'playerChannels', 'rememberReadyPlayer', 'channelIndex', 'showPlayerZap', 'cancelPlayerZap',
  'commitZap', 'zap', 'zapDigit', 'previousPlayerChannel', 'openPlayerChannels',
  'showChrome', 'updatePlayer', 'updatePlayerTimeline', 'updatePlayerHint', 'time', 'clock', 'onKey', 'back', 'dialog',
  'cancelSeekIntent', 'flushSeekIntent', 'renderEpisodeControls', 'changeEpisode', 'advanceCompletedEpisode',
  'playPause', 'control', 'clearPlaybackPresentation', 'startSeekHold', 'stopSeekHold', 'onKeyUp',
  'seekDuration', 'setScrubTarget', 'adjustScrub', 'cancelScrub', 'commitScrub', 'seekBarClick'];
const handlers = declarations.filter(node => node.type === 'FunctionDeclaration' && names.includes(node.id.name))
  .map(node => source.slice(node.start, node.end)).join('\n');
const playPauseBinding = declarations.find(node => node.type === 'ExpressionStatement' &&
  node.expression.type === 'CallExpression' && node.expression.callee.name === 'bind' &&
  node.expression.arguments[0].value === 'play-pause');
const progressBinding = declarations.find(node => node.type === 'ExpressionStatement' &&
  node.expression.type === 'CallExpression' && node.expression.callee.name === 'bind' &&
  node.expression.arguments[0].value === 'player-progress-track');

function harness(count = 161) {
  const calls = [], timers = new Map(), nodes = new Map(), dialogs = [], bodyClasses = new Set();
  let nextTimer = 0;
  function node() {
    return {hidden:false, disabled:false, style:{}, children:[], value:'', offsetWidth:100, offsetHeight:40, attributes:{},
      setAttribute(name, value) { this.attributes[name] = String(value); },
      getBoundingClientRect() { return this.bounds || {left:0,right:100,width:100}; },
      appendChild(child) { this.children.push(child); return child; },
      get firstChild() { return this.children[0]; }};
  }
  const channels = Array.from({length:count}, (_, index) => ({id:'provider-' + index, name:'Channel ' + (index + 1)}));
  const view = {player:true, playerReady:true, chrome:false, channel:channels[0], sourceId:'source',
    source:{id:'source'}, profile:{id:'profile'}, channels, filtered:channels, screen:'catalog',
    playbackRequest:0, playingState:{playing:true, isLive:true, duration:0, position:0}};
  const env = {view, calls, dialogs, Promise, Date, Math, Number, String, Object,
    playerZapTimer:null, playerZapFeedbackTimer:null, playerZapPending:null, playerZapDigits:'', previousPlayer:null,
    readyPlayer:{channel:channels[0],sourceId:'source',profileId:'profile'},
    playerStart:null, playerContent:null, previewStart:null, returnFocus:null, hideTimer:null,
    seekIntent:null,seekTimer:null,seekFlight:null,seekHold:null,scrub:null,episodeNavigation:null,completedEpisodeRequest:null,
    document:{activeElement:null, body:{classList:{add(value) { bodyClasses.add(value); calls.push(['class:add', value]); }, remove(value) { bodyClasses.delete(value); }, contains(value) { return bodyClasses.has(value); }}}},
    window:{setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, {callback,delay}); return id; }, clearTimeout(id) { timers.delete(id); }},
    byId(id) { if (!nodes.has(id)) nodes.set(id, node()); return nodes.get(id); },
    text(target, value) { target.textContent = String(value); },
    t(value, args) { return value.replace(/\{(\w+)\}/g, (_, key) => args[key]); },
    cap() { return true; },
    element() { return node(); },
    clear(target) { target.children = []; },
    button(label, className, action) { const target = node(); target.textContent = label; target.className = className; target.click = action; return target; },
    dialogButton(record, label, action) { const target = env.button(label, '', action); record.actions.appendChild(target); return target; },
    closeDialog() { dialogs.pop(); view.chrome = true; },
    focus(target) { env.document.activeElement = target; },
    visible(target) { return target && !target.hidden && !target.disabled; },
    cancelPreviewIdleTimer() {}, syncPreviewIdleTimer() {}, renderNowNext() {},
    bind(id, action) { env.byId(id).click = action; },
    fullRect() { return {x:0,y:0,width:1280,height:720}; },
    nativeRect(rect) {
      const style = env.byId('native-player').style;
      Object.assign(style, {left:rect.x + 'px', top:rect.y + 'px', width:rect.width + 'px', height:rect.height + 'px'});
      calls.push(['nativeRect', rect]);
    },
    afterLoadingPaint() { calls.push(['paint']); return Promise.resolve(); },
    query(action, args) {
      calls.push([action, args]);
      if (env.onQuery) env.onQuery(action, args);
      if (action === 'playback.play') {
        if (env.failPlayback) return Promise.reject(new Error('failure'));
        if (env.openPlayback) return env.openPlayback(args);
        view.playingState = Object.assign({}, view.playingState, {currentItem:args.channel});
      }
      return Promise.resolve();
    },
    platform:{getState() { return view.playingState; }, seek() { calls.push(['seek']); },
      playPause() {
        calls.push(['nativePlayPause', view.playingState.nativeState]);
        if (view.playingState.nativeState === 'NONE') return Promise.reject(new Error('There is no open Samsung AVPlay session.'));
        view.playingState = {...view.playingState, playing:!view.playingState.playing};
        return Promise.resolve(view.playingState);
      }},
    message(error) { return error.message; }, report(error) { throw error; },
    seek(delta) { calls.push(['seekBy', delta]); }, move(key) { calls.push(['move', key]); },
    stopPlayback() { env.cancelPlayerZap(); calls.push(['stop']); },
    returnFromPlayer() { env.cancelPlayerZap(); calls.push(['return']); }
  };
  vm.createContext(env); vm.runInContext(handlers + '\n' + source.slice(playPauseBinding.start, playPauseBinding.end), env);
  return {env, view, calls, nodes, timers, dialogs,
    press(keyCode, repeat = false) {
      let prevented = false;
      env.onKey({keyCode, repeat, preventDefault() { prevented = true; }});
      return prevented;
    },
    async expire(delay) {
      for (const [id, timer] of [...timers]) if (timer.delay === delay) { timers.delete(id); timer.callback(); }
      await new Promise(resolve => setImmediate(resolve));
    },
    async settle() { await new Promise(resolve => setImmediate(resolve)); },
    plays() { return calls.filter(row => row[0] === 'playback.play'); }};
}

for (const resumeMode of ['beginning', 'resume']) {
  test('foreground Play reopens closed VOD through its original authorization and resume intent: ' + resumeMode, async () => {
    const kit = harness(), item = {id:'movie',kind:'movie',title:'Movie'};
    await kit.env.playContent({item,sourceId:'source',resumeMode});
    kit.env.updatePlayer({nativeState:'NONE',playing:false,buffering:false,isLive:false,currentItem:null});
    const before = kit.plays().length; assert.equal(before, 1, 'lifecycle state updates never autoplay');
    kit.nodes.get('play-pause').click(); await kit.settle();
    assert.equal(kit.plays().length, before + 1);
    const reopened = kit.plays().at(-1)[1];
    assert.equal(reopened.item, item); assert.equal(reopened.sourceId, 'source'); assert.equal(reopened.resumeMode, resumeMode);
    assert.equal(kit.calls.filter(row => row[0] === 'nativePlayPause').length, 0);
  });
}

for (const archive of [false, true]) {
  test('foreground Play preserves ' + (archive ? 'archive programme' : 'live channel') + ' identity when reopening', async () => {
    const kit = harness(), channel = kit.view.channels[0];
    const programme = archive ? {channelId:channel.id,start:'2026-10-27T10:00:00Z',stop:'2026-10-27T11:00:00Z'} : undefined;
    await kit.env.playContent({channel,sourceId:'source',programme});
    kit.view.playingState = {nativeState:'NONE',playing:false,buffering:false,isLive:!archive,currentItem:null};
    kit.press(415); await kit.settle();
    assert.equal(kit.plays().length, 2);
    assert.equal(kit.plays().at(-1)[1].channel, channel);
    assert.equal(kit.plays().at(-1)[1].programme, programme);
  });
}

test('foreground Play still toggles an open PAUSED native session without resolving content again', async () => {
  const kit = harness();
  kit.view.playingState = {nativeState:'PAUSED',playing:false,isLive:false,duration:600,position:100};
  kit.nodes.get('play-pause').click(); await kit.settle();
  assert.equal(kit.calls.filter(row => row[0] === 'nativePlayPause').length, 1);
  assert.equal(kit.plays().length, 0); assert.equal(kit.view.playingState.playing, true);
});

for (const invalidation of ['cancelled request', 'profile changed', 'source changed', 'presentation cleared']) {
  test('foreground Play cannot reopen stale content after ' + invalidation, async () => {
    const kit = harness(); await kit.env.playContent({channel:kit.view.channels[0],sourceId:'source'});
    kit.view.playingState = {nativeState:'NONE',playing:false,buffering:false,isLive:true};
    if (invalidation === 'cancelled request') kit.view.playbackRequest++;
    if (invalidation === 'profile changed') kit.view.profile = {id:'other'};
    if (invalidation === 'source changed') kit.view.sourceId = 'other';
    if (invalidation === 'presentation cleared') { kit.env.clearPlaybackPresentation(); assert.equal(kit.env.playerContent, null); }
    kit.nodes.get('play-pause').click(); await kit.settle();
    assert.equal(kit.plays().length, 1);
  });
}

test('foreground Play shares a pending reopen and cannot revive it after cancellation', async () => {
  const kit = harness(); await kit.env.playContent({channel:kit.view.channels[0],sourceId:'source'});
  kit.view.playingState = {nativeState:'NONE',playing:false,buffering:false,isLive:true};
  let finish;
  kit.env.openPlayback = () => new Promise(resolve => { finish = resolve; });
  kit.nodes.get('play-pause').click(); kit.nodes.get('play-pause').click(); await kit.settle();
  assert.equal(kit.plays().length, 2, 'one new resolve/open for overlapping explicit Play actions');
  kit.env.clearPlaybackPresentation(); finish(); await kit.settle();
  assert.equal(kit.view.player, false); assert.equal(kit.view.playerReady, false); assert.equal(kit.env.playerContent, null);
});

function realSeek(kit) {
  const node = declarations.find(node => node.type === 'FunctionDeclaration' && node.id.name === 'seek');
  vm.runInContext(source.slice(node.start,node.end),kit.env);
  kit.view.playingState = {playing:true,isLive:false,duration:600,position:100};
  kit.env.platform.seek = target => { kit.calls.push(['absoluteSeek',target]); kit.view.playingState.position = target; return Promise.resolve(kit.view.playingState); };
}
test('finite seek burst retains all 20 steps while issuing one settled native request',async()=>{
  const kit=harness();realSeek(kit);
  for(let index=0;index<20;index++)kit.env.seek(10);
  assert.equal(kit.calls.filter(row=>row[0]==='absoluteSeek').length,0);
  await kit.expire(120);
  assert.deepEqual(kit.calls.filter(row=>row[0]==='absoluteSeek'),[['absoluteSeek',300]]);
});

test('holding fast forward keeps seeking without native repeats and stops on release', async () => {
  const kit = harness(); realSeek(kit);
  kit.press(417);
  await kit.expire(120);
  assert.deepEqual(kit.calls.filter(row => row[0] === 'absoluteSeek'), [['absoluteSeek',110]]);
  await kit.expire(400); await kit.expire(120);
  assert.deepEqual(kit.calls.filter(row => row[0] === 'absoluteSeek'), [['absoluteSeek',110],['absoluteSeek',120]]);
  kit.env.onKeyUp({keyCode:417});
  await kit.expire(300); await kit.expire(120);
  assert.equal(kit.calls.filter(row => row[0] === 'absoluteSeek').length, 2);
});

test('holding OK on a seek control repeats once per tick despite native key repeats', async () => {
  const kit = harness(); kit.view.chrome = true;
  kit.view.playingState = {playing:true,isLive:false,duration:600,position:100};
  kit.env.focus(kit.env.byId('seek-back'));
  kit.env.byId('seek-back').click = () => kit.env.seek(-10);
  kit.press(13); kit.press(13,true); kit.press(13,true);
  assert.equal(kit.calls.filter(row => row[0] === 'seekBy').length, 1);
  await kit.expire(400); await kit.expire(300);
  assert.equal(kit.calls.filter(row => row[0] === 'seekBy').length, 3);
  kit.env.onKeyUp({keyCode:13}); await kit.expire(300);
  assert.equal(kit.calls.filter(row => row[0] === 'seekBy').length, 3);
});

test('Back cancels a held seek before hiding controls', async () => {
  const kit = harness(); realSeek(kit); kit.view.chrome = true;
  kit.press(417); kit.press(10009);
  await kit.expire(400); await kit.expire(300); await kit.expire(120);
  assert.equal(kit.view.chrome, false);
  assert.equal(kit.calls.filter(row => row[0] === 'absoluteSeek').length, 1);
});

test('hidden VOD arrow hold is cancelled when playback is replaced', async () => {
  const kit = harness(); realSeek(kit);
  kit.press(37); await kit.expire(120);
  assert.deepEqual(kit.calls.filter(row => row[0] === 'absoluteSeek'), [['absoluteSeek',90]]);
  kit.view.playbackRequest++;
  await kit.expire(400); await kit.expire(300); await kit.expire(120);
  assert.equal(kit.calls.filter(row => row[0] === 'absoluteSeek').length, 1);
  assert.equal(kit.env.seekHold, null);
});

test('a rejected native seek stops the held action and still allows control auto-hide', async () => {
  const kit = harness(); realSeek(kit); kit.view.chrome = true;
  kit.env.platform.seek = () => Promise.reject(Error('InvalidValuesError'));
  kit.press(417); await kit.expire(120);
  assert.equal(kit.env.seekHold, null);
  kit.press(417, true);
  assert.equal(kit.env.seekHold, null, 'native repeats must not restart a rejected hold');
  await kit.expire(5000);
  assert.equal(kit.view.chrome, false);
});

test('playing with a recoverable action error still auto-hides controls', async () => {
  const kit = harness();
  const state = {playing:true,isLive:false,duration:600,position:100,error:{message:'InvalidValuesError'}};
  kit.env.updatePlayer(state); kit.env.showChrome(true);
  await kit.expire(5000); kit.env.updatePlayer(state);
  assert.equal(kit.view.chrome, false);
});

test('Back can keep paused controls hidden across repeated state updates', () => {
  const kit = harness(), state = {playing:false,isLive:false,nativeState:'PAUSED',duration:600,position:100};
  kit.env.updatePlayer(state); kit.press(10009); kit.env.updatePlayer(state);
  assert.equal(kit.view.chrome, false);
});
test('keys arriving during an asynchronous seek serialize and retain the latest target',async()=>{
  const kit=harness();realSeek(kit);let finish;
  kit.env.platform.seek=target=>{kit.calls.push(['absoluteSeek',target]);return new Promise(resolve=>{finish=resolve;});};
  kit.env.seek(10);await kit.expire(120);
  for(let index=0;index<19;index++)kit.env.seek(10);
  await kit.expire(120);
  assert.deepEqual(kit.calls.filter(row=>row[0]==='absoluteSeek'),[['absoluteSeek',110]]);
  finish({playing:true,isLive:false,duration:600,position:110});await kit.settle();
  assert.deepEqual(kit.calls.filter(row=>row[0]==='absoluteSeek'),[['absoluteSeek',110],['absoluteSeek',300]]);
  finish({playing:true,isLive:false,duration:600,position:300});await kit.settle();
  assert.equal(kit.env.seekIntent,null);
});
test('seek intent is cancelled when its playback identity is replaced',async()=>{
  const kit=harness();realSeek(kit);kit.env.seek(10);kit.view.playbackRequest++;
  await kit.expire(120);assert.equal(kit.calls.filter(row=>row[0]==='absoluteSeek').length,0);
});
test('automatic episode advance consumes only one genuine completion for the current identity',()=>{
  const kit=harness(),item={kind:'episode',id:'second'},next={kind:'episode',id:'third'};
  kit.view.channel=null;kit.view.item=item;kit.env.episodeNavigation={next};let advances=0;
  kit.env.changeEpisode=delta=>{assert.equal(delta,1);advances++;};
  kit.env.advanceCompletedEpisode({currentItem:item,playing:false});
  kit.env.advanceCompletedEpisode({currentItem:{id:'old'},completed:true});
  kit.env.advanceCompletedEpisode({currentItem:item,completed:true,error:Error('403')});
  assert.equal(advances,0);
  kit.env.advanceCompletedEpisode({currentItem:item,completed:true});kit.env.advanceCompletedEpisode({currentItem:item,completed:true});
  assert.equal(advances,1);
  kit.view.playbackRequest++;kit.env.episodeNavigation={next:null};kit.env.advanceCompletedEpisode({currentItem:item,completed:true});
  assert.equal(advances,1,'last episode never wraps');
});

test('a held channel key advances the selection but resolves only its settled channel', async () => {
  const kit = harness();
  for (let index = 0; index < 100; index++) assert.equal(kit.press(427, index > 0), true);
  assert.equal(kit.plays().length, 0);
  assert.equal(kit.timers.size, 1);
  assert.equal(kit.nodes.get('player-zap-status').textContent, '101 · Channel 101');
  await kit.expire(600);
  assert.equal(kit.plays().length, 1);
  assert.equal(kit.plays()[0][1].channel.id, 'provider-100');
  assert.equal(kit.view.chrome, false);
});

test('live startup and later buffering keep controls hidden so consecutive arrows still zap', async () => {
  const kit = harness(); let finishFirst;
  kit.env.openPlayback = args => {
    if (args.channel.id === 'provider-1') return new Promise(resolve => { finishFirst = resolve; });
    kit.env.updatePlayer({isLive:true,playing:true,buffering:false,nativeState:'PLAYING'});
    return Promise.resolve();
  };
  kit.press(38); await kit.expire(600);
  const states = [
    {nativeState:'NONE',playing:false,buffering:false},
    {nativeState:'IDLE',playing:false,buffering:true},
    {nativeState:'READY',playing:false,buffering:false},
    {nativeState:'PLAYING',playing:true,buffering:true}
  ];
  for (const state of states) {
    kit.env.updatePlayer({isLive:true,...state});
    assert.equal(kit.view.chrome,false,state.nativeState+' must not reveal controls');
    assert.equal(kit.env.document.activeElement,null,'loading must not move focus to the transport');
  }
  kit.press(38); await kit.expire(600);
  assert.equal(kit.plays().length,2);
  assert.equal(kit.plays()[1][1].channel.id,'provider-2');
  assert.equal(kit.calls.some(row => row[0] === 'move'),false);
  assert.equal(kit.view.playerReady,true);
  finishFirst(); await kit.settle();
  for (const state of states) kit.env.updatePlayer({isLive:true,...state});
  assert.equal(kit.view.chrome,false,'later live rebuffering must preserve arrow zapping');
  kit.press(40); await kit.expire(600);
  assert.equal(kit.plays().at(-1)[1].channel.id,'provider-1');
  finishFirst(); await kit.settle();
});

for (const key of [13,457]) {
  test('explicit '+(key === 13 ? 'OK' : 'Info')+' during a hidden channel start remains visible after readiness', async () => {
    const kit = harness(); let finish;
    kit.env.openPlayback = () => new Promise(resolve => { finish = resolve; });
    const start = kit.env.playContent({channel:kit.view.channels[1],sourceId:'source',keepChromeHidden:true});
    await kit.settle();
    kit.env.updatePlayer({isLive:true,playing:false,buffering:true,nativeState:'IDLE'});
    assert.equal(kit.view.chrome,false);
    kit.press(key); assert.equal(kit.view.chrome,true);
    kit.env.updatePlayer({isLive:true,playing:true,buffering:false,nativeState:'PLAYING'});
    finish(); await start;
    assert.equal(kit.view.chrome,true,'readiness must not reapply the original hidden choice');
    assert.equal(kit.nodes.get('player-chrome').hidden,false);
  });
}

test('real pause, playback failure and completed VOD still reveal controls', () => {
  const kit = harness();
  const states = [
    {isLive:true,playing:false,buffering:false,nativeState:'PAUSED'},
    {isLive:true,playing:false,buffering:false,error:{message:'Playback failed'}},
    {isLive:false,playing:false,buffering:false,position:120,duration:120,nativeState:'READY'}
  ];
  for (const state of states) {
    kit.env.showChrome(false); kit.env.updatePlayer(state);
    assert.equal(kit.view.chrome,true);
  }
});

test('numeric keys use the full channel order, ignore repeats, and commit with OK', async () => {
  const kit = harness(); kit.view.filtered = kit.view.channels.slice(80);
  for (const key of [49,54,49]) { kit.press(key); kit.press(key, true); }
  assert.equal(kit.env.playerZapDigits, '161');
  assert.equal(kit.press(13), true); await kit.settle();
  assert.equal(kit.plays().length, 1);
  assert.equal(kit.plays()[0][1].channel.id, 'provider-160');
  assert.equal(kit.timers.size, 0);
});

test('Back clears the pending number before the player Back ladder', async () => {
  const kit = harness(); kit.press(49); kit.press(10009);
  assert.equal(kit.env.playerZapDigits, ''); assert.equal(kit.timers.size, 0);
  assert.equal(kit.calls.filter(row => row[0] === 'return').length, 0);
  kit.press(10009);
  assert.equal(kit.calls.filter(row => row[0] === 'return').length, 1);
  await kit.expire(1200); assert.equal(kit.plays().length, 0);
});

test('cancelling playback and changing source cannot fire a delayed channel resolve', async () => {
  const kit = harness(); kit.press(427); kit.env.cancelPlayerZap();
  await kit.expire(600); assert.equal(kit.plays().length, 0);
  kit.press(427); kit.view.source = {id:'other'};
  await kit.expire(600); assert.equal(kit.plays().length, 0);
});

for (const key of [427, 49]) {
  test('opening a player dialog cancels pending ' + (key === 427 ? 'channel navigation' : 'numeric selection'), async () => {
    const kit = harness(); kit.press(key);
    assert.equal(kit.timers.size, 1);
    kit.env.dialog('Audio');
    assert.equal(kit.env.playerZapPending, null); assert.equal(kit.env.playerZapDigits, '');
    assert.equal(kit.nodes.get('player-zap-status').hidden, true);
    await kit.expire(600); await kit.expire(1200);
    assert.equal(kit.plays().length, 0); assert.equal(kit.dialogs.length, 1);
  });
}

test('previous channel swaps successful channels and respects profile isolation', async () => {
  const kit = harness();
  await kit.env.playContent({channel:kit.view.channels[1],sourceId:'source',keepChromeHidden:true});
  assert.equal(kit.env.previousPlayer.channel.id, 'provider-0');
  kit.press(39); await kit.settle();
  assert.equal(kit.plays().at(-1)[1].channel.id, 'provider-0');
  assert.equal(kit.env.previousPlayer.channel.id, 'provider-1');
  kit.press(10190); await kit.settle();
  assert.equal(kit.plays().at(-1)[1].channel.id, 'provider-1');
  kit.view.profile = {id:'other-profile'}; const before = kit.plays().length;
  kit.press(10190); await kit.settle(); assert.equal(kit.plays().length, before);
});

test('previous channel remembers the last ready channel when an intermediate resolve is superseded', async () => {
  const kit = harness(); let finishIntermediate;
  kit.env.openPlayback = args => args.channel.id === 'provider-1'
    ? new Promise(resolve => { finishIntermediate = resolve; }) : Promise.resolve();
  const intermediate = kit.env.playContent({channel:kit.view.channels[1],sourceId:'source',keepChromeHidden:true});
  await kit.settle();
  await kit.env.playContent({channel:kit.view.channels[2],sourceId:'source',keepChromeHidden:true});
  finishIntermediate(); await intermediate;
  assert.equal(kit.env.previousPlayer.channel.id, 'provider-0');
  assert.equal(kit.env.readyPlayer.channel.id, 'provider-2');
  kit.press(10190); await kit.settle();
  assert.equal(kit.plays().at(-1)[1].channel.id, 'provider-0');
});

test('quick channel list mounts a bounded window and changes channel only after selection', async () => {
  const kit = harness(2000); kit.view.channel = kit.view.channels[1000];
  kit.press(37);
  const record = kit.dialogs[0], list = record.body.firstChild;
  assert.equal(record.playerChannels, true); assert.equal(list.children.length, 21);
  assert.equal(kit.env.document.activeElement.id, 'player-channel-1000');
  assert.equal(kit.plays().length, 0);
  record.actions.children.find(row => row.textContent === 'Next channels').click();
  assert.equal(list.firstChild.id, 'player-channel-1011'); assert.equal(list.children.length, 21);
  record.actions.children.find(row => row.textContent === 'Previous channels').click();
  assert.equal(list.firstChild.id, 'player-channel-990');
  list.children[11].click(); await kit.settle();
  assert.equal(kit.plays()[0][1].channel.id, 'provider-1001');
  assert.equal(kit.dialogs.length, 0);
});

test('fullscreen object is presented before open and receives its final rectangle after paint', async () => {
  const kit = harness();
  kit.env.onQuery = action => {
    if (action !== 'playback.play' && action !== 'player.rect') return;
    assert.equal(kit.env.document.body.classList.contains('player-open'), true);
    assert.deepEqual(kit.nodes.get('native-player').style, {left:'0px', top:'0px', width:'1280px', height:'720px'});
  };
  await kit.env.playContent({channel:kit.view.channels[1],sourceId:'source'});
  const open = kit.calls.findIndex(row => row[0] === 'playback.play');
  const shown = kit.calls.findIndex(row => row[0] === 'class:add' && row[1] === 'player-open');
  const paint = kit.calls.findIndex(row => row[0] === 'paint');
  const rect = kit.calls.findIndex(row => row[0] === 'player.rect');
  assert.ok(shown >= 0 && shown < open); assert.ok(open < paint && paint < rect);
  assert.equal(kit.view.playerReady, true);
});

test('returning during the paint wait prevents a stale native rectangle update', async () => {
  const kit = harness(); let finishPaint;
  kit.env.afterLoadingPaint = () => new Promise(resolve => { finishPaint = resolve; });
  const start = kit.env.playContent({channel:kit.view.channels[1],sourceId:'source'});
  await kit.settle(); assert.equal(typeof finishPaint, 'function');
  kit.view.playbackRequest++; kit.view.player = false; finishPaint(); await start;
  assert.equal(kit.calls.filter(row => row[0] === 'player.rect').length, 0);
  assert.equal(kit.view.playerReady, false);
});

test('an older channel paint wait cannot resize or finish a newer request', async () => {
  const kit = harness(); let finishPaint;
  kit.env.afterLoadingPaint = () => new Promise(resolve => { finishPaint = resolve; });
  const first = kit.env.playContent({channel:kit.view.channels[1],sourceId:'source'});
  await kit.settle(); const finishFirst = finishPaint;
  kit.env.afterLoadingPaint = () => Promise.resolve();
  await kit.env.playContent({channel:kit.view.channels[2],sourceId:'source'});
  const rectangles = kit.calls.filter(row => row[0] === 'player.rect').length;
  finishFirst(); await first;
  assert.equal(kit.calls.filter(row => row[0] === 'player.rect').length, rectangles);
  assert.equal(kit.view.channel.id, 'provider-2');
});

test('VOD arrows retain seeking while visible controls retain ordinary navigation', () => {
  const kit = harness(); kit.view.playingState.isLive = false;
  kit.press(37); assert.deepEqual(kit.calls.at(-1), ['seekBy', -10]);
  kit.view.chrome = true; kit.press(39); assert.deepEqual(kit.calls.at(-1), ['move', 39]);
});

test('player timeline exposes finite progress and hides live-only shortcuts for VOD', () => {
  const kit = harness(), track = kit.env.byId('player-progress-track');
  kit.view.playingState = {isLive:false, duration:120, position:30};
  kit.env.updatePlayerTimeline(kit.view.playingState);
  assert.equal(kit.nodes.get('player-progress').hidden, false);
  assert.equal(kit.nodes.get('player-progress-fill').style.width, '25%');
  assert.equal(kit.nodes.get('player-time').textContent, '0:30 / 2:00');
  assert.equal(track.attributes['aria-valuenow'], '30');
  assert.equal(track.attributes['aria-valuemax'], '120');
  assert.equal(track.attributes['aria-valuetext'], '0:30 / 2:00');
  assert.equal(kit.nodes.get('player-channels').hidden, true);
  kit.env.updatePlayerTimeline({isLive:true});
  assert.equal(kit.nodes.get('player-progress').hidden, true);
  assert.equal(track.disabled, true);
});

test('progress track is an accessible, focusable slider in the player UI', () => {
  const html = fs.readFileSync(path.join(__dirname, '../ui/index.html'), 'utf8');
  assert.match(html, /id="player-progress-track"[^>]*role="slider"[^>]*tabindex="0"[^>]*data-nav/);
  assert.match(html, /id="player-progress-track"[^>]*aria-label="Playback position"/);
});

test('bar-specific key guidance appears only when the slider is focused or being adjusted', () => {
  const kit = harness(), track = kit.env.byId('player-progress-track'), state = {playing:true,isLive:false,duration:600,position:100};
  realSeek(kit); kit.view.playingState = state;
  kit.env.focus(kit.env.byId('play-pause')); kit.env.updatePlayer(state);
  assert.equal(kit.nodes.get('player-hint').textContent, 'OK — controls · Back — hide controls · Hold seek — keep seeking');
  kit.view.chrome = true; kit.env.focus(track); kit.env.updatePlayer(state);
  assert.equal(kit.nodes.get('player-hint').textContent, '← / → — adjust · OK — seek · Back — cancel');
  kit.press(39); kit.env.focus(kit.env.byId('play-pause')); kit.env.updatePlayer(state);
  assert.equal(kit.nodes.get('player-hint').textContent, '← / → — adjust · OK — seek · Back — cancel');
});

test('D-pad adjusts the focused progress slider and OK commits one seek', async () => {
  const kit = harness(); realSeek(kit); kit.view.chrome = true;
  kit.env.focus(kit.env.byId('player-progress-track'));
  assert.equal(kit.press(37), true);
  assert.equal(kit.calls.filter(row => row[0] === 'move').length, 0);
  assert.equal(kit.calls.filter(row => row[0] === 'absoluteSeek').length, 0, 'adjustment previews until OK');
  kit.press(13);
  await kit.settle();
  assert.deepEqual(kit.calls.filter(row => row[0] === 'absoluteSeek'), [['absoluteSeek', 90]]);
});

test('clicking the progress track commits the corresponding timeline position', async () => {
  assert.ok(progressBinding, 'the progress slider has a click handler');
  const kit = harness(); realSeek(kit);
  vm.runInContext(source.slice(progressBinding.start, progressBinding.end), kit.env);
  const track = kit.env.byId('player-progress-track');
  track.bounds = {left:20,right:220,width:200};
  track.click({detail:1,clientX:120,preventDefault() {}});
  await kit.settle();
  assert.deepEqual(kit.calls.filter(row => row[0] === 'absoluteSeek'), [['absoluteSeek', 300]]);
});

test('Back cancels a pending scrub without seeking or hiding controls', () => {
  const kit = harness(); realSeek(kit); kit.view.chrome = true;
  kit.env.focus(kit.env.byId('player-progress-track'));
  kit.press(37);
  kit.press(10009);
  assert.equal(kit.env.scrub, null);
  assert.equal(kit.view.chrome, true);
  assert.equal(kit.calls.filter(row => row[0] === 'absoluteSeek').length, 0);
});

test('controls remain visible while a keyboard scrub is pending', async () => {
  const kit = harness(); realSeek(kit); kit.view.chrome = true;
  kit.env.focus(kit.env.byId('player-progress-track'));
  kit.press(39);
  await kit.expire(5000);
  assert.equal(kit.view.chrome, true);
  assert.ok(kit.env.scrub);
});

test('live and non-finite-duration progress cannot be focused or sought', async () => {
  assert.ok(progressBinding, 'the progress slider has a click handler');
  const kit = harness(); realSeek(kit);
  vm.runInContext(source.slice(progressBinding.start, progressBinding.end), kit.env);
  const track = kit.env.byId('player-progress-track');
  kit.view.playingState = {isLive:true,duration:600,position:100};
  kit.env.updatePlayerTimeline(kit.view.playingState);
  assert.equal(track.disabled, true);
  track.click({detail:1,clientX:50,preventDefault() {}});
  kit.view.playingState = {isLive:false,duration:Infinity,position:100};
  kit.env.updatePlayerTimeline(kit.view.playingState);
  assert.equal(kit.env.byId('player-progress').hidden, true);
  assert.equal(track.disabled, true);
  track.click({detail:1,clientX:50,preventDefault() {}});
  await kit.settle();
  assert.equal(kit.calls.filter(row => row[0] === 'absoluteSeek').length, 0);
});

test('a scrub from an older playback request cannot seek the replacement stream', async () => {
  const kit = harness(); realSeek(kit); kit.view.chrome = true;
  kit.env.focus(kit.env.byId('player-progress-track'));
  kit.press(37);
  assert.ok(kit.env.scrub, 'the adjusted target remains pending until commit');
  kit.view.playbackRequest++;
  kit.press(13);
  await kit.settle();
  assert.equal(kit.calls.filter(row => row[0] === 'absoluteSeek').length, 0);
});

test('an in-flight scrub completion cannot flush a queued seek into replacement playback', async () => {
  assert.ok(progressBinding, 'the progress slider has a click handler');
  const kit = harness(); realSeek(kit); let finish;
  kit.env.platform.seek = target => {
    kit.calls.push(['absoluteSeek', target]);
    return new Promise(resolve => { finish = resolve; });
  };
  vm.runInContext(source.slice(progressBinding.start, progressBinding.end), kit.env);
  const track = kit.env.byId('player-progress-track'); track.bounds = {left:20,right:220,width:200};
  track.click({detail:1,clientX:120,preventDefault() {}});
  kit.env.setScrubTarget(450); kit.env.commitScrub();
  kit.env.clearPlaybackPresentation();
  finish({playing:true,isLive:false,duration:600,position:300});
  await kit.settle();
  assert.deepEqual(kit.calls.filter(row => row[0] === 'absoluteSeek'), [['absoluteSeek', 300]]);
});
