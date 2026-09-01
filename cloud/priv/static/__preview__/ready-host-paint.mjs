// ready-host-paint.mjs — THE RENDERED-HOST FLOOR, and the settle it was missing.
//
// ── WHAT THE FLOOR IS FOR (cchi-w20-bl-guard-greens-when-its-hosts-disappear) ─
// display:none keeps a node in the DOM: querySelector stays truthy, computed
// styles still read their specified values, and every rect is 0x0 — so `0 <= 0`
// scored 28/28 cells clean over 98 pills that no person could see. The floor is
// DERIVED from what each leg already declares: the literal selectors inside its
// own readyExpr. After readiness, every non-negated literal selector that
// MATCHES at least one node must also PAINT at least one non-zero box, or the
// guard refuses by name — the leg was about to certify an invisible screen.
//
// ── WHY IT ALSO NEEDED A SETTLE (task-e72560e947dba4e6) ──────────────────────
// The floor ran the INSTANT readiness flipped and filtered hosts through
// `checkVisibility({checkVisibilityCSS:true, checkOpacity:true})`. A host inside
// a CSS ENTRY ANIMATION whose first keyframe is `opacity: 0` is, at t=0, fully
// laid out and completely invisible — so the floor refused a screen that renders
// perfectly. app.css ships three such animations (modal-in 0.15s, toast-in
// 0.18s, new-detail-in 0.28s, each `from { opacity: 0 }`), and four of the last
// fifteen console-harness runs ON MAIN died this way on `.topbar` and
// `#a2f-error` — different selectors, different scenarios, different legs.
//
// MEASURED IN A REAL BROWSER, one element, one navigation (see
// fixtures/ready-host-paint/proof.sh, which re-runs this):
//     t+5ms    rect 300x40  opacity "0"         new-detail-in:running   NOT rendered
//     t+105ms  rect 300x40  opacity "0.674274"  new-detail-in:running   rendered
//     t+405ms  rect 300x40  opacity "1"         (no animations)         rendered
// The refusal is exit 2 — "the guard refused to measure, NO claim is being made
// about any screen" — so a genuine layout defect landing in the same run is
// INVISIBLE. That is worse than a flake: nobody can tell a refusing guard from
// a clean one, and the standing response to a red main is to re-run it.
//
// ── WHY THE REMEDY DOES NOT RE-OPEN THE HOLE ─────────────────────────────────
// The two states are DISTINGUISHABLE at the moment of judgment, and the same
// measurement separates them:
//     animating host   rect 300x40 (non-zero)   >=1 RUNNING animation
//     display:none     rect 0x0                 NO animations
// So the settle is CONDITIONAL on a running animation, never blanket. A
// display:none host has none, refuses on the FIRST pass, and spends no settle
// budget at all — the hole stays shut and stays fast. Nothing here drops
// `checkOpacity`; dropping it would re-open visibility:hidden and
// content-visibility:hidden, both of which this floor is measured to catch.
//
// ── AND WHY THAT WAS ONLY HALF OF IT (the residual, measured 2026-09-01) ─────
// Making the settle conditional on a RUNNING ANIMATION closed the entry-fade
// half and left the other half wide open. console-harness run 33474373014 on
// main died on:
//     READY HOST NOT PAINTED: ".topbar" … at /?scen=empty&theme=light
//     box 0x0, computed opacity "1", no animation running
// Nothing was animating, so the floor took the FAST refusal path — one probe,
// no settle, exit 2 — on a screen that renders perfectly.
//
// `.topbar` is `display: flex; height: 56px` (app.css). It CANNOT measure 0x0
// once it has been laid out. MEASURED on the real preview page, 18 refusals in
// 20 navigations at load 6.45 on 10 cpus, probed exactly where nav() judges:
//     box 0x0   getClientRects() []   display "flex"   readyState "loading"
//     +50ms     box 700x56            display "flex"   readyState "complete"
// The stylesheet is already applied — the host simply has NO LAYOUT BOX YET,
// because the document is still parsing. A guard that judges a host before the
// browser has laid it out is not measuring the screen; it is measuring how busy
// the runner was.
//
// So the settle now has a SECOND reason to wait, and the discrimination is
// again made from facts read on the same pass (all five committed fixtures
// measured, 6/6 runs each):
//     un-laid-out (the bug)   no box   display "flex"    readyState "loading"
//     display:none (the hole) no box   display "none"    readyState "complete"
//     zero-AREA (the hole)    HAS box  display "block"   readyState "complete"
//     animating               HAS box  display "block"   readyState "complete"
// Each of the three clauses in `notLaidOutYet` is independently sufficient to
// reject a hole-case, and ALL THREE must be explicitly present and affirmative
// to excuse a host — so a probe that lost a field refuses exactly as it did
// before. Absence of evidence is never an excuse here.
//
// The settle is BOUNDED rather than awaiting `animation.finished`, deliberately:
// app.css ships five INFINITE animations (fresh-pulse, new-spin, live-breathe,
// ov-pulse, deploy-rail-breathe) whose `finished` promise never resolves, so an
// await would hang the guard instead of refusing it. A bounded re-poll turns an
// infinite animation into a refusal that NAMES it, which is the honest outcome.

