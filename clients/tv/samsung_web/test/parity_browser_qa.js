// Run through playwright-cli run-code --filename against ui_browser_server.cjs.
// Uses the real UI, core, platform and storage; only the server's provider/SDK
// boundaries are synthetic. A fresh local QA profile isolates existing fixtures.
async (page) => {
  const phases=[],errors=[];page.on('pageerror',error=>errors.push(error.message));
  const origin=new URL(page.url()).origin;
  if(new URL(origin).hostname!=='127.0.0.1')throw Error('Loopback QA server required');
  const snapshotKey='__tvbro_parity_qa_sdk_aliases';
  await page.evaluate(key=>sessionStorage.removeItem(key),snapshotKey);
  // Persist only synthetic SDK aliases. Every reload reconstructs the actual
  // production storage, source engines and UI, including their cold-start gates.
  await page.addInitScript(key=>{
    let current;
    Object.defineProperty(window,'__samsungFixture',{configurable:true,get(){return current;},set(value){
      current=value;const saved=sessionStorage.getItem(key);
      if(saved)Object.entries(JSON.parse(saved)).forEach(([name,raw])=>{
        if(Object.prototype.hasOwnProperty.call(value.data,name))throw Error('Reload must not overwrite an SDK alias');
        value.data[name]=raw;
      });
    }});
  },snapshotKey);
  async function reloadAliases(){await page.evaluate(key=>sessionStorage.setItem(key,JSON.stringify(window.__samsungFixture.data)),snapshotKey);await page.reload();}
  async function homeReady(){
    await page.locator('#home-view').waitFor({state:'visible'});
    await page.waitForFunction(()=>!document.querySelector('#home-live').disabled);
    await page.waitForFunction(async()=>{const catalog=await window.TVBroSamsungPlatform.query('sources.catalog');return !!(catalog&&catalog.source&&catalog.channels.length);});
  }
  async function check(value,message){if(!value)throw Error(message);}
  const modal=()=>page.locator('#modal-layer > .dialog:not([hidden])');
  async function press(locator){await (typeof locator==='string'?page.locator(locator):locator).press('Enter');}
  async function edit(locator,value){await press(locator);await locator.fill(value);await locator.press('Escape');}
  async function action(name){await press(modal().getByRole('button',{name,exact:true}));}
  async function closeEditors(){for(let count=0;count<8;count++){if(await page.locator('#modal-layer').isHidden())return;await page.keyboard.press('Escape');}throw Error('Editor stack did not close');}
  async function settings(){await closeEditors();if(await page.locator('#show-home').isVisible())await press('#show-home');await press('#show-settings');await page.locator('#settings-view').waitFor({state:'visible'});}
  async function sourceTools(){await settings();await press(page.getByRole('button',{name:'Source settings · Parity QA',exact:true}));}
  async function live(){await closeEditors();if(await page.locator('#show-home').isVisible())await press('#show-home');await press('#home-live');await page.locator('#guide-panel').waitFor({state:'visible'});}
  const fixture=await page.evaluate(async origin=>{
    const q=window.TVBroSamsungPlatform.query;
    await q('profiles.create',{name:'Parity QA'});await q('language.set',{code:'en'});await q('settings.set',{settings:{profilePickerStartup:'off'}});
    const sources=await q('sources.add',{config:{kind:'m3u',label:'Parity QA',fields:{playlistUrl:origin+'/fixture/playlist.m3u',epgUrl:origin+'/fixture/guide.xml'},settings:{}}});
    const source=sources[sources.length-1];await q('sources.load',{id:source.id});return {sourceId:source.id};
  },origin);
  await reloadAliases();await homeReady();

  await sourceTools();await action('Organize channels');await modal().getByRole('button',{name:'Kanał 1',exact:true}).waitFor();
  await check(await modal().locator('.editor-item').count()<=40,'Channel editor must mount no more than 40 rows');
  await action('Kanał 1');await edit(modal().locator('input').first(),'Parity News');await action('Save');
  await modal().getByRole('button',{name:'Parity News',exact:true}).waitFor();await action('Parity News');await action('Move down');
  await modal().getByRole('button',{name:'Parity News',exact:true}).waitFor();
  await edit(modal().locator('input').first(),'Kanał 3');await modal().getByRole('button',{name:'Kanał 3',exact:true}).waitFor();await action('Kanał 3');await action('Hide channel');
  await modal().getByRole('button',{name:'Kanał 3 · Hidden',exact:true}).waitFor();
  await action('New group');await edit(modal().locator('input').first(),'Parity group');await action('Save');
  await modal().getByRole('heading',{name:'Organize channels',exact:true}).waitFor();
  await edit(modal().locator('input').first(),'Parity News');await action('Parity News');await action('Groups');await action('Parity group');await action('Save');
  await modal().getByRole('heading',{name:'Organize channels',exact:true}).waitFor();
  const organized=await page.evaluate(id=>window.TVBroSamsungPlatform.query('organization.get',{sourceId:id}),fixture.sourceId);
  await check(organized.channels[1].name==='Parity News'&&organized.organization.hidden.length===1&&organized.organization.groups[0].channels.length===1,'Names, order, hidden channels and group membership must persist through real source settings');
  phases.push('bounded channel editor: name, order, hiding and custom membership');

  await sourceTools();await action('Hide categories');await action('TV');await action('Polska');await action('Save');await closeEditors();await live();
  await check(await page.locator('#category-list').getByRole('button',{name:'Polska',exact:true}).count()===0,'A hidden category must disappear from the actual live catalogue');
  await sourceTools();await action('Hide categories');await action('TV');await action('Polska · Hidden');await action('Save');
  await closeEditors();await live();await page.locator('#category-list').getByRole('button',{name:'Parity group',exact:true}).waitFor();await press(page.locator('#category-list').getByRole('button',{name:'Parity group',exact:true}));
  await page.waitForFunction(()=>document.querySelectorAll('.guide-channel[data-nav]').length===1);
  await check((await page.locator('.guide-channel[data-nav]').first().textContent()).includes('Parity News'),'Custom group must filter by membership instead of provider category');
  phases.push('category hiding/unhiding and group catalogue filtering');

  await sourceTools();await action('Source settings');
  await edit(modal().getByLabel('EPG URL (optional) 1',{exact:true}),origin+'/fixture/guide.xml?extra=1');
  await edit(modal().getByLabel('Catch-up timezone',{exact:true}),'UTC');
  await edit(modal().getByLabel('Catch-up offset (minutes)',{exact:true}),'-60');
  await edit(modal().getByLabel('Catch-up day limit',{exact:true}),'3');
  await press(modal().getByRole('button',{name:'Playback buffer: Default',exact:true}));await action('Stable');await action('Save');
  await modal().getByRole('heading',{name:'Parity QA',exact:true}).waitFor();
  const saved=await page.evaluate(id=>window.TVBroSamsungPlatform.query('sourceSettings.get',{sourceId:id}),fixture.sourceId);
  await check(saved.settings.catchupOffsetMinutes===-60&&saved.settings.catchupMaxDays===3&&saved.settings.bufferPreset==='stable'&&saved.config.fields.epgUrls.includes('?extra=1'),'Extra EPG URLs and catch-up/buffer fields must use real source persistence');
  await closeEditors();await live();await page.getByRole('button',{name:/Teraz QA/}).first().waitFor();
  await press('#guide-search');await edit(modal().locator('input').first(),'Teraz QA');await modal().getByRole('button',{name:/Teraz QA/}).first().waitFor();
  await check(await modal().locator('.editor-item').count()<=40,'Programme search must bound rendered results');await closeEditors();
  phases.push('extra guide priority, catch-up settings, native buffering and cached programme search');

  await sourceTools();await action('EPG mapping');await edit(modal().locator('input').first(),'Parity News');await action('Parity News');
  await edit(modal().getByLabel('Find a guide channel by name or ID',{exact:true}),'live1');
  await modal().locator('.editor-item').first().waitFor();await press(modal().locator('.editor-item').first());
  await edit(modal().getByLabel('Time correction in minutes',{exact:true}),'30');await action('Save');
  await modal().getByRole('heading',{name:'EPG mapping',exact:true}).waitFor();
  const mapping=await page.evaluate(async id=>{const data=await window.TVBroSamsungPlatform.query('organization.get',{sourceId:id});const channel=data.channels.find(row=>row.name==='Parity News');return window.TVBroSamsungPlatform.query('guide.mapping.get',{sourceId:id,channelId:channel.id});},fixture.sourceId);
  await check(mapping.override.offsetMinutes===30&&mapping.override.guideChannelId==='live1','EPG correction must persist chosen guide identity and offset');
  await closeEditors();await reloadAliases();await homeReady();await live();
  await page.locator('.guide-channel[data-nav]').filter({hasText:'Parity News'}).waitFor();
  const persisted=await page.evaluate(id=>window.TVBroSamsungPlatform.query('organization.get',{sourceId:id}),fixture.sourceId);
  await check(persisted.organization.groups[0].name==='Parity group'&&persisted.organization.hidden.length===1,'Channel organization must survive a complete app reload');
  await page.screenshot({path:'D:/tvbro/output/playwright/samsung-full-ui/parity-editors.png'});
  await check(errors.length===0,'Browser exceptions: '+errors.join(' | '));
  await page.evaluate(key=>sessionStorage.removeItem(key),snapshotKey);
  return {phases:phases.concat(['manual mapping/time correction and app-reload persistence']),errors};
}
