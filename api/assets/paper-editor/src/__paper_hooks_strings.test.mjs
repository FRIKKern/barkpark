// __paper_hooks_strings.test.mjs — task-e8a5c972b7720591: the paper editor's
// own words (footer save status, field validity, the save-conflict banner, the
// block menu) were English literals in bp-paper-editor-hooks.js, whatever the
// Studio language. They now read the `data-paper-strings` map the server stamps
// on the editor root, falling back to the English.
//
// The footer is also a protocol: the hook only overwrites a TRANSIENT status,
// recognised by its text. The server renders that status translated, so a
// Norwegian "✓ Lagret automatisk" must still count as transient — otherwise the
// footer sticks on a stale saved claim.
//
// Run: node src/__paper_hooks_strings.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';

const HOOKS = readFileSync(new URL('../../../priv/static/assets/bp-paper-editor-hooks.js', import.meta.url), 'utf8');

const NB = {
  'Auto-saved': 'Lagret automatisk',
  '✓ Auto-saved': '✓ Lagret automatisk',
  'Saving…': 'Lagrer …',
  'Unsaved changes — fix invalid fields.': 'Ulagrede endringer — rett ugyldige felt.',
  'Save paused — review required.': 'Lagring satt på pause — må gås gjennom.',
  'Save paused — retry required.': 'Lagring satt på pause — må prøves på nytt.',
  'Enter a positive whole number.': 'Skriv inn et positivt heltall.',
  'Save paused': 'Lagring satt på pause',
  'This document changed elsewhere. Your edits are still here.': 'Dokumentet er endret et annet sted. Endringene dine er fortsatt her.',
  'Review': 'Gå gjennom',
  'Keep mine': 'Behold mine',
  'Use latest': 'Bruk nyeste',
  'Technical details': 'Tekniske detaljer',
  'Unsaved draft payload': 'Ulagret utkast',
  'Server revision %{revision}. No exact retry payload is available. Use latest explicitly discards this retained draft.':
    'Serverrevisjon %{revision}. Det finnes ingen nøyaktig versjon å prøve på nytt. Bruk nyeste forkaster dette beholdte utkastet.',
  'Block actions': 'Blokkhandlinger',
  'Move up': 'Flytt opp',
  'Move down': 'Flytt ned',
  'Delete block': 'Slett blokk',
  'Part of the document template': 'Del av dokumentmalen',
};

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

