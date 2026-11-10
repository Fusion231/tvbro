'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');

// Execute the shipped details handlers; only DOM, provider IO and native playback are doubled.
const source = fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8');
const declarations = acorn.parse(source, {ecmaVersion:2022}).body[0].expression.callee.body.body;
const names = ['showDetails','runtimeLabel','detailsCurrent','renderDetailsInformation','loadDetailsSeasons',
  'toggleDetailsSeason','renderEpisodeWindow','updateEpisodeProgress','startDetailsPlayback','discardDetails',
  'restoreDetails','moveDetails','time','updateSeriesProgress','episodeNumberLabel','episodeSummaryLabel'];
const handlers = declarations.filter(node => node.type === 'FunctionDeclaration' && names.includes(node.id.name))
  .map(node => source.slice(node.start,node.end)).join('\n');

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return {promise,resolve};
}
function harness(options = {}) {
  const calls = [], nodes = new Map();
  let env;
  class Node {
    constructor(tag, className, value) {
      this.tagName = tag; this.className = className || ''; this.value = value || '';
      this.children = []; this.attributes = {}; this.events = {}; this.style = {};
      this.hidden = false; this.disabled = false; this.scrollTop = 0; this.scrollLeft = 0;
      this.classList = {
        add:name => { if (!this.className.split(' ').includes(name)) this.className += ' ' + name; },
        remove:name => { this.className = this.className.split(' ').filter(value => value !== name).join(' '); },
        contains:name => this.className.split(' ').includes(name)
      };
    }
    get textContent() { return this.value + this.children.map(child => child.textContent).join(''); }
    set textContent(value) { this.value = String(value); this.children = []; }
    get firstChild() { return this.children[0]; }
    appendChild(child) { if (child.parentNode) child.parentNode.removeChild(child); this.children.push(child); child.parentNode = this; return child; }
    removeChild(child) {
      if (child.contains(env.document.activeElement)) env.document.activeElement = null;
      this.children.splice(this.children.indexOf(child),1); child.parentNode = null; return child;
    }
    contains(target) { return this === target || this.children.some(child => child.contains(target)); }
    setAttribute(name,value) { this.attributes[name] = String(value); }
    getAttribute(name) { return this.attributes[name] == null ? null : this.attributes[name]; }
    addEventListener(name,action) { (this.events[name] || (this.events[name] = [])).push(action); }
    querySelectorAll(selector) {
      const matches = [], className = /^\.([^\[]+)/.exec(selector), attribute = /\[([^=\]]+)="([^"]*)"\]/.exec(selector);
      function walk(parent) { parent.children.forEach(child => {
        if ((!className || child.className.split(' ').includes(className[1])) &&
          (!attribute || child.getAttribute(attribute[1]) === attribute[2])) matches.push(child);
        walk(child);
      }); }
      walk(this); return matches;
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  }
  const season = {id:'season-1',kind:'season',title:'Season 1'};
  const episodes = Array.from({length:options.count || 120},(_,index) =>
    ({id:'episode-'+index,kind:'episode',title:'Episode '+(index+1),episodeNumber:index+1}));
  const modal = new Node('div'); modal.hidden = true; nodes.set('modal-layer',modal);
  const body = new Node('body');
  env = {Promise,Math,Number,String,Object,view:{screen:'media',request:1,source:{id:'source'},profile:{id:'profile'}},
    dialogs:[],suspendedDetails:null,document:{activeElement:null,body},
    byId:id => nodes.get(id),
    element:(tag,className,value) => new Node(tag,className,value),
    clear(target) { [...target.children].forEach(child => target.removeChild(child)); },
    text(target,value) { target.textContent = String(value); },
    t(value,args) { return value.replace(/\{(\w+)\}/g,(_,key) => args[key]); },
    array:value => Array.isArray(value) ? value : value && value.items || [],
    cap:name => name === 'favorites' && !!options.favorites,
    message:error => error.message,
    image(url,className,parent) { const image = new Node('img',className); image.url = url; parent.appendChild(image); },
    button(label,className,action) {
      const target = new Node('button',className,label);
      target.click = () => { if (!target.disabled) return action(); }; return target;
    },
    dialog() {
      const node = new Node('section'), content = new Node('div'), error = new Node('p');
      node.appendChild(content); node.appendChild(error); modal.appendChild(node); modal.hidden = false;
      const record = {node,body:content,error}; env.dialogs.push(record); body.classList.add('dialog-open'); return record;
    },
    closeDialog(restore,record) {
      record = record || env.dialogs[env.dialogs.length-1]; record.closed = true;
      env.dialogs.splice(env.dialogs.indexOf(record),1); if (record.node.parentNode) record.node.parentNode.removeChild(record.node);
    },
    focus(target) { if (!target) return; env.document.activeElement = target; (target.events.focus || []).forEach(action => action()); },
    afterLoadingPaint:() => Promise.resolve(),
    query(action,args) {
      calls.push([action,args]);
      if (options.query) { const result = options.query(action,args); if (result !== undefined) return result; }
      if (action === 'media.children') return Promise.resolve({items:args.item.kind === 'series' ? [season] : episodes});
      if (action === 'media.progress') return Promise.resolve({positions:{},resumeAllowed:true});
      if (action === 'favorites.list') return Promise.resolve([]);
      return Promise.resolve({configured:false});
    },
    playContent(args) { calls.push(['play',args]); },
    chooseResume(item,sourceId,record) { env.startDetailsPlayback(record,item,'beginning'); }
  };
  vm.createContext(env); vm.runInContext(handlers,env);
  return {env,calls,modal,season,episodes,
    settle:() => new Promise(resolve => setImmediate(resolve)),
    async series() {
      const record = env.showDetails({id:'series',kind:'series',title:'Series'},'source');
      await this.settle(); env.toggleDetailsSeason(record.seasons[0]); await this.settle(); return record;
    }};
}

