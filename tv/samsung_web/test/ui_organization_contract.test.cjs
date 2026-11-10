'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');
const source = fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8');
const names = ['pagedEditor','organizationCopy','editOrganizedChannel','saveOrganization','sourceSettings',
  'epgMapping','searchProgrammes','playerSettings','editorContext','openCategoryVisibility',
  'chooseBackupPath','backupFlow','confirmBackupImport','renderSettings','connectionHelp','loadSource','hostedHttpSource'];
const handlers = acorn.parse(source, {ecmaVersion:2022}).body[0].expression.callee.body.body
  .filter(node => node.type === 'FunctionDeclaration' && names.includes(node.id.name))
  .map(node => source.slice(node.start,node.end)).join('\n');

function harness() {
  const calls = [], dialogs = [], timers = new Map(), nodes = Object.create(null); let sequence = 0;
  class Node {
    constructor(tag, className, value) { this.tagName = tag; this.className = className || ''; this.textContent = value || ''; this.children = []; this.listeners = {}; this.value = ''; }
    appendChild(child) { this.children.push(child); return child; }
    get firstChild() { return this.children[0]; }
    get lastChild() { return this.children.at(-1); }
    setAttribute() {}
    addEventListener(name, callback) { this.listeners[name] = callback; }
    fire(name) { if (this.listeners[name]) this.listeners[name](); }
    querySelector() { return this.children.find(node => node.tagName === 'button' || node.tagName === 'input') || null; }
  }
  const view = {request:1,screen:'settings',source:{id:'source'},languages:[{code:'en',name:'English'},{code:'pl',name:'Polski'}],languageCode:'en',
    playingState:{speed:2,displayMode:'PLAYER_DISPLAY_MODE_FULL_SCREEN'},caps:{playbackRates:[1,2],aspectModes:[{id:'fit',label:'Fit'},{id:'fill',label:'Fill'}]}};
  const env = {view,dialogs,calls,Promise,Object,String,Number,JSON,Date,Math,Array,isFinite,
    t(value, args) { return value.replace(/\{(\w+)\}/g, (_, key) => args[key]); },
    byId(id) { return nodes[id] || (nodes[id] = new Node('div')); },
    core:{appLanguages:()=>JSON.stringify(view.languages)},
    element(tag, className, value) { return new Node(tag,className,value); },
    button(label, className, action) { const node = new Node('button',className,label); node.click = action; return node; },
    clear(node) { node.children = []; },text(node,value) { node.textContent = value; },
    array(value) { return Array.isArray(value) ? value : []; },uiLabel(value) { return value; },
    window:{setTimeout(callback,delay) { const id = ++sequence; timers.set(id,{callback,delay}); return id; },clearTimeout(id) { timers.delete(id); }},
    dialog(title) { const record = {title,body:new Node('div'),actions:new Node('div'),error:new Node('p')}; dialogs.push(record); return record; },
    closeDialog(cancel,record) { if (!record) record = dialogs.at(-1); if (dialogs.at(-1) === record) { dialogs.pop(); record.closed = true; } },
    dialogButton(record,label,action) { const node = env.button(label,'',action); record.actions.appendChild(node); return node; },
    editableInput(parent,label,type,value) { const node = new Node('input'); node.label = label; node.type = type; node.value = value; parent.appendChild(node); return node; },
    focus(node) { env.focused = node; },cap() { return true; },
    parentalForm() {},
    applyEditedCatalog(data) { calls.push(['catalog',data]); },renderSources() {},renderChannels() {},
    message(error) { return error.message; },report(error) { throw error; },clock() { return '12:00'; },
    cancelPlayerZap() {},busy(value) { view.busy=value; },sourceName(config) { return config.label || ''; },
    afterLoadingPaint() { return Promise.resolve(); },
    showProgramme(programme,channel) { calls.push(['programme',programme,channel]); },
    cancelled() { return Object.assign(new Error('Cancelled'),{code:'ui_cancelled'}); },
    status(value) { calls.push(['status',value]); },
    closeAllDialogs() {while(dialogs.length)env.closeDialog(true);},
    refreshBootstrap() {return Promise.resolve();},showProfiles() {calls.push(['profiles']);},
    optionDialog(title,options,selected,action) { calls.push(['options',title,options,selected,action]); },
    query(action,args) { calls.push([action,args]); return Promise.resolve(env.respond ? env.respond(action,args) : {}); }
  };
  vm.createContext(env); vm.runInContext(handlers,env);
  return {env,view,calls,dialogs,timers,Node,
    async settle() { await new Promise(resolve => setImmediate(resolve)); },
    async expire() { for (const [id,timer] of [...timers]) { timers.delete(id); timer.callback(); } await this.settle(); },
    action(record,label) { return record.actions.children.find(node => node.textContent === label); },
    inputs(record) { const rows=[];function visit(parent) { for(const child of parent.children) {if(child.tagName==='input')rows.push(child);visit(child);} }visit(record.body);return rows; }
  };
}

