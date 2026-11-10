'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');

// Exercise the shipped catalogue state handlers; only DOM and provider IO are doubled.
const source = fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8');
const names = ['fetchMedia','renderMediaBuffer','seriesCurrent','renderSeriesLoading',
  'appendSeriesItems','seriesNode','renderSeriesWindow','loadSeriesMore','scheduleSeriesScroll','moveSeries'];
const declarations = acorn.parse(source, {ecmaVersion:2022}).body[0].expression.callee.body.body;
const handlers = declarations.filter(node => node.type === 'FunctionDeclaration' && names.includes(node.id.name))
  .map(node => source.slice(node.start,node.end)).join('\n');

function deferred() {
  let resolve, reject;
  const promise = new Promise((done,failed) => { resolve = done; reject = failed; });
  return {promise,resolve,reject};
}
function items(start,count) {
  return Array.from({length:count},(_,offset) => ({id:'series-'+(start+offset),kind:'series',title:'Series '+(start+offset)}));
}
function cards(node) { return node.children.filter(child => child.className === 'media-card'); }
function harness(initial = items(0,14), hasMore = true) {
  const nodes = new Map(), calls = [], requests = [], paints = [], failures = [];
  let env;
  class Node {
    constructor(className = '') { this.children = []; this.attributes = {}; this.className = className; this.style = {}; this.hidden = false; this.value = ''; this.readOnly = true; this.clientWidth = 800; }
    appendChild(child) { return this.insertBefore(child,null); }
    insertBefore(child,before) { if (child.parentNode) child.parentNode.removeChild(child); this.children.splice(before ? this.children.indexOf(before) : this.children.length,0,child); child.parentNode = this; return child; }
    removeChild(child) { this.children.splice(this.children.indexOf(child),1); child.parentNode = null; return child; }
    get firstChild() { return this.children[0] || null; }
    get nextSibling() { return this.parentNode && this.parentNode.children[this.parentNode.children.indexOf(this)+1] || null; }
    get offsetWidth() { return this.className === 'media-card' ? 150 : this.clientWidth; }
    setAttribute(name,value) { this.attributes[name] = String(value); }
    getAttribute(name) { return this.attributes[name] == null ? null : this.attributes[name]; }
    contains(child) { return this.children.includes(child); }
    getBoundingClientRect() { return {top:-panel.scrollTop,height:500}; }
    querySelector(selector) {
      if (selector === '.media-panel') return panel;
      if (selector === 'button') return cards(this)[0] || null;
      const index = /^\[data-series-index="(\d+)"\]$/.exec(selector);
      return this.children.find(child => index ? child.getAttribute('data-series-index') === index[1] : selector.split(', ').some(value => child.className === value.slice(1))) || null;
    }
  }
  const panel = {scrollTop:720,clientHeight:500,offsetHeight:500,scrollHeight:100000,getBoundingClientRect:() => ({top:0,height:500})};
  for (const id of ['media-items','media-view','media-loading','media-retry','media-empty',
    'clear-media-search','media-search','media-previous','media-next','media-page']) nodes.set(id,new Node());
  env = {Promise,Math,Number,String,Object,
    view:{request:1,mediaRequest:1,source:{id:'source'},profile:{id:'profile'},screen:'media',mediaKind:'series',
      mediaCategory:null,mediaPage:1,mediaSlice:0,mediaItems:initial,mediaHasMore:hasMore},
    seriesList:null,mediaStart:null,mediaSearchTimer:null,seriesScrollScheduled:false,pageSize:80,
    dialogs:[],document:{activeElement:null},window:{clearTimeout() {},getComputedStyle(node) {
      return {height:node.className === 'media-card-title' ? '46px' : node.className === 'media-card-meta' ? '21.390625px' : '201px',
        paddingTop:node.className === 'media-card' ? '6px' : '4px',paddingBottom:'6px',borderTopWidth:'2px',borderBottomWidth:'2px',paddingLeft:'10px',paddingRight:'10px',marginRight:'6px',marginBottom:'8px'};
    }},
    byId:id => nodes.get(id),
    clear(node) { node.children.forEach(child => { child.parentNode = null; }); node.children = []; },
    text(node,value) { node.textContent = value; },t:value => value,
    array:value => Array.isArray(value) ? value : value && value.items || [],
    element(tag,className) { return new Node(className); },
    mediaCard(item) { const node = new Node('media-card'); node.item = item; node.appendChild(new Node('poster-placeholder')); node.appendChild(new Node('media-card-title')); if (item.year || item.rating) node.appendChild(new Node('media-card-meta')); return node; },
    focus(node) { env.document.activeElement = node; },
    status() {},report(error) { failures.push(error); },
    renderMediaItems() { throw Error('Series must append without replacing the grid'); },
    afterLoadingPaint() { const paint = deferred(); paints.push(paint); return paint.promise; },
    query(action,args) { calls.push({action,args}); const request = deferred(); requests.push(request); return request.promise; }
  };
  vm.createContext(env); vm.runInContext(handlers,env);
  env.seriesList = {request:1,source:env.view.source,categoryId:null,query:'',shown:0,keys:Object.create(null),
    ready:true,loading:false,failed:false,paused:false};
  env.appendSeriesItems();
  return {env,nodes,panel,calls,requests,failures,
    settle:() => new Promise(resolve => setImmediate(resolve)),
    async paint() { const pending = paints.splice(0); pending.forEach(paint => paint.resolve()); await this.settle(); }};
}

