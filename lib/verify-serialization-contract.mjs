// Contract guards for the tool-result serialization path.
//
// Background: three separate bugs each produced the SAME user-visible message
// ("tool result must be losslessly JSON-serializable") while the real error was
// somewhere else entirely. All three were found by reading `dsh-tools`, not by
// reading our own code. These checks pin the upstream behaviour we depend on, so
// a future DSH upgrade that changes it fails here loudly instead of silently
// replacing real error messages with a serialization error.
//
// See docs/COMPATIBILITY.md section 7.
//
// Usage (peer deps linked first via lib/link-deps.ps1):
//   node lib/verify-serialization-contract.mjs
//
// Exits 0 when every contract still holds, 1 otherwise.

import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

// ---------------------------------------------------------------- host resolve
//
// Same auto-detection idea as link-deps.ps1: never hardcode one machine's
// install path, or the checks silently validate a different DSH than the one
// that runs.
const HERE = dirname(fileURLToPath(import.meta.url));
const CANDIDATES = [
  process.env.DSH_APP_DIR,
  process.env.DSH_APP_DIR && join(process.env.DSH_APP_DIR, 'resources', 'app'),
  'D:\\Program\\DSH\\DSH NEXT\\resources\\app',
  'C:\\Program Files\\DSH Desktop\\resources\\app.asar.unpacked',
  'C:\\Program Files\\DSH Desktop\\resources\\app',
  join(process.env.LOCALAPPDATA ?? '', 'Programs', 'DSH Desktop', 'resources', 'app.asar.unpacked'),
  join(process.env.LOCALAPPDATA ?? '', 'Programs', 'DSH Desktop', 'resources', 'app'),
].filter(Boolean);

function findHost() {
  for (const c of CANDIDATES) {
    const probe = join(c, 'node_modules', '@deepseek-ai', 'dsh-tools', 'package.json');
    if (existsSync(probe)) return c;
  }
  return null;
}

const HOST = findHost();
if (HOST === null) {
  console.error('SKIP: no DSH install found. Set DSH_APP_DIR to its resources/app directory.');
  process.exit(0);
}

function hostPkg(name) {
  return JSON.parse(readFileSync(join(HOST, 'node_modules', '@deepseek-ai', name, 'package.json'), 'utf8'));
}

const toolsVersion = hostPkg('dsh-tools').version;
console.log(`DSH app dir : ${HOST}`);
console.log(`dsh-tools   : ${toolsVersion}`);

const { snapshotJsonValue } = await import(
  new URL(`file:///${join(HOST, 'node_modules', '@deepseek-ai', 'dsh-util-values', 'lib', 'index.js').replace(/\\/g, '/')}`).href
);

// --------------------------------------------------------------------- harness

let pass = 0;
const failures = [];

function check(name, fn) {
  try {
    fn();
    pass += 1;
    console.log(`  PASS  ${name}`);
  } catch (err) {
    failures.push(`${name} -- ${err.message}`);
    console.log(`  FAIL  ${name}`);
    console.log(`        -> ${err.message}`);
  }
}

