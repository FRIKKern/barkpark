# Cloud Console INSTRUMENTS — epic charter

**Epic task:** `cch-instruments-epic`
**Successor of:** `cloud-console-hardening-epic` (the console-hardening epic), split at wave 12, 2026-07-31.
**Owner:** frikk@guerrilla.no — the repo owner, who is the only person who can discharge the
human gates these instruments keep running into (branch-protection PUTs, prod env, npm/DNS).
**Steward:** the wave lead of record for any `bp-epic-cycle` run launched against THIS charter.
The steward may decide anything inside the fence below; the owner decides everything that
changes what CI *enforces*.

---

## Why this epic exists

The console-hardening epic chartered one promise: *"After this epic, what the console SHOWS
and what it DOES match — and the instruments asserting that match are themselves able to
fail."* Three waves running, the second half ate the first. Waves 9, 10 and 11 spent
5-of-6, 5-of-6 and 4-of-6 slices on instruments, every reviewer flagged it, and the epic's
own row count went **+11, +16, +7** — it filed faster than it closed for three consecutive
waves.

That is not a backlog problem, and no amount of discipline fixes it, because the cause is
structural:

- **Vision rows are TERMINAL.** A console lie is fixed, the row closes, and nothing is filed.
  The set is bounded by the console's own surface.
- **Instrument rows are GENERATIVE.** Every gate, generator, harness, preview shim, spec and
  ledger row is *itself a claim about the console*. Under the parent epic's own triage
  predicate — *a row survives if it names a claim/reality divergence* — an instrument that
  makes a claim is a legitimate subject for another instrument. Instrumenting the instruments
  recurses without bound, and the parent epic's seal clause (a) can never reach zero residue
  while it hosts them.

So the two classes are split. The parent epic keeps the console and terminates on it. This
epic hosts the instruments and **does not pretend it will terminate** — it is a standing
maintenance epic, judged on the health of its instruments, not on emptying a roster.

## The vision

Every instrument this repo points at the cloud console is **able to fail, and known to be
able to fail** — proven by mutation, not by a green run. An instrument that cannot fail is
worse than no instrument: it manufactures confidence. This epic's job is to keep the
measuring equipment honest, and to keep it out of the console epic's way.

## Standing laws

1. **Mutation or it did not happen.** A guard, gate, oracle or test is proven only by
   reverting the thing it guards and quoting the failure. A pass alone proves nothing.
2. **A refusal is a verdict; an infra fault is not.** Nothing measured means nothing claimed.
   Instruments here keep the three-way exit triad (0 / 1 / 2) rather than collapsing it.
3. **Cite MERGE SHAs, never branch SHAs.** origin/main is a linear squash chain, so a branch
   head is never an ancestor of main and a branch-SHA citation is unverifiable by construction.
4. **Never quote a `--successor` run as progress.** Reading an instrument is not sealing with
   it. A predicate read that names no successor and no roster (`--ladder-only`) is a reading;
   anything that prints a verdict token with a successor in it is a claim, and claims need
   the evidence, not the flag.
5. **No row is closed on a promise.** `gr-p5r5-successor-seal` was closed `done` for
   *promising* to file a successor, and then resolved for months as a live forwarding
   address. Close on the artifact, never on the intention.

## THE FILING LAW (binds this epic and the parent equally)

> **A wave may not end with more live rows than it began.** Count residue at the wave's first
> claim and at its debrief; a wave that nets positive states the number in its debrief and
> names what it will close next wave to repay it.
>
> **Instrument residue is filed HERE, never under `cloud-console-hardening-epic`.** A builder
> in a console slice who finds an instrument defect files it under `cch-instruments-epic`.

## The surface fence

**In fence:**

- CI gates, aggregators, workflow shape, path matchers, required-checks generation/verification
  *machinery* (not the enforcement decision — see out of fence).
- Preview + harness: `cloud/priv/static/__preview__/**` (scenarios, smoke, serve, overflow
  guard, seal predicate), `cloud/priv/static/__css_check.mjs`, `cssom-parity.mjs`, `shoot.sh`.
- Test rigs, oracles, fixtures, coverage gaps, flaky tests.
- The ledger and its tooling: `bp` write paths, the GitHub mirror, roster reads, citation
  hygiene, draft twins, charter/doc drift.
- The epic-cycle's own method: wave accounting, review-owed rows, filing discipline.

**Out of fence (belongs to `cloud-console-hardening-epic`):**

- Anything a person can see, click or be misled by on the console: SPA behaviour, layout,
  focus, copy, payloads served to a browser, API responses a console screen renders.
- Server behaviour a console user experiences (a 500 they see, a token in a header they hold).
- Registration/enforcement DECISIONS — which contexts become required, and the protection PUT.
  Those are the owner's, and they are deliberately left under the parent epic so the decision
  and its consequences stay in one place.

## The triage predicate

A row belongs in this epic when **all four** hold:

1. It names a divergence between what an INSTRUMENT claims and what it measures.
2. The defect is invisible to a person using the console — fixing it changes no pixel and no
   response byte.
3. It is inside the surface fence above.
4. It carries a measurement, not a suspicion — the body says what was run and what it printed.

A row that names something a person can see on a console screen goes to the parent epic, even
if an instrument found it. When it is genuinely both, it goes to the parent: the console is
the promise, the instrument is the means.

## First roster

Seeded at the wave-12 split with the instrument-class rows re-parented out of
`cloud-console-hardening-epic` by `bp task move`, classified BY BODY (not by title) against
the predicate above. **62 rows moved**, verified by re-reading
`filter[parent_id]=cch-instruments-epic` after the move — 62 children, set-identical to the
move list, zero extras. The parent went from 201 children / 102 live + 1 considering at the
split's first claim to 139 children / 39 live + 1 considering.

**40 rows stayed**, and the reasons are part of the fence, not exceptions to it: console
surfaces (a person can see them), operator/human-gate-blocked rows, the six wave-12 slices
in flight under live claims, and **eight** registration-class rows — the seven named at
Decide plus `cch-bl-generate-jq-merge-and-leaf-promotion`, which its own body and
`cch-w11-s1` both declare to be ONE INDIVISIBLE DIFF with the protection flip. Moving half
of an unmade human decision is not a split; it is a way to lose it.

The full moved and kept lists are recorded on
`cch-w12-s5-successor-split-and-letterbox-fence`.

**Known residue of the split itself, disclosed rather than owned:** the GitHub mirror has
`add_sub_issue` and NO remove verb, and `content.github.parent_marker` is written only on the
cap-flatten branch and never cleared. So a moved row's ISSUE BODY keeps naming
`cloud-console-hardening-epic` while the half a human actually reads — the `goal:<parent>`
label — is derived live from `parent_id` and converges in about 40 seconds.
`gr-bl-github-mirror-reparent-residue` owns that defect and is itself in the move set.
