'use strict';

var SERVICE_ID = 'online.tvbro.webos.epg';
var APP_ID = 'online.tvbro.webos';
var STORE_DIRECTORY = '/media/internal/online.tvbro.webos.epg';

function responseForError(error) {
  var result = {returnValue:false, errorKind:error && error.kind || 'storage'};
  if (error && typeof error.status === 'number' && error.status >= 100 && error.status <= 599) {
    result.status = error.status;
  }
  if (error && typeof error.retryAfter === 'string') result.retryAfter = error.retryAfter;
  return result;
}

function start(Service, store, metadataHttp) {
  var service = new Service(SERVICE_ID);
  var downloads = Object.create(null);
  var metadataJobs = Object.create(null);
  metadataHttp = metadataHttp || require('./metadata_http').create();

  function allowed(message) {
    return !!message && message.sender === APP_ID;
  }
  function rejectCaller(message) {
    message.respond({returnValue:false, errorKind:'invalid'});
  }
  function register(method, callback, cancel) {
    return service.register(method, callback, cancel);
  }
  function successResponse(value, flatten) {
    if (flatten && value && typeof value === 'object' && !Array.isArray(value)) {
      var result = {returnValue:true};
      Object.keys(value).forEach(function (key) { result[key] = value[key]; });
      return result;
    }
    if (typeof value === 'undefined') return {returnValue:true};
    return {returnValue:true, value:value};
  }
  function run(message, operation, flatten) {
    var pending;
    try { pending = operation(); }
    catch (error) { message.respond(responseForError(error)); return; }
    Promise.resolve(pending).then(function (value) {
      message.respond(successResponse(value, flatten));
    }, function (error) {
      message.respond(responseForError(error));
    });
  }

  register('available', function (message) {
    if (!allowed(message)) { rejectCaller(message); return; }
    message.respond({returnValue:true, available:store.available()});
  });
  register('download', function (message) {
    if (!allowed(message)) { rejectCaller(message); return; }
    if (message.isSubscription !== true || typeof message.uniqueToken !== 'string' ||
        message.uniqueToken.length < 1 || message.uniqueToken.length > 128) {
      message.respond({returnValue:false, errorKind:'invalid'}); return;
    }
    var id = message.uniqueToken;
    if (downloads[id]) { message.respond({returnValue:false, errorKind:'invalid'}); return; }
    downloads[id] = true;
    var payload = message.payload || {}, pending;
    try { pending = store.download(payload, payload.key, id); }
    catch (error) { delete downloads[id]; message.respond(responseForError(error)); return; }
    Promise.resolve(pending).then(function (value) {
      if (!downloads[id]) return;
      delete downloads[id]; message.respond(successResponse(value, true));
    }, function (error) {
      if (!downloads[id]) return;
      delete downloads[id]; message.respond(responseForError(error));
    });
  }, function (message) {
    if (!allowed(message) || typeof message.uniqueToken !== 'string') return;
    if (downloads[message.uniqueToken]) {
      delete downloads[message.uniqueToken];
      store.cancel(message.uniqueToken);
    }
  });
  register('query', function (message) {
    if (!allowed(message)) { rejectCaller(message); return; }
    run(message, function () { return store.query(message.payload); }, true);
  });
  register('requestMetadata', function (message) {
    if (!allowed(message)) { rejectCaller(message); return; }
    if (message.isSubscription !== true || typeof message.uniqueToken !== 'string' ||
        message.uniqueToken.length < 1 || message.uniqueToken.length > 128 ||
        metadataJobs[message.uniqueToken]) {
      message.respond({returnValue:false, errorKind:'invalid'}); return;
    }
    var id = message.uniqueToken, operation;
    try { operation = metadataHttp.request(message.payload); }
    catch (error) { message.respond(responseForError(error)); return; }
    if (!operation || !operation.promise || typeof operation.cancel !== 'function') {
      message.respond({returnValue:false, errorKind:'invalid'}); return;
    }
    metadataJobs[id] = operation;
    Promise.resolve(operation.promise).then(function (value) {
      if (metadataJobs[id] !== operation) return;
      delete metadataJobs[id]; message.respond(successResponse(value, true));
    }, function (error) {
      if (metadataJobs[id] !== operation) return;
      delete metadataJobs[id]; message.respond(responseForError(error));
    });
  }, function (message) {
    if (!allowed(message) || typeof message.uniqueToken !== 'string') return;
    var operation = metadataJobs[message.uniqueToken];
    if (!operation) return;
    delete metadataJobs[message.uniqueToken];
    operation.cancel();
  });
  register('abort', function (message) {
    if (!allowed(message)) { rejectCaller(message); return; }
    run(message, function () { return store.abort(); }, false);
  });
  return service;
}

module.exports = {start:start, responseForError:responseForError,
  serviceId:SERVICE_ID, appId:APP_ID, storeDirectory:STORE_DIRECTORY};

if (require.main === module) {
  var Service = require('webos-service');
  start(Service, require('./store').create({directory:STORE_DIRECTORY}));
}
