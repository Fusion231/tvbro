// playwright-cli run-code --filename against ui_browser_server.cjs.
// Exercises the packaged UI, original Source parsers and canonical metadata
// helpers; only provider HTTP and the Samsung SDK boundary are synthetic.
async (page) => {
  const origin = new URL(page.url()).origin;
  if (new URL(origin).hostname !== '127.0.0.1') throw Error('Loopback QA server required');
  const errors = [], requests = [], phases = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => {
    const url = new URL(request.url());
    if (url.origin === origin && url.pathname === '/player_api.php') requests.push(url.searchParams.get('action'));
  });
  const activate = async selector => (typeof selector === 'string' ? page.locator(selector) : selector).press('Enter');
  const shown = selector => page.locator(selector).waitFor({state:'visible'});
  const modal = () => page.locator('.dialog:not([hidden])');
  const details = () => page.locator('.dialog.media-details:not([hidden])');
  async function edit(selector,value) {
    const input = typeof selector === 'string' ? page.locator(selector) : selector;
    await activate(input); await input.fill(value); await input.press('Escape');
  }
  function check(value,label) { if (!value) throw Error(label); }
  async function homeSection(kind) {
    if (!await page.locator('#home-view').isVisible()) await activate('#show-home');
    await shown('#home-view');
    await activate('#home-'+kind); await shown('#media-view');
    await page.locator('#media-items .media-card').first().waitFor();
  }
  async function playing() {
    await page.waitForFunction(() => document.body.classList.contains('player-open') &&
      window.TVBroSamsungPlatform.getState().playing && document.querySelector('#player-view').getAttribute('aria-busy') === 'false');
  }
  async function closeDetails() { await activate(details().locator('.details-close')); await page.locator('.dialog.media-details').waitFor({state:'detached'}); }
  async function scrollState() {
    return page.evaluate(() => ({categories:document.querySelector('#media-view .category-list').scrollTop,
      catalogue:document.querySelector('#media-view .media-panel').scrollTop}));
  }
  await page.goto(origin);
  await shown('#language-view');
  await activate(page.locator('#language-list').getByRole('button',{name:'English',exact:true}));
  await shown('#profiles-view');
  await activate('#add-profile'); await edit(modal().locator('input').first(),'Details QA');
  await activate(modal().getByRole('button',{name:'Save',exact:true}));
  await shown('#setup-view'); await activate('#setup-source'); await shown('#sources-view');
  await activate('#kind-xtream');
  await edit('#source-label','Details source'); await edit('#source-field-host',origin+'/');
  await edit('#source-field-username','fixture-user'); await edit('#source-field-password','fixture-pass');
  await activate('#connect-source'); await shown('#home-view');
  for (const size of [{width:1280,height:720},{width:1920,height:1080}]) {
    await page.setViewportSize(size); await homeSection('movie');
    await page.evaluate(() => {
      document.querySelector('#media-view .category-list').scrollTop=180;
      document.querySelector('#media-view .media-panel').scrollTop=180;
    });
    const movie = page.locator('#media-items .media-card').filter({has:page.getByText('Film 7',{exact:true})});
    await movie.focus();
    await page.evaluate(() => { window.__detailsOpener=document.activeElement; });
    const behind = await scrollState();
    await activate(movie); await details().waitFor();
    await check(await page.locator('#media-view .category-panel').isHidden(),'Movie details must hide the category rail at '+size.width);
    await check(await page.locator('#media-view .media-panel').isHidden(),'Movie details must hide the catalogue scrollbar at '+size.width);
    await check(await details().locator('.details-title').textContent() === 'Film 7','Movie title must remain the provider title');
    const text = await details().innerText();
    for (const value of ['Original movie QA','Drama, Adventure','Alicja Reżyser','Poland','2024-06-12','Anna Kowalska','Jan Nowak','Anna role QA','Jan role QA']) {
      await check(text.includes(value),'Movie information is missing '+value);
    }
    await check(await details().locator('.details-info-row').count() >= 6,'Movie must expose structured information rows');
    await check(await details().locator('.details-cast .details-person').count() === 2,'Cast must include both named actors');
    await check(await details().getByRole('button',{name:'Play',exact:true}).evaluate(node => node===document.activeElement),'The primary movie action must start focused');
    await page.screenshot({path:'D:/tvbro/output/playwright/samsung-details/movie-'+size.width+'.png'});
    const bounds = await details().evaluate(node => {
      const box=node.getBoundingClientRect(), close=node.querySelector('.details-close').getBoundingClientRect();
      return {left:box.left,top:box.top,right:box.right,bottom:box.bottom,closeTop:close.top,closeBottom:close.bottom};
    });
    await check(bounds.left>=0 && bounds.top>=0 && bounds.right<=size.width+1 && bounds.bottom<=size.height+1,'Details must fit the TV viewport');
    const scroll = details().locator('.details-scroll');
    await scroll.evaluate(node => { node.scrollTop=node.scrollHeight; });
    await scroll.hover(); await page.mouse.wheel(0,1200);
    const afterWheel = await scrollState();
    await check(JSON.stringify(afterWheel)===JSON.stringify(behind),'Details scroll must not change the hidden catalogue/category viewport');
    const closeAfter = await details().locator('.details-close').boundingBox();
    await check(closeAfter.y>=0 && closeAfter.y+closeAfter.height<=size.height,'Close remains visible after scrolling');
    await closeDetails();
    await check(JSON.stringify(await scrollState())===JSON.stringify(behind),'Closing movie details must restore background scroll');
    await check(await page.evaluate(() => document.activeElement===window.__detailsOpener),'Closing details must restore the original movie focus');
    phases.push('movie information, cast, isolated scroll and focus at '+size.width);

    await homeSection('series');
    await activate(page.locator('#media-items .media-card').filter({has:page.getByText('Serial QA',{exact:true})}));
    await details().waitFor();
    await check((await details().innerText()).includes('Original series QA'),'Series original title must be present');
    await check((await details().innerText()).includes('Maria Twórczyni'),'Series creator must be present');
    await check((await details().innerText()).includes('Detective Anna'),'Series cast roles must be present');
    const primary = details().getByRole('button',{name:'View episodes',exact:true});
    await check(await primary.evaluate(node => node===document.activeElement),'Series hero must retain initial action focus');
    await check(await details().locator('.episode-card').count()===0,'Collapsed seasons must not mount episode rails');
    await activate(primary);
    const seasons = details().locator('.season-button'); await seasons.nth(1).waitFor();
    await check(await seasons.first().evaluate(node => node===document.activeElement),'View episodes must focus the first season');
    await activate(seasons.first()); await details().locator('.episode-card').first().waitFor();
    await check(await details().locator('.episode-card').count()<=20,'A long season must mount a bounded episode window');
    const firstCard = details().locator('.episode-card[data-episode-index="0"]'); await firstCard.focus();
    await check((await firstCard.innerText()).includes('Pilot QA'),'First episode retains its provider title');
    await check((await firstCard.innerText()).includes('Episode 1 provider overview.'),'Episode cards must show their own synopsis');
    await check(await firstCard.locator('img').count()>0,'Episode cards must include artwork');
    await check(await firstCard.locator('img').first().evaluate(node => (node.getAttribute('src') || node.getAttribute('data-artwork-src') || '').includes('/episode-1.svg')),'Episode cards must prefer their own artwork');
    for(let step=0;step<25;step++) await page.keyboard.press('ArrowRight');
    await check(await page.locator(':focus').getAttribute('data-episode-index')==='25','Remote Right must cross lazy episode windows');
    await check(await details().locator('.episode-card').count()<=20,'Episode DOM must remain bounded after scrolling');
    await page.screenshot({path:'D:/tvbro/output/playwright/samsung-details/series-'+size.width+'.png'});
    await page.keyboard.press('ArrowUp');
    await check(await seasons.first().evaluate(node => node===document.activeElement),'Episode Up must return to its season header');
    await page.keyboard.press('ArrowDown');
    await check(await page.locator(':focus').getAttribute('data-episode-index')==='25','Returning to the episode rail must retain its cursor');
    await page.keyboard.press('ArrowDown');
    await check(await seasons.nth(1).evaluate(node => node===document.activeElement),'Episode Down must reach the next season');
    await seasons.first().focus(); await page.keyboard.press('ArrowDown');
    const saved = await details().evaluate(node => {
      window.__seriesDetailsNode=node;
      window.__seriesEpisodeNode=document.activeElement;
      const rail=document.activeElement.closest('.episode-rail');
      return {outer:node.querySelector('.details-scroll').scrollTop,rail:rail ? rail.scrollLeft : null,index:document.activeElement.getAttribute('data-episode-index')};
    });
    await page.keyboard.press('Enter'); await playing();
    if (await page.locator('#player-chrome').isVisible()) await page.keyboard.press('Escape');
    await page.keyboard.press('Escape');
    await details().waitFor();
    const restored = await details().evaluate(node => {
      const rail=document.activeElement.closest('.episode-rail');
      return {same:node===window.__seriesDetailsNode,outer:node.querySelector('.details-scroll').scrollTop,
        rail:rail ? rail.scrollLeft : null,index:document.activeElement.getAttribute('data-episode-index')};
    });
    await check(restored.same && restored.index===saved.index,'Back from episode must restore the same details and selected episode');
    await check(Math.abs(restored.outer-saved.outer)<=1 && restored.rail===saved.rail,'Episode Back must preserve details and episode scroll');
    await check(await seasons.first().getAttribute('aria-expanded')==='true','The selected season must stay expanded after playback');
    await closeDetails();
    phases.push('inline seasons, bounded episode rail, remote navigation and episode Back at '+size.width);
  }
  if(errors.length) throw Error('Browser errors: '+errors.join('; '));
  return {status:'passed',phases,browserErrors:errors,providerActions:requests,
    scope:'Actual packaged UI/canonical core with synthetic provider HTTP and Samsung SDK only; not physical TV decoding or remote qualification.'};
}
