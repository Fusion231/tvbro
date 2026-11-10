/* Browser QA only. Never copied into the Samsung application package.
 * Synthetic SDK-shape callbacks verify wiring, not native video or TV storage. */
(function () {
  'use strict';
  var data = Object.create(null);
  var state = 'NONE';
  var listener = {};
  var calls = [];
  function notFound() { var error = new Error('Missing synthetic alias'); error.name = 'NotFoundError'; throw error; }
  window.__samsungFixture = { calls: calls, data: data };
  window.tizen = {
    keymanager: {
      getData: function (alias) { return Object.prototype.hasOwnProperty.call(data, alias.name) ? data[alias.name] : notFound(); },
      getDataAliasList: function () { return Object.keys(data).map(function (name) { return { name: name, packageId: 'TVBroWebTV' }; }); },
      saveData: function (name, raw, password, success, failure) {
        calls.push(['keymanager.save', name]);
        window.setTimeout(function () {
          if (Object.prototype.hasOwnProperty.call(data, name)) {
            var error = new Error('Synthetic KeyManager alias already exists'); error.name = 'UnknownError';
            calls.push(['keymanager.duplicate', name]); if (failure) failure(error); else throw error; return;
          }
          data[name] = raw; success();
        }, 0);
      },
      removeData: function (alias) { delete data[alias.name]; }
    },
    tvinputdevice: {
      getSupportedKeys: function () { return []; },
      registerKey: function (name) { calls.push(['registerKey', name]); }
    },
    application: { getCurrentApplication: function () { return { appInfo: { packageId: 'TVBroWebTV' }, exit: function () { calls.push(['exit']); } }; } }
  };
  window.webapis = { avplay: {
    open: function (url) { if (state !== 'NONE') throw new Error('Previous native player is still open'); calls.push(['open', url]); state = 'IDLE'; },
    setListener: function (value) { listener = value; },
    setDisplayRect: function () { calls.push(['rect'].concat(Array.prototype.slice.call(arguments))); },
    setDisplayMethod: function () {},
    setStreamingProperty: function (name, value) { calls.push(['header', name, value]); },
    setBufferingParam: function (option, unit, amount) {
      if (state !== 'IDLE' || unit !== 'PLAYER_BUFFER_SIZE_IN_SECOND' || amount < 4) throw new Error('Invalid buffer setup');
      calls.push(['buffer', option, unit, amount]);
    },
    prepareAsync: function (success) {
      if (state !== 'IDLE') throw new Error('Prepare requires IDLE');
      calls.push(['prepare']);
      if (listener.onbufferingstart) listener.onbufferingstart();
      window.setTimeout(function () {
        state = 'READY';
        if (listener.onbufferingcomplete) listener.onbufferingcomplete();
        success();
      }, 0);
    },
    play: function () {
      if (state !== 'READY' && state !== 'PAUSED') throw new Error('Invalid play state');
      state = 'PLAYING'; calls.push(['play']);
      window.setTimeout(function () {
        if (state === 'PLAYING' && listener.oncurrentplaytime) listener.oncurrentplaytime(0);
      }, 0);
    },
    pause: function () { state = 'PAUSED'; calls.push(['pause']); },
    stop: function () { state = 'IDLE'; calls.push(['stop']); },
    close: function () { state = 'NONE'; calls.push(['close']); },
    getState: function () { return state; },
    getCurrentTime: function () { return 0; },
    getDuration: function () { return 600000; },
    seekTo: function (ms, success) { calls.push(['seek', ms]); window.setTimeout(success, 0); }
  } };
}());