function uiMessages() {
  const body=acorn.parse(source,{ecmaVersion:2022}).body[0].expression.callee.body.body;
  const declaration=body.filter(node=>node.type==='VariableDeclaration').flatMap(node=>node.declarations).find(row=>row.id.name==='uiMessages');
  return vm.runInNewContext('('+source.slice(declaration.init.start,declaration.init.end)+')');
}

test('Settings Help & connection is reachable, bilingual and explains Titan HTTP without network or export claims',()=>{
  const kit=harness();kit.view.caps.requiresHttpsProvider=true;kit.env.renderSettings({fields:[]});
  const rows=kit.env.byId('settings-list').children;
  const row=rows.find(node=>node.textContent==='Help & connection');
  assert.ok(row,'Settings exposes a D-pad button for connection help');
  row.click();
  const record=kit.dialogs.at(-1),text=record.body.children.map(node=>node.textContent).join(' ');
  assert.equal(record.title,'Help & connection');
  assert.match(text,/provider requests directly/i);assert.match(text,/Titan/i);assert.match(text,/HTTPS/i);assert.match(text,/provider must allow TVBro/i);
  assert.match(text,/does not automatically rewrite/i);assert.match(text,/explicitly configured/i);assert.doesNotMatch(text,/clipboard|export|https?:\/\//i);
  assert.equal(kit.calls.length,0,'opening help is local and read-only');
  const close=kit.action(record,'Done');assert.ok(close,'the dialog has a normal remote-friendly close action');close.click();
  assert.equal(record.closed,true);
  const messages=uiMessages();
  assert.equal(messages['Help & connection'],'Pomoc i połączenie');
  assert.match(messages['This provider uses HTTP. This TV version needs HTTPS. Ask your provider for an HTTPS address or use TVBro on Android, Windows or Samsung.'],/Poproś o adres HTTPS/);
});

test('Titan source form gives a local HTTP warning before sending the source-load query',async()=>{
  const kit=harness();kit.view.caps.requiresHttpsProvider=true;
  const config={id:'http-source',kind:'m3u',label:'HTTP',fields:{playlistUrl:'http://provider.fixture/list.m3u'}};
  await kit.env.loadSource(config);
  assert.equal(kit.calls.some(call=>call[0]==='sources.load'),false);
  assert.ok(kit.calls.some(call=>call[0]==='status'&&/needs HTTPS/i.test(call[1])));
  assert.equal(kit.env.hostedHttpSource({kind:'xtream',fields:{host:'provider.fixture'}}),true);
  assert.equal(kit.env.hostedHttpSource({kind:'xtream',fields:{host:'https://provider.fixture'}}),false);
});

test('10,000 channel editor mounts 40 rows and searches without provider calls',async()=>{
  const kit=harness(), rows=Array.from({length:10000},(_,i)=>({id:String(i),name:'Channel '+i}));
  const record=kit.env.pagedEditor('Channels',rows,row=>row.name,()=>{});
  assert.equal(record.body.children[1].children.length,40);
  kit.action(record,'Next').click(); assert.equal(record.body.children[1].firstChild.textContent,'Channel 40');
  const input=kit.inputs(record)[0];input.value='Channel 9999';input.fire('input');await kit.expire();
  assert.equal(record.body.children[1].children.length,1);
  assert.equal(record.body.children[1].firstChild.textContent,'Channel 9999');assert.equal(kit.calls.length,0);
});

test('nested source guide fields keep unique labels and input identities',()=>{
  const kit=harness();kit.env.editableSequence=0;
  const declaration=acorn.parse(source,{ecmaVersion:2022}).body[0].expression.callee.body.body.find(node=>node.type==='FunctionDeclaration'&&node.id.name==='editableInput');
  vm.runInContext(source.slice(declaration.start,declaration.end),kit.env);
  const body=new kit.Node('div'),guides=new kit.Node('div');
  const primary=kit.env.editableInput(body,'Primary','text','',100),extra=kit.env.editableInput(guides,'Extra','text','',100);
  assert.notEqual(primary.id,extra.id);assert.equal(body.firstChild.htmlFor,primary.id);assert.equal(guides.firstChild.htmlFor,extra.id);
});

test('channel rename and move preserve stable IDs, hidden rows and group membership',async()=>{
  const kit=harness(), org={names:{},hidden:['a'],order:[],groups:[{id:'tvbro.group.one',name:'One',channels:['a']}]};
  const state={config:{id:'source'},data:{organization:org,channels:[{id:'a',name:'A'},{id:'b',name:'B'}]},saving:false,record:{closed:false,repaint(){}}};
  kit.env.respond=(action,args)=>({organization:args.organization,channels:state.data.channels});
  kit.env.editOrganizedChannel(state,state.data.channels[0]);let record=kit.dialogs.at(-1);
  kit.inputs(record)[0].value='New A';kit.action(record,'Save').click();await kit.settle();
  let args=kit.calls.find(call=>call[0]==='organization.set')[1];
  assert.equal(args.organization.names.a,'New A');assert.deepEqual([...args.organization.hidden],['a']);
  assert.equal(args.organization.groups[0].channels[0],'a');assert.deepEqual(org.names,{});
  kit.env.editOrganizedChannel(state,state.data.channels[0]);record=kit.dialogs.at(-1);kit.action(record,'Move down').click();await kit.settle();
  args=kit.calls.filter(call=>call[0]==='organization.set').at(-1)[1];assert.deepEqual([...args.organization.order],['b','a']);
});

test('source settings submit only schema fields and keep ordered EPG URLs',async()=>{
  const kit=harness();kit.env.respond=(action)=>action==='sourceSettings.get'?{settings:{},fields:[
    {key:'epgUrls',scope:'fields',type:'urls',value:'https://one/guide.xml\nhttps://two/guide.xml'},
    {key:'catchupMaxDays',type:'number',label:'Days',value:3}
  ]}:action==='sources.list'?[]:{};
  await kit.env.sourceSettings({id:'source',fields:{password:'never-copied'}});
  const record=kit.dialogs.at(-1),inputs=kit.inputs(record);inputs[0].value='';inputs[1].value='https://other/guide.xml';
  kit.action(record,'Save').click();await kit.settle();
  const args=kit.calls.find(call=>call[0]==='sourceSettings.set')[1];
  assert.equal(args.fields.epgUrls,'https://other/guide.xml');assert.equal(args.fields.password,undefined);assert.equal(args.settings.catchupMaxDays,'3');
});

test('mapping validates offsets before writing and stores the explicitly chosen XMLTV identity',async()=>{
  const kit=harness();kit.env.respond=()=>({available:true,override:{offsetMinutes:0},channels:[{guideId:'g',guideLabel:'Guide',channelId:'xml',name:'Station'}]});
  await kit.env.epgMapping({id:'source'},{id:'provider',name:'Channel'});
  const record=kit.dialogs.at(-1),offset=kit.inputs(record)[0];offset.value='1441';kit.action(record,'Save').click();
  assert.equal(kit.calls.some(call=>call[0]==='guide.mapping.set'),false);
  record.body.children.find(node=>node.className==='dialog-list').firstChild.click();offset.value='-60';kit.action(record,'Save').click();await kit.settle();
  const args=kit.calls.find(call=>call[0]==='guide.mapping.set')[1];
  assert.equal(args.channelId,'provider');assert.equal(args.guideChannelId,'xml');assert.equal(args.guideId,'g');assert.equal(args.offsetMinutes,-60);
});

test('programme search requests only 40 cached results and ignores results after dismissal',async()=>{
  const kit=harness();let finish;kit.env.respond=()=>new Promise(resolve=>{finish=resolve;});
  kit.env.searchProgrammes();const record=kit.dialogs.at(-1),input=kit.inputs(record)[0];input.value='News';input.fire('input');await kit.expire();
  const args=kit.calls.find(call=>call[0]==='guide.search')[1];assert.equal(args.limit,40);assert.equal(args.sourceId,'source');
  kit.env.closeDialog(true,record);finish({programmes:[{programme:{title:'News'},channel:{name:'One'}}]});await kit.settle();
  assert.equal(record.body.children.at(-1).children.length,0);
});

test('playback menus select native speed and AVPlay display mode',()=>{
  const kit=harness();kit.env.playerSettings();const list=kit.dialogs[0].body.firstChild;
  list.children.find(node=>node.textContent==='Playback speed').click();assert.equal(kit.calls.at(-1)[3],2);
  list.children.find(node=>node.textContent==='Aspect ratio').click();assert.equal(kit.calls.at(-1)[3],'fill');
});

test('native backup picker chooses the actual destination before encryption and keeps typed bytes',async()=>{
  const kit=harness(),bytes=new Uint8Array([1,2,3]);
  kit.env.respond=(action,args)=>action==='backup.files.list'?args.path?{path:'USB',entries:[]}:{storages:[{label:'USB',type:'EXTERNAL',state:'MOUNTED'}]}:
    action==='backup.export'?{bytes,filename:'backup.tvbro'}:action==='backup.export.save'?{path:'USB/backup.tvbro'}:{};
  kit.env.backupFlow(true);await kit.settle();let picker=kit.dialogs.at(-1);
  assert.equal(kit.calls.some(call=>call[0]==='backup.export'),false);
  picker.body.children[1].firstChild.click();await kit.settle();kit.action(picker,'Use this folder').click();await kit.settle();
  const record=kit.dialogs.at(-1),inputs=kit.inputs(record);inputs[0].value='backup.tvbro';inputs[1].value='password-123';inputs[2].value='different';
  kit.action(record,'Export encrypted backup').click();assert.equal(kit.calls.some(call=>call[0]==='backup.export'),false);
  inputs[2].value='password-123';kit.action(record,'Export encrypted backup').click();await kit.settle();
  const saved=kit.calls.find(call=>call[0]==='backup.export.save')[1];assert.equal(saved.directoryPath,'USB');assert.equal(saved.filename,'backup.tvbro');assert.equal(saved.bytes,bytes);
  assert.equal(inputs[1].value,'');assert.equal(inputs[2].value,'');
});

test('import explicitly adds recovery profiles only after the review action',async()=>{
  const kit=harness();kit.env.confirmBackupImport({token:'opaque',summary:{profileCount:2,sourceCount:3,favoriteCount:4}});
  const record=kit.dialogs.at(-1);assert.equal(kit.calls.length,0);
  assert.match(record.body.firstChild.textContent,/adds recovery profiles/);
  kit.action(record,'Add recovery profiles').click();await kit.settle();
  const call=kit.calls.find(row=>row[0]==='backup.import');assert.equal(call[1].token,'opaque');assert.equal(kit.calls.some(row=>row[0]==='profiles'),true);
});