test('returning from playback keeps the freshly watched label when an older progress lookup finishes last', async () => {
  const progress = [];
  const kit = harness({query(action) { if (action === 'media.progress') { const request = deferred(); progress.push(request); return request.promise; } }});
  const record = await kit.series(), section = record.seasons[0];
  assert.equal(progress.length,1);
  kit.env.startDetailsPlayback(record,kit.episodes[0],'beginning');
  assert.equal(kit.modal.hidden,true);
  assert.equal(kit.env.restoreDetails(),true);
  assert.equal(progress.length,2);
  progress[1].resolve({positions:{'episode-0':{position:100,duration:100,progress:1,finished:true}}}); await kit.settle();
  const card = section.rail.querySelector('[data-episode-index="0"]');
  assert.equal(card.querySelector('.episode-position').textContent,'Watched');
  progress[0].resolve({positions:{'episode-0':{position:20,duration:100,progress:0.2,finished:false}}}); await kit.settle();
  assert.equal(card.querySelector('.episode-position').textContent,'Watched');
  assert.equal(card.querySelector('.episode-progress-fill').style.width,'100%');
});

test('restoring details removes a still-open player dialog before replacing its stack', async () => {
  const kit = harness(), record = await kit.series();
  kit.env.startDetailsPlayback(record,kit.episodes[0],'beginning');
  const playerDialog = kit.env.dialog('Playback settings');
  assert.equal(kit.env.restoreDetails(),true);
  assert.equal(playerDialog.closed,true);
  assert.equal(playerDialog.node.parentNode,null);
  assert.equal(kit.env.dialogs.length,1);
  assert.equal(kit.env.dialogs[0],record);
});

for (const changed of ['closed','source request','profile']) {
  test('a delayed progress response cannot update details after '+changed+' changes', async () => {
    const pending = deferred(), kit = harness({query:action => action === 'media.progress' ? pending.promise : undefined});
    const record = await kit.series(), card = record.seasons[0].rail.querySelector('.episode-card');
    if (changed === 'closed') kit.env.closeDialog(false,record);
    else if (changed === 'source request') kit.env.view.request++;
    else kit.env.view.profile = {id:'other-profile'};
    pending.resolve({positions:{'episode-0':{position:100,duration:100,finished:true}}}); await kit.settle();
    assert.equal(card.querySelector('.episode-position'),null);
    if (changed === 'closed') assert.equal(kit.modal.children.length,0);
    assert.equal(kit.env.detailsCurrent(record),false);
  });
}

for (const changed of ['source request','profile']) {
  test('returning after a different '+changed+' discards the old details sheet', async () => {
    const kit = harness(), record = await kit.series();
    kit.env.startDetailsPlayback(record,kit.episodes[0],'beginning');
    if (changed === 'source request') { kit.env.view.source = {id:'other-source'}; kit.env.view.request++; }
    else kit.env.view.profile = {id:'other-profile'};
    assert.equal(kit.env.restoreDetails(),false);
    assert.equal(kit.modal.hidden,true);
    assert.equal(kit.modal.children.length,0);
    assert.equal(kit.env.detailsCurrent(record),false);
  });
}