async function run(strings) {
  const attr = strings ? ` data-paper-strings='${JSON.stringify(strings).replace(/'/g, '&#39;')}'` : '';
  const dom = new JSDOM(
    '<main data-paper-doc-key="production:paper:probe" data-paper-rev="7">' +
      `<div class="bp-paper-editor"${attr}>` +
        '<div id="paper-canvas-probe-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>' +
        '<div data-edit-block-id="a"><span>A</span></div><div data-edit-block-id="b"><span>B</span></div>' +
        '<div id="ctx-host"></div>' +
      '</div>' +
      '<footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer>' +
    '</main>');
  const { window } = dom;
  let nextRequestId = 0;
  Object.defineProperty(window, 'crypto', { configurable: true, value: {
    randomUUID: () => `00000000-0000-4000-8000-${String(++nextRequestId).padStart(12, '0')}`,
  } });
  const context = vm.createContext({ window, document: window.document, CustomEvent: window.CustomEvent,
    FormData: window.FormData, Date, setTimeout, clearTimeout,
    customElements: { whenDefined: () => new Promise(() => {}) } });
  vm.runInContext(HOOKS, context);
  const hooks = window.BarkparkPaperEditorHooks;
  const doc = window.document;
  const main = doc.querySelector('main');
  const wrapper = doc.querySelector('[phx-hook="BarkparkPaperCanvas"]');
  const replies = [];
  const bridge = { ...hooks.BarkparkPaperCanvas, el: wrapper,
    handleEvent: () => {},
    pushEvent: (name, payload) => {
      if (name !== 'paper-ops' && name !== 'paper-edit-block' && name !== 'paper-block-autosave') return Promise.resolve({});
      return new Promise((resolve, reject) => replies.push({ resolve, reject, payload }));
    },
  };
  bridge.mounted();
  const footer = doc.querySelector('[data-test-id="bp-paper-footer-save"]');
  const t = (text) => (strings && strings[text]) || text;

  // 1. The footer: the server painted the calm token in this language; a newly
  // invalid draft must replace it, in the same language.
  const form = doc.createElement('form');
  form.className = 'bp-paper-edit-form';
  form.setAttribute('phx-change', 'paper-block-autosave');
  form.setAttribute('phx-debounce', '0');
  form.setAttribute('data-test-id', 'paper-toc-editor');
  form.innerHTML = '<input name="block_id" value="toc-1"><input name="depth" value="2"><input name="toc-0-level" value="3">';
  main.querySelector('.bp-paper-editor').append(form);
  const level = form.querySelector('[name="toc-0-level"]');
  footer.textContent = t('✓ Auto-saved');
  level.value = 'not-a-number';
  level.dispatchEvent(new window.Event('input', { bubbles: true }));
  await tick();
  const status = {
    invalid: footer.textContent,
    validity: level.validationMessage,
  };
  level.value = '4';
  level.dispatchEvent(new window.Event('input', { bubbles: true }));
  status.saving = footer.textContent;
  form.remove();

  // 2. The save-conflict banner.
  const conflicted = doc.createElement('form');
  conflicted.className = 'bp-paper-edit-form';
  conflicted.setAttribute('phx-change', 'paper-block-autosave');
  conflicted.innerHTML = '<input name="block_id" value="c"><input name="text" value="x">';
  main.append(conflicted);
  bridge._bpPaperExitCoordinator._setConflict({ conflict: true, current_rev: 99 }, conflicted, 'production:paper:probe');
  const banner = main.querySelector('[data-bp-paper-conflict]');
  banner.querySelector('[data-action="review"]').click();
  const conflict = {
    title: banner.querySelector('.bp-conflict-title').textContent,
    description: banner.querySelector('.bp-conflict-description').textContent,
    buttons: [...banner.querySelectorAll('.bp-conflict-actions button')].map((b) => b.textContent),
    summary: banner.querySelector('summary').textContent,
    payloadLabel: banner.querySelector('[data-conflict-draft]').getAttribute('aria-label'),
    message: banner.querySelector('[data-conflict-message]').textContent,
    footer: footer.textContent,
  };

  // 3. The block menu (one body-level element, named per editor on open).
  const menuHook = { ...hooks.BarkparkPaperContextMenu, el: doc.querySelector('#ctx-host'),
    pushEvent: () => Promise.resolve({}) };
  menuHook.mounted();
  doc.querySelector('[data-edit-block-id="a"]').dispatchEvent(
    new window.MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }));
  const menu = doc.querySelector('#bp-paper-context-menu');
  const blockMenu = {
    label: menu.getAttribute('aria-label'),
    items: [...menu.querySelectorAll('[role="menuitem"]')].map((b) => b.textContent),
    note: menu.querySelector('.bp-paper-context-menu__note').textContent,
  };
  menuHook.destroyed();
  bridge.destroyed();
  window.close();
  return { status, conflict, blockMenu };
}

const nb = await run(NB);
assert.equal(nb.status.invalid, 'Ulagrede endringer — rett ugyldige felt.',
  'a Norwegian "✓ Lagret automatisk" counts as transient and is replaced in Norwegian');
assert.equal(nb.status.validity, 'Skriv inn et positivt heltall.');
assert.equal(nb.status.saving, 'Lagrer …');
assert.deepEqual(nb.conflict, {
  title: 'Lagring satt på pause',
  description: 'Dokumentet er endret et annet sted. Endringene dine er fortsatt her.',
  buttons: ['Gå gjennom', 'Behold mine', 'Bruk nyeste'],
  summary: 'Tekniske detaljer',
  payloadLabel: 'Ulagret utkast',
  message: 'Serverrevisjon 99. Det finnes ingen nøyaktig versjon å prøve på nytt. Bruk nyeste forkaster dette beholdte utkastet.',
  footer: 'Lagring satt på pause — må gås gjennom.',
});
assert.deepEqual(nb.blockMenu, {
  label: 'Blokkhandlinger',
  items: ['Flytt opp', 'Flytt ned', 'Slett blokk'],
  note: 'Del av dokumentmalen',
});

const en = await run(null);
assert.equal(en.status.invalid, 'Unsaved changes — fix invalid fields.');
assert.equal(en.status.validity, 'Enter a positive whole number.');
assert.equal(en.status.saving, 'Saving…');
assert.deepEqual(en.conflict, {
  title: 'Save paused',
  description: 'This document changed elsewhere. Your edits are still here.',
  buttons: ['Review', 'Keep mine', 'Use latest'],
  summary: 'Technical details',
  payloadLabel: 'Unsaved draft payload',
  message: 'Server revision 99. No exact retry payload is available. Use latest explicitly discards this retained draft.',
  footer: 'Save paused — review required.',
});
assert.deepEqual(en.blockMenu, {
  label: 'Block actions',
  items: ['Move up', 'Move down', 'Delete block'],
  note: 'Part of the document template',
});

// A translation is text, never markup: the banner template escapes it.
const hostile = await run({ ...NB, 'Save paused': '<img src=x onerror=alert(1)>' });
assert.equal(hostile.conflict.title, '<img src=x onerror=alert(1)>');

console.log('paper hooks strings: all checks passed');
