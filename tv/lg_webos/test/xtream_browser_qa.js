// Run with playwright-cli against shared ui_browser_server.cjs serving an LG payload.
// Generate output/lg-xtream-fixture.mp4 as documented in VALIDATION.md first.
async (page) => {
  const origin = new URL(page.url()).origin;
  if (new URL(origin).hostname !== '127.0.0.1') throw Error('Loopback QA server required');
  const requests = [], errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.unroute('**/*');
  await page.route('**/*', async route => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) return route.abort();
    if (/^\/(movie|series)\/fixture-user\/fixture-pass\/\d+\.mp4$/.test(url.pathname)) {
      requests.push({path:url.pathname, userAgent:route.request().headers()['user-agent']});
      return route.continue();
    }
    return route.continue();
  });
  await page.goto(origin);
  await page.locator('#language-view').waitFor({state:'visible'});
  const result = await page.evaluate(async origin => {
    const api = window.TVBroSamsungPlatform, video = document.getElementById('native-player');
    if (window.tizen || window.webapis) throw Error('Samsung SDK must not be loaded');
    // Host Chrome's autoplay policy is not a TV playback capability.
    video.muted = true;
    await api.query('profiles.create', {name:'Xtream native playback QA'});
    await api.query('sources.add', {config:{id:'lg-xtream',kind:'xtream',label:'Fixture Xtream',
      fields:{host:origin,username:'fixture-user',password:'fixture-pass'},settings:{}}});
    await api.query('sources.load', {id:'lg-xtream'});
    const movies = await api.query('catalog.items', {kind:'movie',categoryId:'movies',page:1});
    const movie = movies.items[0];
    await api.query('playback.play', {item:movie,sourceId:'lg-xtream'});
    if (!api.getState().playing || video.videoWidth !== 320 || video.readyState < 2) throw Error('Movie did not decode');
    const movieUrl = video.currentSrc;
    await api.seek(4);
    if (Math.abs(video.currentTime - 4) > 1) throw Error('Movie seek did not complete');
    await api.playPause();
    if (!video.paused) throw Error('Movie pause failed');
    await api.playPause();
    if (video.paused) throw Error('Movie resume failed');
    const series = await api.query('catalog.items', {kind:'series',categoryId:'series',page:1});
    const seasons = await api.query('media.children', {item:series.items[0]});
    const episodes = await api.query('media.children', {item:seasons.items[0]});
    await api.query('playback.play', {item:episodes.items[0],sourceId:'lg-xtream'});
    if (!api.getState().playing || video.videoWidth !== 320 || video.readyState < 2) throw Error('Episode did not decode');
    const episodeUrl = video.currentSrc;
    await api.seek(3);
    if (Math.abs(video.currentTime - 3) > 1) throw Error('Episode seek did not complete');
    await api.query('playback.play', {item:episodes.items[1],sourceId:'lg-xtream'});
    if (!api.getState().playing || video.videoWidth !== 320) throw Error('Next episode did not decode');
    const nextEpisodeUrl = video.currentSrc;
    await api.query('playback.stop');
    if (video.getAttribute('src') || !video.paused || document.querySelectorAll('video').length !== 1) throw Error('Playback cleanup failed');
    await api.query('sources.cancel');
    return {movieUrl,episodeUrl,nextEpisodeUrl,seek:true,pauseResume:true,singleVideo:true,cleanup:true};
  }, origin);
  for (const url of [result.movieUrl,result.episodeUrl,result.nextEpisodeUrl]) {
    if (!requests.some(request => request.path === new URL(url).pathname)) throw Error('Direct source request missing');
  }
  if (requests.some(request => /VLC\//.test(request.userAgent || ''))) throw Error('Native UA expected');
  if (errors.length) throw Error(errors.join('; '));
  return {status:'passed',...result,mediaRequests:requests,browserErrors:errors,
    scope:'Actual compiled Xtream resolver, shared library, LG adapter and H.264/AAC decoding in host Chrome; local provider fixture only. No TV tested; no relay in product.'};
}
