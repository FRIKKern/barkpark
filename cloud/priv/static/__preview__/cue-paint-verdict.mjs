// cue-paint-verdict.mjs — charter D253's "can a cue ACTUALLY paint?" predicate,
// and the browser-side measurement that feeds it, owned in ONE place.
//
// WHY THIS FILE EXISTS (cch-w23-bl-three-screens-zero-geometry-coverage).
// The predicate below was written twice inside overflow-guard.mjs — once for
// `#members-body .set-row` (`.set-row-name`) and once for
// `W24-activity-feed-phone-band` (`.tlv-title`) — and the third population that
// needs it (`#overview-digest .fleet-row.activity-row`) would have made three.
// Three copies of a four-clause predicate is three places for one clause to go
// missing: a copy that drops `tw > 0` still prints a plausible verdict on every
// row that has text, and nothing reds. The metrics snippet is worse — it is a
// ~20-line browser-side clone/measure/walk written as a JS SOURCE STRING, where
// a dropped `!important` or a mis-escaped regex is invisible to `node --check`
// and shows up only as a min-content of 0 (which, deliberately, FLAGS rather
// than exempts — so a broken copy reds loudly rather than certifying quietly,
// but reds it on the wrong cause).
//
// ZERO DEPENDENCIES, NO SIDE EFFECTS ON IMPORT, NO BROWSER — the predicate is a
// pure function of the record the browser hands back, so cue-paint-verdict.test.mjs
// drives every branch under `node --test` without Chrome. Same reason
// font-pin.mjs / bringup-retry.mjs / ready-host-paint.mjs / width-drivers.mjs
// are siblings rather than inline blocks.
//
// THE PREDICATE, AND WHY EACH CLAUSE IS THERE (the long-form reasoning, with
// the decoded-PNG evidence that refuted the `white-space` version of this test,
// lives at overflow-guard.mjs's `.set-row-name` arm and is not repeated here):
//
//   (1) the marker is declared          te === "ellipsis"
//   (2) the box clips on the X AXIS     ox !== "visible"   (read by name: the
//       shorthand can legally serialise "visible clip", and the horizontal axis
//       is the only one a single-line ellipsis truncates on — cch-w29-s3)
//   (3) NO break opportunity fits       mw > cw            (min-content width;
//       `white-space` is NOT the test — an unbreakable run paints "…" under
//       `white-space: normal`, driven on Linux, charter D253)
//   (4) there is TEXT on that line      tw > 0             (a line holding only
//       atomic inlines has nothing to ellipsize)
//
// A ZERO `mw` — a min-content clone that failed to measure — makes (3) false and
// therefore FLAGS the row rather than exempting it.

// `n` is the record CUE_METRICS_FN returns: {sw, cw, mw, tw, ws, te, ov, ox, t}.
export function cuePaints(n) {
  return n.te === "ellipsis" && n.ox !== "visible" && n.mw > n.cw && n.tw > 0;
}

// The trailing clause of a failure sentence: WHICH clause failed, in the words
// the reader needs. THE SENTENCE NAMES THE LEG THAT ACTUALLY FAILED — blaming
// `white-space` for an `overflow: visible` cause would put this epic's own
// defect class (a person told the wrong reason) inside the instrument that
// polices it. Only ever called where `cuePaints(n)` is false.
export function cueWhy(n) {
  if (n.ox === "visible") {
    return `the box does not clip horizontally (overflow-x "${n.ox}", shorthand "${n.ov}"), so no marker is ever reached`;
  }
  if (n.te !== "ellipsis") {
    return `computed text-overflow is "${n.te}", so nothing is authored to paint`;
  }
  if (!(n.mw > n.cw)) {
    return `min-content ${n.mw}px FITS inside clientWidth ${n.cw}px, so the overflow is VERTICAL — \`overflow: hidden\` eats whole lines and no marker is ever reached`;
  }
  return `the overflowing line carries no text run to truncate (widest run ${n.tw}px)`;
}

// THE BROWSER SIDE, as a source string — a parenthesised function expression
// taking the element and returning the record above. Interpolated into a
// `Runtime.evaluate` payload by the caller: `rec.x = ${CUE_METRICS_FN}(el);`
//
// `cssText` is APPENDED, never assigned — assigning deletes the copied style
// attribute and measures the clone under a cascade it does not have.
//
// The text-run walk descends through `display: inline` / `contents` ONLY: an
// inline-block child is an ATOM and contributes no truncatable run, which is
// exactly the case clause (4) exists to catch.
export const CUE_METRICS_FN =
  `(function(n){` +
  `var cs=getComputedStyle(n);` +
  `var cl=n.cloneNode(true);` +
  `cl.style.cssText+=';position:absolute!important;left:-99999px!important;top:0!important;visibility:hidden!important;width:min-content!important;max-width:none!important;min-width:0!important;height:auto!important;overflow:visible!important;flex:0 0 auto!important;';` +
  `n.parentNode.appendChild(cl);` +
  `var mw=Math.ceil(cl.getBoundingClientRect().width);` +
  `cl.parentNode.removeChild(cl);` +
  `var tw=0;` +
  `(function walk(e){` +
  `for(var k=0;k<e.childNodes.length;k++){var ch=e.childNodes[k];` +
  `if(ch.nodeType===3){` +
  `if(!(ch.nodeValue||'').trim()) continue;` +
  `var rg=document.createRange();rg.selectNodeContents(ch);` +
  `var rl=rg.getClientRects();` +
  `for(var q=0;q<rl.length;q++) tw=Math.max(tw,rl[q].width);` +
  `} else if(ch.nodeType===1){` +
  `var dd=getComputedStyle(ch).display;` +
  `if(dd==='inline'||dd==='contents') walk(ch);` +
  `}}})(n);` +
  `return {sw:n.scrollWidth,cw:n.clientWidth,mw:mw,tw:Math.round(tw*100)/100,` +
  `ws:cs.whiteSpace,te:cs.textOverflow,ov:cs.overflow,ox:cs.overflowX,` +
  `t:(n.textContent||'').trim().replace(/\\s+/g,' ').slice(0,48)};})`;
