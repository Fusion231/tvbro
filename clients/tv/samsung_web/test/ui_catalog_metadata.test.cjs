'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');

const source = fs.readFileSync(path.join(__dirname,'../ui/app.js'),'utf8');
const declarations = acorn.parse(source,{ecmaVersion:2022}).body[0].expression.callee.body.body;
const handlers = declarations.filter(node=>node.type==='FunctionDeclaration' &&
  ['enrichMediaCards','renderMediaCard','moveSeries'].includes(node.id.name)).map(node=>source.slice(node.start,node.end)).join('\n');

function harness() {
  let finish;
  const pending = new Promise(resolve=>{finish=resolve;});
  const calls=[];
  const env={Object,JSON,view:{screen:'media',mediaRequest:1,source:{id:'source'},profile:{id:'profile'}},
    mediaMetadataRequest:null,mediaMetadata:Object.create(null),seriesList:null,array:value=>value,
    query(action,args){calls.push({action,args});return pending;},
    clear(node){node.children=[];},
    image(url,style,node){node.children.push({url});},
    element(tag,style,value){return {style,value};}
  };
  vm.createContext(env);vm.runInContext(handlers,env);
  const item={id:'series',kind:'series',title:'PL - Show',poster:'https://images.test/actor.jpg'};
  const node={parentNode:{},children:[],appendChild(child){this.children.push(child);}};
  return {env,calls,item,node,finish,settle:()=>new Promise(resolve=>setImmediate(resolve))};
}

test('catalog artwork updates in place without waiting to show cards or losing focus',async()=>{
  const h=harness();
  h.env.enrichMediaCards([{item:h.item,node:h.node}]);
  h.env.enrichMediaCards([{item:h.item,node:h.node}]);
  assert.equal(h.calls.length,1,'virtualization must not repeat the same lookup');
  assert.equal(h.calls[0].action,'media.enrich');
  h.finish([{...h.item,title:'Show',poster:'https://images.test/poster.jpg',description:'Synopsis'}]);await h.settle();
  assert.equal(h.item.poster,'https://images.test/poster.jpg');
  assert.equal(h.item.description,'Synopsis');
  assert.equal(h.node.children[0].url,'https://images.test/poster.jpg');
  assert.equal(h.node.children[1].value,'Show');
});

test('large windows enrich in bounded batches without dropping remaining cards',async()=>{
  const h=harness(), pending=[];
  h.env.query=(action,args)=>new Promise(resolve=>pending.push({args,resolve}));
  const cards=Array.from({length:65},(_,id)=>({item:{...h.item,id:String(id)},node:h.node}));
  h.env.enrichMediaCards(cards);
  for(let index=0;index<17;index++) {
    assert.equal(pending[index].args.items.length,index===16?1:4);
    pending[index].resolve(pending[index].args.items);await h.settle();
  }
  assert.equal(pending.length,17);
  h.env.enrichMediaCards(cards);assert.equal(pending.length,17);
});

test('a remounted visible card receives its pending metadata result',async()=>{
  const h=harness();h.env.enrichMediaCards([{item:h.item,node:h.node}]);
  h.node.parentNode=null;
  const remounted={...h.node,parentNode:{},children:[]};
  h.env.enrichMediaCards([{item:h.item,node:remounted}]);
  h.finish([{...h.item,poster:'https://images.test/poster.jpg'}]);await h.settle();
  assert.equal(h.calls.length,1);
  assert.equal(remounted.children[0]?.url,'https://images.test/poster.jpg');
});

test('remote navigation remains usable between enrichment and the next layout paint',async()=>{
  const h=harness(), target={};let rendered=false,focused;
  Object.assign(h.env,{dialogs:[],seriesCurrent:()=>true,scheduleSeriesScroll(){},
    seriesList:{layout:{columns:3,count:6},items:Array(6)},
    seriesNode:index=>rendered&&index===3?target:null,
    renderSeriesWindow(){rendered=true;},focus:node=>{focused=node;}});
  h.env.enrichMediaCards([{item:h.item,node:h.node}]);
  h.finish([{...h.item,poster:'https://images.test/poster.jpg'}]);await h.settle();
  assert.equal(h.env.moveSeries(40,{getAttribute:()=> '0'}),true);
  assert.equal(focused,target);
});

for(const changed of ['request','source','profile','screen']) {
  test('late catalog enrichment cannot repaint after '+changed+' changes',async()=>{
    const h=harness();h.env.enrichMediaCards([{item:h.item,node:h.node}]);
    if(changed==='request')h.env.view.mediaRequest++;
    if(changed==='source')h.env.view.source={id:'other'};
    if(changed==='profile')h.env.view.profile={id:'other'};
    if(changed==='screen')h.env.view.screen='home';
    h.finish([{...h.item,poster:'https://images.test/poster.jpg'}]);await h.settle();
    assert.equal(h.item.poster,'https://images.test/actor.jpg');
    assert.equal(h.node.children.length,0);
  });
}
