'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {tvRoot} = require('../../paths.cjs');
const buildShared = require('../../samsung_web/tools/build.cjs');
const project = path.resolve(__dirname, '..');
const lg = path.join(tvRoot, 'lg_webos');

function replaceOne(html, before, after) {
  if (html.split(before).length !== 2) throw new Error('Shared HTML platform binding changed: ' + before);
  return html.replace(before, after);
}

function transformHtml(html) {
  html = replaceOne(html, '<object id="native-player" type="application/avplayer" tabindex="-1"></object>',
    '<video id="native-player" tabindex="-1" preload="none" playsinline></video>');
  html = replaceOne(html, '<script src="$WEBAPIS/webapis/webapis.js"></script>', '');
  html = replaceOne(html, '<script src="platform/avplay.js"></script>',
    '<script src="platform/html5-player.js"></script>\n  <script src="platform/player.js"></script>');
  return replaceOne(html, '<script src="platform.js"></script>',
    '<script src="titan-bootstrap.js"></script>\n  <script src="platform.js"></script>');
}

function build() {
  const portable = ['secure_store', 'memory_policy', 'catalog_store', 'backup_files'];
  const shared = ['user_state', 'transport', 'source_worker', 'organization', 'backup', 'library'];
  const result = buildShared({
    output: path.join(tvRoot, 'output/titan-os'),
    core: path.join(tvRoot, 'output/samsung-web/core'),
    chrome: '47',
    status: 'titan_os_payload_staged',
    target: 'Titan OS hosted HTML5; physical TV qualification pending',
    inputFiles: [__filename],
    manifestFile: path.join(project, 'hosting.json'),
    transformHtml,
    platformModules: [
      {source:path.join(lg, 'platform/player.js'), relative:'platform/html5-player.js'},
      {source:path.join(project, 'platform/player.js'), relative:'platform/player.js'},
      ...portable.map((name) => ({source:path.join(lg, 'platform/' + name + '.js'), relative:'platform/' + name + '.js'})),
      ...shared.map((name) => 'platform/' + name + '.js'),
      {source:path.join(project, 'platform.js'), relative:'titan-bootstrap.js'},
      'platform.js'
    ]
  });
  delete result.samsungSigned;
  result.hostedHtml5 = true;
  result.entryPoint = 'index.html';
  result.httpsRequired = true;
  result.storeCertified = false;
  result.titanPublished = false;
  fs.writeFileSync(path.join(path.dirname(result.payload), 'latest-build.json'), JSON.stringify(result, null, 2) + '\n');
  return result;
}

module.exports = {build, transformHtml};
if (require.main === module) build();
