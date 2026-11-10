(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroSamsungSecureStore = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';

  options = options || {};

  var environment = options.environment || (typeof window !== 'undefined' ? window : null);
  var tizen = options.tizen || (environment && environment.tizen);
  var alias = 'tvbro_sources_v1';
  var userStateAlias = 'tvbro_user_state_v1';
  var maxSafeInteger = 9007199254740991;
  var writeTail = Promise.resolve();
  var hasCommittedSnapshot = false;
  var committedSnapshot = null;
  var hasCommittedUserState = false;
  var committedUserState = null;

  function makeError(name, message) {
    var error = new Error(message);
    error.name = name;
    return error;
  }

  function isNotFound(error) {
    return !!error && (error.name === 'NotFoundError' || error.errorType === 'NotFoundError');
  }

  function keyManager() {
    if (tizen && tizen.keymanager) return tizen.keymanager;
    if (environment && environment.tizen && environment.tizen.keymanager) {
      tizen = environment.tizen;
      return tizen.keymanager;
    }
    throw makeError('NotSupportedError', 'Samsung Tizen KeyManager API is unavailable.');
  }

  function requiredMethod(manager, name) {
    if (!manager || typeof manager[name] !== 'function') {
      throw makeError('NotSupportedError', 'Samsung Tizen KeyManager does not provide ' + name + '().');
    }
    return manager[name];
  }

  function isPlainObject(value) {
    if (!value || Object.prototype.toString.call(value) !== '[object Object]') return false;
    var prototype = Object.getPrototypeOf(value);
    return prototype === Object.prototype || prototype === null;
  }

  function assertJsonValue(value, ancestors) {
    if (value === null || typeof value === 'string' || typeof value === 'boolean') return;
    if (typeof value === 'number') {
      if (!isFinite(value)) throw makeError('TypeError', 'Source data contains a non-finite number.');
      return;
    }
    if (typeof value !== 'object') throw makeError('TypeError', 'Source data must contain only JSON values.');
    if (ancestors.indexOf(value) !== -1) throw makeError('TypeError', 'Source data cannot contain circular references.');

    ancestors.push(value);
    if (Object.prototype.toString.call(value) === '[object Array]') {
      for (var i = 0; i < value.length; i += 1) {
        if (!Object.prototype.hasOwnProperty.call(value, i)) {
          throw makeError('TypeError', 'Source data cannot contain sparse arrays.');
        }
        assertJsonValue(value[i], ancestors);
      }
    } else {
      if (!isPlainObject(value)) throw makeError('TypeError', 'Source data objects must be plain JSON objects.');
      Object.keys(value).forEach(function (key) {
        assertJsonValue(value[key], ancestors);
      });
    }
    ancestors.pop();
  }

  function validateSourceList(sources) {
    if (Object.prototype.toString.call(sources) !== '[object Array]') {
      throw makeError('TypeError', 'Samsung source storage expects an array.');
    }
    sources.forEach(function (source) {
      if (!isPlainObject(source) || typeof source.id !== 'string' ||
          typeof source.kind !== 'string' || typeof source.label !== 'string' ||
          !isPlainObject(source.fields)) {
        throw makeError('TypeError', 'A saved source is not in the canonical source format.');
      }
      Object.keys(source.fields).forEach(function (key) {
        if (typeof source.fields[key] !== 'string') {
          throw makeError('TypeError', 'Saved source fields must contain strings.');
        }
      });
      if (source.settings !== undefined && !isPlainObject(source.settings)) {
        throw makeError('TypeError', 'Saved source settings must be a JSON object.');
      }
    });
    assertJsonValue(sources, []);
  }

  function encodeSnapshot(sources) {
    validateSourceList(sources);
    var encoded;
    try { encoded = JSON.stringify(sources); }
    catch (_) { throw makeError('TypeError', 'Source data could not be encoded as JSON.'); }
    if (typeof encoded !== 'string') throw makeError('TypeError', 'Source data could not be encoded as JSON.');
    return encoded;
  }

  // The canonical FlutterSecureStorage contract stores each domain value as a
  // string (often JSON). Keep those exact key/value strings inside one
  // KeyManager snapshot so each successful write commits atomically.
  function validateUserState(state) {
    if (!isPlainObject(state)) {
      throw makeError('TypeError', 'Samsung user state must be a string-keyed object.');
    }
    Object.keys(state).forEach(function (key) {
      if (!key || typeof state[key] !== 'string') {
        throw makeError('TypeError', 'Samsung user state keys must be non-empty and values must be strings.');
      }
    });
  }

  function copyUserState(state) {
    validateUserState(state);
    var result = {};
    Object.keys(state).forEach(function (key) {
      Object.defineProperty(result, key, {
        value:state[key], enumerable:true, configurable:true, writable:true
      });
    });
    return result;
  }

  function stringifyUserState(state) {
    var encoded;
    try { encoded = JSON.stringify(state); }
    catch (_) { throw makeError('TypeError', 'Samsung user state could not be encoded as JSON.'); }
    if (typeof encoded !== 'string') throw makeError('TypeError', 'Samsung user state could not be encoded as JSON.');
    return encoded;
  }

  function decodeUserState(raw) {
    if (typeof raw !== 'string') throw makeError('SyntaxError', 'Stored Samsung user state is malformed.');
    var parsed;
    try { parsed = JSON.parse(raw); }
    catch (_) { throw makeError('SyntaxError', 'Stored Samsung user state is malformed.'); }
    try { validateUserState(parsed); }
    catch (_) { throw makeError('SyntaxError', 'Stored Samsung user state is malformed.'); }
    return parsed;
  }

  function decodeSnapshot(raw) {
    if (typeof raw !== 'string') throw makeError('SyntaxError', 'Stored Samsung source data is malformed.');
    var parsed;
    try { parsed = JSON.parse(raw); }
    catch (_) { throw makeError('SyntaxError', 'Stored Samsung source data is malformed.'); }
    try { validateSourceList(parsed); }
    catch (_) { throw makeError('SyntaxError', 'Stored Samsung source data is malformed.'); }
    return JSON.stringify(parsed);
  }

  function copyCommittedSnapshot() {
    return JSON.parse(committedSnapshot);
  }

  function copyCommittedUserState() {
    return copyUserState(committedUserState);
  }

  function currentPackageId() {
    var candidates = [tizen, environment && environment.tizen];
    for (var i = 0; i < candidates.length; i += 1) {
      var candidate = candidates[i];
      if (!candidate || (i > 0 && candidate === candidates[0])) continue;
      try {
        var current = candidate.application &&
          typeof candidate.application.getCurrentApplication === 'function' &&
          candidate.application.getCurrentApplication();
        var appInfo = current && current.appInfo;
        if (appInfo && typeof appInfo.packageId === 'string' && appInfo.packageId) {
          return appInfo.packageId;
        }
      } catch (_) {}
      try {
        var packageInfo = candidate.package &&
          typeof candidate.package.getPackageInfo === 'function' &&
          candidate.package.getPackageInfo();
        if (packageInfo && typeof packageInfo.id === 'string' && packageInfo.id) {
          return packageInfo.id;
        }
      } catch (_) {}
    }
    return null;
  }

  function isSafeGeneration(value) {
    return typeof value === 'number' && value >= 1 && value <= maxSafeInteger &&
      Math.floor(value) === value;
  }

  function generationPattern(base) {
    return new RegExp('^' + base.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '_g([1-9][0-9]*)$');
  }

  function aliasMetadata(manager, base) {
    var list = requiredMethod(manager, 'getDataAliasList').call(manager);
    if (Object.prototype.toString.call(list) !== '[object Array]') {
      throw makeError('UnknownError', 'Samsung KeyManager returned an invalid alias list.');
    }
    var packageId = currentPackageId();
    var pattern = generationPattern(base);
    var prefix = base + '_g';
    var generations = [];
    var hasLegacy = false;
    var relevantWithoutIdentity = false;

    list.forEach(function (entry) {
      if (!entry || typeof entry.name !== 'string') return;
      var name = entry.name;
      var isLegacy = name === base;
      var isGenerationNamespace = name.indexOf(prefix) === 0;
      if (!isLegacy && !isGenerationNamespace) return;

      if (!packageId) {
        relevantWithoutIdentity = true;
        return;
      }
      if (typeof entry.packageId !== 'string' || !entry.packageId) {
        throw makeError('SecurityError', 'Samsung KeyManager alias ownership could not be verified.');
      }
      if (entry.packageId !== packageId) return;

      if (isLegacy) {
        hasLegacy = true;
        return;
      }
      var match = pattern.exec(name);
      if (!match) {
        throw makeError('SyntaxError', 'Stored Samsung KeyManager generation alias is malformed.');
      }
      var generation = Number(match[1]);
      if (!isSafeGeneration(generation) || String(generation) !== match[1]) {
        throw makeError('RangeError', 'Stored Samsung KeyManager generation is outside the safe range.');
      }
      generations.push({ name: name, generation: generation });
    });

    if (!packageId && relevantWithoutIdentity) {
      throw makeError('NotSupportedError', 'Samsung application identity is required to read KeyManager data safely.');
    }

    generations.sort(function (left, right) { return right.generation - left.generation; });
    var unique = [];
    var seen = Object.create(null);
    generations.forEach(function (item) {
      if (seen[item.name]) return;
      seen[item.name] = true;
      unique.push(item);
    });
    return { packageId: packageId, hasLegacy: hasLegacy, generations: unique };
  }

  function readOwnedData(manager, name) {
    try {
      // Omitting packageId asks KeyManager for data owned by this application.
      return requiredMethod(manager, 'getData').call(manager, { name: name });
    } catch (error) {
      if (isNotFound(error)) {
        throw makeError('UnknownError', 'Samsung KeyManager alias list and stored data disagree.');
      }
      throw error;
    }
  }

  function readDomain(base, decode, emptySnapshot) {
    var manager = keyManager();
    var metadata = aliasMetadata(manager, base);
    var raw;
    if (metadata.generations.length) {
      // The newest owned generation is authoritative. A corrupt newest value
      // must not silently roll back to an older snapshot or the legacy alias.
      raw = readOwnedData(manager, metadata.generations[0].name);
      return decode(raw);
    }
    if (metadata.hasLegacy) return decode(readOwnedData(manager, base));
    return emptySnapshot;
  }

  function read() {
    if (hasCommittedSnapshot) return copyCommittedSnapshot();
    committedSnapshot = readDomain(alias, decodeSnapshot, '[]');
    hasCommittedSnapshot = true;
    return copyCommittedSnapshot();
  }

  function readUserState() {
    if (hasCommittedUserState) return copyCommittedUserState();
    committedUserState = readDomain(userStateAlias, decodeUserState, {});
    hasCommittedUserState = true;
    return copyCommittedUserState();
  }

  function saveData(name, raw) {
    return new Promise(function (resolve, reject) {
      var settled = false;
      function success() {
        if (settled) return;
        settled = true;
        resolve();
      }
      function failure(error) {
        if (settled) return;
        settled = true;
        reject(error || makeError('UnknownError', 'Samsung KeyManager could not save source data.'));
      }
      try {
        var manager = keyManager();
        requiredMethod(manager, 'saveData').call(manager, name, raw, null, success, failure);
      }
      catch (error) { failure(error); }
    });
  }

  function serializeWrite(operation) {
    var result = writeTail.then(operation);
    writeTail = result.then(function () {}, function () {});
    return result;
  }

  function cleanupOldGenerations(manager, base) {
    try {
      var metadata = aliasMetadata(manager, base);
      if (metadata.generations.length <= 2 || typeof manager.removeData !== 'function') return;
      metadata.generations.slice(2).forEach(function (item) {
        try { manager.removeData({ name: item.name }); }
        catch (_) {}
      });
    } catch (_) {
      // A committed value must remain successful even if optional cleanup fails.
    }
  }

  function writeDomain(base, snapshot, decode, commit) {
    var manager = keyManager();
    var metadata = aliasMetadata(manager, base);
    if (!metadata.packageId) {
      throw makeError('NotSupportedError', 'Samsung application identity is required to write KeyManager data safely.');
    }
    var highest = metadata.generations.length ? metadata.generations[0].generation : 0;
    if (metadata.generations.length) {
      decode(readOwnedData(manager, metadata.generations[0].name));
    } else if (metadata.hasLegacy) {
      decode(readOwnedData(manager, base));
    }
    if (highest >= maxSafeInteger) {
      throw makeError('RangeError', 'Samsung KeyManager generation counter is exhausted.');
    }
    var nextGeneration = highest + 1;
    if (!isSafeGeneration(nextGeneration)) {
      throw makeError('RangeError', 'Samsung KeyManager generation counter is exhausted.');
    }
    var generationName = base + '_g' + String(nextGeneration);
    return saveData(generationName, snapshot).then(function () {
      commit();
      cleanupOldGenerations(manager, base);
    });
  }

  function write(sources) {
    var snapshot;
    try { snapshot = encodeSnapshot(sources); }
    catch (error) { return Promise.reject(error); }
    return serializeWrite(function () {
      return writeDomain(alias, snapshot, decodeSnapshot, function () {
        committedSnapshot = snapshot;
        hasCommittedSnapshot = true;
      });
    });
  }

  function writeUserState(state) {
    var snapshot, userStateSnapshot;
    try {
      userStateSnapshot = copyUserState(state);
      snapshot = stringifyUserState(userStateSnapshot);
    }
    catch (error) { return Promise.reject(error); }
    return serializeWrite(function () {
      return writeDomain(userStateAlias, snapshot, decodeUserState, function () {
        committedUserState = userStateSnapshot;
        hasCommittedUserState = true;
      });
    });
  }

  function remove() {
    return write([]);
  }

  function removeUserState() {
    return writeUserState({});
  }

  return {
    read: read,
    write: write,
    remove: remove,
    readUserState: readUserState,
    writeUserState: writeUserState,
    removeUserState: removeUserState
  };
}));