test('concurrent series scroll loads share one next-page request without invalidating details', async () => {
  const kit = harness(), generation = kit.env.view.mediaRequest;
  const first = kit.env.loadSeriesMore(), second = kit.env.loadSeriesMore();
  assert.equal(first,second); assert.equal(kit.calls.length,1);
  assert.equal(kit.calls[0].args.page,2);
  assert.equal(kit.env.view.mediaRequest,generation);
  kit.requests[0].resolve({items:items(14,14),page:2,hasMore:true}); await first;
  assert.equal(cards(kit.nodes.get('media-items')).length,28);
  assert.equal(kit.env.seriesList.loading,false);
});

for (const changed of ['category','query','profile generation','source','screen']) {
  test('a late series append cannot modify the catalogue after '+changed+' changes', async () => {
    const kit = harness(), pending = kit.env.loadSeriesMore(), original = kit.env.view.mediaItems;
    if (changed === 'category') kit.env.view.mediaCategory = 'another';
    if (changed === 'query') kit.nodes.get('media-search').value = 'another';
    if (changed === 'profile generation') { kit.env.view.profile = {id:'another'}; kit.env.view.mediaRequest++; }
    if (changed === 'source') kit.env.view.source = {id:'another'};
    if (changed === 'screen') kit.env.view.screen = 'home';
    kit.requests[0].resolve({items:items(14,14),page:2,hasMore:false}); await pending;
    assert.equal(kit.env.view.mediaItems,original);
    assert.equal(kit.env.view.mediaPage,1);
    assert.equal(cards(kit.nodes.get('media-items')).length,14);
    assert.equal(kit.failures.length,0);
  });
}

test('large local search results reveal the remaining batch without provider queries or losing focus and scroll', async () => {
  const kit = harness(items(0,165),false), grid = kit.nodes.get('media-items');
  assert.equal(kit.env.seriesList.items.length,80); assert.equal(cards(grid).length,30);
  const first = cards(grid)[0], focused = cards(grid)[25]; kit.env.document.activeElement = focused;
  await kit.env.loadSeriesMore();
  assert.equal(kit.env.seriesList.items.length,160); assert.equal(cards(grid).length,30);
  assert.equal(cards(grid)[0],first); assert.equal(kit.env.document.activeElement,focused);
  assert.equal(kit.panel.scrollTop,720); assert.equal(kit.calls.length,0);
  await kit.env.loadSeriesMore();
  assert.equal(kit.env.seriesList.items.length,165); assert.equal(cards(grid).length,30); assert.equal(kit.calls.length,0);
});

