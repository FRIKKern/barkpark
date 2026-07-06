// tooling/risk/fn-coverage.mjs — per-PUBLIC-function coverage, from data already
// on disk (zero new test runs). It sharpens the Tested dimension's ¬coverage
// EVIDENCE: a 0%-covered public fn inside a high-% file is a masking defect the
// file rollup hides (the pane_builder / find_doc_path case). NOT a new axis —
// risk.mjs folds the WORST public fn into the same reach × ¬coverage composite.
//
// Two pure parsers, no I/O, so they unit-test trivially:
//   elixirFnCov(html)         ← api/cover/Elixir.<Module>.html row-stream
//   jsFnCov(fileCoverage)     ← one file's Istanbul entry (fnMap + f)
// Both return [{ name, startLine, endLine, hit, miss, pct, exported:true }] for
// PUBLIC functions only, pct = hit/(hit+miss)*100. Fns with NO coverable line are
// omitted (a fn with nothing to cover is not a coverage gap).

const decode = (s) => String(s)
  .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
  .replace(/&#0?39;/g, "'").replace(/&#0?96;/g, "`").replace(/&amp;/g, "&");

// A public Elixir fn header: `def name` — NOT `defp` (private), NOT `defmodule`,
// NOT `defmacro*` (the `\s` after `def` excludes defmodule/defp/defmacro, which
// have no space at that position). Captures the fn name.
const PUB_DEF = /^\s*def\s+([a-zA-Z_][a-zA-Z0-9_?!]*)/;
// Any def-family header that CLOSES the current public span (private clause or a
// new module) — private lines must not bucket into a public fn.
const PRIV_DEF = /^\s*(defp|defmacrop)\s+[a-zA-Z_]/;
const MODULE = /^\s*defmodule\s/;

// Parse the Elixir `mix test --cover` HTML row-stream into per-public-fn coverage.
// Each <tr> carries: class hit|miss|(none=non-coverable), line id="L{n}", and the
// source <code>. Walk rows top-down maintaining the open public-fn span; multi-
// clause `def foo` collapses to the union span for foo (symbols.json semantics).
export function elixirFnCov(html) {
  const ROW = /<tr(?:\s+class="(\w+)")?>\s*<td class="line" id="L(\d+)">.*?<td class="source"><code>(.*?)<\/code>/gs;
  const byName = new Map();      // name -> span (collapses clauses)
  const order = [];
  let current = null;
  let m;
  while ((m = ROW.exec(html))) {
    const cls = m[1] || null;         // "hit" | "miss" | null (non-coverable)
    const line = +m[2];
    const src = decode(m[3]);
    const pub = src.match(PUB_DEF);
    if (pub) {
      const name = pub[1];
      current = byName.get(name);
      if (!current) { current = { name, startLine: line, endLine: line, hit: 0, miss: 0, exported: true }; byName.set(name, current); order.push(current); }
      // fall through: the def header line itself is coverable (e.g. `def build` L39 hit=12)
    } else if (PRIV_DEF.test(src) || MODULE.test(src)) {
      current = null;                 // private clause / module boundary closes the public span
      continue;
    }
    if (current && cls) {             // bucket a coverable (hit|miss) line into the open span
      if (cls === "hit") current.hit++;
      else if (cls === "miss") current.miss++;
      if (line > current.endLine) current.endLine = line;
    }
  }
  const out = [];
  for (const s of order) {
    const cov = s.hit + s.miss;
    if (!cov) continue;               // no coverable line → not a coverage gap
    out.push({ ...s, pct: Math.round((s.hit / cov) * 100) });
  }
  return out;
}

// Per-public-fn coverage from a single file's Istanbul entry (data.fnMap + data.f).
// Istanbul gives CALL COUNTS, not line %; treat a 0-call fn as 0% (hit=0, miss=1)
// and a called one as 100%.
//
// HEURISTIC, not exhaustive: Istanbul's fnMap lists EVERY function — exports,
// inner helpers, AND anonymous callbacks — with no exported flag. We can't do
// true export analysis from the coverage dump, so we approximate "public surface"
// by NAME: drop anonymous fns (Istanbul names them "" or "(anonymous_N)") since an
// unnamed callback is never a named API a caller could target. Named inner helpers
// still slip through — an uncalled named fn is at least a plausible dead/untested
// signal — so `exported` here means "named", not "confirmed re-exported". Elixir
// (the motivating case) is exact via `def`/`defp`; JS stays a lean best-effort.
const JS_ANON = /^\(?anonymous/i;
export function jsFnCov(fileCoverage) {
  const fnMap = fileCoverage?.fnMap || {};
  const f = fileCoverage?.f || {};
  const out = [];
  for (const [id, fn] of Object.entries(fnMap)) {
    const name = fn.name || "";
    if (!name || JS_ANON.test(name)) continue;   // anonymous → not a named public surface
    const called = (f[id] || 0) > 0;
    const decl = fn.decl || fn.loc || {};
    out.push({
      name,
      startLine: decl.start?.line ?? fn.line ?? 0,
      endLine: decl.end?.line ?? decl.start?.line ?? fn.line ?? 0,
      hit: called ? 1 : 0, miss: called ? 0 : 1,
      pct: called ? 100 : 0, exported: true,
    });
  }
  return out;
}
