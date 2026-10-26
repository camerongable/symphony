import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../priv/static/dashboard.js', import.meta.url), 'utf8');
const prompt = '\uFEFFRework the current candidate.\r\nPreserve Ω exactly.';
const listeners = new Map();
const status = {textContent: 'Copy does not send.'};
const button = {dataset: {promptBase64: Buffer.from(prompt).toString('base64')}, disabled: false};
const writes = [];
let resolveCopy;
let rejectCopy;
const context = {
  window: {}, Uint8Array, TextDecoder, Date, Intl,
  atob: value => Buffer.from(value, 'base64').toString('binary'),
  navigator: {clipboard: {writeText(value) {
    writes.push(value);
    return new Promise((resolve, reject) => { resolveCopy = resolve; rejectCopy = reject; });
  }}}
};
vm.runInNewContext(source, context);
const element = {
  contains: candidate => candidate === button,
  querySelector: selector => selector === '.copy-note' ? status : null,
  addEventListener: (name, callback) => listeners.set(name, callback),
  removeEventListener: (name, callback) => { assert.equal(listeners.get(name), callback); listeners.delete(name); }
};
const hook = {el: element};
context.window.SymphonyHooks.CopySuggestedPrompt.mounted.call(hook);
let prevented = 0;
const event = {target: {closest: () => button}, preventDefault: () => prevented++};
const first = listeners.get('click')(event);
assert.equal(writes.length, 1);
assert.equal(writes[0], prompt);
assert.equal(button.disabled, true);
assert.equal(status.textContent, 'Copy does not send.');
await listeners.get('click')(event);
assert.equal(writes.length, 1);
resolveCopy();
await first;
assert.match(status.textContent, /Copied.*nothing has been sent/);
assert.equal(button.disabled, false);
const second = listeners.get('click')(event);
rejectCopy(new Error('Clipboard denied'));
await second;
assert.equal(status.textContent, 'Copy unavailable. Nothing has been sent.');
assert.equal(button.disabled, false);
assert.equal(prevented, 2);
context.window.SymphonyHooks.CopySuggestedPrompt.destroyed.call(hook);
assert.equal(listeners.size, 0);
console.log('PASS: exact prompt copied only after click; success waits; duplicate clicks suppressed; refusal truthful; no send or navigation interface supplied.');

