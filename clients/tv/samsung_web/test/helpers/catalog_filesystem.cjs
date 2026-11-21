'use strict';
const assert = require('node:assert/strict');
const create = require('../../platform/catalog_store.js').create;

// Only the Tizen filesystem boundary is synthetic; exercise the actual store.
function filesystem() {
  const files = new Map(); let failure = null;
  function makeFile(name, raw, size = Buffer.byteLength(raw)) {
    return {name, raw, isDirectory: false, get fileSize() { return size; },
      readAsText(ok) { queueMicrotask(() => ok(raw)); },
      openStream(mode, ok) {
        assert.equal(mode, 'r'); let position = 0; const bytes = new TextEncoder().encode(raw);
        queueMicrotask(() => ok({get bytesAvailable() { return bytes.length-position; },
          get eof() { return position>=bytes.length; },
          readBytes(count) {const value=bytes.slice(position,position+count);position+=value.length;return Array.from(value);},
          close() {}}));
      }};
  }
  function missing() { const error = Error('Missing file'); error.name = 'NotFoundError'; throw error; }
  const directory = {
    isDirectory: true, fullPath: 'wgt-private/tvbro_catalog_v1',
    resolve(name) { return files.get(name) || missing(); },
    listFiles(ok) { queueMicrotask(() => ok([...files.values()])); },
    createFile(name) {
      const file = {name, raw: '', isDirectory: false,
        get fileSize() { return Buffer.byteLength(this.raw); },
        readAsText(ok) { queueMicrotask(() => ok(file.raw)); },
        openStream(mode, ok) { let position=0; queueMicrotask(() => ok({
          get bytesAvailable() { return new TextEncoder().encode(file.raw).length-position; },
          get eof() { return position>=new TextEncoder().encode(file.raw).length; },
          readBytes(count) {const value=new TextEncoder().encode(file.raw).slice(position,position+count);position+=value.length;return Array.from(value);},
          writeBytes(bytes) { if (failure && failure(name)) throw Error('Disk full'); file.raw += new TextDecoder().decode(new Uint8Array(bytes)); },
          close() {}
        })); }
      };
      files.set(name, file); return file;
    },
    deleteFile(path, ok) { files.delete(path.split('/').pop()); queueMicrotask(ok); }
  };
  const environment = {Blob, TextEncoder, TextDecoder, setTimeout, tizen: {filesystem: {
    resolve(path, ok) { assert.equal(path, 'wgt-private'); queueMicrotask(() => ok({resolve: () => directory})); }
  }}};
  return {files, environment, fail(predicate) { failure = predicate; },
    seedGeneration(key, token, raw, size) {
      const name=key+'.'+token+'.json', marker='v1\n'+raw.length;
      files.set(name,makeFile(name,raw,size));files.set(name+'.ok',makeFile(name+'.ok',marker));
    }, restart() { return create({environment}); }};
}

module.exports = {filesystem};
