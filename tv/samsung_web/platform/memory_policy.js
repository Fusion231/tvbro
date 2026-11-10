(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroSamsungMemoryPolicy = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';

  options = options || {};
  var environment = options.environment || (typeof window !== 'undefined' ? window : {});
  var mib = 1024 * 1024;
  var fallback = 32 * mib;
  var pressure = false;
  var listener = null;
  var last = { maximumEpgBytes: fallback, verified: false, reason: 'unavailable' };
  var system = environment.tizen && environment.tizen.systeminfo;

  function bytes(value) {
    return typeof value === 'number' && isFinite(value) && value >= 0 &&
      Math.floor(value) === value && value <= 9007199254740991 ? value : null;
  }
  function result(reason, usage, limit, available) {
    // XHR bytes are copied through a binary string, base64, JSON, a worker
    // message and Dart decoded/parser data. Reserve eight times its size plus
    // 64 MiB for player/UI growth. System RAM is never an app limit.
    var maximum = fallback;
    if (reason === 'verified') {
      [48, 64].forEach(function (size) {
        var required = (size * 8 + 64) * mib;
        if (limit - usage >= required && available >= required + 128 * mib) maximum = size * mib;
      });
      if (maximum === fallback) reason = 'insufficient-headroom';
    }
    last = { maximumEpgBytes: maximum, verified: reason === 'verified', reason: reason };
    if (usage !== undefined) last.appUsageBytes = usage;
    if (limit !== undefined) last.appLimitBytes = limit;
    if (available !== undefined) last.systemAvailableBytes = available;
    return snapshot();
  }
  function snapshot() {
    var copy = {};
    Object.keys(last).forEach(function (key) { copy[key] = last[key]; });
    return copy;
  }
  function sample() {
    if (pressure) return result('memory-pressure');
    // PMS is public since Tizen 10.0 and reports the calling application's
    // RSS + swap + GEM + GPU and its actual allowed limit, in KiB. Earlier
    // TVs only expose system memory; that cannot justify a larger guide.
    var pms = environment.webapis && environment.webapis.pms;
    if (!pms || typeof pms.getVersion !== 'function' || typeof pms.getWebAppMemoryUsage !== 'function' ||
        typeof pms.getWebAppMemoryLimit !== 'function' || !system ||
        typeof system.getAvailableMemory !== 'function' || typeof system.getTotalMemory !== 'function') return result('unavailable');
    try {
      if (!/^\d+(?:\.\d+)*$/.test(String(pms.getVersion()))) return result('invalid-reading');
      var usageKb = bytes(pms.getWebAppMemoryUsage()), limitKb = bytes(pms.getWebAppMemoryLimit());
      var total = bytes(system.getTotalMemory()), available = bytes(system.getAvailableMemory());
      if (usageKb === null || limitKb === null || total === null || available === null ||
          usageKb === 0 || limitKb === 0 || usageKb >= limitKb || available > total || total < fallback ||
          limitKb > Math.floor(total / 1024)) return result('invalid-reading');
      return result('verified', usageKb * 1024, limitKb * 1024, available);
    } catch (_) { return result('unavailable'); }
  }
  if (system && typeof system.addPropertyValueChangeListener === 'function') {
    try {
      listener = system.addPropertyValueChangeListener('MEMORY', function (memory) {
        if (memory && memory.status === 'WARNING') pressure = true;
        else if (memory && memory.status === 'NORMAL') pressure = false;
        if (pressure) result('memory-pressure');
      });
    } catch (_) { /* Older firmware still uses the per-operation memory sample. */ }
  }
  return {
    sample: sample,
    getState: snapshot,
    dispose: function () {
      if (listener !== null && system && typeof system.removePropertyValueChangeListener === 'function') {
        try { system.removePropertyValueChangeListener(listener); } catch (_) {}
      }
      listener = null;
    }
  };
}));
