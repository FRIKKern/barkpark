// same-document-nav-census.mjs — WHICH BROWSER CELLS CAN INHERIT THE PREVIOUS
// CELL'S DOM, AND THE ONE CALL THAT STOPS THEM.
//
// ── THE DEFECT (cch-w24-bl-hash-only-nav-is-same-document) ──────────────────
// The browser oracles in this directory drive their cells with CDP
// `Page.navigate`. Chrome performs a SAME-DOCUMENT navigation — the DOM, the
// script state, every injected stylesheet and every open dialog SURVIVE —
// whenever the target URL carries a fragment and is otherwise equal to the URL
// the page is already on. Two consequences a reader does not expect:
//
//   1. `…?scen=x#a` -> `…?scen=x#b` KEEPS the document. The second cell measures
//      the first cell's paint.
//   2. `…?scen=x#a` -> `…?scen=x#a` — the IDENTICAL url, navigated twice — is
//      ALSO same-document. A fragment-carrying URL never reloads itself, so a
//      "re-navigate and try again" retry does not re-navigate anything.
//
// It cost W24-s1 a false control: that leg's `#overview` control cell reported
// TWO `#cred-submit` hosts, because it was still holding the providers connect
// card the PREVIOUS cell had painted — a control that had inherited the very
// condition it is the control FOR. It was caught only because that leg asserts
// its control has exactly one host. A leg without such an assertion prints a
// plausible table over a stale DOM and nobody ever knows.
//
// W24-s1 fixed ITS OWN cells with a unique `cell=` query param — a difference
// OUTSIDE the fragment forces a real document load, and mock.js reads `scen` and
// nothing else off the page URL — and audited nothing else. This file is that
// audit, and it is deliberately TWO things:
//
//   THE FIX, at run time.  `createCrossDocumentNavigator()` sits inside each
//     instrument's own navigation helper. It remembers the URL the session is
//     on, applies Chrome's own rule to the next one, and when the answer is
//     "same-document" it rewrites the URL with a unique `cell=` tag so the load
//     is real. It also COUNTS what it caught, so a run says out loud how many
//     of its cells would have inherited a DOM. A guard nobody can forget to
//     apply to a new cell, because it is not per-cell.
//
//   THE NET, at edit time.  `census()` reads an instrument's SOURCE and reports
//     every navigation site, whether that site routes through a guarded helper,
//     and every consecutive pair whose URLs differ only by fragment. It is how a
//     RAW `cdp.send("Page.navigate", …)` added tomorrow — outside every guard —
//     gets caught. Where a URL is assembled from a runtime hole it says
//     UNRESOLVED rather than dropping the site: an unreadable site is a site a
//     human must rule on, and silence would be this very bug again.
//
// THE VERDICTS a navigation site can carry:
//   GUARDED  — it routes through a helper whose body calls the navigator above,
//              so no two consecutive cells can be equal-but-for-the-fragment.
//   CELL     — the call site itself interpolates a `cell=` param (W24-s1's own
//              three sites, which predate the guard and remain correct).
//   REASONED — a `// same-document-ok: <why>` annotation sits on, or within
//              ANNOTATION_LOOKBACK lines above, the call. The reason is carried
//              into the report, so the claim is READABLE and not merely counted.
//   OPEN     — none of the above. The census reds.
//
// Pure and browserless: same-document-nav-census.test.mjs drives every clause of
// it with `node --test` and no Chrome at all.

export const ANNOTATION_LOOKBACK = 4;
export const ANNOTATION = "same-document-ok:";
export const CELL_PARAM = "cell";

// ── 1. CHROME'S RULE, WRITTEN DOWN ───────────────────────────────────────────

/**
 * Would navigating from `prev` to `next` be a SAME-DOCUMENT navigation?
 *
 * The rule Blink applies: the destination must carry a fragment, and must be
 * equal to the current URL once both fragments are removed. Note what this does
 * NOT say — it does not require the two fragments to DIFFER. Navigating to the
 * exact URL you are already on, fragment included, is a fragment navigation and
 * keeps the document; that is why the identical-URL retry is on this list.
 *
 * `prev === null` (nothing navigated yet) is always cross-document: about:blank
 * shares no base with anything the harness serves.
 */
export function wouldBeSameDocument(prev, next) {
  if (!prev || !next) return false;
  const h = next.indexOf("#");
  if (h < 0) return false;
  return stripFragment(prev) === next.slice(0, h);
}

