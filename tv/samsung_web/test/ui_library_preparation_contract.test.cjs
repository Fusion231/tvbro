'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const acorn=require('acorn');

const source=fs.readFileSync(path.join(__dirname,'../ui/app.js'),'utf8');
const declarations=acorn.parse(source,{ecmaVersion:2022}).body[0].expression.callee.body.body;
const functions=declarations.filter(node=>node.type==='FunctionDeclaration'&&['loadSource','updatePlayer'].includes(node.id.name));
const handlers=functions.map(node=>source.slice(node.start,node.end)).join('\n');

function nodes(){
  const values=Object.create(null);
  return id=>values[id]||(values[id]={hidden:false,disabled:false,style:{},setAttribute(){},getAttribute(){return null;},classList:{contains(){return false;}}});
}

test('source load reports failed sections while preserving available content',async()=>{
  const statuses=[],calls=[],translations=[],view={request:0,screen:'home',busy:false,caps:{}};
  const byId=nodes(),catalog={source:{id:'fixture'},channels:[{id:'live'}],categories:[],preparation:{warnings:[{kind:'series',label:'Series'}]}};
  const env={Promise,view,byId,cancelPlayerZap(){},busy(value){view.busy=value;},status(value,isError){statuses.push({value,isError});},
    sourceName:()=> 'Fixture',t(value,parameters){translations.push(value);return value.replace(/\{(\w+)\}/g,(match,key)=>parameters&&parameters[key]!=null?parameters[key]:match);},afterLoadingPaint:()=>Promise.resolve(),query(action){calls.push(action);return Promise.resolve(catalog);},
    cancelled:()=>Error('cancelled'),clearPlaybackPresentation(){},setCatalog(value){assert.equal(value,catalog);},showHome(){calls.push('home');view.screen='home';},
    report(error){throw error;}};
  vm.createContext(env);vm.runInContext(handlers,env);
  await env.loadSource({id:'fixture'});
  assert.deepEqual(calls,['sources.load','home']);
  assert.equal(statuses.some(row=>/Series/.test(row.value)),true,'the existing app status surface names the failed section');
  assert.equal(translations.includes('Series'),true,'section labels pass through the existing translator');
  assert.equal(statuses.some(row=>row.isError),false,'partial success is a warning, not a blocked-library error');
});

test('existing status surface labels each catalog-preparation stage',()=>{
  const statuses=[],view={busy:true,screen:'home',pairingDownloading:false,playingState:null,playerReady:false,player:false,chrome:false};
  const byId=nodes(),env={Promise,view,byId,t:value=>value,text(node,value){node.textContent=value;},status(value,isError,loading){statuses.push({value,isError,loading});},
    seekDuration:()=>0,updatePlayerHint(){},updatePlayerTimeline(){},message:error=>error.message,time:()=>'',syncPreviewIdleTimer(){},advanceCompletedEpisode(){}};
  vm.createContext(env);vm.runInContext(handlers,env);
  ['catalog-live','catalog-movie','catalog-series','catalog-guide','catalog-persist'].forEach(loadingStage=>{
    env.updatePlayer({loadingStage,isLive:true,playing:false});
  });
  assert.deepEqual(statuses.map(row=>row.value),['Preparing live TV…','Preparing movies…','Preparing series…','Loading guide…','Saving your library…']);
  assert.ok(statuses.every(row=>row.loading===true));
  assert.match(source, /"No channels, movies or series were found in this source\."\s*:\s*"To źródło nie zwróciło kanałów TV, filmów ani seriali\."/,
    'the new empty-library error has a Polish UI translation');
});
