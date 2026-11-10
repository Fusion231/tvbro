// playwright-cli run-code --filename, with the shared fixture server serving a Titan payload.
// Real DOM, IndexedDB, WebCrypto, worker, canonical core and shared Samsung UI/library.
async (page) => {
  const origin = new URL(page.url()).origin;
  if (new URL(origin).hostname !== '127.0.0.1') throw Error('Loopback QA server required');
  const errors = [], consoleErrors = [], downloads = [], blockedExternalRequests = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => {
    if (message.type() !== 'error') return;
    // The explicit external-request guard can produce this browser network log.
    // Application exceptions, CSP errors and other console failures remain fatal.
    if (/^Failed to load resource: net::ERR_(FAILED|ABORTED)$/.test(message.text())) return;
    consoleErrors.push(message.text());
  });
  await page.route('**/*', route => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) {
      blockedExternalRequests.push(url.origin);
      return route.abort();
    }
    if (url.pathname === '/fixture/playlist.m3u') downloads.push('playlist');
    return route.continue();
  });
  // Only the TV's final native exit is replaced. Storage/media/core/UI stay real.
  await page.addInitScript(() => {
    window.__titanExitCalls = 0;
    window.SmartTvA_API = { exit() { window.__titanExitCalls++; } };
  });
  await page.goto(origin);
  await page.locator('#language-view').waitFor({state:'visible'});
  const saved = await page.evaluate(async origin => {
    const api = window.TVBroSamsungPlatform;
    if (window.tizen || window.webapis || window.webOS) throw Error('Foreign TV SDK must not be present');
    if (document.querySelectorAll('video').length !== 1 || document.querySelector('object[type="application/avplayer"]')) throw Error('Exactly one Titan HTML5 video expected');
    if (!window.isSecureContext || !window.crypto.subtle) throw Error('Actual WebCrypto requires a secure loopback context');
    const created = await api.query('profiles.create', {name:'Titan restart QA'});
    const source = {id:'titan-persistence',kind:'m3u',label:'Titan channels',fields:{playlistUrl:origin+'/fixture/playlist.m3u'},settings:{}};
    await api.query('sources.add', {config:source});
    const catalog = await api.query('sources.load', {id:source.id});
    if (catalog.channels.length !== 161 || catalog.channels[0].name !== 'Kanał 1') throw Error('Canonical M3U parser did not load the synthetic provider');
    await api.query('favorites.toggle', {sourceId:source.id,channel:catalog.channels[0]});
    await api.query('settings.set', {settings:{profilePickerStartup:'off'}});
    await api.query('cache.flush');
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open('tvbro_webos_protected_v1', 1);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    const records = await new Promise((resolve, reject) => {
      const tx = db.transaction('values', 'readonly'), rows = {};
      for (const name of ['key','sources','user']) {
        const request = tx.objectStore('values').get(name);
        request.onsuccess = () => { rows[name] = request.result; };
      }
      tx.oncomplete = () => resolve(rows);
      tx.onabort = () => reject(tx.error || Error('Protected storage read aborted'));
    });
    db.close();
    if (!(records.key instanceof CryptoKey) || records.key.extractable || records.key.algorithm.name !== 'AES-GCM') throw Error('Persisted key is not a non-extractable AES-GCM CryptoKey');
    // Current profile/source configurations live in encrypted user state;
    // the standalone sources slot is retained only for legacy callers.
    for (const name of ['user'].concat(records.sources == null ? [] : ['sources'])) {
      const record = records[name];
      if (!record || record.version !== 1 || !(record.ciphertext instanceof ArrayBuffer) || record.ciphertext.byteLength < 16 || record.iv.byteLength !== 12) throw Error('Persisted '+name+' is not encrypted');
    }
    const userState = await window.TVBroPlatformAdapters.store.decrypt(records.user, 'user');
    if (!userState.includes(source.id)) throw Error('Synthetic source configuration is missing from protected user state');
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const probe = await crypto.subtle.encrypt({name:'AES-GCM',iv}, records.key, new TextEncoder().encode('Titan persistent key QA'));
    return {profileId:created.profile.id,channels:catalog.channels.length,favorites:await api.query('favorites.list'),
      keyProbe:{iv:[...iv],ciphertext:[...new Uint8Array(probe)]},protectedStorage:true};
  }, origin);
  const downloadsBeforeRestart = downloads.length;
  if (downloadsBeforeRestart !== 1) throw Error('Expected one real synthetic playlist transfer');
  await page.reload();
  await page.locator('#language-view').waitFor({state:'visible'});
  const restored = await page.evaluate(async saved => {
    const api = window.TVBroSamsungPlatform;
    const profiles = await api.query('profiles.list');
    if (!profiles.profile || profiles.profile.id !== saved.profileId) throw Error('Profile did not survive restart');
    const sources = await api.query('sources.list');
    if (!sources.some(source => source.id === 'titan-persistence')) throw Error('Source did not survive restart');
    const favorites = await api.query('favorites.list');
    if (JSON.stringify(favorites) !== JSON.stringify(saved.favorites)) throw Error('Favorites did not survive restart');
    const catalog = await api.query('sources.load', {id:'titan-persistence'});
    if (catalog.channels.length !== saved.channels) throw Error('Restored catalog mismatch');
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open('tvbro_webos_protected_v1', 1);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    const key = await new Promise((resolve, reject) => {
      const tx = db.transaction('values', 'readonly');
      const request = tx.objectStore('values').get('key');
      let value;
      request.onsuccess = () => { value = request.result; };
      tx.oncomplete = () => resolve(value);
      tx.onabort = () => reject(tx.error || Error('Persisted key read aborted'));
    });
    db.close();
    const clear = await crypto.subtle.decrypt({name:'AES-GCM',iv:new Uint8Array(saved.keyProbe.iv)},key,new Uint8Array(saved.keyProbe.ciphertext));
    if (new TextDecoder().decode(clear) !== 'Titan persistent key QA') throw Error('Persistent CryptoKey changed across reload');
    return {channels:catalog.channels.length,profileRestored:true,favoritesRestored:true,persistentCryptoKey:true};
  }, saved);
  if (downloads.length !== downloadsBeforeRestart) throw Error('Restart discarded encrypted catalog cache and downloaded again');
  await page.locator('#language-continue').click();
  await page.locator('#home-view').waitFor({state:'visible'});
  await page.locator('#home-live').click();
  await page.locator('#catalog-view').waitFor({state:'visible'});
  await page.keyboard.press('ArrowDown');
  const focusVisible = await page.evaluate(() => !!document.activeElement && document.activeElement.hasAttribute('data-nav'));
  if (!focusVisible) throw Error('Remote focus lost');
  const back = () => page.evaluate(() => document.dispatchEvent(new KeyboardEvent('keydown',{keyCode:8,which:8,bubbles:true,cancelable:true})));
  await back();
  await page.locator('#home-view').waitFor({state:'visible'});
  if (await page.evaluate(() => window.__titanExitCalls) !== 0) throw Error('Back from Live exited the app');
  await back();
  const dialog = page.locator('#modal-layer [role="dialog"]');
  await dialog.waitFor({state:'visible'});
  if (await page.evaluate(() => window.__titanExitCalls) !== 0) throw Error('Home Back exited without confirmation');
  await back();
  await dialog.waitFor({state:'hidden'});
  if (await page.evaluate(() => window.__titanExitCalls) !== 0) throw Error('Cancelling exit triggered native exit');
  await page.screenshot({path:'D:/tvbro/output/playwright/titan-os-home.png',fullPage:true});
  await back();
  await dialog.waitFor({state:'visible'});
  await dialog.locator('.dialog-actions button').last().click();
  await dialog.waitFor({state:'hidden'});
  if (await page.evaluate(() => window.__titanExitCalls) !== 0) throw Error('Cancel button triggered native exit');
  await back();
  await dialog.waitFor({state:'visible'});
  await dialog.locator('.dialog-actions .button-primary').click();
  await page.waitForFunction(() => window.__titanExitCalls === 1);
  await dialog.waitFor({state:'hidden'});
  await page.evaluate(() => window.TVBroSamsungPlatform.query('sources.cancel'));
  if (errors.length || consoleErrors.length) throw Error([...errors,...consoleErrors].join('; '));
  return {status:'passed',...restored,protectedStorage:saved.protectedStorage,playlistDownloads:downloads.length,
    restartDownloads:downloads.length-downloadsBeforeRestart,nativeVideoElements:await page.locator('video').count(),
    remoteBack:true,exitConfirmation:true,exitCancellation:true,nativeExitCalls:await page.evaluate(() => window.__titanExitCalls),
    focusVisible,browserErrors:errors,consoleErrors,blockedExternalOrigins:[...new Set(blockedExternalRequests)],
    screenshot:'D:/tvbro/output/playwright/titan-os-home.png',
    scope:'Host Chrome; actual encrypted IndexedDB/WebCrypto, shared core/UI/worker and synthetic local M3U provider. Only native Titan exit stubbed; no TV playback, codec, performance or certification claim.'};
}
