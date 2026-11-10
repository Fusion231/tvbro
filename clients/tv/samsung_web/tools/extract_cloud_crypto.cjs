'use strict';

const fs = require('node:fs');
const path = require('node:path');
const parser = require('@babel/parser');
const traverse = require('@babel/traverse').default;

const selectedNames = new Set([
  'subtle', 'ENVELOPE_VERSION', 'ENVELOPE_ALG', 'HKDF_NAME', 'CloudCryptoError',
  '_te', '_td', 'utf8Encode', 'utf8Decode', 'b64Encode', 'b64Decode', 'randomBytes',
  'canonicalJson', 'sourceSecretAad', 'metadataSecretAad', 'deviceWrapAad',
  'hkdfSha256', 'aesGcmEncrypt', 'aesGcmDecrypt', '_asBytes', '_requireInt',
  '_requireString', '_checkHeader', 'encryptSecretEnvelope', 'decryptSecretEnvelope',
  'decodeDeviceWrap'
]);

const exportedNames = [
  'CloudCryptoError', 'utf8Encode', 'utf8Decode', 'b64Encode', 'b64Decode',
  'randomBytes', 'canonicalJson', 'sourceSecretAad', 'metadataSecretAad',
  'deviceWrapAad', 'encryptSecretEnvelope', 'decryptSecretEnvelope', 'decodeDeviceWrap'
];

function parseExpression(source) {
  return parser.parseExpression(source, {sourceType:'script'});
}

function declaredNames(declaration) {
  if (declaration.type === 'FunctionDeclaration' || declaration.type === 'ClassDeclaration') {
    return declaration.id ? [declaration.id.name] : [];
  }
  if (declaration.type === 'VariableDeclaration') {
    return declaration.declarations.map((item) => item.id && item.id.type === 'Identifier' ? item.id.name : null).filter(Boolean);
  }
  return [];
}

module.exports = function extractPanelCloudCrypto(babel, presetEnv, project, payload, options = {}) {
  if (!babel || typeof babel.transformFromAstSync !== 'function' || !presetEnv || !project || !payload) {
    throw new TypeError('Expected Babel, preset-env, project path, and payload path.');
  }
  const sourcePath = path.resolve(project, '../../../panel/src/crypto.js');
  const source = fs.readFileSync(sourcePath, 'utf8');
  const parsed = parser.parse(source, {sourceType:'module'});
  const selected = [];
  const found = new Set();

  parsed.program.body.forEach((statement) => {
    const declaration = statement.type === 'ExportNamedDeclaration' ? statement.declaration : statement;
    if (!declaration) return;
    const names = declaredNames(declaration);
    if (!names.some((name) => selectedNames.has(name))) return;
    selected.push(declaration);
    names.forEach((name) => { if (selectedNames.has(name)) found.add(name); });
  });

  const missing = Array.from(selectedNames).filter((name) => !found.has(name));
  if (missing.length) throw new Error('Panel crypto source is missing expected declarations: ' + missing.join(', '));

  const selectedProgram = {
    type:'File',
    program:{type:'Program', sourceType:'script', body:selected, directives:[]}
  };
  let nativeEcdhCalls = 0;
  traverse(selectedProgram, {
    VariableDeclarator(p) {
      const name = p.node.id && p.node.id.type === 'Identifier' ? p.node.id.name : '';
      if (name === 'subtle') {
        p.node.init = parseExpression('root.crypto && (root.crypto.subtle || root.crypto.webkitSubtle)');
      } else if (name === '_te') {
        p.node.init = parseExpression("({encode:function(value){var Encoder=root.TextEncoder;if(typeof Encoder!=='function')throw new CloudCryptoError('TextEncoder is unavailable');return new Encoder().encode(value);}})");
      } else if (name === '_td') {
        p.node.init = parseExpression("({decode:function(bytes){var Decoder=root.TextDecoder;if(typeof Decoder!=='function')throw new CloudCryptoError('TextDecoder is unavailable');return new Decoder('utf-8',{fatal:false}).decode(bytes);}})");
      }
    },
    MemberExpression(p) {
      const node = p.node;
      if (node.object && node.object.type === 'Identifier' && node.object.name === 'globalThis' &&
          node.property && node.property.type === 'Identifier' && node.property.name === 'crypto') {
        p.replaceWith(parseExpression('root.crypto'));
      }
    },
    FunctionDeclaration(p) {
      if (!p.node.id || p.node.id.name !== 'decodeDeviceWrap') return;
      p.node.params.push({type:'Identifier', name:'nativeEcdhSharedX'});
      p.traverse({
        CallExpression(callPath) {
          if (callPath.node.callee.type === 'Identifier' && callPath.node.callee.name === 'ecdhSharedX') {
            callPath.node.callee = {type:'Identifier', name:'nativeEcdhSharedX'};
            callPath.replaceWith({type:'AwaitExpression', argument:callPath.node});
            nativeEcdhCalls += 1;
          }
        }
      });
    }
  });
  if (nativeEcdhCalls !== 1) throw new Error('Expected exactly one panel decodeDeviceWrap ECDH call.');

  const transformed = babel.transformFromAstSync(selectedProgram, source, {
    babelrc:false,
    configFile:false,
    sourceType:'script',
    comments:false,
    compact:true,
    presets:[[presetEnv, {
      targets:{chrome:options.chrome || '47'},
      forceAllTransforms:true,
      modules:false,
      useBuiltIns:false
    }]]
  });
  const exportMap = '{' + exportedNames.map((name) => name + ':' + name).join(',') + '}';
  const output = '(function(root){\'use strict\';' + transformed.code + ';root.TVBroPanelCrypto=' + exportMap + ';})(typeof window!==\'undefined\'?window:(typeof global!==\'undefined\'?global:this));\n';
  if (/\bBigInt\b|(?:^|[^\w])\d+n\b/.test(output)) throw new Error('Panel P-256 BigInt code leaked into the Tizen crypto payload.');
  const target = path.join(payload, 'cloud-crypto.js');
  fs.mkdirSync(path.dirname(target), {recursive:true});
  fs.writeFileSync(target, output);
  return {path:target, sourcePath, exportedNames:exportedNames.slice()};
};