test('deep scrolling bounds mounted cards, preserves exact row gaps, and remounts earlier series', async () => {
  const data = items(0,2000).map((item,index) => index % 10 < 5 ? {...item,year:'2024'} : item);
  const kit = harness(data,false), grid = kit.nodes.get('media-items');
  for (let batch=1;batch<25;batch++) await kit.env.loadSeriesMore();
  const first = kit.env.seriesNode(0); kit.env.document.activeElement = first;
  const offsets = kit.env.seriesList.layout.offsets;
  assert.equal(offsets[1],292.390625); assert.equal(offsets[2],563.390625);
  kit.panel.scrollTop = offsets[300]; kit.env.renderSeriesWindow();
  assert.ok(cards(grid).length <= 35); assert.equal(kit.env.seriesNode(0),first);
  assert.ok(kit.env.seriesNode(1500)); assert.equal(kit.panel.scrollTop,offsets[300]);
  assert.equal(grid.getAttribute('data-series-count'),'2000');
  kit.env.document.activeElement = kit.nodes.get('media-search'); kit.panel.scrollTop = 0; kit.env.renderSeriesWindow();
  assert.ok(kit.env.seriesNode(0)); assert.equal(kit.env.seriesNode(1500),null); assert.ok(cards(grid).length <= 30);
});

test('remote navigation crosses an unmounted window boundary in both directions', async () => {
  const kit = harness(items(0,160),false);
  await kit.env.loadSeriesMore();
  const active = kit.env.seriesNode(29); kit.env.document.activeElement = active;
  assert.equal(kit.env.moveSeries(40,active),true);
  assert.equal(kit.env.document.activeElement.getAttribute('data-series-index'),'34');
  const below = kit.env.document.activeElement;
  kit.panel.scrollTop = 5000; kit.env.renderSeriesWindow();
  assert.equal(kit.env.moveSeries(38,below),true);
  assert.equal(kit.env.document.activeElement.getAttribute('data-series-index'),'29');
  assert.equal(kit.calls.length,0);
});

test('small scroll and focus changes retain the same window and spacer nodes', () => {
  const kit = harness(items(0,160),false), grid = kit.nodes.get('media-items'), original = [...grid.children];
  kit.env.document.activeElement = kit.env.seriesNode(20); kit.panel.scrollTop += 10;
  kit.env.renderSeriesWindow();
  assert.deepEqual(grid.children,original); assert.equal(kit.panel.scrollTop,730);
});

test('a narrower grid recomputes row heights and keeps the focused logical series', () => {
  const data = items(0,80).map((item,index) => index % 10 < 5 ? {...item,year:'2024'} : item);
  const kit = harness(data,false), grid = kit.nodes.get('media-items'), focused = kit.env.seriesNode(25);
  kit.env.document.activeElement = focused; grid.clientWidth = 644; kit.env.renderSeriesWindow();
  assert.equal(kit.env.seriesList.layout.columns,4);
  assert.equal(kit.env.seriesList.layout.offsets[2],584.78125);
  assert.equal(kit.env.seriesNode(25),focused); assert.equal(kit.env.document.activeElement,focused);
  assert.ok(cards(grid).length <= 28); assert.equal(kit.panel.scrollTop,720);
});

test('an in-flight page arriving during details keeps the opener and catalogue position', async () => {
  const kit = harness(), opener = kit.env.seriesNode(13), pending = kit.env.loadSeriesMore();
  const original = [...cards(kit.nodes.get('media-items'))];
  kit.env.dialogs.push({focus:opener}); kit.env.document.activeElement = kit.nodes.get('media-search');
  kit.requests[0].resolve({items:items(14,14),page:2,hasMore:false}); await pending;
  assert.deepEqual(cards(kit.nodes.get('media-items')),original); assert.equal(kit.panel.scrollTop,720);
  kit.env.dialogs.pop(); kit.env.document.activeElement = opener; kit.env.renderSeriesWindow();
  assert.equal(kit.env.seriesNode(13),opener); assert.equal(kit.env.seriesList.items.length,28);
});

test('canonical end-of-list stops repeated scroll loads', async () => {
  const kit = harness(items(0,14),false);
  await kit.env.loadSeriesMore(); await kit.env.loadSeriesMore();
  kit.panel.scrollHeight = 900; kit.env.scheduleSeriesScroll(); await kit.paint();
  assert.equal(kit.calls.length,0);
  assert.equal(kit.nodes.get('media-loading').hidden,true);
  assert.equal(kit.nodes.get('media-retry').hidden,true);
});

