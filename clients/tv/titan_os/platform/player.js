/* Titan uses the existing HTML5 media lifecycle; no LG or Samsung SDK is needed. */
(function (root, factory) {
  var shared = typeof module === 'object' && module.exports
    ? require('../../lg_webos/platform/player.js') : root.TVBroLgWebosPlayer;
  var exported = factory(shared);
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroTitanPlayer = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (shared) {
  'use strict';

  return {
    create: function (options) {
      if (!shared || typeof shared.create !== 'function') {
        throw new Error('The shared HTML5 player is unavailable for Titan OS.');
      }
      var settings = {};
      Object.keys(options || {}).forEach(function (key) { settings[key] = options[key]; });
      settings.platformName = 'Titan OS';
      return shared.create(settings);
    }
  };
}));
