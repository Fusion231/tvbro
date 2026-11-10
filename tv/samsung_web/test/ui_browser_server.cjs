'use strict';
// Browser QA boundaries only: synthetic provider HTTP and Samsung SDK calls.
// The served UI, platform, original Dart core and panel modules are real payload bytes.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const project = path.resolve(__dirname, '..');
const output = path.resolve(project, '../output/samsung-web');
const payload = fs.realpathSync(process.argv[2] || JSON.parse(fs.readFileSync(path.join(output, 'latest-build.json'))).payload);
const mediaFixture = process.env.TVBRO_QA_MEDIA ? fs.realpathSync(process.env.TVBRO_QA_MEDIA) : null;
if (!fs.existsSync(path.join(payload, 'platform/library.js'))) throw Error('Build the full original-Source payload first.');
const requests = [];
const now = Date.now();
const stamp = milliseconds => new Date(milliseconds).toISOString().replace(/[-:TZ.]/g, '').slice(0, 14) + ' +0000';
const guide = id => '<?xml version="1.0"?><tv><channel id="' + id + '"><display-name>Kanał 1</display-name></channel>' +
  [[-60, -30, 'Archiwum QA'], [-15, 30, 'Teraz QA'], [30, 90, 'Następnie QA']].map(([start, end, title]) =>
    '<programme channel="' + id + '" start="' + stamp(now + start * 60000) + '" stop="' + stamp(now + end * 60000) + '"><title>' + title + '</title><desc>Opis oryginalnego programu z XMLTV</desc></programme>').join('') + '</tv>';
