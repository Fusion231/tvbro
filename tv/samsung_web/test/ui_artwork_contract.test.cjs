'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');
const source = fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8');
const declarations = acorn.parse(source, {ecmaVersion:2022}).body[0].expression.callee.body.body;
const functions = declarations.filter(n=>n.type==='FunctionDeclaration' &&
  ['artworkUrl','image','startArtwork','scheduleArtwork'].includes(n.id.name))
  .map(n=>source.slice(n.start,n.end)).join('\n');

function harness() {
  let now=100000, timerId=0;
  const timers=new Map(), nodes=[], requests=[], metrics={visible:0,bounds:0};
  function element(tag) {
    if(tag==='a') return {set href(value){this.host=new URL(value).host;}};
    const listeners={}, attrs={};
    const node={hidden:false, onscreen:true, parentNode:null,
      addEventListener(event,fn){(listeners[event]??=[]).push(fn);},
      removeEventListener(event,fn){listeners[event]=(listeners[event]||[]).filter(f=>f!==fn);},
      setAttribute(key,value){attrs[key]=value;},removeAttribute(key){delete attrs[key];},getAttribute(key){return attrs[key];},
      getBoundingClientRect(){metrics.bounds++;return {top:this.onscreen?10:3000,bottom:this.onscreen?100:3100,left:0,right:100};},
      set src(value){requests.push({url:value,time:now,node:this});},
      emit(event){for(const fn of [...(listeners[event]||[])]) fn.call(this);}};
    nodes.push(node);return node;
  }
  const env={artworkScheduled:false,artworkTimer:null,artworkFlights:{},artworkInFlight:0,
    artworkHosts:{},artworkFailures:{},Date:{now:()=>now},window:{innerHeight:1080,innerWidth:1920},
    document:{hidden:false,body:{},createElement:element,querySelectorAll:()=>nodes.filter(n=>n.getAttribute('data-artwork-src'))},
    view:{player:false},dialogs:[],element,visible:n=>{metrics.visible++;return !n.hidden;},afterLoadingPaint:()=>Promise.resolve(),
    setTimeout(fn,delay){timers.set(++timerId,{fn,at:now+delay});return timerId;},clearTimeout:id=>timers.delete(id)};
  vm.createContext(env);vm.runInContext(functions,env);
  return {env,requests,nodes,metrics,
    add(url,onscreen=true){const n=env.image(url,'media-poster',{appendChild(){}});n.onscreen=onscreen;return n;},
    async tick(ms=0){now+=ms;for(const [id,timer] of [...timers])if(timer.at<=now){timers.delete(id);timer.fn();}await Promise.resolve();await Promise.resolve();}};
}
test('visible artwork from one host starts both bounded transfers without a one-second delay',async()=>{
  const h=harness();h.add('https://images.fixture/one.jpg');h.add('https://images.fixture/two.jpg');h.add('https://images.fixture/three.jpg');
  await h.tick();assert.equal(h.requests.length,2);
  h.requests[0].node.emit('load');await h.tick();assert.equal(h.requests.length,3);
  assert.equal(h.requests[2].time,h.requests[0].time,'cached and healthy artwork never waits for an artificial host timer');
});

test('rapid scrolling limits artwork to two transfers and skips offscreen posters',async()=>{
  const h=harness();for(let i=0;i<100;i++)h.add('https://images.fixture/'+i+'.jpg',i<20);
  await h.tick();assert.equal(h.requests.length,2);
  await h.tick(1000);assert.equal(h.requests.length,2);
  await h.tick(5000);assert.equal(h.requests.length,2);
  h.nodes[2].onscreen=false;h.requests[0].node.emit('load');await h.tick();
  assert.equal(h.requests.length,3);assert.equal(h.requests[2].url,'https://images.fixture/3.jpg');
  assert.equal(h.env.artworkInFlight,2);
});

test('a full artwork gate skips geometry reads and completion resumes the pending order',async()=>{
  const h=harness();
  for(let i=0;i<30;i++)h.add('https://images-'+i+'.fixture/poster.jpg');
  await h.tick();
  assert.equal(h.requests.length,2);
  assert.deepEqual(h.metrics,{visible:2,bounds:2},'stop measuring once both transfer slots are filled');
  h.env.scheduleArtwork();await h.tick();
  assert.deepEqual(h.metrics,{visible:2,bounds:2},'scroll/focus while full needs no layout reads');
  h.requests[0].node.emit('load');await h.tick();
  assert.equal(h.requests.length,3);
  assert.equal(h.requests[2].url,'https://images-2.fixture/poster.jpg');
  assert.equal(h.env.artworkInFlight,2);
});
test('three image errors pause the artwork host; another host still works and later action probes once',async()=>{
  const h=harness();for(let i=0;i<30;i++)h.add('https://images.fixture/'+i+'.jpg');
  for(let i=0;i<3;i++){await h.tick(i?1000:0);h.requests[i].node.emit('error');await h.tick();}
  assert.equal(h.requests.length,4,'only the already active second transfer may outlive the third failure');
  h.requests[3].node.emit('error');await h.tick(5000);assert.equal(h.requests.length,4);
  h.add('https://other.fixture/ok.jpg');await h.tick();assert.equal(h.requests.length,5);
  h.requests[4].node.emit('load');await h.tick();await h.tick(60000);
  assert.equal(h.requests.length,5,'no automatic cooldown retry');
  h.env.scheduleArtwork();await h.tick();assert.equal(h.requests.length,7,'normal bounded concurrency resumes only on later action');
});
test('duplicate pending URLs, failed URLs and hung images cannot flood the host',async()=>{
  const h=harness();h.add('https://images.fixture/same.jpg');h.add('https://images.fixture/same.jpg');
  await h.tick();await h.tick(2000);assert.equal(h.requests.length,1);
  await h.tick(15000);assert.equal(h.env.artworkInFlight,0);
  h.env.scheduleArtwork();await h.tick();assert.equal(h.requests.length,1);
});
test('TMDB thumbnail fallback passes through the same rate gate exactly once',async()=>{
  const h=harness(), n=h.add('https://image.tmdb.org/t/p/original/poster.jpg');
  await h.tick();assert.match(h.requests[0].url,/\/w342\//);
  n.emit('error');await h.tick();assert.equal(h.requests.length,2);
  await h.tick(1000);assert.match(h.requests[1].url,/\/original\//);
  n.emit('error');await h.tick(5000);assert.equal(h.requests.length,2);
});
