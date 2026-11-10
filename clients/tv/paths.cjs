'use strict';

const path = require('node:path');

const tvRoot = __dirname;
const repoRoot = path.resolve(tvRoot, '../..');
const playerRoot = path.join(repoRoot, 'clients/player');

module.exports = {repoRoot, playerRoot, tvRoot};
