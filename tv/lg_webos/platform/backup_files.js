(function (root, factory) {
  var exported = { create: factory };
  if (typeof module === 'object' && module.exports) module.exports = exported;
  if (root) root.TVBroWebOSBackupFiles = exported;
}(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this), function () {
  'use strict';
  // LG TV web apps have no supported native file picker/write API. Do not
  // advertise the Tizen filesystem or an anchor download as a working backup.
  function unavailable() {
    var error = new Error('Local backup file access is not supported by LG webOS TV web apps.');
    error.name = 'NotSupportedError'; error.code = 'backup_files_unavailable';
    return Promise.reject(error);
  }
  return {
    capabilities: function () { return { import: false, export: false }; },
    chooseImport: unavailable,
    saveExport: unavailable,
    listStorages: unavailable,
    listDirectory: unavailable
  };
}));
