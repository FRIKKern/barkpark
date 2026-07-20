# Production Truth — epic charter

Epic task: `paper-cache-drift-mass-422-on-renderer-change` (p0)
Wave 1 Paper: `production-truth-wave-2026-07-20`

## Vision

Every surface that reports success reports the truth. This epic exists to kill
**wrong-value generators** — code that returns 200 while the answer is wrong, or
returns an error while the answer is right.

The finished experience: a renderer change lands, and every published paper keeps
rendering. No sweep to remember, no version to bump by hand, no 422 for a paper
whose blocks are perfectly valid. When a paper genuinely IS ambiguous, it still
fails loudly. And when any scheduled gate goes red against live production, a
human is told the same night instead of a JSON artifact nobody opens.

The governing idea is **provenance over guesswork**. A cache must record what it
DEPENDS on, not merely what it was derived from. A byte-compare with no
provenance cannot tell "the renderer moved" from "this HTML was never rendered
from these blocks" — and conflating those two is the whole defect.

## Decisions

Each decision is followed by the one-line reason it beat its rivals. Decisions
marked **(evidence overturned the plan)** are places where verification
contradicted the strategic direction and the evidence won.

### The direction

- **D1 — Provenance wins; kill-the-cache is deferred; CI-gating is absorbed as a
  secondary belt.** Provenance is the only option that removes the false alarms
  without creating a silent loss, needs no storage migration, and leaves
  kill-the-cache fully open later.
- **D2 — Rival C (prefer blocks whenever blocks are valid) is REJECTED.** It
  deletes a real safety property: a paper with rich `body_html` and a thin
  blocks list would silently render the thin version — content loss behind 200,
  which is the exact failure class this epic exists to eliminate.
- **D3 — Rival A (kill the cache) is a LATER wave, not this one.** `body_html`
  is consumed by email delivery, SSE frames, the source controller and exports,
  making it a multi-consumer storage migration rather than a defect fix.

### Deriving the version

- **D4 — The renderer version is a compile-time sha256 over sorted SOURCE TEXT
  of the covered files, using the `@external_resource` + `File.read!` precedent
  already proven in `render/status_vocab.ex`.** Proven rebuild-stable (identical
  digest across two independent build directories) and change-sensitive (a
  one-byte comment append moved it; reverting restored it exactly).
- **D5 — NOT `:beam_lib.md5`, and emphatically NOT a raw `.beam` file hash.**
  Raw `.beam` MD5 embeds the absolute source path and was measured UNSTABLE
  across build directories — it would have become the permanent false alarm it
  was meant to prevent; `beam_lib.md5` needs already-loaded modules
  (chicken-and-egg at compile time) and is sensitive to the OTP toolchain, which
  differs on the ARM prod host.
- **D6 — Covered set = `render.ex` + all 16 `render/*.ex` + `slots.ex`.**
  `Tiers` and `Constraints` stay OUT: an Erlang trace over `render_blocks/2`
  across callout/note/stage/card captured ZERO calls into either module.
- **D7 — Known and accepted gap: a transitive Hex dependency bump can change
  rendered bytes without touching a covered file.** Strictly smaller than
  today's gap (a hand-typed integer catches nothing automatically); recorded
  rather than claimed away.

### The classification rule

- **D8 — The reader's rule is: stamp ≠ digest ⇒ DRIFT ⇒ serve blocks and refresh
  the cache. Stamp == digest AND bytes differ AND no resolver-dependent block ⇒
  DIVERGENCE ⇒ keep the 422. No stamp ⇒ provenance unknown ⇒ fail closed on
  today's behaviour.** This removes the entire false-alarm class while preserving
  the original safety property exactly.
- **D9 — RESOLVER EXEMPTION: a block list containing any `field-reference` or
  `codelist` block with a non-empty value disables the byte-compare's 422.
  (evidence overturned the plan)** `Labels.paper_render_opts/3` — the SAME opts
  builder used by both the cache writes and the 422 gate — injects live-Repo
  resolver closures, so renaming a REFERENCED paper changes rendered bytes with
  zero change to blocks and zero change to renderer code. Proven at runtime on
  both variants; under the naive rule that paper is misclassified as divergence
  and hard-fails. There is a third case the drift/divergence split does not
  name: **external referent drift**.
- **D10 — REJECT freezing resolved labels into provenance.** A frozen label makes
  "stamp matches" true while the correct rendering legitimately differs — the
  reader would then serve the OLD title, a wrong-value generator; and checking
  whether a frozen label is still current requires the same live query it was
  meant to avoid.