// Only LITERAL querySelector('...')/getElementById('...') strings contribute.
// HONEST LIMITS, stated rather than implied: (a) the floor runs at the NAV width
// — a width-scoped display:none inside a leg's own width loop is not caught here
// and stays each leg's own duty; (b) a readyExpr built from variables derives
// nothing; (c) a NEGATED selector (`!document.querySelector(...)` — a leg
// waiting on absence) is skipped, as is a selector matching zero nodes (an ||
// arm whose twin satisfied the gate); (d) a ZERO-HEIGHT CLIPPING ANCESTOR
// (height:0; overflow:hidden) passes this floor — child rects keep their
// laid-out sizes (measured: 102.4x28 under a 0-height .attention-list) and
// checkVisibility stays true, so that case remains each clip-walking leg's own
// duty. visibility:hidden and content-visibility:hidden ARE caught, via
// checkVisibility (measured: both flip it false while the rect area stays
// 2868px²).
export const READY_SELECTOR_RE =
  /(!?)\s*document\.(?:querySelector(?:All)?\(\s*'([^']+)'\s*\)|getElementById\(\s*'([^']+)'\s*\))/g;

// The settle budget. app.css's longest entry animation is new-detail-in at
// 0.28s; this is ~5x that, so a genuinely-animating host always wins and a host
// that is invisible for any OTHER reason still refuses promptly. It is a CAP on
// the refusal path only — a screen that paints on the first pass never waits.
export const SETTLE_CAP_MS = 1500;
export const SETTLE_POLL_MS = 50;

// Pull the literal, non-negated selectors out of a leg's own readiness
// expression. Order-preserving and de-duplicated so the refusal names them the
// way the leg wrote them.
export function readySelectorsFrom(readyExpr) {
  const sels = [];
  for (const m of String(readyExpr).matchAll(READY_SELECTOR_RE)) {
    if (m[1] === "!") continue;
    const q = m[2] != null ? m[2] : "#" + m[3];
    if (!sels.includes(q)) sels.push(q);
  }
  return sels;
}

// THE BROWSER PROBE. Returns one row per selector. `rendered` is the verdict the
// floor acts on; the rest is the DIAGNOSIS the refusal quotes, and it is
// gathered on the same pass on purpose — a refusal that re-queries the page
// would be describing a different moment than the one it judged.
export function paintProbeJs(sels) {
  return (
    `(function(){return ${JSON.stringify(sels)}.map(function(q){` +
    `var els=[].slice.call(document.querySelectorAll(q));` +
    `var rendered=els.filter(function(el){` +
    `var r=el.getBoundingClientRect();if(!(r.width>0&&r.height>0))return false;` +
    `return el.checkVisibility?el.checkVisibility({checkVisibilityCSS:true,checkOpacity:true}):true;` +
    `}).length;` +
    // Diagnosis from the FIRST match: its box, its computed opacity, and every
    // animation running on it, inside it, OR ON ANY ANCESTOR.
    //
    // THE ANCESTOR WALK IS NOT BELT-AND-BRACES — it is the majority case, and
    // omitting it was measured to defeat this whole fix. `getAnimations({
    // subtree:true })` returns the element's own animations and its
    // DESCENDANTS'; it does NOT climb. Two of the four observed main refusals
    // named `#a2f-error`, which does not animate — the `.modal` AROUND it
    // carries `modal-in`, and `checkOpacity` resolves against ancestor opacity.
    // A subtree-only query reports `opacity "1", no animation running` on that
    // host (measured: box 297x20, opacity "1", animations []) and the floor
    // refuses it as a display:none. fixtures/ready-host-paint/nested-modal.html
    // is that case, and proof.mjs fails without this walk.
    `var el=els[0];var box="",op="",disp="",laid=null,anims=[];` +
    `if(el){var r0=el.getBoundingClientRect();box=Math.round(r0.width)+"x"+Math.round(r0.height);` +
    // LAYOUT IS ASKED ABOUT DIRECTLY, not inferred from the box. A host that
    // layout HAS run for and given no area (zero-box.html: width:0;height:0)
    // returns one rect and is the ORIGINAL defect; a host layout has not
    // reached at all returns none. Both measure 0x0, and only this tells them
    // apart — which is the whole difference between the hole and the flake.
    `try{laid=el.getClientRects().length>0;}catch(e){laid=null;}` +
    `try{op=getComputedStyle(el).opacity;disp=getComputedStyle(el).display;}catch(e){op="";disp="";}` +
    `try{var seen=[],n=el;` +
    `while(n&&n.getAnimations){seen=seen.concat(n.getAnimations(n===el?{subtree:true}:{}));n=n.parentElement;}` +
    `anims=seen.filter(function(a){return a.playState==="running";})` +
    `.map(function(a){return String(a.animationName||"animation");})` +
    `.filter(function(v,i,arr){return arr.indexOf(v)===i;});}catch(e){anims=[];}}` +
    // `docReady` is a DOCUMENT fact stamped onto every row on purpose: it is
    // read in the SAME evaluate as the box it excuses. Reading it in a second
    // round trip would judge a box from one moment against a document state
    // from another — the exact race this floor keeps losing.
    `return {q:q, matches:els.length, rendered:rendered, box:box, opacity:op, display:disp, laidOut:laid, docReady:document.readyState, animations:anims};});})()`
  );
}