test('playback return restores the selected episode and scroll without fetching its loaded season again', async () => {
  const kit = harness(), record = await kit.series(), section = record.seasons[0];
  kit.env.renderEpisodeWindow(section,25,true); section.rail.scrollLeft = 25*252; record.scroll.scrollTop = 840;
  const childReads = kit.calls.filter(row => row[0] === 'media.children').length;
  section.rail.querySelector('[data-episode-index="25"]').click();
  assert.equal(kit.modal.hidden,true);
  assert.equal(kit.calls.at(-1)[0],'play');
  section.rail.scrollLeft = 0; record.scroll.scrollTop = 0;
  assert.equal(kit.env.restoreDetails(),true);
  assert.equal(kit.modal.hidden,false);
  assert.equal(kit.env.document.activeElement.episodeIndex,25);
  assert.equal(section.rail.scrollLeft,25*252);
  assert.equal(record.scroll.scrollTop,840);
  assert.equal(section.header.getAttribute('aria-expanded'),'true');
  assert.equal(section.rail.querySelectorAll('.episode-card').length,12);
  assert.equal(kit.calls.filter(row => row[0] === 'media.children').length,childReads);
  assert.equal(Object.hasOwn(kit.env.view.episodes,'details'),false,'episode navigation must not retain the entire details DOM');
});

test('an initial favorites response arriving after a successful toggle cannot undo the visible favorite state', async () => {
  const list = deferred(), toggle = deferred();
  const kit = harness({favorites:true,query(action) {
    if (action === 'favorites.list') return list.promise;
    if (action === 'favorites.toggle') return toggle.promise;
  }});
  const record = kit.env.showDetails({id:'movie',kind:'movie',title:'Movie'},'source');
  const favorite = record.node.querySelectorAll('.details-actions')[0].children.find(node => node.textContent === '♡ Favorites');
  favorite.click(); favorite.click();
  assert.equal(favorite.disabled,true);
  assert.equal(kit.calls.filter(row => row[0] === 'favorites.toggle').length,1);
  toggle.resolve({favorite:true}); await kit.settle();
  assert.equal(favorite.textContent,'♥ Favorites'); assert.equal(favorite.disabled,false);
  list.resolve([]); await kit.settle();
  assert.equal(favorite.textContent,'♥ Favorites');
});

function seriesSummary(overrides = {}) {
  const latestEpisode = {id:'episode-0',kind:'episode',title:'Pilot',seasonNumber:1,episodeNumber:1,parentId:'season-1'};
  return Object.assign({watchedCount:1,latestEpisode,
    latestPosition:{position:100,duration:100,progress:1,finished:true},
    nextEpisode:{id:'episode-1',kind:'episode',title:'Second episode',seasonNumber:1,episodeNumber:2,parentId:'season-1'},
    complete:false},overrides);
}

test('a collapsed started series shows watched history and plays the next episode through the existing handoff', async () => {
  const summary = seriesSummary();
  const kit = harness({query:action => action === 'media.seriesProgress' ? Promise.resolve(summary) : undefined});
  const record = kit.env.showDetails({id:'series',kind:'series',title:'Series'},'source');
  await kit.settle();
  assert.equal(record.node.querySelector('.details-series-progress').hidden,false);
  assert.equal(record.node.querySelector('.details-series-watched').textContent,'Watched episodes: 1');
  assert.equal(record.node.querySelector('.details-series-latest').textContent,'Last watched: S1E1, Pilot');
  assert.equal(record.node.querySelector('.details-series-next').textContent,'Next episode: S1E2, Second episode');
  assert.equal(record.node.querySelectorAll('.episode-card').length,0);
  assert.equal(kit.calls.filter(row => row[0] === 'media.children').length,1,'summary must not expand a season in the UI');
  const primary = record.node.querySelector('.details-primary');
  assert.equal(primary.textContent,'Play S1E2');
  assert.equal(kit.env.document.activeElement,primary,'async summary must preserve the initial primary focus');
  primary.click();
  const play = kit.calls.find(row => row[0] === 'play');
  assert.equal(play[1].item.id,'episode-1');
  assert.equal(play[1].sourceId,'source');
  assert.equal(play[1].resumeMode,'beginning');
});

