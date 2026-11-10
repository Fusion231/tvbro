'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');

// Run the actual remote handlers while keeping DOM and native exit at the boundary.
const source = fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8');
const declarations = acorn.parse(source, {ecmaVersion:2022}).body[0].expression.callee.body.body;
const handlers = declarations.filter(node => node.type === 'FunctionDeclaration' &&
  ['back', 'onKey', 'stopSeekHold', 'leaveLanguage', 'requestExit', 'confirmAction', 'dialog', 'closeDialog', 'dialogButton'].includes(node.id.name))
  .map(node => source.slice(node.start, node.end)).join('\n');

function harness(screen, options = {}) {
  const calls = [], dialogs = [];
  const view = {screen};
  function node(tag, label) {
    const value = {tag, label, children:[], attributes:{}, hidden:false,
      classList:{add() {},remove() {}},
      setAttribute(name, content) { this.attributes[name] = content; },
      hasAttribute(name) { return Object.hasOwn(this.attributes, name); },
      appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
      removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; },
      querySelectorAll(selector) {
        const result = [];
        function visit(parent) {
          for (const child of parent.children) {
            if (selector === child.tag || selector === '[data-nav]' && child.hasAttribute('data-nav')) result.push(child);
            visit(child);
          }
        }
        visit(this); return result;
      }
    };
    return value;
  }
  const homeFocus = node('button', 'Home'), layer = node('div'), body = node('body');
  homeFocus.setAttribute('data-nav', '');
  const screens = {home:node('section'),language:node('section')};
  screens.home.appendChild(homeFocus);
  const document = {activeElement:homeFocus,body};
  const environment = {
    view, dialogs, Promise, document, exitPending:null, hideTimer:null, seekHold:null,
    window:{TVBroPlatformAdapters:options.confirmExit ? {confirmExit:true} : {},clearTimeout() {}},
    byId:(id) => id === 'modal-layer' ? layer : id.endsWith('-view') ? screens[id.slice(0,-5)] : {value:''},
    t:value => value, text(target, value) { target.textContent = value; },
    message:error => error.message,element:node,
    button(label, classes, action) {
      const value = node('button', label); value.setAttribute('data-nav', '');
      value.click = () => { if (!value.disabled) action(); }; return value;
    },
    focus(value) { document.activeElement = value; },
    visible(value) { return !!value && !value.hidden; },
    cancelPlayerZap() {},syncPreviewIdleTimer() {},resetPreviewIdleTimer() {},
    showHome() { calls.push('home'); view.screen = 'home'; },
    showSources() { calls.push('sources'); view.screen = 'sources'; },
    platform:{exit() { calls.push('exit'); return options.exit ? options.exit() : undefined; }},
    report(error) { throw error; }
  };
  vm.createContext(environment); vm.runInContext(handlers, environment);
  const closeDialog = environment.closeDialog;
  environment.closeDialog = (...args) => { calls.push('dialog'); return closeDialog(...args); };
  return {
    calls, dialogs, view, environment, document, homeFocus, layer,
    settle:() => new Promise(resolve => setImmediate(resolve)),
    async pressBack(keyCode) {
      let prevented = false;
      environment.onKey({keyCode,preventDefault() { prevented = true; }});
      assert.equal(prevented, true);
      await new Promise(resolve => setImmediate(resolve));
    }
  };
}

test('Samsung Back returns from the catalog to Home, then exits without opening playlists', async () => {
  const kit = harness('catalog');
  await kit.pressBack(10009);
  assert.equal(kit.view.screen, 'home');
  assert.deepEqual(kit.calls, ['home']);
  await kit.pressBack(10009);
  assert.equal(kit.view.screen, 'home');
  assert.deepEqual(kit.calls, ['home','exit']);
});

for (const keyCode of [10009,27,8]) {
  test('Back key ' + keyCode + ' exits directly from Home', async () => {
    const kit = harness('home');
    await kit.pressBack(keyCode);
    assert.equal(kit.view.screen, 'home');
    assert.deepEqual(kit.calls, ['exit']);
  });
}

test('Back dismisses a Home dialog before exiting', async () => {
  const kit = harness('home');
  kit.environment.dialog('Existing dialog');
  await kit.pressBack(10009);
  assert.equal(kit.dialogs.length, 0);
  assert.deepEqual(kit.calls, ['dialog']);
  await kit.pressBack(10009);
  assert.deepEqual(kit.calls, ['dialog','exit']);
});

test('Titan Home Back opens one exit confirmation with Cancel focused and Back restores focus', async () => {
  const kit = harness('home', {confirmExit:true});
  await kit.pressBack(10009);
  assert.equal(kit.dialogs.length, 1);
  assert.equal(kit.dialogs[0].node.attributes['aria-label'], 'Exit TVBro?');
  assert.equal(kit.document.activeElement.label, 'Cancel');
  assert.equal(kit.calls.includes('exit'), false);
  await kit.pressBack(10009);
  assert.equal(kit.dialogs.length, 0);
  assert.equal(kit.document.activeElement, kit.homeFocus);
  assert.equal(kit.calls.includes('exit'), false);
});

test('Titan confirmation exits once after explicit Confirm and disables repeated activation while pending', async () => {
  let finish;
  const kit = harness('home', {confirmExit:true,exit:() => new Promise(resolve => { finish = resolve; })});
  await kit.pressBack(10009);
  const record = kit.dialogs[0], confirm = record.actions.children[0];
  confirm.click(); confirm.click(); await kit.settle();
  assert.equal(kit.calls.filter(value => value === 'exit').length, 1);
  assert.equal(confirm.disabled, true);
  kit.environment.requestExit(); await kit.settle();
  assert.equal(kit.dialogs.length, 1);
  finish(); await kit.settle();
  assert.equal(kit.dialogs.length, 0);
});

test('Titan exit failure keeps confirmation usable without losing focus or silently exiting', async () => {
  const kit = harness('home', {confirmExit:true,exit:() => Promise.reject(new Error('Exit unavailable'))});
  await kit.pressBack(10009);
  const record = kit.dialogs[0]; record.actions.children[0].click(); await kit.settle();
  assert.equal(record.error.textContent, 'Exit unavailable');
  assert.equal(record.actions.children[0].disabled, false);
  assert.equal(kit.dialogs.length, 1);
  record.actions.children[1].click();
  assert.equal(kit.dialogs.length, 0);
  assert.equal(kit.document.activeElement, kit.homeFocus);
});

test('Titan first-run language Back also requests confirmation without exiting', async () => {
  const kit = harness('language', {confirmExit:true});
  await kit.pressBack(10009);
  assert.equal(kit.dialogs.length, 1);
  assert.equal(kit.calls.includes('exit'), false);
});
