// playwright-cli run-code --filename against the loopback UI fixture server.
// Real profile, PIN and KeyManager code runs; only SDK/provider IO is synthetic.
async (page) => {
  const origin = new URL(page.url()).origin;
  if (new URL(origin).hostname !== '127.0.0.1') throw Error('Loopback QA server required');
  const phases = [], errors = [], blocked = [];
  const snapshotKey = '__tvbro_profile_startup_qa_sdk_aliases';
  const onError = error => errors.push(error.message);
  page.on('pageerror', onError);
  const router = async route => {
    const url = new URL(route.request().url());
    if (url.origin === origin) return route.continue();
    blocked.push(url.origin); return route.abort('blockedbyclient');
  };
  await page.route('**/*', router);
  // Preserve only exact synthetic KeyManager alias bytes written by the platform.
  // Reload reconstructs every real platform/UI object and clears unlocked PIN state.
  await page.evaluate(key => sessionStorage.removeItem(key), snapshotKey);
  await page.addInitScript(key => {
    let current;
    Object.defineProperty(window, '__samsungFixture', {configurable:true,
      get() { return current; },
      set(value) {
        current = value;
        const saved = sessionStorage.getItem(key);
        if (saved) Object.entries(JSON.parse(saved)).forEach(([name,raw]) => {
          if (Object.prototype.hasOwnProperty.call(value.data,name)) throw Error('Reload must not overwrite an SDK alias');
          value.data[name] = raw;
        });
      }
    });
  }, snapshotKey);
  const activate = selector => (typeof selector === 'string' ? page.locator(selector) : selector).press('Enter');
  const shown = selector => page.locator(selector).waitFor({state:'visible'});
  const modal = () => page.locator('.dialog:not([hidden])');
  const check = (value, message) => { if (!value) throw Error(message); };
  const read = () => page.evaluate(() => window.TVBroSamsungPlatform.query('bootstrap'));
  const settlePaint = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  async function homeReady() {
    await shown('#home-view');
    await page.waitForFunction(() => !document.querySelector('#home-live').disabled);
  }
  async function reloadAliases() {
    await page.evaluate(key => sessionStorage.setItem(key,JSON.stringify(window.__samsungFixture.data)), snapshotKey);
    await page.reload();
  }
  async function enterPin(value) {
    const input = modal().locator('input').first();
    await activate(input); await input.fill(value); await input.press('Escape');
    await activate(modal().getByRole('button',{name:'Continue',exact:true}));
  }
  async function profileCard(name) {
    await activate('#show-profiles'); await shown('#profiles-view');
    await activate(page.locator('#profile-list .profile-card').filter({has:page.getByText(name,{exact:true})}));
  }
  try {
    for (const size of [{width:1280,height:720},{width:1920,height:1080}]) {
      await page.setViewportSize(size);
      await page.evaluate(key => sessionStorage.removeItem(key), snapshotKey); await page.goto(origin);
      await shown('#language-view');
      await activate(page.locator('#language-list').getByRole('button',{name:'English',exact:true})); await shown('#profiles-view');
      const identities = await page.evaluate(async origin => {
        const query = (action,args) => window.TVBroSamsungPlatform.query(action,args);
        const first = (await query('profiles.create',{name:'Open startup QA'})).profile;
        await query('sources.add',{config:{id:'open-startup-source',kind:'m3u',label:'Open startup source',
          fields:{playlistUrl:origin+'/fixture/playlist.m3u'},settings:{}}});
        const locked = (await query('profiles.create',{name:'Locked startup QA',pin:'2468'})).profile;
        await query('sources.add',{config:{id:'locked-startup-source',kind:'m3u',label:'Locked startup source',
          fields:{playlistUrl:origin+'/fixture/playlist.m3u'},settings:{}}});
        await query('settings.set',{settings:{profilePickerStartup:'off'}});
        return {first:first.id,locked:locked.id};
      }, origin);

      await reloadAliases(); await modal().locator('input').first().waitFor();
      check((await read()).profile.id===identities.locked,'Cold launch must remember the last selected profile');
      check((await read()).profile.locked===true && (await read()).sources.length===0,'Auto-selection must not unlock the remembered PIN profile');
      await page.screenshot({path:'D:/tvbro/output/playwright/samsung-profile-startup/pin-'+size.width+'.png'});
      await page.keyboard.press('Escape'); await page.locator('#modal-layer').waitFor({state:'hidden'}); await shown('#profiles-view');
      await settlePaint();
      check(await page.locator('#modal-layer').isHidden() && await page.locator('#home-view').isHidden(),'Cancelling automatic PIN must leave the chooser without prompting again');
      check(await page.locator('#profile-list .profile-card').first().isEnabled(),'Cancelling PIN must re-enable manual profile selection');

      await activate(page.locator('#profile-list .profile-card').filter({has:page.getByText('Locked startup QA',{exact:true})}));
      await modal().locator('input').first().waitFor(); await enterPin('0000');
      await page.waitForFunction(() => document.querySelector('#app-status').classList.contains('is-error'));
      check((await read()).profile.locked===true && (await read()).sources.length===0,'Incorrect PIN must keep the saved profile locked');
      await activate(page.locator('#profile-list .profile-card').filter({has:page.getByText('Locked startup QA',{exact:true})}));
      await modal().locator('input').first().waitFor(); await enterPin('2468'); await homeReady();
      const unlocked = await read();
      check(unlocked.profile.id===identities.locked && !unlocked.profile.locked,'Correct PIN must open the remembered profile');
      check(unlocked.sources[0].id==='locked-startup-source','Automatic startup must retain the saved profile source');
      phases.push('remembered PIN profile starts at PIN; cancel and invalid PIN preserve the gate at '+size.width);

      await profileCard('Open startup QA'); await homeReady(); await reloadAliases(); await homeReady();
      const open = await read();
      check(open.profile.id===identities.first && open.settings.profilePickerStartup==='off','Switching profiles must update the remembered startup identity');
      check(await page.locator('#profiles-view').isHidden() && await page.locator('#modal-layer').isHidden(),'Saved unprotected profile must open directly without the chooser');
      check(open.sources[0].id==='open-startup-source','Unprotected cold launch must restore its own source');
      phases.push('unprotected last-selected profile and global startup mode survive cold reload at '+size.width);

      await page.evaluate(() => window.TVBroSamsungPlatform.query('settings.set',{settings:{profilePickerStartup:'auto'}}));
      await reloadAliases(); await shown('#profiles-view'); await settlePaint();
      check(await page.locator('#modal-layer').isHidden(),'Auto mode with multiple profiles must retain the chooser');
      await activate(page.locator('#profile-list .profile-card').filter({has:page.getByText('Locked startup QA',{exact:true})}));
      await modal().locator('input').first().waitFor(); await enterPin('2468'); await homeReady();
      await page.evaluate(() => window.TVBroSamsungPlatform.query('settings.set',{settings:{profilePickerStartup:'always'}}));
      await reloadAliases(); await shown('#profiles-view'); await settlePaint();
      check(await page.locator('#modal-layer').isHidden(),'Always mode must not automatically open a remembered PIN profile');
      phases.push('auto and always startup modes retain the normal chooser at '+size.width);
    }
    check(errors.length===0,'Browser runtime errors: '+errors.join('; '));
    check(blocked.length===0,'Unexpected external requests were blocked: '+blocked.join('; '));
    return {status:'passed',phases,browserErrors:errors,
      scope:'Actual packaged UI/platform/canonical profile and PIN code. Synthetic SDK aliases model cold reload persistence; provider HTTP is loopback only. No real TV, accounts or profile data.'};
  } finally {
    page.off('pageerror',onError); await page.unroute('**/*',router);
    await page.evaluate(key => sessionStorage.removeItem(key),snapshotKey);
  }
}
