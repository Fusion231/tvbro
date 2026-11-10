'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {playerRoot} = require('../../paths.cjs');
const babel = require('@babel/core');
const presetEnv = require('@babel/preset-env');
const acorn = require('acorn');
const extract = require('../tools/extract_cloud_crypto.cjs');

const vectors = JSON.parse(fs.readFileSync(path.join(playerRoot, 'test/fixtures/crypto_vectors.json'), 'utf8'));
const project = path.resolve(__dirname, '..');

function base64Url(bytes) {
  return Buffer.from(bytes).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

test('extracted panel protocol is ES5, excludes BigInt P-256, and preserves the shared E2EE vectors', async (t) => {
  const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tvbro-cloud-crypto-'));
  t.after(() => fs.rmSync(outputDir, {recursive:true, force:true}));
  const result = extract(babel, presetEnv, project, outputDir);
  const source = fs.readFileSync(result.path, 'utf8');
  acorn.parse(source, {ecmaVersion:5, sourceType:'script'});
  assert.equal(/\bBigInt\b|(?:^|[^\w])\d+n\b/.test(source), false);

  const previous = global.TVBroPanelCrypto;
  delete global.TVBroPanelCrypto;
  try {
    require(result.path);
    const panel = global.TVBroPanelCrypto;
    assert.ok(panel);
    const wrapper = vectors.deviceWrap[0];
    const secret = vectors.secretEnvelope[0];
    const ownPublic = Buffer.from(wrapper.devicePublicKey_hex, 'hex');
    const ownPrivate = Buffer.from(wrapper.devicePrivateKey_hex, 'hex');
    const envelope = wrapper.envelope;
    const aad = panel.deviceWrapAad(wrapper.profileId, wrapper.deviceUid, secret.ckVersion);
    let nativeEcdhCalls = 0;
    const key = await panel.decodeDeviceWrap({
      envelope, devicePrivateKey:new Uint8Array(ownPrivate), ckVersion:secret.ckVersion, aad
    }, async (privateBytes, peerBytes) => {
      nativeEcdhCalls += 1;
      assert.deepEqual(Buffer.from(privateBytes), ownPrivate);
      const privateKey = await crypto.webcrypto.subtle.importKey('jwk', {
        kty:'EC', crv:'P-256', x:base64Url(ownPublic.slice(1, 33)), y:base64Url(ownPublic.slice(33, 65)),
        d:base64Url(privateBytes), ext:true, key_ops:['deriveBits']
      }, {name:'ECDH', namedCurve:'P-256'}, false, ['deriveBits']);
      const peerKey = await crypto.webcrypto.subtle.importKey('raw', peerBytes,
        {name:'ECDH', namedCurve:'P-256'}, false, []);
      return new Uint8Array(await crypto.webcrypto.subtle.deriveBits({name:'ECDH', public:peerKey}, privateKey, 256));
    });
    assert.equal(nativeEcdhCalls, 1);
    assert.deepEqual(Buffer.from(key), Buffer.from(wrapper.contentKey_hex, 'hex'));

    const plaintext = await panel.decryptSecretEnvelope({
      envelope:secret.envelope,
      contentKey:Buffer.from(secret.contentKey_hex, 'hex'),
      ckVersion:secret.ckVersion,
      aad:panel.sourceSecretAad(wrapper.profileId, secret.sourceId, secret.ckVersion)
    });
    assert.deepEqual(plaintext, secret.secret);
    await assert.rejects(panel.decryptSecretEnvelope({
      envelope:secret.envelope,
      contentKey:Buffer.from(secret.contentKey_hex, 'hex'),
      ckVersion:secret.ckVersion + 1,
      aad:panel.sourceSecretAad(wrapper.profileId, secret.sourceId, secret.ckVersion)
    }));
  } finally {
    if (previous === undefined) delete global.TVBroPanelCrypto;
    else global.TVBroPanelCrypto = previous;
  }
});
