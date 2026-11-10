// playwright-cli run-code --filename, against the existing loopback QA server.
// Real payload/UI/platform/Dart/PIN/storage code runs. API replies alone are
// routed fixtures; no platform.query implementation or result is replaced.
async (page) => {
  const origin = new URL(page.url()).origin;
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(new URL(origin).hostname)) throw new Error('Run onboarding QA on the loopback fixture server only.');
  const configuration = await page.evaluate(() => ({apiUrl:window.TVBroSamsungConfig && window.TVBroSamsungConfig.apiUrl, fixture:!!window.__samsungFixture}));
  if (!configuration.apiUrl || !configuration.fixture) throw new Error('The real configured payload and synthetic Samsung SDK fixture are required.');
  const api = new URL(configuration.apiUrl), prefix = api.pathname.replace(/\/$/, '');
  const phases = [], browserErrors = [], blocked = [], requests = [];
  const snapshotKey = '__tvbro_onboarding_qa_sdk_aliases';
  const deviceId = '7f4fc8ed-5ec6-4601-9e9a-2d3396547771';
  const profileId = 'f1d7e5d2-1e02-4e4c-8d29-11b4f11a0502';
  const sourceId = '90a03a25-9dbf-43c2-a0ab-66737e7f4301';
  let paired = false, activeProfileId = null, pairingNumber = 0, pinVerifier, multipleProfiles = false;
  let deferClaim = true, releaseClaim = null, observeClaim;
  const claimObserved = new Promise(resolve => { observeClaim = resolve; });
  const onError = error => browserErrors.push(error.message);
  page.on('pageerror', onError);
  async function check(value, label) { if (!value) throw new Error(label); }
  async function shown(selector) { await page.locator(selector).waitFor({state:'visible'}); }
  async function activate(selector) { await (typeof selector === 'string' ? page.locator(selector) : selector).press('Enter'); }
  function modal() { return page.locator('.dialog:not([hidden])'); }
  async function action(name) { await activate(modal().getByRole('button', {name,exact:true})); }
  async function edit(selector, value) { const node = typeof selector === 'string' ? page.locator(selector) : selector; await node.press('Enter'); await node.fill(value); await node.press('Escape'); }
  async function bootstrap() { return page.evaluate(() => window.TVBroSamsungPlatform.query('bootstrap')); }
  function count(path) { return requests.filter(row => row.path === path && row.method !== 'OPTIONS').length; }
  const profile = () => ({id:profileId,name:'Cloud QA',position:0,pin:pinVerifier,updated_at:'2026-01-01T00:00:00Z',favorites:[{source_id:sourceId,kind:'movie',item_id:'500'}]});
  async function reply(route, body, status = 200) {
    await route.fulfill({status,headers:{'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'apikey, authorization, content-type, prefer','Access-Control-Allow-Methods':'GET, POST, DELETE, OPTIONS','Content-Type':'application/json'},body:status === 204 ? '' : JSON.stringify(body)});
  }
  const apiRouter = async route => {
    const request = route.request(), url = new URL(request.url());
    if (url.origin === origin) { await route.continue(); return; }
    if (url.origin !== api.origin || !url.pathname.startsWith(prefix + '/')) {
      blocked.push({origin:url.origin,path:url.pathname}); await route.abort('blockedbyclient'); return;
    }
    const path = url.pathname.slice(prefix.length), method = request.method();
    requests.push({path,method});
    if (method === 'OPTIONS') { await reply(route,null,204); return; }
    const body = request.postData() ? JSON.parse(request.postData()) : {};
    if (path === '/auth/v1/signup' && method === 'POST') {
      await reply(route,{access_token:'fixture-access',refresh_token:'fixture-refresh',expires_at:4102444800,expires_in:3600,user:{id:deviceId}}); return;
    }
    if (path === '/rest/v1/devices' && method === 'GET') {
      await reply(route,paired ? [{device_uid:deviceId,owner:'owner-fixture',label:'Samsung QA',active_profile_id:activeProfileId}] : []); return;
    }
    if (path === '/rest/v1/rpc/request_pairing') {
      pairingNumber++; await reply(route,[{code:'ABCD0'+pairingNumber,expires_at:'2100-01-01T00:00:00Z'}]); return;
    }
    if (path === '/rest/v1/rpc/pairing_status') {
      if (deferClaim) {
        deferClaim = false; await new Promise(resolve => { releaseClaim = resolve; observeClaim(); });
        await reply(route,false); return;
      }
      paired = true; await reply(route,true); return;
    }
    if (path === '/rest/v1/profiles' && method === 'GET') {
      await reply(route,multipleProfiles && !url.searchParams.has('id') ? [profile(),{id:'e46df7f2-0766-4e4e-8955-8481548a7563',name:'Other profile',position:1,pin:null}] : [profile()]); return;
    }
    if (path === '/rest/v1/rpc/get_crypto_state') { await reply(route,{enabled:false,ck_version:0}); return; }
    if (path === '/rest/v1/rpc/get_secrets') {
      await reply(route,{sources:{[sourceId]:{format:0,payload:{playlistUrl:origin+'/fixture/playlist.m3u',epgUrl:origin+'/fixture/guide.xml'}}},metadata:null}); return;
    }
    if (path === '/rest/v1/sources' && method === 'GET') {
      await reply(route,[{id:sourceId,kind:'m3u',label:'Cloud playlist QA',fields:{},settings:{hiddenCategories:{movie:['cloud-hidden']}},position:0}]); return;
    }
    if (path === '/rest/v1/metadata_configs' && method === 'GET') { await reply(route,[]); return; }
    if (path === '/rest/v1/rpc/get_playback_delta') { await reply(route,{positions:[],next_cursor:'0',has_more:false}); return; }
    if (path === '/rest/v1/rpc/get_supporter_status') { await reply(route,{status:'free',supported:false}); return; }
    if (path === '/rest/v1/rpc/set_device_profile') {
      if (body.p_profile_id !== profileId) throw new Error('Unexpected remote profile selection.');
      activeProfileId = body.p_profile_id; await reply(route,null,204); return;
    }
    blocked.push({origin:url.origin,path,method}); await reply(route,{code:'unexpected_fixture_request'},500);
  };
  await page.route('**/*', apiRouter);
  // The existing SDK double is intentionally memory-only. This reload fixture
  // restores its exact raw alias bytes, after real platform writes, to model
  // KeyManager persistence. It never seeds query/domain/profile results.
  await page.evaluate(key => sessionStorage.removeItem(key), snapshotKey);
  await page.addInitScript(key => {
    let current;
    Object.defineProperty(window,'__samsungFixture',{configurable:true,get(){return current;},set(value){
      current=value; const saved=sessionStorage.getItem(key);
      if(saved) Object.entries(JSON.parse(saved)).forEach(([name,raw]) => {
        if(Object.prototype.hasOwnProperty.call(value.data,name)) throw new Error('SDK reload fixture cannot overwrite an alias.');
        value.data[name]=raw;
      });
    }});
  },snapshotKey);
  async function reloadWithSdkAliases() {
    await page.evaluate(key => sessionStorage.setItem(key,JSON.stringify(window.__samsungFixture.data)),snapshotKey);
    await page.reload();
  }
  try {
    await page.goto(origin);
    await page.waitForFunction(() => !document.querySelector('#language-view').hidden || document.querySelector('#app-status').classList.contains('is-error'));
    const bootSdk = await page.evaluate(() => ({saves:window.__samsungFixture.calls.filter(row => row[0] === 'keymanager.save').length,
      duplicates:window.__samsungFixture.calls.filter(row => row[0] === 'keymanager.duplicate').length}));
    await check(bootSdk.saves >= 2 && bootSdk.duplicates === 0,'Fresh boot must complete both migrations without overwriting a create-only KeyManager alias.');
    await shown('#language-view');
    await check(await page.locator('#language-view h1').textContent() === 'Choose your language','Unsaved language must use canonical English first choice.');
    await activate(page.locator('#language-list').getByRole('button',{name:'Polski',exact:true})); await shown('#profiles-view');
    await check(await page.locator('html').getAttribute('lang') === 'pl','Polish selection must translate the actual page.');
    await check(await page.locator('#profiles-view h1').textContent() === 'Kto ogląda?','Polish profile heading is missing.');
    await reloadWithSdkAliases(); await shown('#profiles-view');
    await check(await page.locator('#language-view').isHidden(),'Saved language must survive reload.');
    await check((await bootstrap()).languageCode === 'pl','Actual persisted language did not survive reload.');
    phases.push('Canonical first PL language selection and raw-KeyManager reload persistence');

    await activate('#add-profile'); await edit(modal().locator('input').first(),'Settings'); await action('Zapisz'); await shown('#setup-view');
    await check((await page.locator('#setup-title').textContent()).includes('Settings'),'User profile name was translated as UI content.');
    await activate('#setup-demo'); await shown('#home-view'); await activate('#show-settings'); await shown('#settings-view');
    await activate(page.locator('#settings-list .setting-row').first()); await shown('#language-view');
    await activate(page.locator('#language-list').getByRole('button',{name:'English',exact:true})); await shown('#settings-view');
    await check(await page.locator('#settings-view h1').textContent() === 'Settings','English Settings heading was not translated.');
    await check(await page.locator('#show-profiles').textContent() === 'Profiles','English global controls were not translated.');
    await check(await page.locator('#settings-profile').textContent() === 'Settings','User profile name must remain byte-identical.');
    await reloadWithSdkAliases(); await shown('#home-view');
    await check((await bootstrap()).languageCode === 'en','English choice must persist across reload.');
    await activate('#show-settings'); await shown('#settings-view');
    await activate(page.locator('#settings-list .setting-row').first()); await shown('#language-view');
    await page.keyboard.press('Escape'); await shown('#settings-view');
    await check((await bootstrap()).languageCode === 'en','Back from language selection must preserve the saved language.');
    await activate(page.locator('#settings-list .setting-row').first());
    await activate(page.locator('#language-list').getByRole('button',{name:'Polski',exact:true})); await shown('#settings-view');
    phases.push('Real Settings PL→EN, reload, Back without commit, and EN→PL; user name preserved');

    await activate('#show-profiles'); await shown('#profiles-view'); await activate('#manage-profiles');
    await page.locator('#manage-profiles').filter({hasText:'Gotowe'}).waitFor();
    await activate(page.locator('.profile-card').filter({hasText:'Settings'})); await action('Usuń profil'); await action('Potwierdź');
    await page.locator('#modal-layer').waitFor({state:'hidden'});
    const empty = await bootstrap();
    await check(empty.profiles.length === 0 && empty.profile === null,'Pre-profile cloud test requires zero actual local profiles.');
    await shown('#download-cloud');
    pinVerifier = await page.evaluate(() => window.TVBroCanonical.hashPin('2468'));
    await activate('#download-cloud'); await shown('#pairing-view');
    await page.waitForFunction(() => document.querySelector('#pairing-code').textContent === 'ABCD01');
    await check(count('/auth/v1/signup') === 1,'Pairing should create exactly one fixture anonymous session, never a real account.');
    await activate('#pairing-check'); await claimObserved;
    await page.keyboard.press('Escape'); await shown('#profiles-view');
    const lateResponse = page.waitForResponse(response => new URL(response.url()).pathname.endsWith('/rest/v1/rpc/pairing_status'));
    releaseClaim(); releaseClaim=null; await lateResponse;
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    await check(await page.locator('#profiles-view').isVisible() && await page.locator('#pairing-view').isHidden(),'Late pairing reply reopened a cancelled view.');
    await check(count('/rest/v1/rpc/set_device_profile') === 0 && count('/rest/v1/sources') === 0,'Back from a pending claim must not select or download a profile.');
    phases.push('Cloud entry with no local profiles; actual signup/code XHR fixtures; Back rejects stale claim UI callback');

    await activate('#download-cloud'); await shown('#pairing-view');
    await page.waitForFunction(() => document.querySelector('#pairing-code').textContent === 'ABCD02');
    await activate('#pairing-check');
    await modal().getByRole('heading',{name:'PIN profilu',exact:true}).waitFor();
    await edit(modal().locator('input').first(),'0000'); await action('Dalej');
    await page.waitForFunction(() => document.querySelector('#app-status').textContent.indexOf('PIN') >= 0);
    await check(count('/rest/v1/sources') === 0 && count('/rest/v1/rpc/set_device_profile') === 0,'Incorrect PIN must not fetch or activate the remote profile.');
    await check(await page.locator('#home-view').isHidden(),'Incorrect PIN must not continue onboarding.');
    multipleProfiles = true;
    await activate('#pairing-choose-profile');
    await modal().getByRole('button',{name:'Other profile',exact:true}).waitFor();
    await check(await modal().getByRole('button',{name:'Other profile',exact:true}).count() === 1,'Multiple cloud profiles must still require an explicit choice.');
    await activate(modal().getByRole('button',{name:/^Cloud QA/}));
    await edit(modal().locator('input').first(),'2468'); await action('Dalej');
    // Native onboarding continues automatically after a conscious profile
    // choice. No manual Pull/Continue button is used to make this pass.
    await shown('#home-view');
    const selected = await bootstrap();
    await check(selected.profile && selected.profile.id === profileId && selected.profile.source === 'cloud','Remote UUID must remain the selected cloud identity.');
    await check(selected.profiles.length === 2 && selected.profiles.every(row => row.source === 'cloud'),'Cloud onboarding must not create a LocalProfile clone.');
    await check(selected.sources.length === 1 && selected.sources[0].id === sourceId && selected.activeSourceId === sourceId,'Downloaded source identity/active selection was lost.');
    await check(selected.sources[0].settings.hiddenCategories.movie[0] === 'cloud-hidden','Source settings must arrive before onboarding completes.');
    await check(selected.favorites.length === 1 && selected.favorites[0].sourceId === sourceId && selected.favorites[0].item.id === '500','Favorites must arrive before onboarding completes for this free account.');
    await check(await page.locator('#home-source').textContent() === 'Cloud playlist QA','Automatic onboarding must load the real canonical M3U source before Home.');
    await activate('#home-live'); await shown('#guide-grid');
    await check(await page.locator('#guide-grid .guide-channel[data-nav]').count() === 40,'Real 161-channel M3U fixture must reach the bounded default TV guide.');
    await check(count('/auth/v1/signup') === 1,'Existing fixture anonymous session must be reused.');
    phases.push('Claim→sole-profile automatic PIN gate; multiple profiles retain choice; complete free-account favorites/settings import before real M3U load/Home');
    await check(blocked.length === 0,'Unexpected remote HTTP was blocked: '+JSON.stringify(blocked));
    await check(browserErrors.length === 0,'Browser runtime errors: '+browserErrors.join('; '));
    return {status:'passed',phases,browserErrors,apiRequestCounts:Object.fromEntries([...new Set(requests.map(row=>row.path))].map(path=>[path,count(path)])),
      scope:'Actual local payload UI/platform/Dart and synthetic Samsung SDK. Every configured API request is intercepted before network; no real signup/profile mutation. Reload models persistence by restoring exact synthetic SDK alias bytes. Unencrypted cloud fixture only; no TV storage, native decoding, production backend or encrypted-profile browser qualification.'};
  } catch (error) {
    throw new Error('Completed phases: ' + phases.join('; ') + '. ' + error.message+' UI '+(await page.locator('body').innerText()).slice(-2200));
  } finally {
    if (releaseClaim) releaseClaim();
    await page.unroute('**/*',apiRouter); page.off('pageerror',onError);
    await page.evaluate(key => sessionStorage.removeItem(key),snapshotKey);
  }
}
