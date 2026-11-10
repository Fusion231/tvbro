'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {createRequire} = require('node:module');
const {repoRoot, tvRoot} = require('../../paths.cjs');
const buildShared = require('../../samsung_web/tools/build.cjs');
const project = path.resolve(__dirname, '..');
const toolingRoot = path.dirname(repoRoot);
const serviceDir = path.join(project, 'epg_service');
const acorn = createRequire(path.join(project, '../samsung_web/package.json'))('acorn');

function hash(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }

function sourceFiles(root, base = root, result = {}) {
  if (fs.lstatSync(root).isSymbolicLink()) throw new Error('Refuse symlinks in the webOS service source.');
  for (const entry of fs.readdirSync(root, {withFileTypes:true}).sort((a, b) => a.name.localeCompare(b.name))) {
    const absolute = path.join(root, entry.name);
    if (entry.isSymbolicLink()) throw new Error('Refuse symlinks in the webOS service source.');
    if (entry.isDirectory()) sourceFiles(absolute, base, result);
    else if (entry.isFile()) result[path.relative(base, absolute).split(path.sep).join('/')] = hash(fs.readFileSync(absolute));
    else throw new Error('Unexpected webOS service source entry.');
  }
  return result;
}

function validateServiceSyntax(directory, hashes = sourceFiles(directory)) {
  for (const relative of Object.keys(hashes).filter((file) => file.endsWith('.js'))) {
    acorn.parse(fs.readFileSync(path.join(directory, relative), 'utf8'), {ecmaVersion:5});
  }
}

function replaceOne(html, before, after) {
  if (html.split(before).length !== 2) throw new Error('Shared HTML platform binding changed: ' + before);
  return html.replace(before, after);
}

function transformHtml(html) {
  html = replaceOne(html, '<object id="native-player" type="application/avplayer" tabindex="-1"></object>',
    '<video id="native-player" tabindex="-1" preload="none"></video>');
  html = replaceOne(html, '<script src="$WEBAPIS/webapis/webapis.js"></script>', '');
  html = replaceOne(html, '<script src="polyfills.js"></script>', '<script src="polyfills.js"></script>\n  <script src="webOSTV.js"></script>');
  html = replaceOne(html, 'src="platform/avplay.js"', 'src="platform/player.js"');
  return replaceOne(html, '<script src="platform.js"></script>',
    '<script src="webos-bootstrap.js"></script>\n  <script src="platform.js"></script>');
}

function build() {
  const sdk = process.env.TVBRO_WEBOSTV_JS || path.join(toolingRoot,
    'evaluation/tooling/webos-cli/node_modules/@webos-tools/cli/files/templates/tv-sdk-templates/bootplate-web/webOSTVjs-1.2.13/webOSTV.js');
  if (!fs.existsSync(sdk)) throw new Error('Set TVBRO_WEBOSTV_JS to the official webOSTV.js SDK library.');
  const overrides = ['secure_store', 'memory_policy', 'catalog_store', 'backup_files', 'epg_files'];
  const shared = ['user_state', 'transport', 'source_worker', 'organization', 'backup', 'library'];
  const serviceHashes = sourceFiles(serviceDir);
  if (!Object.keys(serviceHashes).length) throw new Error('LG webOS EPG service source is empty.');
  validateServiceSyntax(serviceDir, serviceHashes);
  const serviceInputs = Object.keys(serviceHashes).map((relative) => path.join(serviceDir, relative));
  const result = buildShared({
    output: path.join(tvRoot, 'output/lg-webos'),
    core: path.join(tvRoot, 'output/samsung-web/core'),
    chrome: '38',
    status: 'lg_webos_payload_staged',
    target: 'LG webOS TV / Chromium M38 compatibility floor; physical TV qualification pending',
    inputFiles: [__filename, ...serviceInputs],
    manifestFile: path.join(project, 'appinfo.json'),
    transformHtml,
    copyFiles: [{source:sdk, relative:'webOSTV.js'}],
    platformModules: [
      {source:path.join(project, 'platform/player.js'), relative:'platform/player.js'},
      ...overrides.map((name) => ({source:path.join(project, 'platform/' + name + '.js'), relative:'platform/' + name + '.js'})),
      ...shared.map((name) => 'platform/' + name + '.js'),
      {source:path.join(project, 'platform.js'), relative:'webos-bootstrap.js'},
      'platform.js'
    ]
  });
  for (const name of ['icon.png', 'largeIcon.png']) {
    const source = path.join(project, 'assets', name);
    const target = path.join(result.payload, name);
    fs.copyFileSync(source, target);
    result.inputHashes[path.relative(repoRoot, source).split(path.sep).join('/')] = hash(fs.readFileSync(source));
    result.payloadHashes[name] = hash(fs.readFileSync(target));
  }
  const latestBuild = path.join(path.dirname(result.payload), 'latest-build.json');
  const currentServiceHashes = sourceFiles(serviceDir);
  if (JSON.stringify(currentServiceHashes) !== JSON.stringify(serviceHashes)) {
    throw new Error('Service source changed during staging.');
  }
  result.serviceId = 'online.tvbro.webos.epg';
  result.serviceDir = serviceDir;
  result.serviceHashes = serviceHashes;
  fs.writeFileSync(latestBuild, JSON.stringify(result, null, 2) + '\n');
  return result;
}

module.exports = {build, transformHtml, validateServiceSyntax};
if (require.main === module) build();
