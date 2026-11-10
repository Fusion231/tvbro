'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

test('packaged catalogue exports retain models without exceeding a constrained heap', { timeout: 180000 }, () => {
  const build = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../output/samsung-web/latest-build.json'), 'utf8'));
  const result = spawnSync(process.execPath, [path.resolve(__dirname, '../core_builder/test_catalog_memory.cjs'), build.payload],
    { encoding: 'utf8', timeout: 170000, maxBuffer: 1024 * 1024 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
});
