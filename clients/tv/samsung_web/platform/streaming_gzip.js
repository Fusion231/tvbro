(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = {create:factory};
  if (root) root.TVBroGzipCreate = function (maximum) { return factory(maximum, root); };
}(typeof self !== 'undefined' ? self : typeof window !== 'undefined' ? window : this, function (maximum, environment) {
  'use strict';
  environment = environment || (typeof global !== 'undefined' ? global : {});
  var pako = environment.pako || (typeof require === 'function' ? require('pako') : null);
  var inflater = null, total = 0, failure = null, batch = [], batchSize = 0, seen = false, finished = false;
  if (!pako || typeof pako.Inflate !== 'function' || typeof maximum !== 'number' ||
      !isFinite(maximum) || maximum < 1 || maximum > 4294967296 || Math.floor(maximum) !== maximum) failure = 'invalid-gzip';
  function start() {
    inflater = new pako.Inflate({windowBits:31,chunkSize:32768});
    inflater.onData = function (bytes) {
      total += bytes.length; batchSize += bytes.length;
      if (total > maximum) { failure = 'limit'; throw new Error('Decoded guide work limit'); }
      // One KiB of DEFLATE input can expand to about one MiB; never queue a
      // whole inflated block before the Dart stream can apply backpressure.
      if (batchSize > 2 * 1024 * 1024) { failure = 'invalid-gzip'; throw new Error('Invalid gzip batch'); }
      var text = '';
      for (var offset = 0; offset < bytes.length; offset += 8192) text += String.fromCharCode.apply(null, bytes.subarray(offset,offset+8192));
      batch.push(environment.btoa(text));
    };
    inflater.onEnd = function (status) { this.err = status; };
  }
  return function (encoded, last) {
    batch = []; batchSize = 0;
    if (failure) return JSON.stringify({chunks:[],ended:false,error:failure});
    try {
      if (typeof encoded !== 'string' || encoded.length > 1368 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded) ||
          typeof last !== 'boolean' || finished && (encoded.length || !last)) throw new Error('Invalid gzip input');
      var text = environment.atob(encoded), bytes = new Uint8Array(text.length);
      if (bytes.length > 1024) throw new Error('Invalid gzip input size');
      for (var index = 0; index < text.length; index++) bytes[index] = text.charCodeAt(index);
      if (bytes.length) {
        if (!inflater || inflater.ended) start();
        seen = true;
        if (!inflater.push(bytes, false) || inflater.err) throw new Error('Invalid gzip stream');
        if (inflater.ended && inflater.strm.avail_in) throw new Error('Trailing gzip data');
        var header = inflater.header;
        if (header && (header.name && header.name.length > 4096 || header.comment && header.comment.length > 4096)) throw new Error('Oversized gzip header');
      }
      if (last) {
        if (!seen || !inflater.ended || inflater.err) throw new Error('Incomplete gzip stream');
        finished = true;
      }
      var result = JSON.stringify({chunks:batch,ended:!!(inflater && inflater.ended)});
      batch = []; return result;
    } catch (_) {
      failure = failure || 'invalid-gzip'; batch = []; inflater = null;
      return JSON.stringify({chunks:[],ended:false,error:failure});
    }
  };
}));
