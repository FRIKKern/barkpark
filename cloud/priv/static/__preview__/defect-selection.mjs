// defect-selection.mjs — how overflow-guard.mjs turns `argv` into the set of
// legs it will measure, extracted so it can be DRIVEN WITHOUT A BROWSER.
//
// WHY THIS FILE EXISTS (cch-w17-bl-overflow-guard-honours-one-defect-flag).
// The guard used to resolve its selection with:
//
//     const di = argv.indexOf("--defect");
//     if (di !== -1) { only = argv[di + 1]; ... }
//     const requested = only ? [only] : DEFECTS;
//
// `Array.prototype.indexOf` returns the FIRST match. So
// `--defect W13-detail-route-band --defect W15-fleet-row-text-bounded`
// measured W13, dropped W15 WITHOUT A WORD, and printed
// `OVERFLOW GUARD PASS — W13-detail-route-band measured fixed in a real browser`
// at exit 0. The operator asked for two legs and got a green covering one, with
// nothing in the output saying so — the exact defect class this guard was built
// to catch, committed inside the guard.
//
// THE CHOSEN FIX IS ACCUMULATE, NOT REFUSE. `--defect A --defect B` has exactly
// one reasonable reading, and refusing an unambiguous request makes a worse
// instrument than honouring it. It is also the honest half of this guard's exit
// vocabulary: exit 2 is documented as "REFUSED to measure (…environment…)", and
// a well-formed request is not an environment fault. The guard's PASS line
// already prints `requested.join(", ")`, so an accumulated run STATES the leg
// set it stands behind at the point it makes the claim — the reader does not
// have to trust the invocation to know what the green covers.
//
// NOTHING IN `argv` IS IGNORED. Accumulating alone would leave a sibling of the
// same defect open: `--defect A B` would take A and drop the bare `B` just as
// silently. So an unrecognised argument, and a `--defect` with no id after it,
// are REFUSALS in this guard's own `!! GUARD (exit 2)` vocabulary. That is safe
// against every live caller: `--defect` is the only flag overflow-guard.mjs has
// ever read (`argv` appeared in exactly three lines of it),
// .github/workflows/console-harness.yml invokes it with no arguments at all,
// and seal-predicate.mjs spawns it as `node <guard> --defect <id>`.
//
// A REPEAT OF THE SAME ID is deduped and SAID OUT LOUD, never dropped in
// silence — a `notes` line rather than a refusal, because the requested leg set
// is genuinely unchanged by the repeat.
//
// ZERO DEPENDENCIES, NO SIDE EFFECTS ON IMPORT — this module is pure so the
// wired console-unit step (__app.test.mjs) can assert the behaviour directly
// instead of spawning a browser. Same reason font-pin.mjs, bringup-retry.mjs
// and ready-host-paint.mjs are siblings rather than inline blocks.

export const DEFECT_FLAG = "--defect";

// Returns EITHER `{ requested, notes }` — `requested` is the leg list in the
// order the caller asked for it, `notes` are lines the caller should print — OR
// `{ refusal }`, a ready-to-write stderr line whose contract is exit 2.
//
// With no `--defect` at all, `requested` is a COPY of `known`: the historical
// "measure every defect" default, unchanged.
export function selectDefects(argv, known) {
  const picked = [];
  const notes = [];
  const seenCount = new Map();

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];

    if (arg !== DEFECT_FLAG) {
      return {
        refusal:
          `!! GUARD (exit 2): unrecognised argument "${arg}" at position ${i + 1}. ` +
          `This guard reads only \`${DEFECT_FLAG} <id>\`, which may be REPEATED to ask for ` +
          `several legs (\`${DEFECT_FLAG} A ${DEFECT_FLAG} B\`) — a bare id is not a second ` +
          `leg and will not be measured. Known: ${known.join(", ")}\n`,
      };
    }

    const value = argv[i + 1];
    i += 1;

    if (value === undefined || value.startsWith("--")) {
      return {
        refusal:
          `!! GUARD (exit 2): \`${DEFECT_FLAG}\` at position ${i} has no defect id after it ` +
          `(next argument: ${value === undefined ? "end of arguments" : `"${value}"`}). ` +
          `Known: ${known.join(", ")}\n`,
      };
    }

    if (!known.includes(value)) {
      // Wording preserved VERBATIM from the pre-fix guard: this is the refusal
      // seal-predicate.mjs's doctrine block cites by name, and a caller reading
      // the guard's output should see no change in it.
      return {
        refusal: `!! GUARD (exit 2): unknown ${DEFECT_FLAG} "${value}". Known: ${known.join(", ")}\n`,
      };
    }

    seenCount.set(value, (seenCount.get(value) || 0) + 1);
    if (!picked.includes(value)) picked.push(value);
  }

  for (const [id, n] of seenCount) {
    if (n > 1) {
      notes.push(
        `note: ${DEFECT_FLAG} ${id} was given ${n} times; it is one leg and is measured once.\n`,
      );
    }
  }

  return { requested: picked.length ? picked : known.slice(), notes };
}
