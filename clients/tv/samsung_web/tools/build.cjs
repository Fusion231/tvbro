'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const babel = require('@babel/core');
const presetEnv = require('@babel/preset-env');
const acorn = require('acorn');
const vm = require('node:vm');
const {repoRoot, playerRoot, tvRoot} = require('../../paths.cjs');

function build(options = {}) {
const project = path.resolve(__dirname, '..');
const output = options.output || path.join(tvRoot, 'output/samsung-web');
const chrome = options.chrome || '47';
const stamp = new Date().toISOString().replace(/[-:.]/g, '');
const payload = path.join(output, 'payload-' + stamp);
const core = options.core || path.join(output, 'core');
const proofFile = path.join(core, 'reuse-proof.json');
const proofBytes = fs.readFileSync(proofFile);
const proof = JSON.parse(proofBytes.toString('utf8'));
const hash = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const hashFile = (file) => hash(fs.readFileSync(file));
const inputs = {};
const outputs = {};
const proofHash = hash(proofBytes);
const coreFile = path.join(core, 'core.js');
if (hashFile(coreFile) !== proof.jsSha256) throw new Error('Generated core.js does not match its canonical reuse proof.');
inputs[path.relative(repoRoot, proofFile).replaceAll(path.sep, '/')] = proofHash;
inputs[path.relative(repoRoot, __filename).replaceAll(path.sep, '/')] = hashFile(__filename);
const pathsFile = path.join(tvRoot, 'paths.cjs');
inputs[path.relative(repoRoot, pathsFile).replaceAll(path.sep, '/')] = hashFile(pathsFile);
for (const [relative, proofField] of [
  ['clients/tv/samsung_web/core_builder/web_bindings.dart.txt', 'webPortSha256'],
  ['clients/tv/samsung_web/core_builder/metadata_bindings.dart.txt', 'metadataPortSha256'],
]) {
  const file = path.resolve(repoRoot, relative);
  if (typeof proof.bindings[proofField] !== 'string' || hashFile(file) !== proof.bindings[proofField]) {
    throw new Error('Canonical web binding changed; rebuild its generated core: ' + relative);
  }
  inputs[relative] = proof.bindings[proofField];
}
for (const file of options.inputFiles || []) {
  inputs[path.relative(repoRoot, file).replaceAll(path.sep, '/')] = hashFile(file);
}

if (proof.status !== 'canonical_core_compiled' || proof.originalSourcesUnchanged !== true) {
  throw new Error('Build the canonical Dart core first.');
}
for (const [relative, expected] of Object.entries(proof.sourceFilesSha256)) {
  const file = path.resolve(repoRoot, relative);
  if (!file.startsWith(repoRoot + path.sep) || hashFile(file) !== expected) {
    throw new Error('Canonical source changed; rebuild its generated core: ' + relative);
  }
  inputs[relative] = expected;
}
const protectedManifests = ['pubspec.yaml', 'pubspec.lock'];
for (const relative of protectedManifests) {
  const file = path.join(playerRoot, relative);
  inputs[path.relative(repoRoot, file).replaceAll(path.sep, '/')] = hashFile(file);
}
fs.mkdirSync(payload, { recursive: true });

function copy(source, relative) {
  const target = path.join(payload, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(source, target);
  inputs[path.relative(repoRoot, source).replaceAll(path.sep, '/')] = hashFile(source);
  outputs[relative] = hashFile(target);
}
function transform(source, relative, panelModule = false) {
  let code = fs.readFileSync(source, 'utf8');
  if (relative === 'platform/source_worker.js') {
    const pinSource = path.join(repoRoot, 'panel/src/pin.js');
    const pinText = fs.readFileSync(pinSource, 'utf8');
    const pinAst = babel.parseSync(pinText, {sourceType:'module', babelrc:false, configFile:false});
    const names = new Set(['PIN_LENGTH', 'PIN_ALGORITHM', 'PIN_ITERATIONS', 'SALT_BYTES',
      'HASH_BYTES', 'isValidPin', 'toBase64', 'hashPin']);
    const bodies = [], found = new Set();
    for (const statement of pinAst.program.body) {
      const declaration = statement.type === 'ExportNamedDeclaration' ? statement.declaration : statement;
      if (!declaration) continue;
      const declared = declaration.type === 'FunctionDeclaration' ? [declaration.id.name]
        : declaration.type === 'VariableDeclaration' ? declaration.declarations.map((item) => item.id.name) : [];
      if (!declared.some((name) => names.has(name))) continue;
      if (declared.some((name) => !names.has(name))) throw new Error('Unexpected grouped panel PIN declaration.');
      bodies.push(pinText.slice(declaration.start, declaration.end));
      declared.forEach((name) => found.add(name));
    }
    if (found.size !== names.size) throw new Error('Canonical panel PIN declarations changed.');
    const marker = '/*__TVBRO_PANEL_PIN_BINDING__*/';
    if (code.split(marker).length !== 2) throw new Error('Expected one panel PIN platform binding.');
    const binding = 'panelPinHash=function(environment){' +
      'var provider=environment.crypto,crypto={subtle:provider.subtle||provider.webkitSubtle,' +
      'getRandomValues:function(bytes){return provider.getRandomValues(bytes);}};' +
      'var TextEncoder=environment.TextEncoder,btoa=function(value){return environment.btoa(value);};' +
      bodies.join('\n') + '\nreturn hashPin;};';
    code = code.replace(marker, () => binding);
    inputs[path.relative(repoRoot, pinSource).replaceAll(path.sep, '/')] = hashFile(pinSource);
  }
  const result = babel.transformSync(code, {
    filename: source,
    babelrc: false,
    configFile: false,
    sourceType: panelModule ? 'module' : 'script',
    comments: false,
    compact: true,
    presets: [[presetEnv, {
      targets: { chrome },
      forceAllTransforms: true,
      modules: panelModule ? 'commonjs' : false,
      useBuiltIns: false,
    }]],
  }).code;
  const wrapped = panelModule
    ? '(function(root){var exports={};' + result + ';root.TVBroPanelValidation=exports;})(window);'
    : result;
  acorn.parse(wrapped, { ecmaVersion: 5, sourceType: 'script' });
  fs.mkdirSync(path.dirname(path.join(payload, relative)), { recursive: true });
  fs.writeFileSync(path.join(payload, relative), wrapped + '\n');
  inputs[path.relative(repoRoot, source).replaceAll(path.sep, '/')] = hashFile(source);
  outputs[relative] = hashFile(path.join(payload, relative));
}

function emit(relative, code) {
  acorn.parse(code, { ecmaVersion: 5, sourceType: 'script' });
  fs.writeFileSync(path.join(payload, relative), code + '\n');
  outputs[relative] = hashFile(path.join(payload, relative));
}
const configurationFile = path.join(project, 'publisher.config.local.json');
const domain = { console, crypto: crypto.webcrypto, setTimeout, clearTimeout, TextEncoder, TextDecoder };
domain.window = domain; domain.self = domain;
vm.createContext(domain);
vm.runInContext(fs.readFileSync(path.join(core, 'core.js'), 'utf8'), domain, { timeout: 10000 });
if (!domain.TVBroCanonical || !domain.TVBroCanonical.cloudConfig) throw new Error('Rebuild the canonical core with the original CloudConfig.');
const originalConfiguration = JSON.parse(domain.TVBroCanonical.cloudConfig());
const defaults = originalConfiguration.enabled && originalConfiguration.configured
  ? { apiUrl: originalConfiguration.apiUrl, panelUrl: originalConfiguration.panelUrl, anonKey: originalConfiguration.anonKey }
  : { enabled: false };
const configuration = fs.existsSync(configurationFile) ? JSON.parse(fs.readFileSync(configurationFile, 'utf8')) : defaults;
if (Object.keys(configuration).some((key) => !['enabled', 'apiUrl', 'panelUrl', 'anonKey', 'providerRelay'].includes(key))) throw new Error('Unknown publisher configuration field.');
for (const key of ['apiUrl', 'panelUrl']) {
  if (!configuration[key]) continue;
  const url = new URL(configuration[key]);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname !== '/' || /(?:\.invalid|\.example|\.test)$/.test(url.hostname)) throw new Error('Publisher ' + key + ' must be a production HTTPS origin.');
}
if (!!configuration.apiUrl !== !!configuration.panelUrl) throw new Error('Configure both apiUrl and panelUrl.');
if (configuration.providerRelay && (!configuration.apiUrl || configuration.providerRelay !== true)) throw new Error('Provider relay requires a configured API and boolean opt-in.');
if (configuration.anonKey && configuration.anonKey !== 'tvbro_public_client') throw new Error('Use the existing API public client key; private keys cannot be packaged.');
if (fs.existsSync(configurationFile)) inputs[path.relative(repoRoot, configurationFile).replaceAll(path.sep, '/')] = hashFile(configurationFile);
emit('publisher-config.js', 'window.TVBroSamsungConfig=' + JSON.stringify(configuration) + ';');

copy(path.join(project, 'ui/index.html'), 'index.html');
if (options.transformHtml) {
  fs.writeFileSync(path.join(payload, 'index.html'), options.transformHtml(fs.readFileSync(path.join(payload, 'index.html'), 'utf8')));
  outputs['index.html'] = hashFile(path.join(payload, 'index.html'));
}
const style = fs.readFileSync(path.join(project, 'ui/styles.css'), 'utf8');
if (/var\s*\(--|display\s*:\s*grid|(?:^|[;{])\s*(?:gap|row-gap|column-gap)\s*:/m.test(style)) {
  throw new Error('The Samsung 2017 stylesheet contains unsupported layout features.');
}
copy(path.join(project, 'ui/styles.css'), 'styles.css');
copy(options.manifestFile || path.join(project, 'config.xml'), options.manifestFile ? path.basename(options.manifestFile) : 'config.xml');
copy(require.resolve('core-js-bundle/minified.js'), 'polyfills.js');
transform(require.resolve('pako/dist/pako_inflate.min.js'), 'pako-inflate.js');
copy(path.join(path.dirname(require.resolve('pako')), 'LICENSE'), 'licenses/pako-LICENSE.txt');
transform(path.join(project, 'platform/streaming_gzip.js'), 'platform/streaming_gzip.js');
if (!(options.platformModules || []).some((item) =>
  (typeof item === 'string' ? item : item.relative) === 'platform/epg_files.js')) {
  transform(path.join(project, 'platform/epg_files.js'), 'platform/epg_files.js');
}
for (const item of options.copyFiles || []) copy(item.source, item.relative);
transform(path.join(core, 'core.js'), 'canonical-core.js');
transform(path.join(repoRoot, 'panel/src/validate.js'), 'panel-validation.js', true);
require('./extract_cloud_crypto.cjs')(babel, presetEnv, project, payload, {chrome});
inputs['panel/src/crypto.js'] = hashFile(path.join(repoRoot, 'panel/src/crypto.js'));
inputs['clients/tv/samsung_web/tools/extract_cloud_crypto.cjs'] = hashFile(path.join(project, 'tools/extract_cloud_crypto.cjs'));
outputs['cloud-crypto.js'] = hashFile(path.join(payload, 'cloud-crypto.js'));
for (const item of options.platformModules || ['platform/avplay.js', 'platform/secure_store.js', 'platform/user_state.js', 'platform/transport.js', 'platform/memory_policy.js', 'platform/source_worker.js', 'platform/catalog_store.js', 'platform/organization.js', 'platform/backup.js', 'platform/backup_files.js', 'platform/library.js', 'platform.js']) {
  const relative = typeof item === 'string' ? item : item.relative;
  transform(typeof item === 'string' ? path.join(project, relative) : item.source, relative);
}
if (fs.existsSync(path.join(project, 'platform/cloud.js'))) transform(path.join(project, 'platform/cloud.js'), 'platform/cloud.js');
transform(path.join(project, 'ui/viewport.js'), 'viewport.js');
transform(path.join(project, 'ui/app.js'), 'app.js');
copy(path.join(playerRoot, 'assets/brand/tvbro-logo.png'), 'assets/logo.png');
copy(path.join(playerRoot, 'assets/brand/tvbro-icon.png'), 'icon.png');
for (const face of ['regular', 'semibold', 'bold']) {
  copy(path.join(playerRoot, 'android/app/src/main/res/font/inter_' + face + '.ttf'), 'assets/fonts/inter_' + face + '.ttf');
}
for (const relative of Object.keys(outputs).filter((file) => file.endsWith('.js'))) {
  acorn.parse(fs.readFileSync(path.join(payload, relative), 'utf8'), { ecmaVersion: 5 });
}
for (const [relative, expected] of Object.entries(inputs)) {
  if (hashFile(path.resolve(repoRoot, relative)) !== expected) throw new Error('Input changed during staging: ' + relative);
}
if (hashFile(coreFile) !== proof.jsSha256 || hashFile(proofFile) !== proofHash) throw new Error('Canonical core or its proof changed during staging.');
const manifest = {
  status: options.status || 'samsung_web_payload_staged',
  target: options.target || 'Samsung Tizen 3.0 / Chromium M47',
  payload,
  canonicalReuseProof: path.join(core, 'reuse-proof.json'),
  canonicalReuseProofSha256: proofHash,
  javascriptEs5Syntax: true,
  legacyCssGate: true,
  inputHashes: inputs,
  payloadHashes: outputs,
  sourceOrRootDependenciesChanged: false,
  physicalTvTested: false,
  samsungSigned: false,
};
fs.writeFileSync(path.join(output, 'latest-build.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(JSON.stringify({ status: manifest.status, payload, files: Object.keys(outputs).length }));
return manifest;
}

module.exports = build;
if (require.main === module) build();
