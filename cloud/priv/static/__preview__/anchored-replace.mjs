// anchored-replace.mjs — the one door a source-text MUTATION may go through, and
// a census that finds the doors nobody used.
//
// WHY THIS FILE EXISTS
// ────────────────────
// A mutation test earns its keep by breaking the thing under test and watching the
// instrument notice. `String.prototype.replace` with a STRING needle takes the FIRST
// substring match anywhere in the receiver — it is not anchored to a line, not
// bounded to a span, and, when the needle has drifted, not applied at all. All three
// failures are SILENT: the run still produces a verdict, and that verdict is about a
// line the test does not name.
//
// The measured specimen: `seal-predicate.test.mjs` rewrapped a 4-space `if: always()`
// inside cloud.yml's `cloud-gate` job. cloud.yml then grew two STEP-level `if: always()`
// lines — 8 spaces — above `cloud-gate:`, and an 8-space line CONTAINS the 4-space
// needle. The rewrap landed on the first of them, cloud-gate's own line stayed bare,
// and the case reported GREEN having asserted nothing about its subject. Re-derive the
// collision for yourself:
//
//     grep -nE '^ *if: always\(\)$' .github/workflows/cloud.yml
//
// Two sibling arms carried the identical shape and were correct only by luck of file
// ordering. `assert.ok(src.includes(needle))` does not save you: `includes` proves AT
// LEAST ONE occurrence, never EXACTLY ONE, and the specimen above had two.
//
// THE CONTRACT
// ────────────
// Both helpers below REFUSE — they throw, they do not return a best guess — when the
// needle matches zero times or more than once inside the span they were given. A
// mutator that has stopped being well defined says so instead of picking one silently.
// `replaceWholeLine` adds the stricter requirement that the needle BE a line, matched
// with its bounding newlines, so a 4-space key can never resolve through an 8-space one.
//
// The census at the bottom is the part that does not depend on anyone remembering this
// paragraph: it walks a tree and reports every `.replace`/`.replaceAll` whose needle is
// a runtime expression rather than a literal and which does not come through this
// module. `anchored-replace.test.mjs` runs it against the shipped tree with a ratchet,
// and against a synthetic PRE-REPAIR specimen that it must flag — a scan that cannot
// say YES is indistinguishable from a clean tree, which is the exact mistake that let
// the specimen above live.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

// A refusal with a NAME, so a caller can tell "your mutation is ill-defined" from
// "the thing under test misbehaved". Every throw in this module is one of these.
export class MutationNeedleError extends Error {
  constructor(message, detail) {
    super(message);
    this.name = 'MutationNeedleError';
    Object.assign(this, detail);
  }
}

const resolveSpan = (text, span) => {
  if (!span) return { from: 0, to: text.length };
  const from = span.from ?? 0;
  const to = span.to ?? text.length;
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to > text.length || from > to) {
    throw new MutationNeedleError(
      `the span given to a mutation is not a range inside the text: from=${from} to=${to} length=${text.length}`,
      { from, to, length: text.length });
  }
  return { from, to };
};

const countOccurrences = (haystack, needle) => {
  let n = 0;
  for (let at = haystack.indexOf(needle); at !== -1; at = haystack.indexOf(needle, at + 1)) n++;
  return n;
};

// EXACTLY-ONE substring replacement, bounded to `span`.
//
// The three ways it refuses are the three ways a bare `.replace` loses quietly:
//   · zero matches  — the anchor drifted; the old code returned the text unchanged and
//                     the caller's `notEqual(mutated, src)` was the only thing between
//                     that and a vacuous green (and in a CHAIN of mutations, even that
//                     is satisfied by a sibling that did apply).
//   · two or more   — the old code picked the first one, which is a coin flip decided
//                     by file order, not by the test.
//   · out of span   — the match exists, but in someone else's job/function; the old
//                     code took it anyway because `replace` has no idea a span exists.
export const replaceUnique = (text, needle, replacement, opts = {}) => {
  const what = opts.what || 'mutation';
  if (typeof text !== 'string') throw new MutationNeedleError(`${what}: the text to mutate must be a string`);
  if (typeof needle !== 'string' || needle.length === 0) {
    throw new MutationNeedleError(`${what}: the needle must be a non-empty string — a regular expression cannot be counted here`, { needle });
  }
  const { from, to } = resolveSpan(text, opts.span);
  const window = text.slice(from, to);
  const hits = countOccurrences(window, needle);
  if (hits === 0) {
    throw new MutationNeedleError(
      `${what}: the needle matches NOTHING inside the span — the anchor has drifted, and an unapplied mutation proves nothing: ${JSON.stringify(needle)}`,
      { hits, needle, from, to });
  }
  if (hits > 1) {
    throw new MutationNeedleError(
      `${what}: the needle matches ${hits} times inside the span — which one the mutation lands on would be decided by file order, not by this test: ${JSON.stringify(needle)}`,
      { hits, needle, from, to });
  }
  const at = from + window.indexOf(needle);
  return `${text.slice(0, at)}${replacement}${text.slice(at + needle.length)}`;
};

