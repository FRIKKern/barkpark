// design/check/state.mjs — the state every Part of design/check.mjs shares: the
// injected-fault set and the failure count. `failed` is a live binding, so a Part
// that imports it reads the current count; only this module writes it.

// Fault injection, driven only by `design/check.mjs --selftest`. BP_DESIGN_CHECK_FAULT is a
// comma-separated set of part ids; each named part records ONE EXTRA failure at
// the point it records its own. It can only ADD a failure, never suppress one, so
// the worst a stray value in CI can do is red this gate loudly — there is no value
// of this variable that mutes a real drift.
//
// There is ONE hook beside EVERY ok-gate in the Part modules, and that is the contract
// the selftest reads. It derives the injectable set by scanning design/check.mjs and
// each Part module it imports, in that order, for `FAULT.has("<id>")`, loops it, and
// NAMES any Part carrying no hook as uncovered.
// A Part added later is therefore covered by adding its hook in its own module, never by
// editing the selftest, and a Part whose author forgets the hook is named in the
// output instead of passing in silence. Every hook prints the same shape,
// `  Part <id> FAIL: injected fault (--selftest)`, because the selftest derives
// that line from the id to prove the fault LANDED before it judges anything.
// Part A's hook says more: Part A prints a per-ARTIFACT ok line and gates no
// part-summary, so it is the one injectable part whose fault withholds no ok. That
// exemption is declared AT THE HOOK, where a reader of either file meets it, and
// is read back by the selftest instead of being hand-listed there. Part 0's hook
// says more too, for the opposite reason: its real failure path exits the process
// immediately, so its hook deliberately does NOT — an injected fault there must
// leave the run standing for the Parts the arm judges beside it.
const FAULT = new Set(
  (process.env.BP_DESIGN_CHECK_FAULT || "").split(",").map((s) => s.trim()).filter(Boolean),
);

// `failed` is a COUNT, not a flag. Every part below gates its `ok` summary on
// `failed === failedBefore<X>` — a snapshot taken at the part's head. With a
// sticky boolean that comparison answered "has anything failed all run?", so
// once ANY earlier part tripped it, `true === true` held even after the part
// recorded its OWN failures, and the part printed its green line beside its own
// red ones. Counting makes the SAME comparison ask the question it always meant:
// "did anything fail SINCE my head?" — a per-part delta. Truthiness is unchanged
// (0 is falsy), so the verdict arm and the process exit code are untouched, and a
// part added later inherits the fix simply by copying the existing idiom.
let failed = 0;
const fail = (msg) => { console.error(msg); failed++; };

// A Part whose own fail helper counts the failure itself (Parts L, M, N, O) calls
// this, since an imported binding cannot be assigned from outside.
const bumpFailed = () => { failed++; };

export { FAULT, failed, fail, bumpFailed };
