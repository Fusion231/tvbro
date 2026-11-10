'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');

const source = fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8');
const names = ['showScreen', 'showLanguage', 'renderLanguages', 'showProfiles', 'renderProfiles'];
const declarations = acorn.parse(source, {ecmaVersion:2022}).body[0].expression.callee.body.body;
const handlers = declarations.filter(node => node.type === 'FunctionDeclaration' && names.includes(node.id.name))
  .map(node => source.slice(node.start, node.end)).join('\n');

function harness() {
  const nodes = {}, focused = [];
  function element(tag, className, value) {
    const attributes = {}, children = [];
    return {tag, className, textContent:value, hidden:false, children,
      get firstChild() { return children[0] || null; },
      appendChild(child) { children.push(child); },
      insertBefore() {},
      removeChild(child) { children.splice(children.indexOf(child), 1); },
      setAttribute(key, value) { attributes[key] = value; },
      getAttribute(key) { return attributes[key]; },
      querySelector(selector) {
        return children.find(child => selector === 'button' ? child.tag === 'button' :
          selector === '[aria-pressed="true"]' ? child.getAttribute('aria-pressed') === 'true' :
          selector === '[data-nav]' ? child.tag === 'button' : false) || null;
      }};
  }
  const byId = id => nodes[id] || (nodes[id] = element('div'));
  const screens = ['language', 'profiles', 'home'].map(name => {
    const node = byId(name + '-view'); node.setAttribute('data-screen', name); return node;
  });
  const oldLanguage = element('button', '', 'Old language');
  byId('language-list').appendChild(oldLanguage);
  byId('language-view').appendChild(oldLanguage);
  const oldProfile = element('button', '', 'Old profile');
  byId('profile-list').appendChild(oldProfile);
  byId('profiles-view').appendChild(oldProfile);
  const view = {screen:'home', languages:[{code:'en', name:'English'}, {code:'pl', name:'Polski'}],
    languageSaving:false, profiles:[{name:'First', source:'local'}, {name:'Second', source:'cloud'}],
    manageProfiles:false, profile:null, guideRequest:0, mediaRequest:0};
  const env = {view, uiLanguage:'pl', suspendedDetails:null, detailsStart:null,
    searchTimer:null, guideScrollTimer:null, channelNowNextTimer:null, mediaSearchTimer:null,
    window:{clearTimeout() {}}, document:{querySelectorAll:() => screens, querySelector:() => element('header')},
    byId, element, button:(label, className) => element('button', className, label),
    clear(node) { while (node.firstChild) node.removeChild(node.firstChild); },
    text(node, value) { node.textContent = value; }, t:value => value, cap:() => true,
    core:{appLanguages:() => '[]'}, cancelPlayerZap() {}, cancelPreviewIdleTimer() {}, status() {}, scheduleArtwork() {},
    focus(node) {
      focused.push({node, languageCount:byId('language-list').children.length,
        profileCount:byId('profile-list').children.length});
    }};
  vm.createContext(env); vm.runInContext(handlers, env);
  return {env, view, byId, focused};
}

test('language entry focuses the selected language once after rendering, including reentry', () => {
  const kit = harness();
  for (const fromSettings of [false, true]) {
    kit.focused.length = 0; kit.env.showLanguage(fromSettings);
    assert.equal(kit.focused.length, 1);
    assert.equal(kit.focused[0].node.textContent, 'Polski');
    assert.equal(kit.focused[0].languageCount, 2);
    assert.equal(kit.view.languageReturn, fromSettings);
  }
});

test('language entry keeps first-language and empty-list Continue fallbacks', () => {
  const kit = harness(); kit.env.uiLanguage = 'unknown'; kit.env.showLanguage(false);
  assert.equal(kit.focused.length, 1);
  assert.equal(kit.focused[0].node.textContent, 'English');
  kit.view.languages = []; kit.focused.length = 0; kit.env.showLanguage(false);
  assert.equal(kit.focused.length, 1);
  assert.equal(kit.focused[0].node, kit.byId('language-continue'));
});

test('profile entry focuses the rendered first profile once and keeps Add profile fallback', () => {
  const kit = harness(); kit.env.showProfiles();
  assert.equal(kit.focused.length, 1);
  assert.equal(kit.focused[0].node, kit.byId('profile-list').firstChild);
  assert.equal(kit.focused[0].profileCount, 2);
  kit.view.profiles = []; kit.focused.length = 0; kit.env.showProfiles();
  assert.equal(kit.focused.length, 1);
  assert.equal(kit.focused[0].node, kit.byId('add-profile'));
});

test('ordinary screen transitions retain default and explicit focus targets', () => {
  const kit = harness(), target = {tag:'button'};
  kit.byId('home-view').appendChild(target); kit.env.showScreen('home');
  assert.equal(kit.focused[0].node, target);
  const explicit = {tag:'button'}; kit.env.showScreen('home', explicit);
  assert.equal(kit.focused[1].node, explicit);
});