// HAS LAYOUT SIMPLY NOT REACHED THIS HOST YET?
//
// FAIL-CLOSED BY CONSTRUCTION: three clauses, each of which must be EXPLICITLY
// present and affirmative. A report missing any of them — an older probe, or one
// whose getComputedStyle threw — is not excused, so this can only ever turn
// refusals into waits for the one shape it was measured against.
//
// Each clause is the one that rejects a different committed fixture, so none of
// them is decoration and each reds a named test on its own:
//   laidOut === false    rejects zero-box.html, which layout HAS run for and
//                        deliberately given no area (the original 0 <= 0 defect)
//   display !== "none"   rejects display-none.html — the hole this floor exists
//                        for — even during a slow load, which is the angle a
//                        readyState-only excuse would have walked straight past
//   docReady incomplete  rejects every hole-case measured at "complete": once
//                        the document is done, a missing box is a VERDICT layout
//                        reached, not a moment layout has not
export function notLaidOutYet(r) {
  return (
    r.laidOut === false &&
    r.display !== "none" &&
    r.docReady != null &&
    r.docReady !== "complete"
  );
}

// PURE VERDICT over one probe report. Three outcomes, and the middle one is the
// whole fix:
//   ok      every matching selector paints — measure on.
//   settle  nothing that fails is BROKEN: each failing host either has a RUNNING
//           animation (mid-entry) or has not been laid out yet (mid-load). Both
//           are screens on their way up, not screens with a defect. Re-poll.
//   refuse  something fails with no reason to still be coming. That is the class
//           the floor exists for; refuse now, do not spend the settle budget.
//
// "A reason to still be coming" is the whole predicate, and it is deliberately
// narrow: a host is excused only by a fact that will EXPIRE on its own. An
// animation ends; a document finishes loading. Neither can excuse a host
// forever, so the cap below is a backstop rather than the thing doing the work.
export function stillArriving(r) {
  return (r.animations || []).length > 0 || notLaidOutYet(r);
}

export function paintVerdict(report) {
  const failing = (report || []).filter((r) => r.matches > 0 && r.rendered === 0);
  if (failing.length === 0) return { kind: "ok" };
  if (failing.every(stillArriving)) return { kind: "settle", failing };
  // MIXED IS A REFUSAL, not a settle. If even one failing host has no reason to
  // still be coming, the run has found the thing the floor is for, and waiting
  // would only delay saying so. The refusal names THAT host — never one that was
  // merely mid-entry or mid-load.
  return { kind: "refuse", failing, blame: failing.find((r) => !stillArriving(r)) };
}