export function stripFragment(url) {
  const h = url.indexOf("#");
  return h < 0 ? url : url.slice(0, h);
}

/**
 * Put a per-cell discriminator OUTSIDE the fragment, which is the whole trick:
 * the base now differs, so Chrome must fetch and parse a new document.
 *
 * The param name and shape are W24-s1's, reused verbatim so there is exactly one
 * thing to grep for when someone asks "what is this `cell=1` in my URL".
 */
export function forceCrossDocument(url, tag) {
  const base = stripFragment(url);
  const frag = url.slice(base.length);
  const sep = base.includes("?") ? "&" : "?";
  return `${base}${sep}${CELL_PARAM}=${encodeURIComponent(String(tag))}${frag}`;
}

/**
 * The guard an instrument installs in its own navigation helper.
 *
 *   const cells = createCrossDocumentNavigator();
 *   await cdp.send("Page.navigate", { url: cells.next(url) }, sessionId);
 *   …
 *   process.stdout.write(cells.line());
 *
 * It is honest about doing nothing: on a run where no two consecutive cells were
 * equal-but-for-the-fragment, `caught` is 0 and `line()` says so. A guard that
 * only ever speaks when it fires cannot be distinguished from a guard that was
 * never wired in — and this directory has been burned by exactly that.
 */
export function createCrossDocumentNavigator(label = "cells") {
  let prev = null;
  const caught = [];
  return {
    label,
    get caught() { return caught.slice(); },
    get count() { return caught.length; },
    /**
     * Forget the current URL. An instrument that parks a FRESH target on
     * about:blank per cell (breakpoint-sweep does) must say so, or the guard
     * compares a new target's blank page against the old target's last URL and
     * rewrites a navigation that was already cross-document — a false positive
     * that would make the caught-count a lie in the safe direction.
     */
    reset() { prev = null; },
    /** The URL to actually navigate to. Rewrites only when it must. */
    next(url) {
      if (!wouldBeSameDocument(prev, url)) { prev = url; return url; }
      const tag = `sdn${caught.length + 1}`;
      const forced = forceCrossDocument(url, tag);
      caught.push({ from: prev, to: url, forced, tag });
      prev = forced;
      return forced;
    },
    /** One line for the run's output. ALWAYS printed, fired or not. */
    line() {
      if (!caught.length) {
        return `   · same-document guard: 0 of this run's navigations were fragment-only ` +
          `(no cell could inherit another's DOM)\n`;
      }
      return `   · same-document guard: ${caught.length} navigation(s) would have been ` +
        `FRAGMENT-ONLY and kept the previous cell's DOM — each was reloaded with a unique ` +
        `${CELL_PARAM}= tag:\n` +
        caught.map((c) => `       ${shortUrl(c.from)}  →  ${shortUrl(c.to)}\n`).join("");
    },
  };
}

const shortUrl = (u) => (u || "").replace(/^https?:\/\/[^/]+/, "");

// ── 2. THE NET, at edit time ─────────────────────────────────────────────────
// The navigation surfaces this directory actually has. `arg` is the 0-based
// argument index holding the URL; `kind: "cdp"` means the URL rides a CDP params
// object (`{ url }`) and has to be resolved through the property.
export const NAV_CALLEES = [
  { name: "nav", arg: 0, kind: "call" },
  { name: "navSettle", arg: 1, kind: "call" },
  { name: "Page.navigate", arg: 1, kind: "cdp" },
];

// ── argument slicing ─────────────────────────────────────────────────────────
// A hand-rolled scanner, because the argument we want is frequently a template
// literal containing `${…}` containing more strings — which is exactly the input
// a comma-split or a regex gets wrong, and getting it wrong here means SILENTLY
// censusing the wrong text.

/**
 * Split the argument list that starts at `open` (the index of `(`), returning
 * the source text of each top-level argument. Depth-aware across (), [], {},
 * quotes, template literals and their `${}` holes; comments are skipped.
 */