// EXACTLY-ONE WHOLE-LINE replacement, bounded to `span`.
//
// The needle is the line's full text WITHOUT its newlines and WITH its indentation;
// it is matched with the newlines around it, so a shorter-indented key can never
// resolve through a deeper-indented one. That containment is the specimen this whole
// module is named after. First and last lines of the span are lines too — the span is
// treated as newline-terminated at both ends rather than quietly excluding them.
export const replaceWholeLine = (text, needle, replacement, opts = {}) => {
  const what = opts.what || 'whole-line mutation';
  if (typeof needle !== 'string' || needle.length === 0) {
    throw new MutationNeedleError(`${what}: the needle must be a non-empty string`, { needle });
  }
  if (needle.includes('\n')) {
    throw new MutationNeedleError(
      `${what}: a WHOLE-LINE needle cannot itself contain a newline — use replaceUnique for a multi-line anchor: ${JSON.stringify(needle)}`,
      { needle });
  }
  const { from, to } = resolveSpan(text, opts.span);
  // Pad the window so a match at either edge is still bracketed by newlines. The pad
  // is one character at each end, so an index in `padded` is `from + i - 1` in `text`.
  const padded = `\n${text.slice(from, to)}\n`;
  const bracketed = `\n${needle}\n`;
  const hits = countOccurrences(padded, bracketed);
  if (hits === 0) {
    const loose = countOccurrences(padded, needle);
    throw new MutationNeedleError(
      loose > 0
        ? `${what}: the needle appears ${loose} time(s) inside the span but never as a WHOLE LINE — it is a SUBSTRING of a longer line, which is precisely how a 4-space key resolves through an 8-space one: ${JSON.stringify(needle)}`
        : `${what}: the needle matches NOTHING inside the span — the anchor has drifted, and an unapplied mutation proves nothing: ${JSON.stringify(needle)}`,
      { hits, loose, needle, from, to });
  }
  if (hits > 1) {
    throw new MutationNeedleError(
      `${what}: the needle is a whole line ${hits} times inside the span — which one the mutation lands on would be decided by file order, not by this test: ${JSON.stringify(needle)}`,
      { hits, needle, from, to });
  }
  const at = from + padded.indexOf(bracketed) - 1; // -1 undoes the leading pad
  return `${text.slice(0, at + 1)}${replacement}${text.slice(at + 1 + needle.length)}`;
};

// ── THE CENSUS ──────────────────────────────────────────────────────────────
// Everything above is a contract nobody is obliged to use. This is what notices.
//
// It masks comments, string/template bodies and regular-expression literals so an
// offset in the masked view is known to be CODE, finds every `.replace(` /
// `.replaceAll(` call site in that view, and extracts the first argument by a
// balanced scan. The classification is of the NEEDLE, because the needle is what
// decides whether the call can land off target:
//
//   REGEX_ANCHORED    — a regex literal carrying `^` or `$`. Bounded by construction.
//   REGEX_UNANCHORED  — a regex literal with no anchor. First-match, but visibly so.
//   STRING_LITERAL    — a quoted/template literal needle, readable at the call site.
//   DYNAMIC           — an identifier, member expression or call. The needle is decided
//                       at RUN TIME, so no reader and no reviewer can see what it will
//                       match. This is the class the specimen belongs to, and the only
//                       class the ratchet in the test file governs.
//
// GUARDED is the sub-class of DYNAMIC that went through this module.

