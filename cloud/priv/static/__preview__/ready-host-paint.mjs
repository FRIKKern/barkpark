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
    `var el=els[0];var box="",op="",anims=[];` +
    `if(el){var r0=el.getBoundingClientRect();box=Math.round(r0.width)+"x"+Math.round(r0.height);` +
    `try{op=getComputedStyle(el).opacity;}catch(e){op="";}` +
    `try{var seen=[],n=el;` +
    `while(n&&n.getAnimations){seen=seen.concat(n.getAnimations(n===el?{subtree:true}:{}));n=n.parentElement;}` +
    `anims=seen.filter(function(a){return a.playState==="running";})` +
    `.map(function(a){return String(a.animationName||"animation");})` +
    `.filter(function(v,i,arr){return arr.indexOf(v)===i;});}catch(e){anims=[];}}` +
    `return {q:q, matches:els.length, rendered:rendered, box:box, opacity:op, animations:anims};});})()`
  );
}

// PURE VERDICT over one probe report. Three outcomes, and the middle one is the
// whole fix:
//   ok      every matching selector paints — measure on.
//   settle  something does not paint YET, and it has a RUNNING animation, so the
//           screen is mid-entry rather than broken. Re-poll.
//   refuse  something does not paint and nothing is animating. That is the class
//           the floor exists for; refuse now, do not spend the settle budget.
export function paintVerdict(report) {
  const failing = (report || []).filter((r) => r.matches > 0 && r.rendered === 0);
  if (failing.length === 0) return { kind: "ok" };
  const animating = failing.filter((r) => (r.animations || []).length > 0);
  if (animating.length === failing.length) return { kind: "settle", failing };
  // MIXED IS A REFUSAL, not a settle. If even one failing host has no animation
  // to explain it, the run has found the thing the floor is for, and waiting
  // would only delay saying so. The refusal names the non-animating host.
  return { kind: "refuse", failing, blame: failing.find((r) => (r.animations || []).length === 0) };
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
  const cause = anims.length
    ? `The host is STILL mid-animation after ${waitedMs}ms of settle (cap ${SETTLE_CAP_MS}ms) — ` +
      `an entry animation with a \`from { opacity: 0 }\` keyframe reads checkOpacity false while it runs, ` +
      `and an INFINITE animation never settles at all. Look at the animation named above, not at Chrome or the port.`
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
      const names = [...new Set(verdict.failing.flatMap((r) => r.animations || []))].join(", ");
      log(`   · ready-host floor settling on ${url} — ${verdict.failing.map((r) => `"${r.q}"`).join(", ")} mid-animation (${names})\n`);
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
