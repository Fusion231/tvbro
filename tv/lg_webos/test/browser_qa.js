// playwright-cli run-code --filename, using the shared fixture server with an LG payload.
// Real DOM, IndexedDB, WebCrypto, worker, canonical core and shared library.
async (page) => {
  const origin = new URL(page.url()).origin;
  if (new URL(origin).hostname !== '127.0.0.1') throw Error('Loopback QA server required');
  const errors = [], requests = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/*', route => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) return route.abort();
    if (url.pathname === '/fixture/playlist.m3u') requests.push('playlist');
    return route.continue();
  });
  await page.goto(origin);
  await page.locator('#language-view').waitFor({state:'visible'});
  const saved = await page.evaluate(async origin => {
    const api = window.TVBroSamsungPlatform;
    if (window.tizen || window.webapis) throw Error('Samsung SDK must not be present');
    if (document.querySelectorAll('video').length !== 1 || document.querySelector('object[type="application/avplayer"]')) throw Error('Exactly one LG video expected');
    const created = await api.query('profiles.create', {name:'LG restart QA'});
    const source = {id:'lg-persistence',kind:'m3u',label:'LG channels',fields:{playlistUrl:origin+'/fixture/playlist.m3u'},settings:{}};
    await api.query('sources.add', {config:source});
    const catalog = await api.query('sources.load', {id:source.id});
    if (!catalog.channels.length) throw Error('No parsed channels');
    await api.query('favorites.toggle', {sourceId:source.id,channel:catalog.channels[0]});
    await api.query('settings.set', {settings:{profilePickerStartup:'off'}});
    await api.query('cache.flush');
    return {profileId:created.profile.id, channels:catalog.channels.length, favorites:await api.query('favorites.list')};
  }, origin);
  const downloadsBeforeRestart = requests.length;
  await page.reload();
  await page.locator('#language-view').waitFor({state:'visible'});
  const restored = await page.evaluate(async saved => {
    const api = window.TVBroSamsungPlatform;
    const profiles = await api.query('profiles.list');
    if (!profiles.profile || profiles.profile.id !== saved.profileId) throw Error('Profile did not survive restart');
    const sources = await api.query('sources.list');
    if (!sources.some(source => source.id === 'lg-persistence')) throw Error('Source did not survive restart');
    const favorites = await api.query('favorites.list');
    if (JSON.stringify(favorites) !== JSON.stringify(saved.favorites)) throw Error('Favorites did not survive restart');
    const catalog = await api.query('sources.load', {id:'lg-persistence'});
    if (catalog.channels.length !== saved.channels) throw Error('Restored catalog mismatch');
    return {channels:catalog.channels.length, profileRestored:true, favoritesRestored:true};
  }, saved);
  if (requests.length !== downloadsBeforeRestart) throw Error('Restart discarded persisted catalog and downloaded again');
  await page.locator('#language-continue').click();
  await page.locator('#home-view').waitFor({state:'visible'});
  await page.locator('#home-live').click();
  await page.locator('#catalog-view').waitFor({state:'visible'});
  // webOS key 461 must use the same existing Back behavior as Samsung key10009.
  await page.evaluate(() => document.dispatchEvent(new KeyboardEvent('keydown', {keyCode:461,which:461,bubbles:true,cancelable:true})));
  await page.locator('#home-view').waitFor({state:'visible'});
  await page.locator('#home-live').click();
  await page.locator('#catalog-view').waitFor({state:'visible'});
  await page.keyboard.press('ArrowDown');
  const focusVisible = await page.evaluate(() => !!document.activeElement && document.activeElement.hasAttribute('data-nav'));
  if (!focusVisible) throw Error('Remote focus lost');
  await page.evaluate(() => document.dispatchEvent(new KeyboardEvent('keydown', {keyCode:461,which:461,bubbles:true,cancelable:true})));
  await page.locator('#home-view').waitFor({state:'visible'});
  await page.evaluate(() => window.TVBroSamsungPlatform.query('sources.cancel'));
  if (errors.length) throw Error(errors.join('; '));
  return {status:'passed', ...restored, playlistDownloads:requests.length, restartDownloads:requests.length-downloadsBeforeRestart,
    nativeVideoElements:await page.locator('video').count(), remoteBack:true, focusVisible, browserErrors:errors,
    scope:'Host Chrome, actual LG encrypted IndexedDB/WebCrypto and shared UI/worker; synthetic local provider, no physical TV playback or performance claim.'};
}