// Exported because every honest scanner over JS source needs the same first step:
// know which byte is CODE. Returns an array parallel to `src` of 'code' | 'str' |
// 'cmt' | 'rx'. A scanner that skips it reads the inside of a comment as a call site.
export const maskKinds = (src) => {
  const kind = new Array(src.length).fill('code');
  const prevSignificant = (at) => {
    for (let j = at - 1; j >= 0; j--) {
      if (kind[j] !== 'code') return null;
      if (/\s/.test(src[j])) continue;
      return src[j];
    }
    return null;
  };
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') {
      const e = src.indexOf('\n', i);
      const end = e === -1 ? src.length : e;
      for (let j = i; j < end; j++) kind[j] = 'cmt';
      i = end; continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      const e = src.indexOf('*/', i + 2);
      const end = e === -1 ? src.length : e + 2;
      for (let j = i; j < end; j++) kind[j] = 'cmt';
      i = end; continue;
    }
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < src.length) {
        if (src[j] === '\\') { j += 2; continue; }
        if (src[j] === c || src[j] === '\n') break;
        j++;
      }
      for (let k = i; k <= Math.min(j, src.length - 1); k++) kind[k] = 'str';
      i = j + 1; continue;
    }
    if (c === '`') {
      let j = i + 1;
      let depth = 0;
      while (j < src.length) {
        if (src[j] === '\\') { j += 2; continue; }
        if (src[j] === '$' && src[j + 1] === '{') { depth++; j += 2; continue; }
        if (depth > 0 && src[j] === '}') { depth--; j++; continue; }
        if (depth === 0 && src[j] === '`') break;
        j++;
      }
      for (let k = i; k <= Math.min(j, src.length - 1); k++) kind[k] = 'str';
      i = j + 1; continue;
    }
    if (c === '/') {
      // A `/` opens a regex only where an expression may begin. Anything that can END
      // an expression (identifier, `)`, `]`, digit) makes it division instead.
      const p = prevSignificant(i);
      if (p === null || /[=(,:[!&|?{};+\-*%<>~^]/.test(p)) {
        let j = i + 1;
        let inClass = false;
        let closed = false;
        while (j < src.length) {
          const d = src[j];
          if (d === '\\') { j += 2; continue; }
          if (d === '\n') break;
          if (inClass) { if (d === ']') inClass = false; j++; continue; }
          if (d === '[') { inClass = true; j++; continue; }
          if (d === '/') { closed = true; break; }
          j++;
        }
        if (closed) {
          let e = j + 1;
          while (e < src.length && /[a-z]/.test(src[e])) e++;
          for (let k = i; k < e; k++) kind[k] = 'rx';
          i = e; continue;
        }
      }
    }
    i++;
  }
  return kind;
};

const firstArgumentText = (src, openParen, kind) => {
  let depth = 0;
  let i = openParen;
  for (; i < src.length; i++) {
    const k = kind[i];
    if (k === 'str' || k === 'cmt' || k === 'rx') {
      while (i + 1 < src.length && kind[i + 1] === k) i++;
      continue;
    }
    const c = src[i];
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') { depth--; if (depth === 0) return src.slice(openParen + 1, i); }
    else if (c === ',' && depth === 1) return src.slice(openParen + 1, i);
  }
  return src.slice(openParen + 1, i);
};

const lineNumberAt = (src, idx) => {
  let n = 1;
  for (let i = 0; i < idx; i++) if (src[i] === '\n') n++;
  return n;
};

// Needles that reach a helper in this module are GUARDED wherever they are written —
// the call is the guard, so the receiver does not matter.
export const GUARDED_CALLEES = ['replaceUnique', 'replaceWholeLine'];

