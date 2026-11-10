(function (root, factory) {
  var api = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.TVBroSamsungBackupFiles = api;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function (options) {
  'use strict';
  options = options || {};
  var environment = options.environment || (typeof window !== 'undefined' ? window : {});
  var tizen = environment.tizen || {}, fs = tizen.filesystem;
  var maximum = 32 * 1024 * 1024, chunkSize = 32768;
  var timers = typeof environment.setTimeout === 'function' ? environment :
    typeof global !== 'undefined' ? global : null;
  var pickerTimeout = typeof options.pickerTimeoutMs === 'number' && options.pickerTimeoutMs > 0 ? options.pickerTimeoutMs : 120000;

  function fail(code, message, name) {
    var value = new Error(message); value.code = code; value.name = name || 'IOError'; return value;
  }
  function needPath() { return fail('backup_path_required', 'Choose a backup file or a writable storage folder.', 'NotSupportedError'); }
  function capability() { return fail('backup_files_unavailable', 'Backup file access is unavailable on this TV.', 'NotSupportedError'); }
  function validSize(value) { return typeof value === 'number' && isFinite(value) && value >= 0 && Math.floor(value) === value; }
  function path(value) {
    if (typeof value !== 'string' || !value || value.length > 4096 || /[\x00-\x1f\x7f\\?#]/.test(value)) throw fail('backup_path_invalid', 'Choose a local storage path.', 'TypeError');
    var normalized = value;
    if (/^file:\/\//i.test(value)) {
      if (!/^file:\/\/\/[^/]/i.test(value)) throw fail('backup_path_invalid', 'Remote file locations are unsupported.', 'TypeError');
      normalized = value.slice(7);
    } else if (/[:]/.test(value) || value.charAt(0) === '/') throw fail('backup_path_invalid', 'Choose a storage label or a local file URI.', 'TypeError');
    var decoded;
    try { decoded = decodeURIComponent(normalized); } catch (_) { throw fail('backup_path_invalid', 'Invalid storage path.', 'TypeError'); }
    if (/[\x00-\x1f\x7f\\?#]/.test(decoded) || /(?:^|\/)\.{1,2}(?:\/|$)/.test(decoded) || /%[0-9a-f]{2}/i.test(decoded)) {
      throw fail('backup_path_invalid', 'Invalid storage path.', 'TypeError');
    }
    return value.replace(/\/+$/, '');
  }
  function fileSystem() { if (!fs || typeof fs.resolve !== 'function') throw capability(); return fs; }
  function resolve(location, mode) {
    return new Promise(function (ok, no) {
      try { fileSystem().resolve(path(location), ok, no, mode); } catch (error) { no(error); }
    });
  }
  function open(file, mode) {
    return new Promise(function (ok, no) {
      try {
        if (!file || typeof file.openStream !== 'function') throw capability();
        file.openStream(mode, ok, no);
      } catch (error) { no(error); }
    });
  }
  function close(stream) { if (stream && typeof stream.close === 'function') stream.close(); }
  function next(callback) { if (timers) timers.setTimeout(callback, 0); else callback(); }
  function read(location) {
    if (typeof environment.atob !== 'function') return Promise.reject(capability());
    return resolve(location, 'r').then(function (file) {
      if (!file || file.isFile !== true || !validSize(file.fileSize) || file.fileSize < 1 || file.fileSize > maximum) {
        throw fail('backup_size_limit', 'Choose a backup file no larger than 32 MiB.');
      }
      var size = file.fileSize;
      return open(file, 'r').then(function (stream) {
        return new Promise(function (ok, no) {
          var output, position = 0;
          function finish(error) {
            try { close(stream); } catch (closing) { if (!error) error = closing; }
            if (error) no(error); else ok(output);
          }
          function run() {
            try {
              if (typeof stream.readBase64 !== 'function') throw capability();
              var available = stream.bytesAvailable;
              // The Tizen 1.0 stream reports -1 at EOF, rather than zero.
              if (position === size) { if (available !== 0 && !(available === -1 && stream.eof === true)) throw fail('backup_read_failed', 'The backup file changed while reading.'); finish(); return; }
              if (stream.eof === true || available === 0 || available === -1) throw fail('backup_read_failed', 'The backup file could not be read completely.');
              if (!validSize(available) || position + available > size) throw fail('backup_size_limit', 'The backup file changed or exceeded its size limit.');
              var count = Math.min(chunkSize, size - position, available);
              var encoded = stream.readBase64(count);
              if (typeof encoded !== 'string' || encoded.length > Math.ceil(count / 3) * 4) throw fail('backup_read_failed', 'Invalid backup file data.');
              var raw = environment.atob(encoded);
              if (!raw.length || raw.length > count) throw fail('backup_read_failed', 'Invalid backup file data.');
              for (var i = 0; i < raw.length; i++) output[position++] = raw.charCodeAt(i);
              next(run);
            } catch (error) { finish(error); }
          }
          try { output = new Uint8Array(size); run(); } catch (error) { finish(error); }
        });
      });
    });
  }
  function pick() {
    return new Promise(function (ok, no) {
      if (typeof tizen.ApplicationControl !== 'function' || !tizen.application || typeof tizen.application.launchAppControl !== 'function' || !timers) { no(needPath()); return; }
      var settled = false, timer = timers.setTimeout(function () { finish(needPath()); }, pickerTimeout);
      function finish(error, location) {
        if (settled) return;
        settled = true; timers.clearTimeout(timer);
        if (error) no(error); else ok(location);
      }
      try {
        // The operation and selected reply are part of the TV Application API.
        // A matching picker is optional; launch errors fall back to path choice.
        var control = new tizen.ApplicationControl('http://tizen.org/appcontrol/operation/pick', null, 'application/octet-stream');
        tizen.application.launchAppControl(control, null, function () {}, function () { finish(needPath()); }, {
          onsuccess: function (data) {
            var selected = [];
            if (Array.isArray(data)) data.forEach(function (row) {
              if (row && row.key === 'http://tizen.org/appcontrol/data/selected' && Array.isArray(row.value)) selected = selected.concat(row.value);
            });
            if (selected.length !== 1 || typeof selected[0] !== 'string') { finish(needPath()); return; }
            try { finish(null, path(selected[0])); } catch (error) { finish(error); }
          },
          onfailure: function () { finish(fail('backup_cancelled', 'Backup file selection was cancelled.', 'AbortError')); }
        });
      } catch (_) { finish(needPath()); }
    });
  }
  function filename(value) {
    if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,150}\.tvbro$/i.test(value)) throw fail('backup_name_invalid', 'Use a simple file name ending in .tvbro.', 'TypeError');
    return value;
  }
  function save(bytes, suggestedName, directoryPath) {
    if (!directoryPath) return Promise.reject(needPath());
    var output, name;
    try {
      if (!bytes || !validSize(bytes.length) || bytes.length < 1 || bytes.length > maximum) throw fail('backup_size_limit', 'Backup files must not exceed 32 MiB.');
      if (typeof environment.btoa !== 'function') throw capability();
      output = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes.length);
      if (!(bytes instanceof Uint8Array)) for (var i = 0; i < bytes.length; i++) {
        if (!validSize(bytes[i]) || bytes[i] > 255) throw fail('backup_invalid', 'Invalid backup bytes.', 'TypeError');
        output[i] = bytes[i];
      }
      name = filename(suggestedName);
    } catch (error) { return Promise.reject(error); }
    return resolve(directoryPath, 'rw').then(function (directory) {
      if (!directory || directory.isDirectory !== true || directory.readOnly === true || typeof directory.createFile !== 'function') throw fail('backup_write_failed', 'Choose a writable storage folder.');
      try { directory.resolve(name); throw fail('backup_exists', 'A backup with this name already exists. Choose another name.'); }
      catch (error) { if (!error || error.name !== 'NotFoundError') throw error; }
      var file = directory.createFile(name), expectedPath = (directory.fullPath || path(directoryPath)) + '/' + name;
      if (!file || file.fullPath && file.fullPath !== expectedPath) throw fail('backup_write_failed', 'Invalid backup destination.');
      function cleanup(error) {
        return new Promise(function (ok) {
          if (typeof directory.deleteFile !== 'function') { ok(); return; }
          try { directory.deleteFile(expectedPath, ok, ok); } catch (_) { ok(); }
        }).then(function () { throw error; });
      }
      return open(file, 'w').then(function (stream) {
        return new Promise(function (ok, no) {
          var position = 0;
          function finish(error) {
            try { close(stream); } catch (closing) { if (!error) error = closing; }
            if (error) no(error); else ok();
          }
          function run() {
            try {
              if (typeof stream.writeBase64 !== 'function') throw capability();
              if (position === output.length) { finish(); return; }
              var end = Math.min(position + chunkSize, output.length), text = '';
              for (var i = position; i < end; i++) text += String.fromCharCode(output[i]);
              stream.writeBase64(environment.btoa(text)); position = end;
              next(run);
            } catch (error) { finish(error); }
          }
          run();
        });
      }).then(function () { return resolve(expectedPath, 'r'); }).then(function (written) {
        if (!written || written.isFile !== true || written.fileSize !== output.length) throw fail('backup_write_failed', 'The backup file was not written completely.');
        return {path:expectedPath};
      }).catch(cleanup);
    });
  }
  function storages() {
    return new Promise(function (ok, no) {
      try {
        if (typeof fileSystem().listStorages !== 'function') throw capability();
        fs.listStorages(function (rows) {
          ok((Array.isArray(rows) ? rows : []).filter(function (row) {
            return row && row.state === 'MOUNTED' && typeof row.label === 'string' && /^[^/\\:\x00-\x1f]{1,128}$/.test(row.label);
          }).slice(0,32).map(function (row) { return {label:row.label,type:row.type,state:row.state}; }));
        }, no);
      } catch (error) { no(error); }
    });
  }
  function directory(location) {
    return resolve(location, 'r').then(function (file) {
      if (!file || file.isDirectory !== true || typeof file.listFiles !== 'function') throw fail('backup_path_invalid', 'Choose a storage folder.');
      return new Promise(function (ok, no) {
        try { file.listFiles(function (rows) {
          var entries = [], truncated = false;
          (Array.isArray(rows) ? rows : []).some(function (entry) {
            if (!entry || typeof entry.name !== 'string' || entry.name === '.' || entry.name === '..' || /[\/\\\x00-\x1f]/.test(entry.name) ||
                entry.isDirectory !== true && !/\.tvbro$/i.test(entry.name)) return false;
            if (entries.length === 200) { truncated = true; return true; }
            entries.push({name:entry.name,path:(file.fullPath || path(location))+'/'+entry.name,isDirectory:entry.isDirectory === true,size:entry.isFile === true?entry.fileSize:null});
            return false;
          });
          ok({path:file.fullPath || location,entries:entries,truncated:truncated});
        }, no); } catch (error) { no(error); }
      });
    });
  }
  return {
    capabilities: function () { return {import:!!(fs && typeof fs.resolve === 'function' && typeof environment.atob === 'function'),export:!!(fs && typeof fs.resolve === 'function' && typeof environment.btoa === 'function')}; },
    chooseImport: function (location) { return location ? read(location) : pick().then(read); },
    saveExport: save,
    listStorages: storages,
    listDirectory: directory
  };
}));