- **D11 — The divergence branch is KEPT even though the class is empirically
  empty** (56 real firings, all resolved as drift, content-loss counter at zero
  across 885+ observations). "Never observed" is not "structurally impossible",
  and provenance keeps the branch for free.

### The lying stamp

- **D12 — A write-side stamp CLEAR is mandatory co-scope, not polish.
  (evidence overturned the plan)** `block_ops.ex` deliberately preserves an
  existing `body_html_sv` on verbatim `body_html` writes. Proven: the same
  persisted record is safe today and safe under the new rule at v3, but at v4
  becomes `drift ⇒ serve blocks and overwrite` — 52 bytes destroyed behind HTTP
  200. The digest ARMS this on every renderer commit, so shipping D4 without D12
  makes the fix worse than the bug.
- **D13 — The clear is `Map.delete`, scoped to the verbatim leg
  (`is_binary(attrs["body_html"])`) ONLY.** The pure carry-over leg produces a
  fully coherent record; deleting there would demote healthy papers into the
  fail-closed unknown class and manufacture new false 422s.
- **D14 — NOT a sentinel value.** A sentinel is by construction ≠ current, so it
  routes straight into the overwrite branch — fail-open by discipline, the same
  class of mistake as the hand-typed version. Absent is already fail-closed.
- **D15 — Strip any caller-supplied `body_html_sv` on the writer path.** Proven a
  client can POST `sv: 1` and have it persist verbatim; under the new rule that
  is a client-controlled classification switch (pin a paper at 422, or force the
  overwrite branch). Provenance must be server-derived.

### The rehydration sweep

- **D16 — The sweep's staleness check becomes EQUALITY, in the same change as the
  digest cutover.** `is_integer(sv) and sv >= current` was proven broken in both
  directions against a hash: unpatched, the noop fast-path is permanently
  unreachable; naively widened to `is_binary`, the leftover `>=` is lexicographic
  and calls a genuinely stale doc current.
- **D17 — The sweep must SKIP the divergent class** (blocks-render ≠ stored HTML
  under a current stamp). D13's clear makes a verbatim record look stale to the
  sweep, which would then destroy exactly the content the clear was protecting —
  trading a read-path loss for a sweep-path loss.
- **D18 — The sweep gains a dry-run, batching, and a rescue around
  `Render.render_blocks`.** It has never been run in production, is unbatched,
  and one bad row currently aborts the whole sweep with no partial-progress
  checkpoint.

### No signal dies unheard

- **D19 — The alerting channel is the built-in `GITHUB_TOKEN` + `gh issue
  create`, NOT a bp task. (evidence overturned the plan)** `BARKPARK_TASK_TOKEN`
  was proven not to exist in ANY scope — not repo, not any of the 6 environments,
  and org secrets are structurally impossible on a user account — so three
  workflows have been silently degrading since they were written. Worse, the
  `createIfNotExists` shape they would copy files a DRAFT that never reaches the
  published ledger, while the workflow prints "Filed override task". The remedy
  must not itself be a wrong-value generator.
- **D20 — Wire ALL THREE scheduled workflows, through one shared shell script
  with a hermetic `.test.sh`.** The repo's sharing idiom is shell scripts (26 are
  workflow-called) and `pr-task-gate.test.sh` is a working no-network template;
  `renew-mail-cert` is monthly, so a failed TLS renewal is ~90 silent days.
- **D21 — The audit's 422 detection gets a permanent fixture.** Detection was
  proven real (the real script exits 1; the same script with the status gate
  removed exits 0 on the identical fault) but rested only on incident history —
  no checked-in test could re-prove it after a refactor.

### The slot-coverage family

- **D22 — The rule is NARROW (all consumed fields empty AND an unknown key
  present), not a positive allowlist.** Measured across all 419 papers: narrow
  flags 5 blocks with ZERO false alarms (all verified as genuine silent losses by
  rendering); an allowlist flags 38 with ~33 false alarms, and needs hand-authored
  consumed-key sets for ~66 live block types against `slot_decls`' 4.
- **D23 — It BLOCKS (409), write-side only, as a RATCHET on the clean→lossy
  edge.** Zero false positives corpus-wide and self-limiting (it can only fire
  when the block already renders to nothing); write-side only because a read-path
  version would manufacture the very 422-on-valid-content class D8 is killing;
  ratchet so the 5 existing live losses stay editable instead of bricking.
