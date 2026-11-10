'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');

const source = fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8');
const names = ['renderGuide', 'createGuideRow', 'groupGuideProgrammes', 'sameGuideProgrammes',
  'rememberGuideProgrammes', 'cachedGuideProgrammes', 'guideWindowChannels', 'onGuideScroll',
  'fetchGuide', 'renderChannels', 'showGuide', 'moveGuideRow', 'loadNowNext', 'visibleNowNextChannels', 'onChannelListScroll'];
const declarations = acorn.parse(source, {ecmaVersion:2022}).body[0].expression.callee.body.body;
const handlers = declarations.filter(node => node.type === 'FunctionDeclaration' && names.includes(node.id.name))
  .map(node => source.slice(node.start, node.end)).join('\n');

function harness(count = 10000) {
  const nodes = new Map(), frames = [], timers = new Map(), calls = [], metrics = {created:0, removed:0, focused:0, logos:0};
  let sequence = 0;
  class Node {
    constructor(tag, className, text) {
      this.tagName = tag; this.className = className || ''; this.textContent = text || ''; this.children = [];
      this.style = {}; this.attributes = {}; this.scrollTop = 0; this.clientHeight = 260; this.value = '';
      this.classList = {toggle:(value, enabled) => {
        const classes = this.className.split(' ').filter(name => name && name !== value);
        if (enabled) classes.push(value); this.className = classes.join(' ');
      }};
      metrics.created++;
    }
    set id(value) { this._id = value; nodes.set(value, this); }
    get id() { return this._id; }
    get firstChild() { return this.children[0]; }
    setAttribute(name, value) { this.attributes[name] = String(value); }
    getAttribute(name) { return this.attributes[name] == null ? null : this.attributes[name]; }
    getBoundingClientRect() {
      const left = parseFloat(this.style.left) || 0, width = parseFloat(this.style.width) || 100;
      return {left, right:left + width};
    }
    appendChild(child) { return this.insertBefore(child, null); }
    insertBefore(child, target) {
      if (child.parentNode) child.parentNode.removeChild(child);
      const index = target ? this.children.indexOf(target) : this.children.length;
      this.children.splice(index, 0, child); child.parentNode = this; return child;
    }
    removeChild(child) {
      if (child.contains(env.document.activeElement)) env.document.activeElement = null;
      this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; metrics.removed++;
    }
    contains(target) { return this === target || this.children.some(child => child.contains(target)); }
    querySelectorAll(selector) {
      const found = [];
      function walk(parent) { for (const child of parent.children) {
        const attribute = /\[([^=\]]+)(?:="([^"]*)")?\]/.exec(selector);
        const className = /^\.([^\[]+)/.exec(selector);
        if ((!attribute || child.getAttribute(attribute[1]) !== null && (attribute[2] == null || child.getAttribute(attribute[1]) === attribute[2])) &&
            (!className || child.className.split(' ').includes(className[1]))) found.push(child);
        walk(child);
      }}
      walk(this); return found;
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  }
  for (const id of ['guide-grid','guide-times','guide-date','guide-empty','channel-list','channel-search','channel-empty',
    'previous-page','next-page','page-label','channel-count','category-title','clear-channel-search','show-guide']) {
    const target = new Node('div'); target.id = id;
  }
  const channels = Array.from({length:count}, (_, index) => ({id:'channel-' + index, name:'Channel ' + index, logo:'logo-' + index}));
  const from = Date.parse('2026-10-26T10:00:00Z');
  const view = {screen:'catalog', source:{id:'source'}, request:1, guideRequest:0, guideFrom:from, guideStartIndex:0,
    guideFilter:'all', guideVisible:true, guideData:Object.create(null), guideDataOrder:[], guideDataRange:'',
    channels, filtered:channels, categories:[], category:null, page:0};
  const env = {view, Promise, Math, Number, String, Object, Date, dialogs:[], guideRowHeight:52, guideWindowSize:40,
    guideScrollTimer:null, guidePaintScheduled:false, guideRenderState:null, guideStart:null, pageSize:80, uiLanguage:'en',
    channelNowNextTimer:null, nowNextStart:null,
    document:{activeElement:null},
    window:{requestAnimationFrame(callback) { frames.push(callback); },
      setTimeout(callback, delay) { const id = ++sequence; timers.set(id, {callback,delay}); return id; }, clearTimeout(id) { timers.delete(id); }},
    byId(id) { return nodes.get(id) || null; },
    element(tag, className, value) { return new Node(tag, className, value); },
    button(label, className, action) { const target = new Node('button', className, label); target.click = action; return target; },
    image(url, className, parent) { metrics.logos++; const target = new Node('img', className); parent.appendChild(target); },
    clear(target) { for (const child of [...target.children]) target.removeChild(child); },
    text(target, value) { target.textContent = String(value); },
    t(value) { return value; }, clock(value) { return new Date(value).toISOString().slice(11,16); },
    focus(target) { if (target) { env.document.activeElement = target; metrics.focused++; } },
    usesLiveGuide() { return view.guideVisible; },
    activateChannel() {}, showProgramme() {}, refreshChannelRows() {}, renderNowNext() {}, updateLockButtons() {},
    cap() { return true; }, array(value) { return value || []; },
    status() {}, report(error) { throw error; },
    query(action, args) { calls.push([action,args]); return Promise.resolve({programmes:[],nowNext:{}}); },
    appendChannel(channel, index, parent) { const target = new Node('button'); target.id = 'channel-row-' + index; parent.appendChild(target); },
    syncLiveGuide() {}, firstLiveChannel() {}
  };
  vm.createContext(env); vm.runInContext(handlers, env);
  return {env, view, nodes, metrics, calls, from, frames, timers,
    programmes(channels, perChannel = 6, counter) {
      return channels.flatMap(channel => Array.from({length:perChannel}, (_, index) => {
        const programme = {title:channel.name + ' programme ' + index,
          start:new Date(from + index * 1200000).toISOString(), stop:new Date(from + (index + 1) * 1200000).toISOString()};
        Object.defineProperty(programme, 'channelId', {get() { if (counter) counter.reads++; return channel.id; }});
        return programme;
      }));
    },
    paint() { while (frames.length) frames.shift()(); },
    render() { const channels = env.guideWindowChannels(); env.renderGuide(channels, env.cachedGuideProgrammes(channels), from, from + 7200000); }};
}

test('guide programme partitioning scans each programme once with a 10k-channel catalogue', () => {
  const kit = harness(), selected = kit.view.channels.slice(0,40), counter = {reads:0};
  const programmes = kit.programmes(selected, 6, counter);
  kit.env.rememberGuideProgrammes(selected, programmes);
  assert.equal(counter.reads, programmes.length);
  assert.equal(kit.view.guideData['channel-39'].length, 6);
});

test('a completed background refresh retains visible EPG until its replacement is read', async () => {
  const kit=harness(1),selected=kit.view.channels.slice(0,1),old=kit.programmes(selected,1);
  kit.view.nowNext={[selected[0].id]:{now:old[0]}};
  kit.env.rememberGuideProgrammes(selected,old);kit.render();
  kit.view.guideDataRange=JSON.stringify([kit.view.request,kit.view.source.id,kit.from,kit.from+7200000]);
  let complete;kit.env.query=()=>new Promise(resolve=>{complete=resolve;});
  const previous=kit.nodes.get('guide-rows').children[0];
  const pending=kit.env.fetchGuide(true);
  assert.equal(kit.nodes.get('guide-rows').children[0],previous);
  assert.equal(kit.view.guideData[selected[0].id][0].title,old[0].title);
  assert.equal(kit.view.nowNext[selected[0].id].now.title,old[0].title);
  complete({programmes:[{...old[0],channelId:selected[0].id,title:'Updated'}],nowNext:{}});await pending;
  assert.equal(kit.view.guideData[selected[0].id][0].title,'Updated');
  assert.equal(kit.view.nowNext[selected[0].id],undefined,'a completed empty now/next replaces the old entry');
});

test('repainting an unchanged EPG reuses row, programme, logo and header nodes and preserves focus', () => {
  const kit = harness(), selected = kit.view.channels.slice(0,40);
  kit.env.rememberGuideProgrammes(selected, kit.programmes(selected)); kit.render();
  const rows = kit.nodes.get('guide-rows'), retained = rows.children[5].firstChild, header = kit.nodes.get('guide-times').firstChild;
  kit.env.document.activeElement = retained;
  const before = {...kit.metrics}; kit.render();
  assert.equal(kit.metrics.created, before.created); assert.equal(kit.metrics.removed, before.removed);
  assert.equal(kit.metrics.logos, before.logos); assert.equal(kit.metrics.focused, before.focused);
  assert.equal(kit.env.document.activeElement, retained); assert.equal(kit.nodes.get('guide-times').firstChild, header);
});

test('2500 pixel scroll events only repaint when leaving the mounted overscan window', () => {
  const kit = harness(); let paints = 0;
  kit.env.renderGuide = () => { paints++; };
  for (let pixel = 1; pixel <= 2500; pixel++) {
    kit.nodes.get('guide-grid').scrollTop = pixel; kit.env.onGuideScroll(); kit.paint();
  }
  assert.equal(paints, 1); assert.equal(kit.timers.size, 1);
  assert.equal(kit.env.guideWindowChannels().length, 40);
});

test('rewindowing retains overlapping EPG rows and only mounts new rows', () => {
  const kit = harness(); kit.render();
  const rows = kit.nodes.get('guide-rows'), retained = rows.children[30];
  kit.env.document.activeElement = retained.firstChild;
  const beforeLogos = kit.metrics.logos;
  kit.nodes.get('guide-grid').scrollTop = 34 * 52; kit.env.onGuideScroll(); kit.paint();
  assert.equal(rows.children.length, 40); assert.equal(kit.view.guideStartIndex, 28);
  assert.equal(rows.children[2], retained); assert.equal(kit.metrics.logos - beforeLogos, 28);
  assert.equal(kit.env.document.activeElement, retained.firstChild);
});

test('guide-only browsing avoids mounting the hidden channel list and mounts it on toggle', () => {
  const kit = harness(); kit.env.renderChannels();
  assert.equal(kit.nodes.get('channel-list').children.length, 0);
  assert.equal(kit.view.filtered, kit.view.channels);
  kit.env.showGuide();
  assert.equal(kit.nodes.get('channel-list').children.length, 80);
});

test('paging an unchanged search does not scan 10k channel names again', () => {
  const kit = harness(); let reads = 0;
  kit.view.channels.forEach((channel, index) => Object.defineProperty(channel, 'name', {get() { reads++; return 'Channel ' + index; }}));
  kit.nodes.get('channel-search').value = '9999'; kit.env.renderChannels();
  assert.equal(reads, 10000); assert.equal(kit.view.filtered.length, 1);
  kit.env.renderChannels(); assert.equal(reads, 10000);
});

test('guide fetch requests only uncached visible channels and keeps a 240-channel cache bound', async () => {
  const kit = harness(); kit.view.guideDataRange = JSON.stringify([1,'source',kit.from,kit.from + 7200000]);
  kit.env.rememberGuideProgrammes(kit.view.channels.slice(0,4), []);
  await kit.env.fetchGuide();
  assert.equal(kit.calls.length, 1);
  assert.deepEqual(Array.from(kit.calls[0][1].channels, channel => channel.id), ['channel-4','channel-5']);
  for (let start = 0; start < 1000; start += 40) kit.env.rememberGuideProgrammes(kit.view.channels.slice(start,start + 40), []);
  assert.equal(Object.keys(kit.view.guideData).length, 240);
});

test('new programme data only replaces affected rows without stealing another row focus', () => {
  const kit = harness(); kit.render(); const rows = kit.nodes.get('guide-rows');
  const unaffected = rows.children[1]; kit.env.document.activeElement = unaffected.firstChild;
  kit.env.rememberGuideProgrammes([kit.view.channels[0]], kit.programmes([kit.view.channels[0]])); kit.render();
  assert.equal(rows.children[1], unaffected); assert.equal(kit.env.document.activeElement, unaffected.firstChild);
  assert.equal(kit.metrics.focused, 0);
});

test('D-pad navigation crosses virtual window boundaries in both directions with 10k channels', () => {
  const kit = harness(); kit.render();
  kit.env.document.activeElement = kit.nodes.get('guide-rows').firstChild.firstChild;
  for (let index = 1; index <= 100; index++) {
    assert.equal(kit.env.moveGuideRow(40, kit.env.document.activeElement), true);
    assert.equal(kit.env.document.activeElement.getAttribute('data-guide-index'), String(index));
    assert.ok(kit.nodes.get('guide-rows').children.length <= 40);
  }
  for (let index = 99; index >= 0; index--) {
    assert.equal(kit.env.moveGuideRow(38, kit.env.document.activeElement), true);
    assert.equal(kit.env.document.activeElement.getAttribute('data-guide-index'), String(index));
  }
  assert.equal(kit.env.moveGuideRow(38, kit.env.document.activeElement), false, 'Up from the first row retains access to the toolbar');
});

test('vertical programme navigation keeps the programme column instead of switching to channel names', () => {
  const kit = harness(), selected = kit.view.channels.slice(0,40);
  kit.env.rememberGuideProgrammes(selected, kit.programmes(selected)); kit.render();
  const record = kit.env.guideRenderState.records['channel-0'];
  kit.env.document.activeElement = record.programmeNodes[3].node;
  kit.env.moveGuideRow(40, kit.env.document.activeElement);
  assert.equal(kit.env.document.activeElement, kit.env.guideRenderState.records['channel-1'].programmeNodes[3].node);
  kit.env.moveGuideRow(38, kit.env.document.activeElement);
  assert.equal(kit.env.document.activeElement, record.programmeNodes[3].node);
});

test('the paged channel list requests guide data for visible rows only and reuses recent results', async () => {
  const kit = harness(), list = kit.nodes.get('channel-list'); kit.view.guideVisible = false; kit.view.nowNextRequest = 0;
  kit.view.nowNext = {}; list.getBoundingClientRect = () => ({top:100,bottom:360});
  for (let index = 0; index < 80; index++) {
    const row = kit.env.element('button'); row.setAttribute('data-channel-id', kit.view.channels[index].id);
    row.getBoundingClientRect = () => ({top:100 + (index - 20) * 52,bottom:152 + (index - 20) * 52}); list.appendChild(row);
  }
  await kit.env.loadNowNext(kit.view.channels.slice(0,80));
  assert.deepEqual(Array.from(kit.calls[0][1].channels, channel => channel.id), ['channel-20','channel-21','channel-22','channel-23','channel-24']);
  await kit.env.loadNowNext(kit.view.channels.slice(0,80)); assert.equal(kit.calls.length, 1);
  assert.equal(list.children.length, 80);
});

test('channel-list scroll debounce keeps guide requests bounded and ignores a stale page', async () => {
  const kit = harness(); kit.view.guideVisible = false; kit.view.nowNextRequest = 0; kit.view.nowNext = {};
  for (let index = 0; index < 100; index++) kit.env.onChannelListScroll();
  assert.equal(kit.timers.size, 1);
  const timer = [...kit.timers.values()][0]; timer.callback(); await Promise.resolve(); await Promise.resolve();
  assert.ok(kit.calls[0][1].channels.length <= 12);
  kit.env.onChannelListScroll(); const stale = [...kit.timers.values()].at(-1); kit.view.page++; stale.callback();
  assert.equal(kit.calls.length, 1);
});