function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${label}: expected ${e}, got ${a}`);
}

// ------------------------------------------------- 1. the validator's rule set
//
// What snapshotJsonValue accepts and rejects. Our fix depends on `undefined`
// values being rejected (that is the whole failure mode) and on `null` being
// accepted (we use null where a value is unknown).

console.log('\n[1] snapshotJsonValue accepts / rejects');

const okCases = {
  'plain object': { a: 1, b: 'x' },
  'null value': { a: null },
  'nested null': { a: { b: null } },
  'empty array': [],
  'array of null': [null, null],
  'empty string': { a: '' },
  'zero and false': { a: 0, b: false },
};
for (const [label, value] of Object.entries(okCases)) {
  check(`accepts ${label}`, () => {
    if (snapshotJsonValue(value) === undefined) throw new Error('rejected, expected accepted');
  });
}

const badCases = {
  'undefined property': { a: undefined },
  'undefined nested one level down': { a: { b: undefined } },
  'undefined inside an array': { a: [undefined] },
  'NaN': { a: Number.NaN },
  'Infinity': { a: Number.POSITIVE_INFINITY },
  'function': { a: () => {} },
  'Symbol value': { a: Symbol('s') },
  'BigInt': { a: 1n },
  'Date instance': { a: new Date(0) },
};
for (const [label, value] of Object.entries(badCases)) {
  check(`rejects ${label}`, () => {
    if (snapshotJsonValue(value) !== undefined) throw new Error('accepted, expected rejected');
  });
}

// The validator never throws on its own — it returns undefined. Callers decide.
check('rejection is a return value, not a throw', () => {
  const v = snapshotJsonValue({ a: undefined });
  if (v !== undefined) throw new Error('expected undefined');
});

// ---------------------------------------------- 2. the applyFinalContent caller
//
// Transcribed verbatim from dsh-tools/lib/index.js:3399-3407. The load-bearing
// fact is that line 3402 does NOT await. If a future DSH awaits it, the async
// trap below stops being a trap — this check tells us either way.

console.log('\n[2] applyFinalContent does not await finalizeContent');

const toolsSource = readFileSync(join(HOST, 'node_modules', '@deepseek-ai', 'dsh-tools', 'lib', 'index.js'), 'utf8');

check('applyFinalContent calls the hook without await', () => {
  // Anchor on the method signature and read to the end of its body. Indentation
  // and brace style are upstream's business, so match on the closing brace at
  // the same tab depth rather than on a fixed indent count.
  const start = toolsSource.indexOf('\tapplyFinalContent(exec, result) {');
  if (start === -1) throw new Error('applyFinalContent(exec, result) not found -- upstream refactored');
  const end = toolsSource.indexOf('\n\t}', start);
  if (end === -1) throw new Error('could not find the end of applyFinalContent -- upstream refactored');
  const body = toolsSource.slice(start, end);

  if (!/finalizeContent\(exec, result\)/.test(body)) {
    throw new Error('the hook call was not found in the body');
  }
  if (/await\s+finalizeContent\s*\(/.test(body)) {
    throw new Error('upstream now awaits the hook; the async trap is closed and COMPATIBILITY 7.5 needs updating');
  }
});

// Replicate the caller so the trap can be demonstrated, not just asserted.
function applyFinalContent(finalizeContent, exec, result) {
  if (finalizeContent === undefined) return result;
  const content = finalizeContent(exec, result); // no await — mirrors line 3402
  return content === undefined ? result : { ...result, content };
}

function materializePresentation(candidate) {
  const detached = snapshotJsonValue(candidate);
  if (detached === undefined) {
    throw new TypeError('tool result must be losslessly JSON-serializable');
  }
  return detached;
}

// ---------------------------------------------------- 3. the async trap (7.5)

console.log('\n[3] async finalizeContent is rejected, sync passes');

const exec = { name: 'desktop_capture' };
const baseResult = { content: [{ type: 'text', text: 'captured 2880x1800' }] };
const THE_ERROR = 'tool result must be losslessly JSON-serializable';

const asyncFinalizer = async (e, r) => [...r.content, { type: 'image', attachment: 'x' }];
const syncFinalizer = (e, r) => [...r.content, { type: 'image', attachment: 'x' }];

check('async finalizer produces a Promise that the validator rejects', () => {
  const wrapped = applyFinalContent(asyncFinalizer, exec, baseResult);
  if (!(wrapped.content instanceof Promise)) throw new Error('expected a Promise at the call site');
  if (snapshotJsonValue(wrapped.content) !== undefined) throw new Error('Promise was accepted');
  let threw = null;
  try { materializePresentation(wrapped); } catch (e) { threw = e.message; }
  if (threw === null) throw new Error('expected the materialization to throw');
  eq(threw, THE_ERROR, 'error message');
});

check('sync finalizer passes', () => {
  const wrapped = applyFinalContent(syncFinalizer, exec, baseResult);
  if (!Array.isArray(wrapped.content)) throw new Error('expected an array');
  materializePresentation(wrapped);
});

check('awaiting before inspecting hides the bug (why review misses it)', async () => {
  // Not an assertion about behaviour we want -- it documents the false negative.
  const wrapped = applyFinalContent(asyncFinalizer, exec, baseResult);
  const awaited = await wrapped.content;
  if (!Array.isArray(awaited)) throw new Error('expected the awaited value to look fine');
});

// The shipped hook must itself be synchronous. Read our own source rather than
// importing it, so this guard needs no DSH runtime context.
console.log('\n[4] our own finalizeContent is synchronous');

check('lib/index.js does not declare an async finalizeContent', () => {
  const src = readFileSync(join(HERE, 'index.js'), 'utf8');
  if (/async\s+finalizeContent\s*\(/.test(src)) {
    throw new Error('finalizeContent is async again -- see docs/COMPATIBILITY.md 7.5');
  }
  if (!/\bfinalizeContent\s*\(/.test(src)) throw new Error('finalizeContent not found at all');
});

// --------------------------------------------------- 5. the `code` in-trap (7.3)

console.log('\n[5] an undefined property is invisible to JSON but visible to `in`');

check('assigning undefined creates the property', () => {
  const bad = new Error('boom');
  bad.code = undefined;
  if (!('code' in bad)) throw new Error('expected `in` to see it');
  eq(Object.keys(bad), ['code'], 'Object.keys');
  eq(JSON.parse(JSON.stringify(bad)).code, undefined, 'JSON round-trip drops it');
  if ('code' in JSON.parse(JSON.stringify(bad))) throw new Error('expected JSON to drop it');
});

check('guarded assignment does not create the property', () => {
  const good = new Error('boom');
  const code = undefined;
  if (code !== undefined && code !== null && code !== '') good.code = code;
  if ('code' in good) throw new Error('expected no code property');
});

// The shipped EngineError must use the guarded form.
check('EngineError guards its code assignment', () => {
  const src = readFileSync(join(HERE, 'index.js'), 'utf8');
  if (/this\.code\s*=\s*payload\.code\s*;/.test(src)) {
    throw new Error('EngineError assigns code unconditionally -- see docs/COMPATIBILITY.md 7.3');
  }
});

// ---------------------------------------------------------------------- verdict

console.log('');
if (failures.length === 0) {
  console.log(`=== 结果：${pass} 通过 / 0 失败 ===`);
  process.exit(0);
}
console.log(`=== 结果：${pass} 通过 / ${failures.length} 失败 ===`);
for (const f of failures) console.log(`  ${f}`);
process.exit(1);