// Classify one file's source. Exported so the test can hand it a synthetic specimen
// without writing anything to disk.
export const classifySource = (src, file = '<memory>') => {
  const kind = maskKinds(src);
  const out = [];
  // A needle written as a bare identifier is only DYNAMIC to a reader who cannot see
  // its binding. When the same file binds it to a LITERAL, the reader can — so resolve
  // one hop and classify the literal. This keeps the DYNAMIC class meaning what it says:
  // a needle whose value no reviewer can read at the call site. It deliberately does NOT
  // follow imports or reassignments; anything it cannot resolve stays DYNAMIC, which is
  // the safe direction for a guard.
  const bindings = new Map();
  const bre = /\b(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*/g;
  let b;
  while ((b = bre.exec(src))) {
    if (kind[b.index] !== 'code') continue;
    let at = b.index + b[0].length;
    while (at < src.length && /\s/.test(src[at])) at++;
    const k = kind[at];
    if (k !== 'str' && k !== 'rx') continue;
    let end = at;
    while (end + 1 < src.length && kind[end + 1] === k) end++;
    // A rebound name is ambiguous; drop it rather than resolve to whichever came last.
    bindings.set(b[1], bindings.has(b[1]) ? null : src.slice(at, end + 1));
  }
  const re = /\.(replaceAll|replace)\s*\(/g;
  let m;
  while ((m = re.exec(src))) {
    if (kind[m.index] !== 'code') continue;
    const open = m.index + m[0].length - 1;
    const written = firstArgumentText(src, open, kind).trim();
    const bound = /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(written) ? bindings.get(written) : null;
    // A binding is followed ONLY to prove the needle is a REGULAR EXPRESSION, because
    // that is the one resolution that changes what `replace` DOES: a regex needle is
    // matched by pattern (and, with /g, everywhere), a string needle by first substring.
    // Following a binding to a STRING would not make the call any safer, so the class
    // stays on what is WRITTEN — the reader's own view of the call site.
    const resolved = bound && bound.startsWith('/') ? bound : written;
    let needleClass;
    if (resolved.startsWith('/') && resolved.lastIndexOf('/') > 0) {
      const body = resolved.slice(1, resolved.lastIndexOf('/'));
      needleClass = /[\^$]/.test(body) ? 'REGEX_ANCHORED' : 'REGEX_UNANCHORED';
    } else if (/^['"`]/.test(resolved)) {
      needleClass = 'STRING_LITERAL';
    } else {
      needleClass = 'DYNAMIC';
    }
    // The receiver: the expression immediately left of the dot.
    let s = m.index - 1;
    while (s >= 0 && /[A-Za-z0-9_$.\])]/.test(src[s])) s--;
    const receiver = src.slice(s + 1, m.index);
    out.push({
      file,
      line: lineNumberAt(src, m.index),
      needleClass,
      receiver,
      needle: written.replace(/\s+/g, ' ').slice(0, 120),
      resolvedNeedle: resolved === written ? null : resolved.replace(/\s+/g, ' ').slice(0, 120),
    });
  }
  // Calls to this module's helpers, counted so a file can prove it uses the door.
  for (const callee of GUARDED_CALLEES) {
    const cre = new RegExp(`\\b${callee}\\s*\\(`, 'g');
    let g;
    while ((g = cre.exec(src))) {
      if (kind[g.index] !== 'code') continue;
      out.push({ file, line: lineNumberAt(src, g.index), needleClass: 'GUARDED', receiver: callee, needle: '' });
    }
  }
  return out.sort((a, b) => a.line - b.line);
};

const walkSources = (dir, out = []) => {
  for (const entry of readdirSync(dir).sort()) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) walkSources(p, out);
    else if (/\.(mjs|js)$/.test(entry)) out.push(p);
  }
  return out;
};

// Walk a tree and classify every call site in it. `root` is a directory path.
export const censusTree = (root) => {
  const findings = [];
  for (const file of walkSources(root)) {
    findings.push(...classifySource(readFileSync(file, 'utf8'), file));
  }
  return findings;
};

// The reportable SET: needles that `String.prototype.replace` resolves by FIRST
// SUBSTRING MATCH — every string needle, whether it is written as a literal at the call
// site or computed at run time. Both land on the first occurrence anywhere in the
// receiver and both are silent when the needle has drifted; the literal is merely easier
// to read, which is not the same as being bounded. A regex needle is excluded because it
// is matched by PATTERN and its anchoring is visible in the literal itself.
//
// `location.replace(url)` and its kin are navigation, not string surgery. They are
// excluded by RECEIVER, named here, because a census that reports them teaches its
// readers to skim it.
export const NON_STRING_RECEIVERS = ['location', 'window.location', 'document.location', 'history'];

export const isBareStringNeedle = (f) =>
  (f.needleClass === 'DYNAMIC' || f.needleClass === 'STRING_LITERAL')
  && !NON_STRING_RECEIVERS.includes(f.receiver);

// WHAT THE RATCHET GOVERNS, as a predicate rather than a list: the test corpus and the
// instruments under __preview__. A mutation is something a TEST does to a copy of the
// subject; `app.js` is the subject, never the mutator, and a ratchet over it would red
// on console work that has nothing to do with this.
export const isGovernedPath = (file) => /\.test\.mjs$/.test(file) || file.includes('/__preview__/');

export const bareStringNeedlesByFile = (findings, { governedOnly = true } = {}) => {
  const byFile = new Map();
  for (const f of findings) {
    if (!isBareStringNeedle(f)) continue;
    if (governedOnly && !isGovernedPath(f.file)) continue;
    if (!byFile.has(f.file)) byFile.set(f.file, []);
    byFile.get(f.file).push(f);
  }
  return byFile;
};