- **D24 — The seam is `block_ops`' unconditional `with`-chain, NOT
  `Template.validate` / `Constraints`. (evidence overturned the plan)**
  `Template.validate/1` is wrapped in `if Enum.any?(blocks, &locked?/1)` — 416 of
  419 published papers skip it entirely, and ZERO of the papers carrying note or
  card blocks are locked. The patch path is separately dead via its before-valid
  guard. `reject_hollow_result` is the proven unconditional pattern to copy.
- **D25 — `card` is worse than `note` and gets equal billing.** A flat-authored
  card renders a completely empty `<div>` with no typo required, because
  `legacy_slot/2` special-cases only callout/note/stage.

### Method and scope

- **D26 — Every fix ships with a test PROVEN able to fail, asserting STATE not
  exit codes.** A republish-based mutation can never prove a cache path — publish
  regenerates the cache and silently overwrites the probe.
- **D27 — FENCE EXTENSION.** The cycle fence (`api/lib/barkpark/content/`,
  `api/lib/barkpark/portable_doc/`, `cloud/test/`) is extended to
  `.github/workflows/{paper-readers,codebase-intel,renew-mail-cert}.yml`,
  `scripts/{audit-paper-readers-test,file-ci-failure-issue}.sh`, and
  `api/lib/mix/tasks/barkpark.rehydrate_body_html.ex`. The fence exists to avoid
  the Studio and PDS epics; none of these paths belong to either, and the
  alerting move and the sweep cutover are unbuildable without them.
- **D28 — The oauth flake is fixed by extracting the blank-creds test to an
  `async: false` module plus adding `OAuth` to the guard's `@shared_seam_keys`.**
  Stays inside `cloud/test/`; the config-injection refactor is architecturally
  cleaner but requires `cloud/lib/`, outside the fence.
- **D29 — The format gate ruling: format main once and make the gate REQUIRED, or
  delete the job.** A permanently-red advisory signal trains dismissal of every
  red beside it; the status quo is the only dishonest option. Not this wave.
- **D30 — Every builder is `opus` this cycle.** Hard model constraint: Fable is
  spend-limited.
- **D31 — Rounds are law.** A slice needing another slice's code on main is round
  ≥2 and is NOT dispatched this run. The reader (C) needs BOTH the digest and the
  honest stamp on main or it destroys content; the sweep hardening (D) needs the
  digest's type; the slot contract (F) shares `block_ops.ex` with B.

## Roadmap

### Wave 1 — 2026-07-20 (in flight)

Round 1 (dependency-free, builds now):

| # | Slice | Task | Size | Surface |
|---|---|---|---|---|
| A | Derive the renderer version — sha256 digest + type cutover | `pt-w1-renderer-source-digest` | medium | `portable_doc/render*`, mix task |
| B | Write-side stamp honesty — clear on verbatim, strip caller-supplied | `pt-w1-write-side-stamp-honesty` | medium | `content/papers/block_ops.ex`, `content/writer.ex` |
| E | No signal dies unheard — alerting on all 3 scheduled workflows + 422 fixture | `pt-w1-scheduled-gate-alerting` | medium | `.github/workflows/`, `scripts/` |
| G | oauth blank-creds race — async isolation + guard key | `cloud-oauth-replay-test-is-seed-flaky` | small | `cloud/test/` |

Round 2 (deferred — lead dispatches after deps merge):

| # | Slice | Task | After | Size | Surface |
|---|---|---|---|---|---|
| C | Reader consults provenance + resolver exemption | `pt-w1-reader-provenance-classification` | A, B | large | `content/papers.ex` |
| D | Rehydration sweep hardening | `pt-w1-rehydrate-sweep-hardening` | A | medium | mix task |
| F | Slot-coverage contract (note + card) | `pd-note-block-silent-content-loss` | B | medium | `portable_doc/slots.ex`, `block_ops.ex` |

### Later waves (filed, not scheduled)

- **Kill the cache (Rival A).** Render from blocks on every read; keep
  `body_html` only for legacy HTML-only papers. Provenance is a prerequisite
  step toward it, not an obstacle.
- **ShareLinkController static fallback** reads `body_html` with no drift check
  at all — a live surface no reader fix touches.
- **Block-field census** across the remaining ~62 live block types.
- **Format gate ruling** (D29) and the **pr-task-gate contradiction**, both
  filed and out of fence.

## Wave log

_(empty — Review appends the wave 1 debrief here)_
