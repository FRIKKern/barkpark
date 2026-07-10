# PortableDoc authoring quality gate — p-quality-gate epic charter

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. Preserved verbatim: **self-update W5** at `bp-self-update-w5-charter.md` (committed
> in #2227) and **gui-premium W5** at `bp-gui-premium-w5-charter.md` (that epic is LIVE
> concurrently — its phases should read/write the preserved file). This file is the memory
> of the **p-quality-gate** epic (paper hollow-body gate).

Epic anchor: bp task slug **`p-quality-gate`** (published, lifecycle open, priority 1,
parent parity-s6-quality, GitHub #1576). Server: guerrilla. Doctrine vein:
drafts.pd-doctrine / drafts.pdd-m1.

## Vision

No hollow published paper, anywhere, from any writer. An author — human in Studio, or a
curl/SDK/CLI/MCP/ingest writer — who submits a paper whose body is nothing but the enforced
title/featured skeleton gets a HARD STOP with honest copy ("This paper has a title but no
content yet — add at least one body block.") carried in the SAME structured 409 `halted`
envelope on every surface. The gate is server-owned, lives in ONE predicate module, and the
editor mirrors it (tokens + honest copy, no native controls, no chat); it never owns it.
Creation stays smooth: a fresh paper is hollow by construction (seeded title + empty
tpl-body paragraph) and must remain freely editable.

The anchor task's own literal scope (TASK-document gate: empty-title 409 halt,
zero-criteria soft warn) is ALREADY SHIPPED — PR #1581 / commit b4e3256f, 9/9 tests green
on HEAD (run-verified 2026-07-10). Its ledger is stale, not its code. The epic's remaining
build scope is the wish's paper hollow-body gate: verified to exist NOWHERE (no code, no
filed task, no ratified copy) before this wave.

## Non-negotiable operational facts (builders read FIRST)

- .ex changes WAIT for the Elixir Test CI gate before merge. Worktrees from origin/main
  after `git fetch`. Claim your bp task BEFORE working. PR body carries `Task: <id>`.
- api/ tests need local Postgres on :5432; run `CC=/usr/bin/clang mix test <files>` from
  `api/`. Never prod compile. `cc` is a Claude wrapper — always set CC=/usr/bin/clang.
- docs/api-v1.md is 7 bytes under its CI byte cap; api/CLAUDE.md is 5 bytes under. This
  wave makes ZERO edits to either (see D4). Don't touch them.
- Concurrent worktrees exist under this repo with stale line numbers — trust fresh
  origin/main only.

## Decisions