test('an unfinished series episode uses the existing resume chooser', async () => {
  const summary = seriesSummary();
  summary.watchedCount = 0; summary.latestPosition = {position:30,duration:100,progress:0.3,finished:false};
  summary.nextEpisode = summary.latestEpisode;
  const kit = harness({query:action => action === 'media.seriesProgress' ? Promise.resolve(summary) : undefined});
  const choices = []; kit.env.chooseResume = (...args) => choices.push(args);
  const record = kit.env.showDetails({id:'series',kind:'series',title:'Series'},'source'); await kit.settle();
  const primary = record.node.querySelector('.details-primary');
  assert.equal(primary.textContent,'Resume S1E1');
  primary.click();
  assert.equal(choices.length,1); assert.equal(choices[0][0].id,'episode-0');
  assert.equal(choices[0][1],'source'); assert.equal(choices[0][2],record);
  assert.equal(kit.calls.some(row => row[0] === 'play'),false,'resume still needs the existing chooser/gate');
});

test('unstarted and complete series retain episode browsing without fabricating a next episode', async () => {
  for (const summary of [{watchedCount:0,latestEpisode:null,nextEpisode:null,complete:false},
    seriesSummary({nextEpisode:null,complete:true})]) {
    const kit = harness({query:action => action === 'media.seriesProgress' ? Promise.resolve(summary) : undefined});
    const record = kit.env.showDetails({id:'series',kind:'series',title:'Series'},'source'); await kit.settle();
    assert.equal(record.node.querySelector('.details-primary').textContent,'View episodes');
    assert.equal(record.node.querySelector('.details-series-progress').hidden,!summary.latestEpisode);
    if (summary.complete) assert.equal(record.node.querySelector('.details-series-next').textContent,'All available episodes watched');
    record.node.querySelector('.details-primary').click();
    assert.equal(kit.env.document.activeElement,record.seasons[0].header);
    assert.equal(kit.calls.some(row => row[0] === 'play'),false);
  }
});

test('the secondary browse action stays available on a started series', async () => {
  const kit = harness({query:action => action === 'media.seriesProgress' ? Promise.resolve(seriesSummary()) : undefined});
  const record = kit.env.showDetails({id:'series',kind:'series',title:'Series'},'source'); await kit.settle();
  const browse = record.node.querySelector('.details-browse-episodes');
  assert.equal(browse.hidden,false); assert.equal(browse.textContent,'View episodes');
  browse.click(); assert.equal(kit.env.document.activeElement,record.seasons[0].header);
});

test('playback return updates the series summary and rejects the older lookup', async () => {
  const pending = [];
  const kit = harness({query:action => {
    if (action === 'media.seriesProgress') { const read = deferred(); pending.push(read); return read.promise; }
  }});
  const record = kit.env.showDetails({id:'series',kind:'series',title:'Series'},'source'); await kit.settle();
  assert.equal(pending.length,1);
  kit.env.startDetailsPlayback(record,kit.episodes[0],'beginning');
  assert.equal(kit.env.restoreDetails(),true); assert.equal(pending.length,2);
  pending[1].resolve(seriesSummary()); await kit.settle();
  assert.equal(record.node.querySelector('.details-primary').textContent,'Play S1E2');
  const old = seriesSummary({watchedCount:0,latestPosition:{position:30,duration:100,finished:false}});
  old.nextEpisode = old.latestEpisode;
  pending[0].resolve(old); await kit.settle();
  assert.equal(record.node.querySelector('.details-primary').textContent,'Play S1E2');
  assert.equal(record.node.querySelector('.details-series-watched').textContent,'Watched episodes: 1');
});

for (const changed of ['closed','source request','profile']) {
  test('a delayed series summary cannot update details after '+changed+' changes', async () => {
    const pending = deferred();
    const kit = harness({query:action => action === 'media.seriesProgress' ? pending.promise : undefined});
    const record = kit.env.showDetails({id:'series',kind:'series',title:'Series'},'source'); await kit.settle();
    if (changed === 'closed') kit.env.closeDialog(false,record);
    else if (changed === 'source request') kit.env.view.request++;
    else kit.env.view.profile = {id:'other-profile'};
    pending.resolve(seriesSummary()); await kit.settle();
    assert.equal(record.node.querySelector('.details-series-progress').hidden,true);
    assert.equal(record.node.querySelector('.details-primary').textContent,'View episodes');
  });
}