// THE REFUSAL STRING. It leads with what was MEASURED on the host it blames —
// box, computed opacity, and any running animation — because the old wording
// named display:none, visibility:hidden and content-visibility:hidden only, and
// sent four main-run readers hunting through Chrome, the port and a keep-both
// merge for a cause that was none of those.
export function paintRefusal({ url, blame, waitedMs }) {
  const anims = (blame.animations || []);
  const measured =
    `box ${blame.box || "?"}, computed opacity ${blame.opacity === "" ? "?" : `"${blame.opacity}"`}` +
    (anims.length ? `, running animation${anims.length > 1 ? "s" : ""} ${anims.join(", ")}` : ", no animation running");
  // THREE CAUSES, THREE DISJOINT WORDINGS. No refusal may send the next reader
  // after another one's cause — the animating one must not mention display:none,
  // the display:none one must not mention an animation, and neither may claim a
  // missing layout box. ready-host-paint.test.mjs pins that disjointness in
  // both directions, because a refusal that names the wrong cause costs a person
  // the same hour a silent one does.
  const cause = anims.length
    ? `The host is STILL mid-animation after ${waitedMs}ms of settle (cap ${SETTLE_CAP_MS}ms) — ` +
      `an entry animation with a \`from { opacity: 0 }\` keyframe reads checkOpacity false while it runs, ` +
      `and an INFINITE animation never settles at all. Look at the animation named above, not at Chrome or the port.`
    : notLaidOutYet(blame)
      ? `The host never got a layout box: after ${waitedMs}ms of settle (cap ${SETTLE_CAP_MS}ms) it still has NO ` +
        `layout box while its own computed display is "${blame.display}" — not "none" — and the document is STILL ` +
        `"${blame.docReady}". A host parsed into the DOM before its first layout measures 0x0 with its stylesheet ` +
        `already applied, which is why the box below is not evidence of anything. Look at why this page never ` +
        `finished loading — a stalled asset, a script that never returned — not at Chrome or the port.`
      : `NOTHING is animating on this host, so it is the class this floor exists for: ` +
        `display:none keeps querySelector truthy while every rect is 0x0, and visibility:hidden / ` +
        `content-visibility:hidden keep the rect while checkVisibility reads false.`;
  return (
    `READY HOST NOT PAINTED: "${blame.q}" matches ${blame.matches} node(s) at ${url} and NONE paints a box — ` +
    `measured on the first match: ${measured}. ${cause} ` +
    `The readiness gate passed on a host a person cannot see; measuring on would certify an invisible ` +
    `screen, so this run refuses instead (cchi-w20-bl-guard-greens-when-its-hosts-disappear, ` +
    `settle added by task-e72560e947dba4e6).`
  );
}

// THE FLOOR. Injected with its browser (`evalJs`) and its clock (`sleep`) so the
// settle mechanics are provable without one — see ready-host-paint.test.mjs.
//
// FAIL-CLOSED: every path out of the loop either returns (measured) or throws
// (refused). There is no path on which an unpainted host is silently accepted,
// which is the assertion the test file pins hardest.
export async function assertReadyHostsPaint({
  url,
  readyExpr,
  evalJs,
  sleep,
  cap = SETTLE_CAP_MS,
  poll = SETTLE_POLL_MS,
  now = () => Date.now(),
  log = () => {},
}) {
  const sels = readySelectorsFrom(readyExpr);
  if (sels.length === 0) return;
  const js = paintProbeJs(sels);

  const t0 = now();
  let verdict = paintVerdict(await evalJs(js));
  let announced = false;

  while (verdict.kind === "settle" && now() - t0 < cap) {
    if (!announced) {
      announced = true;
      // SAID OUT LOUD, once. A settle that happened silently would make this
      // fix invisible in a green run, and the next person to see the guard get
      // slower would have nothing to read.
      // NAMED PER HOST, because the two reasons have different remedies and a
      // line that called an un-laid-out host "mid-animation" would send the
      // reader hunting for a keyframe that does not exist.
      const why = verdict.failing
        .map((r) => {
          const a = r.animations || [];
          return a.length
            ? `"${r.q}" mid-animation (${a.join(", ")})`
            : `"${r.q}" not laid out yet (document "${r.docReady}")`;
        })
        .join(", ");
      log(`   · ready-host floor settling on ${url} — ${why}\n`);
    }
    await sleep(poll);
    verdict = paintVerdict(await evalJs(js));
  }

  if (verdict.kind === "ok") return;
  // A settle that ran out of budget still has to blame someone: take the first
  // failing host, which is the one still animating.
  const blame = verdict.blame || verdict.failing[0];
  throw new Error(paintRefusal({ url, blame, waitedMs: now() - t0 }));
}