test('an append failure retains rows and page, blocks automatic retries, and allows an explicit retry', async () => {
  const kit = harness(), grid = kit.nodes.get('media-items'), retained = cards(grid)[0];
  const load = kit.env.loadSeriesMore(); kit.requests[0].reject(Error('Fixture failure')); await load;
  assert.equal(cards(grid)[0],retained); assert.equal(cards(grid).length,14);
  assert.equal(kit.env.view.mediaPage,1); assert.equal(kit.env.seriesList.failed,true);
  assert.equal(kit.nodes.get('media-retry').hidden,false);
  kit.panel.scrollHeight = 900; kit.env.scheduleSeriesScroll(); await kit.paint();
  assert.equal(kit.calls.length,1);
  const retry = kit.env.loadSeriesMore();
  assert.equal(kit.calls[1].args.page,2);
  kit.requests[1].resolve({items:items(14,5),page:2,hasMore:false}); await retry;
  assert.equal(cards(grid).length,19); assert.equal(kit.env.seriesList.failed,false);
  assert.equal(kit.nodes.get('media-retry').hidden,true);
});

test('an empty filtered page with later pages pauses automatic draining but can advance explicitly', async () => {
  const kit = harness(), load = kit.env.loadSeriesMore();
  kit.requests[0].resolve({items:[],page:2,hasMore:true}); await load;
  assert.equal(kit.env.view.mediaPage,2); assert.equal(kit.env.view.mediaHasMore,true);
  assert.equal(kit.env.seriesList.paused,true); assert.equal(kit.nodes.get('media-retry').textContent,'Load more');
  kit.panel.scrollHeight = 900; kit.env.scheduleSeriesScroll(); await kit.paint();
  assert.equal(kit.calls.length,1);
  const next = kit.env.loadSeriesMore();
  assert.equal(kit.calls[1].args.page,3);
  kit.requests[1].resolve({items:items(14,4),page:3,hasMore:false}); await next;
  assert.equal(cards(kit.nodes.get('media-items')).length,18);
  assert.equal(kit.env.seriesList.paused,false);
});

test('overlapping provider rows are omitted without replacing existing cards', async () => {
  const kit = harness(), retained = cards(kit.nodes.get('media-items'))[12], load = kit.env.loadSeriesMore();
  kit.requests[0].resolve({items:items(12,8),page:2,hasMore:false}); await load;
  assert.equal(cards(kit.nodes.get('media-items')).length,20);
  assert.equal(cards(kit.nodes.get('media-items'))[12],retained);
});

test('retrying a failed initial list requests page one rather than skipping to page two', async () => {
  const kit = harness(), initial = kit.env.fetchMedia();
  assert.equal(kit.panel.scrollTop,0);
  kit.requests[0].reject(Error('Initial fixture failure')); await initial;
  assert.equal(cards(kit.nodes.get('media-items')).length,0);
  assert.equal(kit.nodes.get('media-retry').hidden,false);
  const retry = kit.env.loadSeriesMore();
  assert.equal(kit.calls[1].args.page,1);
  kit.requests[1].resolve({items:items(0,4),page:1,hasMore:false}); await retry;
  assert.equal(cards(kit.nodes.get('media-items')).length,4);
});

test('remote Down waits for the next page and retains the same grid column', async () => {
  const kit = harness(), grid = kit.nodes.get('media-items'), active = cards(grid)[13];
  kit.env.document.activeElement = active;
  assert.equal(kit.env.moveSeries(40,active),true);
  assert.equal(kit.env.document.activeElement,active);
  assert.equal(kit.calls.length,1);
  kit.requests[0].resolve({items:items(14,14),page:2,hasMore:false}); await kit.settle();
  assert.equal(kit.env.document.activeElement,cards(grid)[18]);
  assert.equal(cards(grid)[13],active);
});

test('an asynchronously loaded row cannot steal focus after the viewer moves elsewhere', async () => {
  const kit = harness(), grid = kit.nodes.get('media-items'), active = cards(grid)[13];
  kit.env.document.activeElement = active;
  assert.equal(kit.env.moveSeries(39,active),true);
  const moved = kit.nodes.get('media-search'); kit.env.document.activeElement = moved;
  kit.requests[0].resolve({items:items(14,14),page:2,hasMore:false}); await kit.settle();
  assert.equal(kit.env.document.activeElement,moved);
});