export function splitArgs(src, open) {
  const args = [];
  const st = [];            // open brackets, innermost last
  let start = open + 1;
  let i = open;
  const inTemplate = () => st.length > 0 && st[st.length - 1] === "template";
  while (i < src.length) {
    const c = src[i];
    // Inside a template literal only `\`` and `${` mean anything: a `(` or a
    // `,` there is TEXT, and treating it as syntax is precisely how a naive
    // splitter hands back half a URL.
    if (inTemplate()) {
      if (c === "\\") { i += 2; continue; }
      if (c === "`") { st.pop(); i++; continue; }
      if (c === "$" && src[i + 1] === "{") { st.push("hole"); i += 2; continue; }
      i++;
      continue;
    }
    if (c === "`") { st.push("template"); i++; continue; }
    if (c === '"' || c === "'") {
      const q = c;
      i++;
      while (i < src.length) {
        if (src[i] === "\\") { i += 2; continue; }
        if (src[i] === q) { i++; break; }
        i++;
      }
      continue;
    }
    if (c === "/" && src[i + 1] === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") { i = src.indexOf("*/", i + 2); i = i < 0 ? src.length : i + 2; continue; }
    if (c === "(" || c === "[" || c === "{") { st.push(c); i++; continue; }
    if (c === ")" || c === "]" || c === "}") {
      st.pop();
      if (st.length === 0) { args.push(src.slice(start, i)); return { args, end: i }; }
      i++;
      continue;
    }
    if (c === "," && st.length === 1) { args.push(src.slice(start, i)); start = i + 1; i++; continue; }
    i++;
  }
  return { args, end: -1 };
}

// ── segment scan ─────────────────────────────────────────────────────────────
// Reduce a URL EXPRESSION to a list of segments: LITERAL text the author typed,
// and EXPR holes whose value is only known at run time. Concatenation with `+`
// across several string/template pieces is flattened, because three of these
// instruments build their URL exactly that way.

/** @returns {{kind:"lit"|"expr", text:string}[]} */
export function segments(expr) {
  const out = [];
  let i = 0;
  const pushLit = (t) => { if (t) out.push({ kind: "lit", text: t }); };
  const pushExpr = (t) => { out.push({ kind: "expr", text: t.trim() }); };
  while (i < expr.length) {
    const c = expr[i];
    if (c === "`") {
      i++;
      let lit = "";
      while (i < expr.length && expr[i] !== "`") {
        if (expr[i] === "\\") { lit += expr[i + 1] ?? ""; i += 2; continue; }
        if (expr[i] === "$" && expr[i + 1] === "{") {
          pushLit(lit); lit = "";
          const { args, end } = splitArgs(expr, i + 1);
          pushExpr(args.join(","));
          i = end < 0 ? expr.length : end + 1;
          continue;
        }
        lit += expr[i]; i++;
      }
      pushLit(lit);
      i++;
      continue;
    }
    if (c === '"' || c === "'") {
      const q = c; i++;
      let lit = "";
      while (i < expr.length && expr[i] !== q) {
        if (expr[i] === "\\") { lit += expr[i + 1] ?? ""; i += 2; continue; }
        lit += expr[i]; i++;
      }
      pushLit(lit); i++;
      continue;
    }
    if (/\s/.test(c) || c === "+") { i++; continue; }
    if (c === "/" && expr[i + 1] === "/") { while (i < expr.length && expr[i] !== "\n") i++; continue; }
    if (c === "/" && expr[i + 1] === "*") { i = expr.indexOf("*/", i + 2); i = i < 0 ? expr.length : i + 2; continue; }
    // A bare expression: an identifier, a call, a ternary. Consume to the next
    // top-level `+` that is followed by a string/template, or to the end.
    let j = i, depth = 0, chunk = "";
    while (j < expr.length) {
      const d = expr[j];
      if (d === "(" || d === "[" || d === "{") depth++;
      else if (d === ")" || d === "]" || d === "}") depth--;
      else if (d === "`" || d === '"' || d === "'") {
        // a string inside the bare expression (a ternary arm) — swallow it
        const q = d; j++;
        while (j < expr.length && expr[j] !== q) { if (expr[j] === "\\") j++; j++; }
      } else if (d === "+" && depth === 0) {
        const rest = expr.slice(j + 1).trimStart();
        if (rest[0] === "`" || rest[0] === '"' || rest[0] === "'") break;
      }
      chunk += expr[j]; j++;
    }
    pushExpr(chunk);
    i = j + 1;
  }
  return out;
}

/**
 * Split a URL expression into its base and its fragment.
 * `frag === null` means UNRESOLVED: the fragment may be hiding inside a runtime
 * hole and this file refuses to guess which.
 */
export function splitFragment(expr) {
  const segs = segments(expr);
  let base = "";
  let holes = 0;
  for (let i = 0; i < segs.length; i++) {
    const s = segs[i];
    if (s.kind === "lit") {
      const h = s.text.indexOf("#");
      if (h >= 0) {
        base += s.text.slice(0, h);
        const tail = [{ kind: "lit", text: s.text.slice(h) }, ...segs.slice(i + 1)];
        return { base: base.trim(), frag: render(tail), resolved: true, segs };
      }
      base += s.text;
      continue;
    }
    // A RUNTIME HOLE IS KEPT IN THE BASE, rendered as its own source text, not
    // treated as the end of the world. `${BASE}` and `${theme}` sit BEFORE any
    // fragment in every instrument here, and bailing at the first hole would
    // make every site UNRESOLVED — a census that says "I cannot read anything"
    // is not a census. Two sites share a base when their base SOURCE TEXT
    // matches; that is a deliberately conservative rule (two textually equal
    // holes could hold different values at run time, which can only make this
    // file over-report, never miss).
    base += "${" + s.text + "}";
    holes++;
  }
  // No literal `#` anywhere. If a hole exists the fragment may be INSIDE it —
  // `${sc.deepLink}` is exactly that shape — and this file refuses to guess.
  return holes
    ? { base: base.trim(), frag: null, resolved: false, segs }
    : { base: base.trim(), frag: "", resolved: true, segs };
}

function render(segs) {
  return segs.map((s) => (s.kind === "lit" ? s.text : "${" + s.text + "}")).join("");
}

// A base carries a per-cell discriminator when it interpolates a `cell=` query
// param — W24-s1's fix, reused verbatim so there is ONE shape to grep for.
export function hasCellDiscriminator(segs) {
  for (let i = 0; i < segs.length - 1; i++) {
    if (segs[i].kind === "lit" && /[?&]cell=$/.test(segs[i].text) && segs[i + 1].kind === "expr") return true;
  }
  return false;
}

// ── site extraction ──────────────────────────────────────────────────────────

const lineOf = (src, idx) => src.slice(0, idx).split("\n").length;

/**
 * Every navigation site in one instrument's source, in SOURCE ORDER.
 * A `Page.navigate` whose params object uses the `{ url }` shorthand is resolved
 * one level, through the nearest preceding `const url =` — named, so a reader can
 * check the rule rather than trust the number.
 */
export function findNavSites(src) {
  const sites = [];
  const seen = new Set();
  for (const callee of NAV_CALLEES) {
    const needle = callee.kind === "cdp" ? `"Page.navigate"` : null;
    const re = callee.kind === "cdp"
      ? /cdp\.send\(\s*"Page\.navigate"/g
      : new RegExp(`\\bawait\\s+${callee.name}\\s*\\(`, "g");
    let m;
    while ((m = re.exec(src))) {
      const open = callee.kind === "cdp"
        ? src.indexOf("(", m.index + "cdp.send".length)
        : src.indexOf("(", m.index + m[0].length - 1);
      const { args } = splitArgs(src, open);
      let expr = (args[callee.arg] ?? "").trim();
      let via = callee.name;
      if (callee.kind === "cdp") {
        const prop = urlProperty(expr);
        if (prop === null) { expr = ""; }
        else if (/^[A-Za-z_$][\w$]*$/.test(prop)) {
          const resolved = resolveConstBefore(src, m.index, prop);
          if (resolved === null) { expr = prop; via = `Page.navigate(${prop} — UNRESOLVED binding)`; }
          else { expr = resolved; via = `Page.navigate(${prop})`; }
        } else expr = prop;
      }
      const key = `${m.index}`;
      if (seen.has(key)) continue;
      seen.add(key);
      sites.push({
        index: m.index,
        line: lineOf(src, m.index),
        callee: via,
        calleeName: callee.name,
        expr,
        annotation: annotationFor(src, m.index),
      });
      void needle;
    }
  }
  sites.sort((a, b) => a.index - b.index);
  return sites;
}

/** Pull the `url` property's expression out of a CDP params object literal. */
export function urlProperty(objSrc) {
  const s = objSrc.trim();
  if (!s.startsWith("{")) return null;
  const inner = s.slice(1, s.lastIndexOf("}"));
  const { args } = splitArgs("(" + inner + ")", 0);
  for (const a of args) {
    const t = a.trim();
    if (t === "url") return "url";
    const m = /^url\s*:/.exec(t);
    if (m) return t.slice(m[0].length).trim();
  }
  return null;
}

/** The nearest `const <name> = …;` declaration BEFORE `before`. */
export function resolveConstBefore(src, before, name) {
  const re = new RegExp(`\\b(?:const|let|var)\\s+${name}\\s*=`, "g");
  let m, last = -1;
  while ((m = re.exec(src)) && m.index < before) last = m.index + m[0].length;
  if (last < 0) return null;
  // Read to the terminating `;` at depth 0.
  const { args } = splitArgs("(" + src.slice(last).replace(/;/, ")") + ")", 0);
  return (args[0] ?? "").trim() || null;
}

function annotationFor(src, index) {
  const upto = src.slice(0, index).split("\n");
  const after = src.slice(index).split("\n")[0];
  const window = [...upto.slice(-ANNOTATION_LOOKBACK), after];
  for (const l of window) {
    const at = l.indexOf(ANNOTATION);
    if (at >= 0) return l.slice(at + ANNOTATION.length).trim();
  }
  return null;
}

// ── 3. THE CENSUS ────────────────────────────────────────────────────────────

/**
 * Which of this file's navigation helpers are GUARDED — i.e. declared here AND
 * routing through `createCrossDocumentNavigator`. Derived from the bytes, never
 * listed: a helper that loses its guard in a refactor stops being guarded in
 * this report on the same edit, which is the only way the report cannot rot.
 */
export function guardedCallees(src) {
  const guarded = new Set();
  for (const { name, kind } of NAV_CALLEES) {
    if (kind === "cdp") continue;
    const m = new RegExp(`\\b(?:const|let)\\s+${name}\\s*=`).exec(src);
    if (!m) continue;
    const body = bodyAfter(src, m.index);
    if (/\.next\s*\(/.test(body) && /createCrossDocumentNavigator/.test(src)) guarded.add(name);
  }
  return guarded;
}

/** The source of the arrow function declared at `at`, to its closing brace. */
export function bodyAfter(src, at) {
  const open = src.indexOf("{", src.indexOf("=>", at));
  if (open < 0) return "";
  const { end } = splitArgs(src, open);
  return end < 0 ? src.slice(open) : src.slice(open, end + 1);
}

export function verdictFor(site, guarded, src) {
  if (guarded.has(site.calleeName)) return "GUARDED";
  // A call site that hands the navigator's own output straight to Page.navigate
  // (`{ url: cells.next(url) }`) is guarded WITHOUT a wrapper helper — the shape
  // modal-oracle uses, since it navigates its one shared target inline.
  if (/\.next\s*\(/.test(site.expr) && /createCrossDocumentNavigator/.test(src)) return "GUARDED";
  const { segs } = splitFragment(site.expr);
  if (hasCellDiscriminator(segs)) return "CELL";
  if (site.annotation) return "REASONED";
  // A raw Page.navigate sitting INSIDE a guarded helper's own body is that
  // helper's single call site: it is guarded by construction, and counting it
  // again would double-count every cell in the file.
  if (site.inGuardedBody) return "GUARDED";
  void src;
  return "OPEN";
}

/**
 * The whole report for one instrument.
 *
 * `pairs` are the accusations, in two shapes, because a browser run has two ways
 * to put two navigations back to back:
 *   consecutive — site i then site i+1 in source order, same base text.
 *   self        — ONE site inside a loop whose fragment rides a runtime hole:
 *                 iteration N and N+1 are then a consecutive pair that can
 *                 differ only by fragment.
 * A pair inherits the WEAKER of its two sites' verdicts, so one unguarded site
 * is enough to red a pair.
 */
export function census(file, src) {
  const guarded = guardedCallees(src);
  const bodies = [...guarded].map((n) => {
    const m = new RegExp(`\\b(?:const|let)\\s+${n}\\s*=`).exec(src);
    const open = m ? src.indexOf("{", src.indexOf("=>", m.index)) : -1;
    const { end } = open >= 0 ? splitArgs(src, open) : { end: -1 };
    return open >= 0 && end > 0 ? [open, end] : null;
  }).filter(Boolean);

  const sites = findNavSites(src).map((s) => {
    const inGuardedBody = bodies.some(([a, b]) => s.index > a && s.index < b);
    const f = splitFragment(s.expr);
    const site = { ...s, ...f, inGuardedBody };
    return { ...site, verdict: verdictFor(site, guarded, src) };
  });

  const RANK = { OPEN: 0, REASONED: 1, CELL: 2, GUARDED: 3 };
  const weaker = (a, b) => (RANK[a] <= RANK[b] ? a : b);

  const pairs = [];
  for (let i = 0; i < sites.length - 1; i++) {
    const a = sites[i], b = sites[i + 1];
    if (!a.expr || !b.expr) continue;
    if (a.inGuardedBody || b.inGuardedBody) continue;
    if (norm(a.base) !== norm(b.base)) continue;
    // Identical base. Two fragment-less URLs are a RELOAD, which is
    // cross-document — the one benign case, and it is not an accusation.
    if (a.resolved && b.resolved && a.frag === "" && b.frag === "") continue;
    pairs.push({
      file, kind: "consecutive", aLine: a.line, bLine: b.line, base: a.base,
      fragA: a.resolved ? a.frag : "UNRESOLVED", fragB: b.resolved ? b.frag : "UNRESOLVED",
      verdict: weaker(a.verdict, b.verdict), reason: a.annotation || b.annotation || null,
    });
  }
  for (const s of sites) {
    if (!s.expr || s.inGuardedBody) continue;
    if (s.resolved) continue;   // a literal fragment cannot vary between iterations
    if (!s.base) continue;      // nothing fixed for the next iteration to be equal ON
    pairs.push({
      file, kind: "self", aLine: s.line, bLine: s.line, base: s.base,
      fragA: "UNRESOLVED", fragB: "UNRESOLVED", verdict: s.verdict, reason: s.annotation,
    });
  }
  return { file, guarded: [...guarded], sites, pairs, open: pairs.filter((p) => p.verdict === "OPEN") };
}

const norm = (s) => s.replace(/\s+/g, "");

export function formatCensus(reports) {
  let out = "";
  let open = 0;
  for (const r of reports) {
    out += `── ${r.file} ───\n`;
    if (!r.sites.length) {
      out += `   NO CDP NAVIGATION AT ALL — this instrument never calls Page.navigate, so no\n` +
        `   cell of it can inherit another's DOM. Nothing here to fix or to reason about.\n\n`;
      continue;
    }
    const by = { GUARDED: 0, CELL: 0, REASONED: 0, OPEN: 0 };
    for (const s of r.sites) by[s.verdict]++;
    out += `   navigation sites    ${r.sites.length}` +
      `  (GUARDED ${by.GUARDED} · CELL ${by.CELL} · REASONED ${by.REASONED} · OPEN ${by.OPEN})\n`;
    out += `   guarded helpers     ${r.guarded.length ? r.guarded.join(", ") : "none"}\n`;
    out += `   fragment-only pairs ${r.pairs.length} (open ${r.open.length})\n`;
    for (const p of r.pairs) {
      if (p.verdict === "OPEN") open++;
      out += `     ${p.verdict.padEnd(8)} ${p.kind.padEnd(11)} ` +
        `L${p.aLine}${p.kind === "self" ? " (next loop iteration)" : ` → L${p.bLine}`}` +
        `  ${p.fragA} → ${p.fragB}\n`;
      if (p.reason) out += `              because: ${p.reason}\n`;
    }
    out += "\n";
  }
  out += open
    ? `!! ${open} navigation pair(s) can inherit the previous cell's DOM. Route the call through\n` +
      `   a helper that uses createCrossDocumentNavigator(), or put a \`// ${ANNOTATION} <why>\`\n` +
      `   beside it saying why the inherited DOM cannot change what that cell measures.\n`
    : `OK — every navigation site is guarded, cell-discriminated, or carries a stated reason.\n`;
  return { text: out, open };
}

// The instruments this audit covers. hashchange-wiring.mjs is deliberately NOT
// on the roster: it is an oracle about the SPA's own `hashchange` listener, not
// a cell driver, and it drives no consecutive fragment-only cells because it
// makes no CDP navigation at all. Adding it would print the "NO CDP NAVIGATION"
// line above, which is a true but empty sentence.
export const AUDITED = [
  "overflow-guard.mjs",
  "breakpoint-sweep.mjs",
  "smoke.mjs",
  "modal-oracle.mjs",
  "cssom-parity.mjs",
];

/** Census the whole roster off disk. Node-only; everything above stays pure. */
export async function censusRoster(files = AUDITED) {
  const fs = await import("node:fs");
  return files.map((f) => census(f, fs.readFileSync(new URL(f, import.meta.url), "utf8")));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { text, open } = formatCensus(await censusRoster());
  process.stdout.write(text);
  process.exit(open ? 1 : 0);
}
