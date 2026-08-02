// font-pin.mjs — the console harness's FONT PIN (charter D218/D257).
//
// WHY THIS FILE EXISTS
// ────────────────────
// Every pixel this epic has ever printed is a layout of whatever typeface
// happened to have arrived by the time the instrument measured. No instrument
// awaited `document.fonts.ready` and none asserted WHICH face resolved, so a
// green was only ever "this screen fits in SOME font". Swap the face and every
// number moves; drop a woff2 and the guard measures the fallback and still says
// PASS. That is a guard whose fixture cannot produce the defect — green by
// construction.
//
// THREE THINGS MAKE THIS PIN DIFFERENT FROM THE OBVIOUS ONE
// ─────────────────────────────────────────────────────────
// (a) EVERY SHIPPED WEIGHT, and the list is DERIVED, not typed. `cloud/priv/
//     static/fonts/` ships FOUR woff2 files — Inter-var.woff2 (one variable
//     file, `font-weight: 100 900`) and THREE separate IBM Plex Mono files
//     (Regular=400, Medium=500, SemiBold=600). A pin that asserts "two
//     families" or "Plex 400 + 500" is BLIND to a missing
//     IBMPlexMono-SemiBold-latin.woff2 — measured: rc 0, output byte-identical
//     to baseline — and that file is load-bearing CSS, `var(--mono)` at
//     `font-weight: 600` in `.set-row-key` (app.css:2178), `.cm-name` (:3760)
//     and the provider identity value (:1938). So the pin walks the page's OWN
//     `document.fonts` set: every declared @font-face gets loaded and checked,
//     and a weight added to app.css tomorrow is covered without editing this
//     file. EXPECTED_FACES below is the floor that stops the derivation from
//     silently shrinking to zero — see its own comment.
//
// (b) `load()` IS NECESSARY, not belt-and-braces. Measured on a fresh nav to
//     the real shell, on two scenarios: awaiting `document.fonts.ready` ALONE
//     reports {"status":"loaded","size":4,inter:true,mono400:true,
//     mono500:false,mono600:false} — the promise resolves happily while two
//     SHIPPED weights read false, because nothing painted so far has requested
//     them. A ready-only pin asserting the 500 weight would REFUSE a healthy
//     page. Active `load()` first, THEN `ready`, then `check()`.
//
// (c) THE MONO HALF IS UNPROVABLE BY PIXEL, so the face assertion is the only
//     mechanism that can ever see a mono regression. On Linux the generic
//     -monospace fallback is DejaVu Sans Mono — `fc-match monospace` says so on
//     ubuntu:24.04 with google-chrome-stable installed (the package
//     console-harness.yml pins), and the browser agrees: its `monospace`
//     advance is bit-identical to its "DejaVu Sans Mono" advance. Measured on
//     Chromium 151.0.7922.71 headless, the 50-char string
//     "https://fleet-eu-central-1.barkpark.cloud/i/abc123" at 400 12px:
//
//       IBM Plex Mono   360.0029px      generic (DejaVu)  361.2305px
//       delta +1.2276px over 50 chars = +0.341% = 0.0246px PER CHARACTER
//
//     macOS lands on the same number (359.9998 vs 361.2305; its generic
//     resolves to Menlo, which carries DejaVu's 0.602em advance). No assertion
//     in this harness has a threshold that fine — a wholesale face substitution
//     moves less than a quarter of a device pixel per ten characters. So quote
//     the MUTATION (rc=2 naming `IBM Plex Mono=false`), never a px delta: the
//     pixel cannot see this, and `document.fonts.check` is the only thing that
//     can.
//
// USED BY: overflow-guard.mjs (nav()), breakpoint-sweep.mjs (navSettle()) and
// modal-oracle.mjs (its inline Page.navigate). cssom-parity.mjs is deliberately
// OUT — it never navigates and keeps only `selectorText` strings, and a face
// cannot move a selector string.
//
// REFUSAL IS EXIT 2 IN ALL THREE CALLERS. A missing font file is an
// ENVIRONMENT fault; reporting it as exit 1 would dress an environment fault up
// as a screen defect, which is exactly the confusion this epic exists to end.