const sdk = fs.readFileSync(path.join(__dirname, 'browser_sdk_fixture.js'), 'utf8') + `
(function(){
  var fixture=window.__samsungFixture, av=window.webapis.avplay, oldListener=av.setListener;
  fixture.seconds=0;
  av.setListener=function(listener){fixture.listener=listener;oldListener(listener);};
  av.getCurrentTime=function(){return fixture.seconds*1000;};
  av.getTotalTrackInfo=function(){return [{type:'AUDIO',index:0,extra_info:'{"language":"Polski"}'},{type:'TEXT',index:1,extra_info:'{"language":"English"}'}];};
  av.getCurrentStreamInfo=function(){return [{type:'AUDIO',index:0,extra_info:'{}'},{type:'TEXT',index:1,extra_info:'{}'}];};
  av.setSelectTrack=function(type,index){fixture.calls.push(['track',type,index]);};
  av.setSilentSubtitle=function(silent){fixture.calls.push(['subtitle',silent]);};
  av.setSpeed=function(speed){fixture.calls.push(['speed',speed]);};
  av.setDisplayMethod=function(mode){fixture.calls.push(['aspect',mode]);};
  fixture.tick=function(seconds){fixture.seconds=seconds;if(fixture.listener&&fixture.listener.oncurrentplaytime)fixture.listener.oncurrentplaytime(seconds*1000);};
  // A playing SDK boundary advances its native clock, including when browser
  // QA advances virtual time. A fixed zero clock correctly triggers recovery.
  var tickTimer=null, oldPlay=av.play, oldPause=av.pause, oldClose=av.close, oldOpen=av.open;
  function stopClock(){window.clearTimeout(tickTimer);tickTimer=null;}
  function advanceClock(){tickTimer=null;if(av.getState()!=='PLAYING')return;fixture.tick(fixture.seconds+1);tickTimer=window.setTimeout(advanceClock,1000);}
  av.open=function(url){stopClock();fixture.seconds=0;return oldOpen(url);};
  av.play=function(){stopClock();oldPlay();tickTimer=window.setTimeout(advanceClock,1000);};
  av.pause=function(){stopClock();return oldPause();};
  av.close=function(){stopClock();return oldClose();};
}());
`;
function provider(url, origin) {
  if (url.pathname === '/fixture/playlist.m3u') {
    return '#EXTM3U url-tvg="' + origin + '/fixture/guide.xml"\n' + Array.from({length:161}, (_, i) =>
      '#EXTINF:-1 tvg-id="live' + (i + 1) + '" group-title="' + (i < 100 ? 'Polska' : 'Sport') + '"' +
      (i === 0 ? ' catchup="default" catchup-days="7" catchup-source="' + origin + '/fixture/archive?start={start}&end={end}"' : '') +
      ',Kanał ' + (i + 1) + '\n' + origin + '/fixture/live/' + (i + 1) + '.m3u8\n').join('');
  }
  if (url.pathname === '/fixture/guide.xml') return require('node:zlib').gzipSync(Buffer.from(guide('live1')));
  if (url.pathname === '/xmltv.php') return guide('xtream-live');
  if (url.pathname !== '/player_api.php') return undefined;
  switch (url.searchParams.get('action')) {
    case null: return {user_info:{auth:1,status:'Active',exp_date:'4102444800',max_connections:'2',active_cons:'0'},server_info:{timezone:'UTC'}};
    case 'get_live_categories': return [{category_id:'7',category_name:'Polska'}];
    case 'get_live_streams': return [{stream_id:11,name:'Xtream Live',category_id:'7',epg_channel_id:'xtream-live',tv_archive:1,tv_archive_duration:2}];
    case 'get_vod_categories': return [{category_id:'movies',category_name:'Filmy QA'},
      ...Array.from({length:20},(_,i)=>({category_id:'movie-category-'+i,category_name:'Movie category '+(i+1)}))];
    case 'get_series_categories': return [{category_id:'series',category_name:'Seriale QA'}];
    case 'get_vod_streams': return url.searchParams.has('category_id') && url.searchParams.get('category_id') !== 'movies' ? [] : Array.from({length:15}, (_, i) => ({stream_id:500+i,name:'Film '+i,category_id:'movies',container_extension:'mp4',year:'2024',rating:'8.4'}));
    case 'get_series': return [{series_id:900,name:'Serial QA',category_id:'series',year:'2023',rating:'8.1'}];
    case 'get_vod_info': return {info:{plot:'Opis filmu od dostawcy. '+
      'A long provider synopsis verifies that details scroll independently of the category and movie browsers. '.repeat(8),
      releasedate:'2024-06-12',original_title:'Original movie QA',duration_secs:5400,
      genre:'Drama, Adventure',director:'Alicja Reżyser',country:'Poland',rating:'8.4',
      movie_image:origin+'/fixture/art/movie-poster.svg',backdrop_path:[origin+'/fixture/art/movie-backdrop.svg'],
      cast:[{name:'Anna Kowalska',character:'Anna role QA',photo_url:origin+'/fixture/art/anna.svg'},
        {name:'Jan Nowak',character:'Jan role QA',photo_url:origin+'/fixture/art/jan.svg'}]},movie_data:{}};
    case 'get_series_info': return {info:{plot:'Opis serialu od dostawcy. '+
      'A series overview remains below the inline season browser and must not scroll the underlying catalogue. '.repeat(6),
      original_name:'Original series QA',releasedate:'2023-03-14',genre:'Drama, Mystery',country:'Poland',
      created_by:[{name:'Maria Twórczyni'}],cast:[{name:'Anna Kowalska',character:'Detective Anna',photo_url:origin+'/fixture/art/anna.svg'}],
      cover:origin+'/fixture/art/series-poster.svg',backdrop_path:[origin+'/fixture/art/series-backdrop.svg'],rating:'8.1'},
      seasons:[{season_number:1,name:'Sezon 1'},{season_number:2,name:'Sezon 2'}],episodes:{
        '1':Array.from({length:120},(_,i)=>({id:901+i,title:i===0?'Pilot QA':'Episode QA '+(i+1),episode_num:i+1,
          container_extension:'mp4',info:{duration_secs:i===0?'120':'2700',plot:'Episode '+(i+1)+' provider overview.',
            movie_image:origin+'/fixture/art/episode-'+(i+1)+'.svg',releasedate:'2023-03-14'}})),
        '2':Array.from({length:3},(_,i)=>({id:2001+i,title:'Season 2 episode QA '+(i+1),episode_num:i+1,
          container_extension:'mp4',info:{duration_secs:'2800',plot:'Second season episode '+(i+1)+' overview.',
            movie_image:origin+'/fixture/art/season-2-episode-'+(i+1)+'.svg',releasedate:'2024-03-14'}}))}};
    case 'get_short_epg': return {epg_listings:[]};
    default: throw Error('Unexpected fixture action: ' + url.searchParams.get('action'));
  }
}
const server = http.createServer((request, response) => {
  const origin = 'http://' + request.headers.host;
  const url = new URL(request.url, origin);
  requests.push({path:url.pathname, action:url.searchParams.get('action')});
  response.setHeader('Access-Control-Allow-Origin', '*');
  if (url.pathname === '/__qa/stop') { response.end('done'); setImmediate(() => server.close()); return; }
  if (url.pathname === '/favicon.ico') { response.writeHead(204); response.end(); return; }
  // Optional local media fixture for real decoder/seek tests. Never packaged.
  if (mediaFixture && /^\/(movie|series)\/fixture-user\/fixture-pass\/\d+\.mp4$/.test(url.pathname)) {
    const size = fs.statSync(mediaFixture).size;
    const range = request.headers.range, match = range && /^bytes=(\d+)-(\d*)$/.exec(range);
    const start = match ? Number(match[1]) : 0, end = match && match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
    response.setHeader('Accept-Ranges', 'bytes');
    response.setHeader('Content-Type', 'video/mp4');
    if (range && !match || !Number.isSafeInteger(start) || start > end || start >= size) {
      response.writeHead(416, {'Content-Range':'bytes */' + size}); response.end(); return;
    }
    response.setHeader('Content-Length', end - start + 1);
    if (match) response.writeHead(206, {'Content-Range':'bytes ' + start + '-' + end + '/' + size});
    const file = fs.createReadStream(mediaFixture, {start, end});
    response.on('close', () => file.destroy());
    file.on('error', () => response.destroy()); file.pipe(response); return;
  }
  if (url.pathname === '/$WEBAPIS/webapis/webapis.js') { response.setHeader('Content-Type','text/javascript'); response.end(sdk); return; }
  if (url.pathname === '/fixture/slow.m3u') { request.on('close', () => requests.push({path:'/fixture/slow-request-closed'})); return; }
  if (/^\/fixture\/art\/[a-z0-9-]+\.svg$/.test(url.pathname)) {
    response.setHeader('Content-Type','image/svg+xml');
    response.end('<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360" viewBox="0 0 640 360"><rect width="640" height="360" fill="#312638"/><path d="M0 280 180 130l120 100 130-140 210 230v40H0z" fill="#714057"/><circle cx="470" cy="90" r="42" fill="#b91c35"/></svg>'); return;
  }
  const data = provider(url, origin);
  if (Buffer.isBuffer(data)) { response.setHeader('Content-Type','application/gzip'); response.end(data); return; }
  if (data !== undefined) { response.setHeader('Content-Type',typeof data === 'string' ? 'text/plain; charset=utf-8' : 'application/json'); response.end(typeof data === 'string' ? data : JSON.stringify(data)); return; }
  const file = path.resolve(payload, decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname).slice(1));
  if (!file.startsWith(payload + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) { response.writeHead(404); response.end(); return; }
  const types = {'.js':'text/javascript','.html':'text/html; charset=utf-8','.css':'text/css','.png':'image/png','.ttf':'font/ttf'};
  response.setHeader('Content-Type',types[path.extname(file)] || 'application/octet-stream'); response.end(fs.readFileSync(file));
});
server.listen(0,'127.0.0.1',() => {
  const address={url:'http://127.0.0.1:'+server.address().port,pid:process.pid,payload};
  fs.writeFileSync(path.join(output,'ui-browser-server.json'),JSON.stringify(address)); console.log(JSON.stringify(address));
});
const timer=setTimeout(() => server.close(),1800000);
server.on('close',() => { clearTimeout(timer); fs.writeFileSync(path.join(output,'ui-browser-requests.json'),JSON.stringify(requests,null,2)); });
process.on('SIGINT',() => server.close());
