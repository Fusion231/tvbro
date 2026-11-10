(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.TVBroSamsungOrganization = api;
}(typeof window !== 'undefined' ? window : this, function () {
  'use strict';
  function strings(raw) {
    var seen = Object.create(null);
    return Array.isArray(raw) ? raw.filter(function (id) {
      if (typeof id !== 'string' || seen[id]) return false;
      seen[id] = true; return true;
    }) : [];
  }
  function normalize(raw) {
    raw = raw && typeof raw === 'object' ? raw : {};
    var names = {}, seen = Object.create(null), groups = [];
    if (raw.names && typeof raw.names === 'object') Object.keys(raw.names).forEach(function (id) {
      if (typeof raw.names[id] === 'string' && raw.names[id].trim()) names[id] = raw.names[id].trim();
    });
    if (Array.isArray(raw.groups)) raw.groups.forEach(function (group) {
      if (!group || typeof group.id !== 'string' || group.id.indexOf('tvbro.group.') !== 0 || seen[group.id] || typeof group.name !== 'string' || !group.name.trim()) return;
      seen[group.id] = true; groups.push({ id: group.id, name: group.name.trim(), channels: strings(group.channels) });
    });
    return { version: 1, names: names, hidden: strings(raw.hidden), order: strings(raw.order), groups: groups };
  }
  function apply(channels, raw, includeHidden) {
    var organization = normalize(raw), ranks = Object.create(null), hidden = Object.create(null);
    if (!Object.keys(organization.names).length && !organization.order.length && (includeHidden || !organization.hidden.length)) return channels;
    organization.order.forEach(function (id, index) { ranks[id] = index; });
    organization.hidden.forEach(function (id) { hidden[id] = true; });
    var rows = [];
    channels.forEach(function (channel, index) {
      if (!includeHidden && hidden[channel.id]) return;
      var value = Object.assign({}, channel);
      if (organization.names[channel.id]) value.name = organization.names[channel.id];
      rows.push({ value: value, index: index, rank: ranks[channel.id] == null ? organization.order.length : ranks[channel.id] });
    });
    if (organization.order.length) rows.sort(function (a, b) { return a.rank - b.rank || a.index - b.index; });
    return rows.map(function (row) { return row.value; });
  }
  function hiddenCategories(settings, kind) {
    return strings(settings && settings.hiddenCategories && settings.hiddenCategories[kind || 'live']);
  }
  return { normalize: normalize, apply: apply, strings: strings, hiddenCategories: hiddenCategories };
}));