// The floor. Derivation from `document.fonts` is what keeps the pin honest as
// app.css grows, but a derived-only pin greens on an EMPTY set — delete the
// @font-face block and there is nothing to fail. These counts come from disk:
//
//   $ ls cloud/priv/static/fonts/
//   IBMPlexMono-Medium-latin.woff2      IBMPlexMono-Regular-latin.woff2
//   IBMPlexMono-OFL.txt                 IBMPlexMono-SemiBold-latin.woff2
//   Inter-OFL.txt                       Inter-var.woff2
//
// one Inter face (variable, 100-900) and three IBM Plex Mono faces. Fewer
// declared faces than this is a REFUSAL, not a pass.
export const EXPECTED_FACES = [
  { family: "Inter", min: 1 },
  { family: "IBM Plex Mono", min: 3 },
];

// The pin itself, as one page-side expression. Async — every caller must
// evaluate it with `awaitPromise: true` (both existing evalJs helpers pass
// awaitPromise false/undefined, so each caller opens its own Runtime.evaluate).
//
// Returns { ok, status, size, faces[], families[], summary } — never throws for
// a missing font: a face that fails to load resolves as status "error", which
// is a VERDICT the caller reports, not an exception the caller's catch would
// remap to exit 1.
export const FONT_PIN_JS = `(async () => {
  var expected = ${JSON.stringify(EXPECTED_FACES)};
  var unquote = function (s) { return String(s || "").replace(/^['"]|['"]$/g, ""); };
  // A declared face's own load(), for EVERY declared weight — not a guess at
  // which weights matter. face.weight is "400" or a variable range "100 900";
  // the first number is a weight the face genuinely covers.
  var faces = Array.from(document.fonts).map(function (f) {
    return { face: f, family: unquote(f.family), weight: String(f.weight || "400"), style: String(f.style || "normal") };
  });
  var probeWeight = function (w) { var m = String(w).match(/-?\\d+(\\.\\d+)?/); return m ? m[0] : "400"; };
  await Promise.all(faces.map(function (e) {
    // load() REJECTS when the woff2 is gone. Swallow it here: e.face.status
    // carries the same fact as data, and the caller owns the verdict.
    return e.face.load().catch(function () {});
  }));
  await document.fonts.ready;
  var report = faces.map(function (e) {
    var spec = probeWeight(e.weight) + " 16px \\"" + e.family + "\\"";
    var checked = false;
    try { checked = document.fonts.check(spec); } catch (err) { checked = false; }
    return { family: e.family, weight: e.weight, style: e.style, status: String(e.face.status), check: checked, ok: e.face.status === "loaded" && checked };
  });
  var families = expected.map(function (x) {
    var mine = report.filter(function (r) { return r.family === x.family; });
    return {
      family: x.family,
      declared: mine.length,
      expected: x.min,
      ok: mine.length >= x.min && mine.every(function (r) { return r.ok; }),
      weights: mine.map(function (r) { return r.weight + (r.ok ? "=ok" : "=" + r.status + "/check:" + r.check); }),
    };
  });
  return {
    ok: families.every(function (f) { return f.ok; }),
    status: String(document.fonts.status),
    size: document.fonts.size,
    faces: report,
    families: families,
    summary: families.map(function (f) { return f.family + "=" + (f.ok ? "true" : "false"); }).join(" "),
  };
})()`;

// The refusal line, shared so all three instruments speak with one voice and a
// grep for the string finds every site. `where` is the URL under measurement —
// an environment fault reads far better with the nav that exposed it.
//
// NAMES WHICH FACE FAILED, always: "Inter=true IBM Plex Mono=false" plus the
// per-weight detail, because "fonts not ready" would send a reader looking at
// the network when the fact is that one file is off disk.
//
// It does NOT name the instrument — all three callers already prefix their own
// name (overflow-guard's and the sweep's die(), the oracle's hand-rolled exit-2
// block), and a second copy of it read as a stutter.
export function fontPinRefusal(where, report) {
  if (!report || typeof report !== "object") {
    return `FONT PIN could not run on ${where} — the page returned ${JSON.stringify(report)}. ` +
      `Environment refusal (exit 2), not a screen defect.`;
  }
  const detail = (report.families || [])
    .map((f) => `${f.family} [declared ${f.declared}/${f.expected} face(s): ${(f.weights || []).join(", ") || "none"}]`)
    .join(" · ");
  return `FONT PIN REFUSED on ${where} — ${report.summary || "no summary"}. ` +
    `${detail}. document.fonts.status=${report.status} size=${report.size}. ` +
    `Every px this harness prints is a layout of the face that actually resolved, so a missing or ` +
    `substituted face makes the measurement a fiction — this is an ENVIRONMENT refusal (exit 2), ` +
    `NOT a measured screen defect (exit 1). Check cloud/priv/static/fonts/ against the @font-face ` +
    `block at the top of cloud/priv/static/app.css.`;
}
