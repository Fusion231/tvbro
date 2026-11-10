(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroWebOSMemoryPolicy = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function () {
  'use strict';
  // Public webOS TV APIs do not expose the app's memory limit. OSE's
  // memorymanager is not a supported TV API; keep the existing safe baseline.
  function sample() { return { maximumEpgBytes: 32 * 1024 * 1024, verified: false, reason: 'unavailable' }; }
  return { sample: sample, getState: sample, dispose: function () {} };
}));