- **D1 — Two readings, honestly sequenced.** The anchor = task-doc gate = DONE (merged
  #1581); its remaining action is ledger hygiene only (D9). The paper hollow-body gate =
  net-new, filed fresh this wave as children of p-quality-gate. Never rebuild #1581.
  *Why: verification proved the merge + green tests on HEAD; the digest proved the paper
  gate is unfiled and unbuilt.*
- **D2 — Gate moment is NOT before_publish.** Papers publish in place on the primary
  surfaces: Studio canvas + Bulldocs ingest never traverse `Lifecycle.publish_document`
  (probe-proven — `upsert_paper` hardcodes status published, fires no hooks; Studio has no
  paper Publish button). Enforce at FOUR seams sharing ONE predicate
  (`Barkpark.Content.Papers.Hollow`):
  1. `BlockOps.upsert_paper` — result hollow → `{:error, {:halted, msg}}`, always (Studio
     never calls it, so no birth exemption needed; covers ingest/chat/mutate stubs).
  2. `apply_paper_block_op(s)` (Studio canvas + ingest /ops) — RATCHET: halt only when the
     previous blocks were non-hollow AND the folded result is hollow. Fresh hollow papers
     stay editable; a real paper can't be hollowed out.
  3. Bulldocs `before_save` hook #2 — type paper, published-status/non-`drafts.` write,
     hollow → halt. Draft saves stay free (mutate creates always land drafts; gating them
     bricks creation).
  4. New Bulldocs `before_publish` hook — publishing a hollow draft (mutate publish op,
     proposals flow) → halt.
  *Why: publish-boundary verification killed "gate on publish" for the primary surfaces;
  the ratchet is the only shape that doesn't brick canvas creation.*
- **D3 — Hollow = skeleton-only, text-blankness based.** Skeleton = blocks with
  `locked==true` ∪ `role in ("title","featured")` ∪ block[0]-when-heading (de-facto title
  for the un-migrated corpus — 0/78 live guerrilla papers carry locked/role blocks, so a
  purely additive gate would fire on nothing that exists). Content = any non-skeleton block
  that is an inherently non-text type with real payload (image, table, code, diagram,
  sheet, task-list) OR a text-bearing block whose recursively-flattened trimmed text is
  non-blank. Divider never counts; blank paragraphs/headings never count; image-only papers
  are NOT hollow. Docs with no `blocks` list (body_html-only, pre-doctrine) are exempt.
  *Why: maybe_seed gives every new paper an empty tpl-body paragraph so block-count
  predicates are wrong both ways; corpus blast radius measured 0 hollow under this
  predicate — nothing bricks.*
- **D4 — Reuse `halted`; do not mint `document_hollow`.** The `{:halt, reason}` →
  `{code:"halted", status:409}` path needs ZERO new plumbing: byte-cap probes proved even a
  6-word api-v1.md annotation fails CI (14027B > 14000B); the CLI already maps
  halted→exit 6 and prints the server message verbatim; `@hints["halted"]` exists. Honest
  copy rides the per-call `message` (free text, uncapped, not enum-pinned). Minting a named
  code = backlog `p-hollow-named-code`. *Why: reuse is provably zero-cost; minting is
  provably blocked on doc-budget surgery.*
- **D5 — Fix the swallowing emitters or the gate lies.** `bulldocs_ingest_controller`
  flattens ANY `{:error,_}` into generic `invalid_paper` — it already eats the shipped M1
  template halt TODAY (live, untested bug) and would eat the hollow copy on the surface
  most likely to submit hollow stubs. Studio's `shared/paper.ex` catch-alls ("Edit failed")
  swallow `{:halted, reason}` the same way. Both get explicit halt clauses. *Why:
  layer-parity verification found the third emitter; the wish's "query_controller AND
  legacy_controller" constraint is stale — both already delegate to FallbackController.*
- **D6 — Studio mirror = new banner, existing pattern.** New sibling component modeled on
  `doc_conflict_banner` (`.bp-violations` shell, `--destructive`/`--warn` tokens,
  `role="alert"`), fed by a new assign set from explicit `{:error, {:halted, reason}}`
  clauses in `paper_pane_op` AND `paper_ops` (the batch path never sets save_status on
  error today — fix that too). No new CSS (classes exist, root.html.heex:1190-1209).
  *Why: studio-mirror verification mapped the exact wiring; cross_violations_banner is the
  wrong component (schema cross-field domain).*
- **D7 — Pin hooks composition before hook #2.** Adding a second before_save function to
  Bulldocs' list requires fail-before tests pinning (a) in-list ordering within ONE
  plugin's hook list and (b) hook B sees the pristine payload even when hook A returns a
  mutated map. *Why: structurally guaranteed today (reduce_while ignores hook return
  values) but not test-asserted, and the gate relies on it.*
- **D8 — Exemptions are per-path, not per-doc.** No source/writer field exists on papers,
  so exemption-by-writer from stored docs is impossible. `doctrine_backfill` (raw Repo,
  human-gated) stays outside the gate — backlog adds a would-become-hollow check to its
  plan/1 report. `seeds/clean.ex` seeds real content (verified). github intake writes
  tasks, not papers; its 5xx-redelivery risk against the TASK gate predates this wave —
  filed as backlog. *Why: corpus verification — no doc-field hook to key off.*
- **D9 — Anchor close-out recipe (lead executes on wave merge):** claim fresh
  (`bp task claim p-quality-gate <worker>` — expired epoch 2 → new epoch), then close with
  all 4 criteria flipped met, evidence = "PR #1581/b4e3256f; tasks_quality_gate_test.exs
  9/9 green on HEAD 607584bd (run-verified 2026-07-10)". Do NOT patch acceptance_criteria
  before claiming — the work-digest close fence keys on those fields. The anchor stays open
  through the wave as the heartbeat carrier.

## Roadmap

1. **W1 (this wave, large, fable)** `p-hollow-gate-server` — Hollow predicate module + all
   four enforcement seams + hooks-pinning tests + unit & HTTP-contract deny/positive tests.
   The correctness core.
2. **W2 (this wave, medium, opus)** `p-hollow-ingest-envelope` — bulldocs_ingest_controller
   stops swallowing `{:halted, reason}` (whole-doc clauses + /ops fallbacks): 409 + code
   "halted" + verbatim message; fail-before tests against the TODAY-live M1 template halt.
   Independent of W1.
3. **W3 (this wave, medium, opus)** `p-hollow-studio-mirror` — Studio halt clauses + hollow
   banner (tokens, honest copy, role=alert), assign threading, batch-path save_status fix.
   Matches `{:halted, reason}` generically → surfaces M1 halts today, hollow halts after W1.
4. **Backlog (filed, not this wave):** `p-hollow-named-code` (mint document_hollow:
   api-v1.md byte surgery + @hints + CLI codeExit + hint), `p-hollow-backfill-guard`
   (doctrine_backfill plan/1 reports would-become-hollow as unfixable, pre-t5-migrate),
   `p-gate-github-redelivery` (intake catch-all turns task-gate halts into GitHub 5xx
   redelivery loops → clean refusal), `p-dispatch-frontier-content` (the one near-hollow
   live paper: "/" + two empty paragraphs).
5. **Anchor close-out** — lead closes p-quality-gate per D9 when the wave merges.
6. **Out of scope, permanently parked:** pdd-t5-migrate corpus APPLY (human gate);
   docs/contracts/tenancy.md budget overrun (pre-existing repo-wide red, filed flat as
   `docs-tenancy-budget-overrun`, not this vein).

## Wave log

### Wave 2026-07-10 — all three slices green, reviewed, integration-proven

**Landed (final branches — `-r` suffix = integrate these):**

- **W1 `p-hollow-gate-server`** — branch
  `loop-epic/server-owned-hollow-paper-gate-one-predi-0-r` (review commit adds only this
  charter file; code identical to the builder's `…-0`). `Hollow` predicate (D3 verbatim,
  unknown block types err non-hollow so the gate can never brick an unmet type) + all four
  seams (upsert always-halt, single-op + batch RATCHET, before_save hook #2
  published-surface only, NEW before_publish hook) + D7 hooks-composition pinning landed
  fail-before. 112/0 targeted. Honest limit, verified true: Writer draft-coerces every
  HTTP mutate write, so hook #2's published-surface deny is pinned at the `Hooks.fire`
  seam with the exact Writer payload shape (`"type"` stamped at writer.ex:87/443 —
  reviewer-verified) + the `Errors.to_envelope` 409 mapping; the live HTTP deny is the
  publish-op path, which IS proven end-to-end (409 `halted`, draft intact).
- **W2 `p-hollow-ingest-envelope`** — branch
  `loop-epic/ingest-emitter-honesty-bulldocs-ingest-s-1-r`. All four ingest catch-alls get
  an explicit `{:halted, reason}` → 409 verbatim clause; fail-before proven against the
  TODAY-live M1 halt (red 422 → green 409). 20/0. Review fix: clause comments generalized
  (they carry hollow-gate vetoes post-merge, not only M1). Its positive control already
  carries a body block, so it survives W1's gate — good foresight.
- **W3 `p-hollow-studio-mirror`** — branch
  `loop-epic/studio-mirrors-the-server-halt-hollow-ve-2-r`. Shared `put_paper_halt/2` on
  both canvas seams (verbatim reason, flash, `save_status` fixed on the batch path),
  `paper_halt_banner` sibling of `doc_conflict_banner` (`.bp-violations` shell,
  `--destructive` via existing `.bp-violations-error`, `role=alert`, no new CSS). 1451/0.
  Review fix: the batch `{:constraint,…}` clause now also sets `save_status: "Save
  failed"` — it was the one remaining error path that left a stale "Auto-saved" on screen.

**Integration proof (reviewer):** the three final branches merge cleanly onto origin/main
(W1+W2 share `bulldocs_ingest_controller_test.exs`, non-overlapping hunks); combined suite
1583/0. The cross-slice behavior neither branch could test alone — live `/ops`
remove-last-content-block → HTTP 409 `halted` with `Hollow.ratchet_message()` verbatim,
paper unchanged — was run green on the integration merge and filed as
`p-hollow-ops-live-proof` (child of p-quality-gate) to land permanently post-merge.

**Merge notes (lead):** all three are .ex → WAIT for the Elixir Test CI gate. Any merge
order works (clean pairwise), but W1-then-W2 makes the ingest halt clauses live truth
immediately. Each task's "PR merged" criterion + lifecycle closes on merge; W1's builder
stamped criteria mid-work, so its close may 409 `doc_changed_since_claim` — re-claim fresh
and close (expected, documented). Then execute the anchor close-out per D9 (claim fresh,
flip all 4 task-gate criteria with the #1581 evidence). Backlog untouched and honest:
`p-hollow-named-code`, `p-hollow-backfill-guard`, `p-gate-github-redelivery`,
`p-dispatch-frontier-content`, + new `p-hollow-ops-live-proof`. This charter (with this
log) is committed on the W1 `-r` branch; the shared checkout's uncommitted copy becomes
redundant on merge — reconcile, don't fork.

**Next wave:** (1) land `p-hollow-ops-live-proof` (tiny, evidence already in the task);
(2) `p-gate-github-redelivery` before GitHub-intake volume grows (5xx redelivery loops
against lifecycle gates are a real operational hazard); (3) `p-dispatch-frontier-content`
— after this wave the corpus's one near-hollow paper is grandfathered (stored hollow stays
readable; it just can't be REBORN hollow) and should get real content or retirement;
(4) `p-hollow-named-code` only if the doc-budget surgery ever becomes worth it — the
reused `halted` envelope is doing the job honestly today; (5) `p-hollow-backfill-guard`
before any pdd-t5 corpus APPLY (still human-gated, still parked).
