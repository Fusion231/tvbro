'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),acorn=require('acorn');
const source=fs.readFileSync(path.join(__dirname,'../ui/app.js'),'utf8');
const declarations=acorn.parse(source,{ecmaVersion:2022}).body[0].expression.callee.body.body;
const handlers=declarations.filter(node=>node.type==='FunctionDeclaration'&&['loadSource','showSettings','refreshLibraryPresentation'].includes(node.id.name)).map(node=>source.slice(node.start,node.end)).join('\n');
function harness(){
  let done;const pending=new Promise(resolve=>done=resolve),calls=[],view={request:0,screen:'home',busy:false,caps:{},profile:{name:'Fixture'}};
  const env={Promise,view,cancelPlayerZap(){},busy(value){view.busy=value;},status(){},sourceName:()=>'',t:value=>value,afterLoadingPaint:()=>Promise.resolve(),query:()=>pending,cancelled:()=>Error('cancelled'),clearPlaybackPresentation(){},setCatalog(){calls.push('catalog');},showHome(){calls.push('home');view.screen='home';},report(){calls.push('error');},showScreen(name){view.screen=name;},byId:()=>({}),focus(){},clear(){},text(){},refreshParental:()=>Promise.resolve(),renderSettings(){calls.push('settings');}};
  vm.createContext(env);vm.runInContext(handlers,env);return {env,view,calls,done};
}
test('startup catalogue completion preserves the user selected Settings screen',async()=>{
  const kit=harness(),pending=kit.env.loadSource({id:'fixture'});await Promise.resolve();kit.view.screen='settings';kit.done({});await pending;
  assert.deepEqual(kit.calls,['catalog']);assert.equal(kit.view.screen,'settings');assert.equal(kit.view.busy,false);
});
test('late settings load cannot render or steal focus after leaving Settings',async()=>{
  const kit=harness();kit.env.showSettings();kit.view.screen='profiles';kit.done({});await new Promise(resolve=>setImmediate(resolve));assert.deepEqual(kit.calls,[]);
});

for(const fullscreen of [false,true]) test('background catalogue publication preserves source identity, playback, navigation and list focus: fullscreen='+fullscreen,async()=>{
  const kit=harness(),config={id:'source'},old={id:'one',name:'One'},added={id:'two',name:'Two'};
  Object.assign(kit.view,{source:config,channels:[old],categories:[],category:null,screen:'catalog',player:fullscreen,preview:true,page:3,guideStartIndex:120});
  const list={scrollTop:245},focused={getAttribute:name=>name==='data-channel-id'?old.id:null,classList:{contains:name=>name==='channel-row'}},replacement={};
  kit.env.document={activeElement:focused};kit.env.dialogs=[];kit.env.array=value=>Array.isArray(value)?value:value.items;
  kit.env.byId=id=>id==='channel-list'?list:{};
  kit.env.focus=node=>{kit.env.document.activeElement=node;list.scrollTop=0;};
  kit.env.visible=()=>true;
  kit.env.renderCategories=()=>kit.calls.push('categories');
  kit.env.renderChannels=retain=>{assert.equal(retain,true);kit.calls.push('channels');kit.env.document.activeElement=null;};
  kit.env.document.querySelectorAll=()=>[{getAttribute:()=>old.id,...replacement}];
  kit.env.query=action=>Promise.resolve(action==='sources.catalog'?{source:{...config},channels:[old,added],categories:[]}:[]);
  kit.env.refreshLibraryPresentation();await new Promise(resolve=>setImmediate(resolve));
  assert.equal(kit.view.channels.length,2);assert.equal(kit.view.source,config,'unchanged source identity keeps pending guide reads valid');
  assert.equal(kit.view.screen,'catalog');assert.equal(kit.view.player,fullscreen);assert.equal(kit.view.preview,true);
  assert.equal(kit.view.page,3);assert.equal(kit.view.guideStartIndex,120);assert.equal(list.scrollTop,245);
  assert.equal(kit.env.document.activeElement!==null,true,'refresh retains the selected remote-control target');
  assert.deepEqual(kit.calls,fullscreen?[]:['categories','channels']);
});

for(const target of ['category','programme']) test('catalogue publication retains '+target+' focus without moving it to a channel heading',async()=>{
  const kit=harness(),attribute=target==='category'?'data-category-id':'data-channel-id',value=target==='category'?'"news"':'one';
  Object.assign(kit.view,{source:{id:'source'},screen:'catalog',category:null});
  const retained={getAttribute:name=>name===attribute?value:null,classList:{contains:()=>false}},replacement={getAttribute:name=>name===attribute?value:null};
  kit.env.document={activeElement:retained,querySelectorAll:()=>[replacement]};kit.env.dialogs=[];kit.env.array=value=>value;kit.env.visible=()=>true;
  kit.env.renderCategories=()=>{kit.env.document.activeElement=null;};
  kit.env.renderChannels=()=>{if(target==='programme')kit.env.document.activeElement=replacement;};
  kit.env.focus=node=>{kit.calls.push('focus');kit.env.document.activeElement=node;};
  kit.env.query=action=>Promise.resolve(action==='sources.catalog'?{source:{id:'source'},categories:[],channels:[]}:[]);
  kit.env.refreshLibraryPresentation(true);await new Promise(resolve=>setImmediate(resolve));
  assert.equal(kit.env.document.activeElement,replacement);
  assert.deepEqual(kit.calls,target==='category'?['focus']:[],'the EPG renderer already restored its precise programme');
});

test('daily catalogue updates retain the open series page and do not replace its cards',async()=>{
  const kit=harness();Object.assign(kit.view,{source:{id:'source'},screen:'media',mediaKind:'series',mediaPage:8,mediaSlice:400,category:null});
  kit.env.dialogs=[];kit.env.array=value=>value;kit.env.renderMediaCategories=()=>kit.calls.push('categories');kit.env.fetchMedia=()=>kit.calls.push('fetch');
  kit.env.query=action=>Promise.resolve(action==='sources.catalog'?{source:{id:'source'},categories:[],channels:[]}:[]);
  kit.env.refreshLibraryPresentation(true);await new Promise(resolve=>setImmediate(resolve));
  assert.deepEqual(kit.calls,[]);assert.equal(kit.view.mediaPage,8);assert.equal(kit.view.mediaSlice,400);
});
