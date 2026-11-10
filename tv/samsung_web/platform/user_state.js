(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroSamsungUserState = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';

  options = options || {};
  var store = options.store;
  var writeTail = Promise.resolve();

  // These names match LocalProfileStore's FlutterSecureStorage keys. Values
  // remain opaque strings here: the canonical Dart domain owns JSON schemas,
  // profile rules, PIN verification, favorites, resume, and history policy.
  var keys = {
    localProfiles: 'local_profiles_v1',
    activeLocalProfileId: 'active_local_profile_id',
    cloudProfileSnapshots: 'cloud_profile_snapshots_v1',
    profilePickerStartup: 'profile_picker_startup',
    cloudProfilePins: 'cloud_profile_pins_v1',
    profileStateOwnerless: 'profile_state_ownerless',
    parentalControls: 'tvbro_parental_controls_v1'
  };

  function makeError(name, message) {
    var error = new Error(message);
    error.name = name;
    return error;
  }

  function requireStore() {
    if (!store || typeof store.readUserState !== 'function' ||
        typeof store.writeUserState !== 'function') {
      throw makeError('NotSupportedError', 'Samsung KeyManager user-state storage is unavailable.');
    }
    return store;
  }

  function validateKey(key) {
    if (typeof key !== 'string' || key.length === 0) {
      throw makeError('TypeError', 'User-state key must be a non-empty string.');
    }
  }

  function validateRecord(state) {
    if (!state || Object.prototype.toString.call(state) !== '[object Object]' ||
        (Object.getPrototypeOf(state) !== Object.prototype && Object.getPrototypeOf(state) !== null)) {
      throw makeError('TypeError', 'User state must be a string-keyed object.');
    }
    Object.keys(state).forEach(function (key) {
      validateKey(key);
      if (typeof state[key] !== 'string') {
        throw makeError('TypeError', 'User-state values must be strings.');
      }
    });
  }

  function copy(state) {
    validateRecord(state);
    var result = {};
    Object.keys(state).forEach(function (key) {
      Object.defineProperty(result, key, {
        value:state[key], enumerable:true, configurable:true, writable:true
      });
    });
    return result;
  }

  function sameRecord(left, right) {
    var leftKeys = Object.keys(left);
    var rightKeys = Object.keys(right);
    if (leftKeys.length !== rightKeys.length) return false;
    for (var i = 0; i < leftKeys.length; i += 1) {
      var key = leftKeys[i];
      if (!Object.prototype.hasOwnProperty.call(right, key) || left[key] !== right[key]) return false;
    }
    return true;
  }

  function put(state, key, value) {
    Object.defineProperty(state, key, {
      value:value, enumerable:true, configurable:true, writable:true
    });
  }

  function persistIfChanged(previous, next) {
    if (sameRecord(previous, next)) return Promise.resolve(copy(next));
    return requireStore().writeUserState(next).then(function () { return copy(next); });
  }

  function read() {
    return copy(requireStore().readUserState());
  }

  function enqueue(nextState) {
    var snapshot;
    try { snapshot = copy(nextState); }
    catch (error) { return Promise.reject(error); }
    var result = writeTail.then(function () {
      var previous = read();
      return persistIfChanged(previous, snapshot);
    });
    writeTail = result.then(function () {}, function () {});
    return result;
  }

  function write(state) {
    return enqueue(state);
  }

  function update(mutator) {
    if (typeof mutator !== 'function') {
      return Promise.reject(makeError('TypeError', 'User-state update requires a function.'));
    }
    var result = writeTail.then(function () {
      var previous = read();
      var next = copy(previous);
      var returned = mutator(next);
      if (returned !== undefined) next = returned;
      next = copy(next);
      return persistIfChanged(previous, next);
    });
    writeTail = result.then(function () {}, function () {});
    return result;
  }

  function get(key) {
    validateKey(key);
    var state = read();
    return Object.prototype.hasOwnProperty.call(state, key) ? state[key] : null;
  }

  function set(key, value) {
    try { validateKey(key); }
    catch (error) { return Promise.reject(error); }
    if (value !== null && typeof value !== 'string') {
      return Promise.reject(makeError('TypeError', 'User-state values must be strings or null to remove a key.'));
    }
    var result = writeTail.then(function () {
      var previous = read();
      var next = copy(previous);
      if (value === null) delete next[key];
      else put(next, key, value);
      return persistIfChanged(previous, next);
    });
    writeTail = result.then(function () {}, function () {});
    return result;
  }

  function remove(key) {
    return set(key, null);
  }

  requireStore();
  return {
    keys: keys,
    read: read,
    write: write,
    update: update,
    get: get,
    set: set,
    remove: remove
  };
}));
