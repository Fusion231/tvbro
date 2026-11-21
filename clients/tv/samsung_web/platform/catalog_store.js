(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroSamsungCatalogStore = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';

  options = options || {};
  var environment = options.environment || (typeof window !== 'undefined' ? window : null);
  var directoryName = 'tvbro_catalog_v1';
  var maximumFileBytes = 32 * 1024 * 1024;
  var maximumStoreBytes = 64 * 1024 * 1024;
  var maximumPartBytes = 1024 * 1024, maximumParts = 128, maximumManifestBytes = 256 * 1024;
  var partPattern = /^([0-9a-f]{64})\.([0-9]+-[0-9]+)\.part-(0|[1-9][0-9]*)\.json$/;
  var writeTail = Promise.resolve();
  var directoryFlight = null;
  var activeProtectedKeys = Object.create(null), activeProtectionLeases = 0;
  var maximumProtectionLeases = 16;
  var maximumSafeInteger = 9007199254740991;
  var dataPattern = /^([0-9a-f]{64})\.([0-9]+)-([0-9]+)\.json$/;
  var tokenPattern = /^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$/;

  function makeError(name, message) {
    var error = new Error(message);
    error.name = name;
    return error;
  }

  function isNotFound(error) {
    return !!error && (error.name === 'NotFoundError' || error.errorType === 'NotFoundError');
  }

  function validateKey(key) {
    if (typeof key !== 'string' || !/^[0-9a-f]{64}$/.test(key)) {
      throw makeError('TypeError', 'Catalog cache key must be a 64-character lowercase hexadecimal string.');
    }
  }

  function fileSystem() {
    var tizen = environment && environment.tizen;
    if (!tizen || !tizen.filesystem || typeof tizen.filesystem.resolve !== 'function') {
      throw makeError('NotSupportedError', 'Samsung Tizen Filesystem API is unavailable.');
    }
    return tizen.filesystem;
  }

  function resolveLocation(api, location, mode) {
    return new Promise(function (resolve, reject) {
      try {
        api.resolve(location, resolve, reject, mode);
      } catch (error) { reject(error); }
    });
  }

  function getDirectory() {
    if (directoryFlight) return directoryFlight;
    var api;
    try { api = fileSystem(); }
    catch (error) { return Promise.reject(error); }
    directoryFlight = resolveLocation(api, 'wgt-private', 'rw').then(function (rootDirectory) {
      var directory;
      try { directory = rootDirectory.resolve(directoryName); }
      catch (error) {
        if (!isNotFound(error)) throw error;
        rootDirectory.createDirectory(directoryName);
        directory = rootDirectory.resolve(directoryName);
      }
      if (!directory || directory.isDirectory !== true) {
        throw makeError('IOError', 'Samsung catalog cache directory is unavailable.');
      }
      return directory;
    });
    directoryFlight.then(function () {}, function () { directoryFlight = null; });
    return directoryFlight;
  }

  function listFiles(directory) {
    return new Promise(function (resolve, reject) {
      try { directory.listFiles(resolve, reject); }
      catch (error) { reject(error); }
    });
  }

  function readText(file) {
    return streamFor(file, 'r').then(function (stream) {
      return new Promise(function (resolve, reject) {
        var Decoder = environment && environment.TextDecoder;
        if (typeof Decoder !== 'function' || typeof stream.readBytes !== 'function') {
          closeStream(stream);
          reject(makeError('NotSupportedError', 'Samsung binary cache reading is unavailable.'));
          return;
        }
        var decoder, chunks = [], total = 0;
        try { decoder = new Decoder('utf-8', { fatal: true }); }
        catch (error) { closeStream(stream); reject(error); return; }
        function run() {
          try {
            var available = stream.bytesAvailable;
            if (stream.eof === true || available === 0) {
              chunks.push(decoder.decode());
              closeStream(stream); resolve(chunks.join('')); return;
            }
            if (typeof available !== 'number' || !isFinite(available) || available < 0 ||
                Math.floor(available) !== available || total + available > maximumFileBytes) {
              throw makeError('IOError', 'Samsung cache stream exceeded its size limit.');
            }
            var count = Math.min(32768, available), bytes = stream.readBytes(count);
            if (!bytes || bytes.length < 1 || bytes.length > count) {
              throw makeError('IOError', 'Samsung cache binary read was incomplete.');
            }
            total += bytes.length;
            chunks.push(decoder.decode(new Uint8Array(bytes), { stream: true }));
            var schedule = environment && typeof environment.setTimeout === 'function'
              ? function (callback) { environment.setTimeout(callback, 0); }
              : function (callback) { setTimeout(callback, 0); };
            schedule(run);
          } catch (error) { closeStream(stream); reject(error); }
        }
        run();
      });
    });
  }

  function streamFor(file, mode) {
    return new Promise(function (resolve, reject) {
      try { file.openStream(mode, resolve, reject, 'UTF-8'); }
      catch (error) { reject(error); }
    });
  }

  function sizeOf(file) {
    try {
      var size = file && file.fileSize;
      return typeof size === 'number' && isFinite(size) && size >= 0 ? size : null;
    } catch (_) { return null; }
  }

  function parseGeneration(name) {
    var match = dataPattern.exec(name || '');
    if (!match) return null;
    var timestamp = Number(match[2]), counter = Number(match[3]);
    if (!isFinite(timestamp) || !isFinite(counter) || timestamp < 0 || counter < 0 ||
        timestamp > maximumSafeInteger || counter > maximumSafeInteger ||
        Math.floor(timestamp) !== timestamp || Math.floor(counter) !== counter ||
        String(timestamp) !== match[2] || String(counter) !== match[3]) return null;
    return { key: match[1], timestamp: timestamp, counter: counter,
      token: match[2] + '-' + match[3], name: name, marker: name + '.ok' };
  }

  function generationOrder(left, right) {
    if (left.timestamp !== right.timestamp) return right.timestamp - left.timestamp;
    return right.counter - left.counter;
  }

  function allGenerations(files) {
    var generations = [], names = Object.create(null), byName = Object.create(null);
    (files || []).forEach(function (file) {
      if (!file || file.isDirectory || typeof file.name !== 'string') return;
      names[file.name] = file;
      var generation = parseGeneration(file.name);
      var part = partPattern.exec(file.name);
      if (!generation && part) generation = parseGeneration(part[1] + '.' + part[2] + '.json');
      if (!generation) return;
      var entry = byName[generation.name];
      if (!entry) { entry = byName[generation.name] = generation; entry.parts = []; generations.push(entry); }
      if (part) entry.parts.push(file); else entry.dataFile = file;
    });
    generations.forEach(function (generation) {
      generation.markerFile = names[generation.marker] || null;
      generation.dataSize = sizeOf(generation.dataFile);
      generation.size = generation.parts.reduce(function (total, file) {
        var size = sizeOf(file); return total === null || size === null ? null : total + size;
      }, generation.dataSize);
    });
    return { generations: generations, names: names };
  }

  function generationNames(generation) {
    return [generation.name, generation.marker].concat(generation.parts.map(function (file) { return file.name; }));
  }

  function validGenerationSize(generation) {
    return generation.dataSize !== null && generation.dataSize <= maximumFileBytes && generation.size !== null &&
      generation.size <= (generation.parts.length ? maximumStoreBytes : maximumFileBytes);
  }

  function fullPath(directory, name) {
    var base = typeof directory.fullPath === 'string' ? directory.fullPath : 'wgt-private/' + directoryName;
    return base.replace(/\/$/, '') + '/' + name;
  }

  function deleteFile(directory, name) {
    return new Promise(function (resolve) {
      try {
        if (typeof directory.deleteFile !== 'function') { resolve(false); return; }
        directory.deleteFile(fullPath(directory, name), function () { resolve(true); }, function (error) {
          resolve(isNotFound(error));
        });
      } catch (error) { resolve(isNotFound(error)); }
    });
  }

  function removeNames(directory, names) {
    var unique = Object.create(null), tasks = [];
    names.forEach(function (name) {
      if (typeof name !== 'string' || unique[name]) return;
      unique[name] = true;
      tasks.push(deleteFile(directory, name));
    });
    return Promise.all(tasks).then(function (results) {
      return results.every(function (result) { return result; });
    });
  }

  function removeGeneration(directory, generation) {
    return removeNames(directory, generationNames(generation));
  }

  function parseMarker(marker) {
    var match = /^v1\n(0|[1-9][0-9]*)$/.exec(marker || '');
    if (!match) return null;
    var length = Number(match[1]);
    if (!isFinite(length) || length > maximumSafeInteger || Math.floor(length) !== length ||
        String(length) !== match[1]) return null;
    return length;
  }

  function orderedForKey(files, key) {
    return allGenerations(files).generations.filter(function (generation) {
      return generation.key === key;
    }).sort(generationOrder);
  }

  function readNow(key) {
    return getDirectory().then(function (directory) {
      return listFiles(directory).then(function (files) {
        var index = allGenerations(files), candidates = index.generations.filter(function (generation) {
          return generation.key === key;
        }).sort(generationOrder);
        var markerOrphans = Object.keys(index.names).filter(function (name) {
          if (name.slice(0, key.length + 1) !== key + '.' || name.slice(-8) !== '.json.ok') return false;
          return !!parseGeneration(name.slice(0, -3)) && !index.names[name.slice(0, -3)];
        });
        var attempts = 0, position = 0;
        function next() {
          if (position >= candidates.length || attempts >= 2) return Promise.resolve(null);
          var candidate = candidates[position++];
          if (!candidate.markerFile) {
            return removeGeneration(directory, candidate).then(next);
          }
          attempts += 1;
          var dataSize = candidate.dataSize, markerSize = sizeOf(candidate.markerFile);
          if (dataSize === null || dataSize > maximumFileBytes || markerSize === null || markerSize > 64) {
            return removeGeneration(directory, candidate).then(next);
          }
          return readText(candidate.markerFile).then(function (marker) {
            var expectedLength = typeof marker === 'string' ? parseMarker(marker) : null;
            if (expectedLength === null) {
              return removeGeneration(directory, candidate).then(next);
            }
            return readText(candidate.dataFile).then(function (raw) {
              if (typeof raw !== 'string' || raw.length !== expectedLength) {
                return removeGeneration(directory, candidate).then(next);
              }
              return { raw: raw, token: candidate.token };
            }, function (error) {
              if (isNotFound(error)) return removeGeneration(directory, candidate).then(next);
              return next();
            });
          }, function (error) {
            if (isNotFound(error)) return removeGeneration(directory, candidate).then(next);
            return next();
          });
        }
        return removeNames(directory, markerOrphans).then(next);
      });
    });
  }

  function createFile(directory, name) {
    var file = directory.createFile(name);
    if (!file || file.isDirectory === true) throw makeError('IOError', 'Samsung catalog cache file could not be created.');
    return file;
  }

  function closeStream(stream) {
    if (!stream || typeof stream.close !== 'function') return;
    try { stream.close(); } catch (_) {}
  }

  function writeChunks(stream, raw) {
    return new Promise(function (resolve, reject) {
      var Encoder = environment && environment.TextEncoder;
      if (typeof Encoder !== 'function' || typeof stream.writeBytes !== 'function') {
        reject(makeError('NotSupportedError', 'Samsung binary cache writing is unavailable.'));
        return;
      }
      var encoder = new Encoder(), position = 0, total = 0;
      function run() {
        try {
          if (position >= raw.length) { resolve(); return; }
          var end = Math.min(raw.length, position + 32768);
          if (end < raw.length && end > position) {
            var previous = raw.charCodeAt(end - 1), next = raw.charCodeAt(end);
            if (previous >= 0xD800 && previous <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF) end -= 1;
          }
          if (end <= position) end = Math.min(raw.length, position + 32768);
          var bytes = encoder.encode(raw.slice(position, end));
          total += bytes.length;
          if (total > maximumFileBytes) throw makeError('IOError', 'Samsung cache write exceeded its size limit.');
          stream.writeBytes(Array.prototype.slice.call(bytes));
          position = end;
          var schedule = environment && typeof environment.setTimeout === 'function'
            ? function (callback) { environment.setTimeout(callback, 0); }
            : function (callback) { setTimeout(callback, 0); };
          schedule(run);
        } catch (error) { reject(error); }
      }
      run();
    });
  }

  function writeFile(directory, name, value) {
    var file = createFile(directory, name), stream = null;
    return streamFor(file, 'w').then(function (opened) {
      stream = opened;
      return writeChunks(stream, value).then(function () {
        if (typeof stream.close !== 'function') throw makeError('NotSupportedError', 'Samsung catalog cache stream cannot be closed.');
        stream.close(); stream = null;
        return file;
      });
    }).catch(function (error) {
      closeStream(stream);
      throw error;
    });
  }

  function measureBytes(raw) {
    if (raw.length > maximumFileBytes) return maximumFileBytes + 1;
    try {
      if (environment && typeof environment.Blob === 'function') {
        return new environment.Blob([raw]).size;
      }
    } catch (_) {}
    if (environment && typeof environment.TextEncoder === 'function') {
      return new environment.TextEncoder().encode(raw).length;
    }
    // Without Blob support, use a conservative bound so the global budget is
    // never exceeded by a Unicode catalog.
    return raw.length <= Math.floor(maximumFileBytes / 3) ? raw.length * 3 : maximumFileBytes + 1;
  }

  function nextToken(files, key) {
    var generations = orderedForKey(files, key), timestamp = Math.floor(Date.now()), counter = 0;
    (files || []).forEach(function (file) {
      if (!file || file.isDirectory || typeof file.name !== 'string' || file.name.slice(-3) !== '.ok') return;
      var generation = parseGeneration(file.name.slice(0, -3));
      if (generation && generation.key === key && !generations.some(function (entry) { return entry.token === generation.token; })) {
        generations.push(generation);
      }
    });
    generations.sort(generationOrder);
    if (!isFinite(timestamp) || timestamp < 0) timestamp = 0;
    if (generations.length) {
      var newest = generations[0];
      if (timestamp <= newest.timestamp) {
        timestamp = newest.timestamp;
        counter = newest.counter + 1;
      }
    }
    if (timestamp > maximumSafeInteger || counter > maximumSafeInteger) {
      throw makeError('RangeError', 'Samsung catalog cache generation is outside the safe range.');
    }
    return String(timestamp) + '-' + String(counter);
  }

  function generationFiles(files) {
    var index = allGenerations(files);
    return index.generations.map(function (generation) {
      return { generation: generation, complete: !!generation.markerFile };
    });
  }

  function isProtected(key, localKeys) {
    return !!localKeys[key] || !!activeProtectedKeys[key];
  }

  function pruneBeforeWrite(directory, files, key, nextBytes, preserveKeys) {
    var entries = generationFiles(files), byKey = Object.create(null), remove = [];
    var dataNames = Object.create(null);
    entries.forEach(function (entry) {
      var generation = entry.generation;
      dataNames[generation.name] = true;
      if (!byKey[generation.key]) byKey[generation.key] = [];
      if (entry.complete && validGenerationSize(generation)) {
        byKey[generation.key].push(generation);
      } else {
        remove = remove.concat(generationNames(generation));
      }
    });
    Object.keys(byKey).forEach(function (cacheKey) {
      byKey[cacheKey].sort(generationOrder);
      if (isProtected(cacheKey, preserveKeys)) return;
      var keep = cacheKey === key ? 1 : 2;
      byKey[cacheKey].slice(keep).forEach(function (generation) { remove = remove.concat(generationNames(generation)); });
    });
    Object.keys(indexMarkerNames(files)).forEach(function (name) {
      var dataName = name.slice(0, -3);
      if (!dataNames[dataName]) remove.push(name);
    });
    return removeNames(directory, remove).then(function () {
      return listFiles(directory).then(function (currentFiles) {
        var live = generationFiles(currentFiles).filter(function (entry) {
          return entry.complete && validGenerationSize(entry.generation);
        });
        var total = live.reduce(function (sum, entry) { return sum + entry.generation.size; }, 0);
        if (total + nextBytes <= maximumStoreBytes) return true;
        var byCache = Object.create(null);
        live.forEach(function (entry) {
          var generation = entry.generation;
          if (!byCache[generation.key]) byCache[generation.key] = [];
          byCache[generation.key].push(generation);
        });
        var victims = Object.keys(byCache).filter(function (cacheKey) {
          return cacheKey !== key && !isProtected(cacheKey, preserveKeys);
        }).map(function (cacheKey) {
          byCache[cacheKey].sort(generationOrder);
          return { key: cacheKey, newest: byCache[cacheKey][0], files: byCache[cacheKey] };
        }).sort(function (left, right) { return generationOrder(right.newest, left.newest); });
        var chain = Promise.resolve();
        victims.forEach(function (victim) {
          chain = chain.then(function () {
            if (total + nextBytes <= maximumStoreBytes) return;
            return removeNames(directory, victim.files.reduce(function (names, generation) {
              return names.concat(generationNames(generation));
            }, [])).then(function (ok) {
              if (ok) total -= victim.files.reduce(function (sum, generation) { return sum + generation.size; }, 0);
            });
          });
        });
        return chain.then(function () { return total + nextBytes <= maximumStoreBytes; });
      });
    });
  }

  function indexMarkerNames(files) {
    var names = Object.create(null);
    (files || []).forEach(function (file) {
      if (file && !file.isDirectory && typeof file.name === 'string' && /\.[0-9]+-[0-9]+\.json\.ok$/.test(file.name)) {
        names[file.name] = true;
      }
    });
    return names;
  }

  function pruneAfterWrite(directory, files, key) {
    var generations = orderedForKey(files, key), remove = [];
    generations.slice(2).forEach(function (generation) { remove = remove.concat(generationNames(generation)); });
    generations.forEach(function (generation) {
      if (!generation.markerFile) remove = remove.concat(generationNames(generation));
    });
    return removeNames(directory, remove).then(function () {});
  }

  function serialize(operation) {
    var result = writeTail.then(operation);
    writeTail = result.then(function () {}, function () {});
    return result;
  }

  function writeNow(key, raw, preserveKeys) {
    var bytes = measureBytes(raw);
    if (!isFinite(bytes) || bytes > maximumFileBytes) return Promise.resolve(false);
    var dataName = null, markerName = null, directory = null;
    return getDirectory().then(function (resolvedDirectory) {
      directory = resolvedDirectory;
      return listFiles(directory);
    }).then(function (files) {
      var token = nextToken(files, key);
      dataName = key + '.' + token + '.json';
      markerName = dataName + '.ok';
      return pruneBeforeWrite(directory, files, key, bytes, preserveKeys);
    }).then(function (hasRoom) {
      if (!hasRoom) return false;
      return writeFile(directory, dataName, raw).then(function () {
        var dataFile;
        try { dataFile = directory.resolve(dataName); }
        catch (_) { throw makeError('IOError', 'Samsung catalog cache file could not be reopened.'); }
        var actualSize = sizeOf(dataFile);
        if (actualSize === null || actualSize > maximumFileBytes || actualSize > maximumStoreBytes) {
          throw makeError('IOError', 'Samsung catalog cache file exceeded its size limit.');
        }
        return writeFile(directory, markerName, 'v1\n' + raw.length);
      }).then(function () {
        return listFiles(directory).then(function (files) {
          return pruneAfterWrite(directory, files, key).catch(function () {});
        }).catch(function () {}).then(function () { return true; });
      }).catch(function () {
        return removeNames(directory, [dataName, markerName]).then(function () { return false; });
      });
    }).catch(function () {
      if (!directory || !dataName) return false;
      return removeNames(directory, [dataName, markerName]).then(function () { return false; });
    });
  }

  function discardNow(key, token) {
    var dataName = key + '.' + token + '.json';
    return getDirectory().then(function (directory) {
      return listFiles(directory).then(function (files) {
        var generation = orderedForKey(files, key).filter(function (row) { return row.token === token; })[0];
        return removeNames(directory, generation ? generationNames(generation) : [dataName, dataName + '.ok']);
      });
    }).catch(function () { return false; });
  }

  function removeNow(key) {
    return getDirectory().then(function (directory) {
      return listFiles(directory).then(function (files) {
        var remove = [];
        (files || []).forEach(function (file) {
          if (!file || file.isDirectory || typeof file.name !== 'string') return;
          var generation = parseGeneration(file.name);
          if (generation && generation.key === key) remove.push(file.name, generation.marker);
          else if (partPattern.test(file.name) && file.name.slice(0, key.length + 1) === key + '.') remove.push(file.name);
          else if (file.name.slice(0, key.length + 1) === key + '.' && /\.json\.ok$/.test(file.name)) remove.push(file.name);
        });
        return removeNames(directory, remove);
      });
    }).catch(function () { return false; });
  }

  function protectedKeySet(options) {
    var keys = options && options.preserveKeys;
    if (keys == null) return Object.create(null);
    if (!Array.isArray(keys) || keys.length > 4) {
      throw makeError('TypeError', 'Catalog cache preservation accepts at most four keys.');
    }
    var out = Object.create(null);
    keys.forEach(function (key) { validateKey(key); out[key] = true; });
    return out;
  }

  // Migration pins span catalog and guide writes, including intervening cache writes.
  function protectKeys(keys) {
    var local = protectedKeySet({preserveKeys: keys}), protectedKeysList = Object.keys(local);
    if (!protectedKeysList.length) throw makeError('TypeError', 'Catalog cache protection requires a source key.');
    if (activeProtectionLeases >= maximumProtectionLeases) {
      throw makeError('QuotaExceededError', 'Too many active catalog cache migrations.');
    }
    activeProtectionLeases++;
    protectedKeysList.forEach(function (key) { activeProtectedKeys[key] = (activeProtectedKeys[key] || 0) + 1; });
    var released = false;
    return function () {
      if (released) return;
      released = true;
      activeProtectionLeases--;
      protectedKeysList.forEach(function (key) {
        activeProtectedKeys[key]--;
        if (activeProtectedKeys[key] === 0) delete activeProtectedKeys[key];
      });
    };
  }

  function partName(key, token, index) { return key + '.' + token + '.part-' + index + '.json'; }
  function validManifest(manifest, key, saved) {
    return manifest && manifest.schema === 1 && manifest.key === key && Array.isArray(manifest.parts) &&
      manifest.parts.length <= maximumParts && manifest.parts.every(function (part, index) {
        return part && part.index === index && (!saved || typeof part.checksum === 'string' && /^[a-f0-9]{64}$/.test(part.checksum) &&
          typeof part.bytes === 'number' && part.bytes > 0 && part.bytes <= maximumPartBytes && Math.floor(part.bytes) === part.bytes);
      });
  }
  function readBatchNow(key, remaining) {
    if (!remaining) return Promise.resolve(null);
    return readNow(key).then(function (saved) {
      if (!saved) return null;
      var envelope;
      function previous() {
        return discardNow(key, saved.token).then(function () { return readBatchNow(key, remaining - 1); });
      }
      try { envelope = JSON.parse(saved.raw); } catch (_) { return previous(); }
      if (!envelope || envelope.format !== 'tvbro-catalog-batch-v1') {
        // A legacy canonical snapshot is restored by importCatalog instead.
        // An unreadable batch must not hide the previous committed generation.
        return envelope && envelope.schema === 1 && typeof envelope.payload === 'string' ? null : previous();
      }
      return getDirectory().then(function (directory) {
        var manifest = envelope.manifest;
        if (!validManifest(manifest, key, true) || measureBytes(saved.raw) > maximumManifestBytes || !manifest.parts.every(function (part) {
          try { return sizeOf(directory.resolve(partName(key, saved.token, part.index))) === part.bytes; }
          catch (_) { return false; }
        })) {
          return previous();
        }
        return {manifest: manifest, token: saved.token, count: manifest.parts.length};
      });
    });
  }
  function writeBatchNow(key, input, readPart, preserveKeys) {
    var manifest, directory, token, written = [], pending = Object.create(null), bytes = 0;
    try { manifest = JSON.parse(JSON.stringify(input)); } catch (_) { return Promise.resolve(false); }
    if (!validManifest(manifest, key, false) || typeof readPart !== 'function') return Promise.resolve(false);
    function room(nextBytes) {
      return listFiles(directory).then(function (files) {
        // The new generation is unpublished. Count its bytes in the reservation
        // while keeping its parts out of orphan cleanup until the commit marker.
        return pruneBeforeWrite(directory, files.filter(function (file) { return !pending[file.name]; }), key, nextBytes, preserveKeys);
      }).then(function (ok) { if (!ok) throw makeError('QuotaExceededError', 'Catalog cache is full.'); });
    }
    function write(name, raw) {
      written.push(name); pending[name] = true;
      return writeFile(directory, name, raw);
    }
    function part(position) {
      if (position >= manifest.parts.length) return Promise.resolve();
      var descriptor = manifest.parts[position];
      return Promise.resolve().then(function () { return readPart(descriptor); }).then(function (value) {
        if (!value || typeof value.raw !== 'string' || !value.raw.length || typeof value.checksum !== 'string' || !/^[a-f0-9]{64}$/.test(value.checksum)) {
          throw makeError('TypeError', 'Invalid catalog cache part.');
        }
        var size = measureBytes(value.raw);
        if (size > maximumPartBytes || value.bytes != null && value.bytes !== size) throw makeError('RangeError', 'Catalog part exceeded its size limit.');
        descriptor.bytes = size; descriptor.checksum = value.checksum;
        if (value.decodedBytes != null) descriptor.decodedBytes = value.decodedBytes;
        return room(bytes + size + maximumManifestBytes).then(function () {
          return write(partName(key, token, position), value.raw);
        }).then(function (file) {
          if (sizeOf(file) !== size) throw makeError('IOError', 'Catalog part write was incomplete.');
          bytes += size; return part(position + 1);
        });
      });
    }
    return getDirectory().then(function (value) { directory = value; return listFiles(directory); }).then(function (files) {
      token = nextToken(files, key); return part(0);
    }).then(function () {
      var raw = JSON.stringify({format:'tvbro-catalog-batch-v1',manifest:manifest}), size = measureBytes(raw);
      if (size > maximumManifestBytes) throw makeError('RangeError', 'Catalog manifest exceeded its size limit.');
      return room(bytes + size).then(function () { return write(key + '.' + token + '.json', raw); }).then(function () {
        return write(key + '.' + token + '.json.ok', 'v1\n' + raw.length);
      });
    }).then(function () {
      return listFiles(directory).then(function (files) { return pruneAfterWrite(directory, files, key); }).catch(function () {});
    }).then(function () { return true; }).catch(function () {
      return (directory ? removeNames(directory, written) : Promise.resolve()).then(function () { return false; });
    });
  }

  return {
    protectKeys: protectKeys,
    readBatch: function (key) {
      try { validateKey(key); } catch (error) { return Promise.reject(error); }
      return serialize(function () { return readBatchNow(key, 2).catch(function () { return null; }); });
    },
    readBatchPart: function (key, token, index) {
      try {
        validateKey(key);
        if (typeof token !== 'string' || !tokenPattern.test(token) || typeof index !== 'number' || index < 0 || index >= maximumParts || Math.floor(index) !== index) {
          throw makeError('TypeError', 'Invalid catalog cache part identity.');
        }
      } catch (error) { return Promise.reject(error); }
      return serialize(function () { return getDirectory().then(function (directory) {
        var file = directory.resolve(partName(key, token, index)), size = sizeOf(file);
        if (size === null || size > maximumPartBytes) throw makeError('IOError', 'Catalog part exceeded its size limit.');
        return readText(file);
      }); });
    },
    writeBatch: function (key, manifest, readPart, writeOptions) {
      var preserveKeys;
      try { validateKey(key); preserveKeys = protectedKeySet(writeOptions); } catch (error) { return Promise.reject(error); }
      return serialize(function () { return writeBatchNow(key, manifest, readPart, preserveKeys); });
    },
    discardBatch: function (key, token) {
      try {
        validateKey(key);
        if (typeof token !== 'string' || !tokenPattern.test(token)) throw makeError('TypeError', 'Invalid catalog cache generation.');
      } catch (error) { return Promise.reject(error); }
      return serialize(function () { return discardNow(key, token); });
    },
    read: function (key) {
      try { validateKey(key); } catch (error) { return Promise.reject(error); }
      return serialize(function () { return readNow(key).catch(function () { return null; }); });
    },
    write: function (key, raw, type, writeOptions) {
      var preserveKeys;
      try { validateKey(key); preserveKeys = protectedKeySet(writeOptions); }
      catch (error) { return Promise.reject(error); }
      if (typeof raw !== 'string' || raw.length === 0) return Promise.resolve(false);
      return serialize(function () { return writeNow(key, raw, preserveKeys); });
    },
    discard: function (key, token) {
      try { validateKey(key); } catch (error) { return Promise.reject(error); }
      if (typeof token !== 'string' || !tokenPattern.test(token)) {
        return Promise.reject(makeError('TypeError', 'Catalog cache generation token is invalid.'));
      }
      return serialize(function () { return discardNow(key, token); });
    },
    remove: function (key) {
      try { validateKey(key); } catch (error) { return Promise.reject(error); }
      return serialize(function () { return removeNow(key); });
    }
  };
}));
