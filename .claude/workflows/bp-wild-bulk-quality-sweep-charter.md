<!-- doc-tier: agent | canonical-for: wild-bulk-quality-sweep-epic-charter | budget: 4000tok -->

# Wild Bulk Quality Sweep — Epic Charter

Epic task: `wild-bulk-quality-sweep-2026-07-16-epic`. This charter is written fresh at the
first epic-cycle reconciliation wave (2026-08-18); the July-16 sweep itself ran on the
`wild-bulk-cycle` workflow and left no charter. It records **only** what this reconciliation
decided — it does not invent a mission the sweep never had.

## Vision

A July-16 bulk quality sweep filed 48 children and sealed its own cycle paper at A−. The epic
row nevertheless hangs open at 0/5 with a tail of deferred children. The charter's job is to keep
the ledger a cold reader can trust: the shipped work proven shipped, the open work classified by
its **true** gate, and no false seal placed over a live defect. The end state is an epic that
seals honestly — or stays open honestly — never one that reads "complete" while a live above-bar
security row sits open beneath it.

## Decisions

- **D1 — Census is L1-true: 44 done / 3 open / 1 cancelled, never `child_count` 48.** Re-derived
  from live L1; the raw `child_count` is a decoy the ready-list prints.
- **D2 — All 44 done rows are shipped-and-on-main.** Each joins 1:1 to a merge commit; all 44 are
  `git merge-base --is-ancestor` of origin/main `710c38f0` (44/44 YES, 0 non-ancestor). PR band is
  exactly `#3759–#3793` + `#3812–#3820`. The "44/44 merged" claim is now L1-real, not a wave_status
  self-quote.
- **D3 — The 1 cancelled row is terminal and correct.** `wbqs-api-sobelow-rebaseline` was a
  duplicate of `sobelow-baseline-reconcile` (shipped `#3038`, on main); its 3/3 are provenance
  criteria, not shipped work. Nothing to reopen.
- **D4 — Zero evidence-closes this wave.** Per-row verification found no stale-open shipped row to
  close and no superseded duplicate to park among the open set. The reconciliation *finding* is that
  the ledger is already accurate; honesty here is refusing to manufacture a close.
- **D5 — The three open rows are three different gates, none Opus-buildable this wave.** Treating
  them as one batch would be the false-done sin in reverse:
  - **D5a — `wbq-cloud-billing-reason-leak-backlog` → SPIN CANDIDATE, keep open, hand up.** A LIVE,
    unsuperseded, above-bar security defect on origin/main: `stripe_gateway.ex:280` binds the raw
    Stripe HTTP body into `{:stripe_http_error, status, body}`, and `router.ex` 5842/5872/5932 echo
    it via `reason: inspect(reason)`. Reachable by an authenticated **primary-team owner** (a paying
    customer, `require_primary_team_owner`), not anonymous. Its only prior blocker
    (`wbq-cloud-auth-onboarding-500`) is DONE. The fix edits a `cloud/` cp-deploy prod path — the
    fence forbids building it here. Surface it LOUDLY; NEVER re-parent it quietly shut.
  - **D5b — `wbqs-go-dead-exports-coordination-gated-backlog` → KEEP OPEN, human/coordination-gated.**
    Five Go exports are zero-production-caller on origin/main (`azure.DefaultSpec/WithCredential/
    WithSSHPublicKey`, `apiclient.ConfigFromEnv`, `cloudclient.GetCredentials` test-only vs
    production `GetCredentialsForTeam`), but they are staged Azure go-live wiring under the still-open
    `azh-go-live-human-gate` (0/4). Deleting them now erases unfinished integration. Gated on owner
    sign-off, not offline-buildable.
  - **D5c — `wild-bulk-cycle-v2-revisions` → FABLE-CAPPED RESIDUE, keep open, build after Aug-21.**
    0/5 revisions present in `.claude/workflows/wild-bulk-cycle.workflow.js` on origin/main. It is a
    pure workflow-file edit (offline-buildable in principle), BUT two of the five — post-build roster
    reconciliation and a verdict retry/backoff loop — are subtle, high-blast-radius orchestration
    changes to the engine that drives every future bulk cycle, with no runtime gate but a live
    wild-bulk run (its own criterion C1). `node --check` proves syntax, not correctness. That warrants
    Fable-tier care; Fable is capped until Aug 21, so it is Fable-gated residue (the tlv-s5/s8
    precedent), not an Opus slice.
- **D6 — CONVERGENCE VERDICT: DO NOT SEAL.** All three residue rows are gated (fence-forbidden /
  human-gated / Fable-capped) and the live billing leak forbids a clean seal regardless. Sealing now
  would be a done-parent-over-open-children false-seal. "Already-honest, residue is gated" is the
  A-grade ending.
- **D7 — Epic's 5 cycle-criteria: stamp only what has evidence; the LEAD stamps (not this wave).**
  Stamping requires claiming the multi-wave Goal, which misrepresents its lifecycle — rejected. C1
  (idx 0, "surveys filed as published bp tasks under this epic") is **unsatisfiable as worded**: zero
  of the 48 children are survey-shaped; surveys live in the cycle paper. Reword to "captured in the
  cycle paper `wild-bulk-quality-sweep-2026-07-16`" or leave honestly unmet — never fabricate.
  idx 1–4 have quotable evidence (parentage+PR-Task lines; green Elixir Test gating; Harmonize
  disjointness held; cycle paper closed at Verdict with B+ then lead A−).
- **D8 — No standing repo-health/security successor exists.** Before any future clean seal, the lead
  must FILE a chartered successor (the Cloud-GUI-Remake precedent) and re-home the residue as
  still-open loud children via `bp task move`. A quiet re-parent-shut of the billing leak is forbidden.

## Roadmap

This wave cuts **zero build slices** — it is a reconciliation. The forward work, ordered by when its
gate can lift:

1. **`wbq-cloud-billing-reason-leak-backlog`** (small–medium, Elixir/cloud) — sanitize the three
   billing router sinks to a stable error code + server-side log of the detail, and extend the
   `http_client_test.exs` assertion from `_body` to a concrete body-equality assert so green
   certifies sanitization. Blocked by the `cloud/` cp-deploy fence: a SPIN out of this epic to a
   security/repo-health owner, not an in-fence slice.
2. **`wild-bulk-cycle-v2-revisions`** (medium, workflow engine) — land all five revisions in
   `.claude/workflows/wild-bulk-cycle.workflow.js`. Fable-tier (high blast radius, no runtime gate);
   dispatch after the Aug-21 Fable reset.
3. **`wbqs-go-dead-exports-coordination-gated-backlog`** (small, Go) — wire the five exports in OR
   delete with sign-off. Blocked until `azh-go-live-human-gate` resolves.

## Wave log

<!-- one line per wave: date · wave-paper · outcome. Newest last. -->
