# Jarl Platform Follow-ups (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant on origin/main — **CLI-Reliability** — is preserved in full
> at `.claude/workflows/bp-cli-reliability-charter.md`; do NOT read this file for CLI-Reliability
> history. A CONCURRENT epic (**jarl.no Dogfood Publishing**, decided the same day) also claims
> this slot in its own PR; whichever merges second must move the other occupant to its named
> preservation file (`bp-jarl-dogfood-publishing-charter.md`) — the lead resolves the slot.
> This branch's slot is the memory of the **Jarl Platform Follow-ups** epic.
>
> Epic anchor: bp task **`jarl-platform-followups-epic`** (guerrilla ledger).
> Wave 1 paper: **`jarl-platform-followups-wave-2026-07-31`** (style=article).
> Decided 2026-07-31.
> Baseline: origin/main `e3403110465e094d8ff06f4cc68c2c3ee342dfdd` (cited line numbers pin here).

## Vision

One golden path, proven end-to-end: `git push` → webhook mints a BUILDABLE queued deployment →
the box's own supervised builder shallow-clones the pushed sha → nixpacks → runtime → live, on a
box that came out of `bp launch` already carrying the whole site plane, with the pipeline wearing
its own watchdog. Definition of done is the epic's: a fresh `bp launch` box hosts a site from a
git push with zero manual steps, and the board survives the load. The board lane (guerrilla task
writes under saturation) rides in parallel and never gates the spine.

Ground-truth corrections this epic carries (each proven in the 2026-07-31 verify round, recipe
rows under `tooling/grip/ledger/`, committed on this branch):

- The wish's "real fail-open recovery" phrasing is stale — the codebase deliberately chose
  fail-LOUD (#8136); we extend that doctrine, we do not reverse it.
- The builder is per-box and co-located BY CONSTRUCTION (filesystem tarball handoff), not a
  central "muscle-1" host. The jarl incident root cause was sequential: site plane never
  installed (docker absent until 17:32Z, 41 min after the mint), THEN a token mismatch
  (agent.token vs require_worker — ~29 min of silent 401 polling, invisible in journalctl by
  construction: `Run()` discards the claim error unlogged).
- A dedup outage on the API mutate surface is 409 `halted` (deliberate, byte-budget-gated), and
  a genuine 500 on the GitHub webhook surface. Not 503.

## Decisions

- **D1 — Clone source rides the claim ENVELOPE, never `deployment_json`.** Claim 200 body
  becomes `%{deployment, observed_epoch, source}` with `source = %{kind: "git", url:
  "https://github.com/<github_repo>.git", ref: <full 40-char sha>}`, attached whenever the
  deployment is artifact-less and the site has `github_repo`. Why: `deployment_json/1` has 17
  call sites including tenant-facing reads — anything inside it leaks to the SPA; the envelope
  is worker-gated by construction, and zero tests pin the claim body as an exact map (proven:
  no `== %{`/`Map.keys` assert in `router_builder_test.exs`), so the key is free.
- **D2 — Predicate flip and git-ref lane land as ONE integration (same wave, spine merges
  together).** `github_build_available?/1` (router.ex:11657) flips from hardcoded `false` to
  repo-present (`is_binary(site.github_repo)`). Why: the webhook mints artifact-less rows, so a
  flip without the builder lane makes push-to-deploy fail LOUDER than today; repo visibility is
  not persisted, so repo-present is the only honest predicate available — private repos get a
  queued→failed cycle with a classified clone error instead of a pre-emptive apology. Previews
  need no gating: they never consulted the predicate and become buildable for free.
- **D3 — The clone sequence is sha-first, and there is no fallback.** `git init; git remote add
  origin <url>; GIT_TERMINAL_PROMPT=0 git -c credential.helper= fetch --depth 1 origin
  <full-sha>; git checkout FETCH_HEAD`. Why: proven live against GitHub — unadvertised and root
  shas fetch at depth 1, while the guessed fallback (branch fetch then checkout sha) FAILS for
  every non-tip sha (`reference is not a tree`). Short shas are refused (`couldn't find remote
  ref`); `not our ref` = terminal source-gone; a credential prompt = terminal repo-inaccessible
  (and without GIT_TERMINAL_PROMPT=0 the builder would hang on stdin forever).
- **D4 — Builder identity: `require_agent` + barkpark scope on ALL FIVE `/v1/builder/*` routes,
  reusing the box's existing `/etc/barkpark/agent.token`. No dedicated builder token.** Why:
  the runtime half of the same pipeline is already agent-scoped (symmetry on a tested seam);
  fleet-wide claim is correctness-broken at ≥2 boxes (wrong-box builds wedge `pushing` rows —
  the tarball handoff is a local filesystem); WORKER_TOKEN on a customer box opens
  `/v1/internal/*` (list/deprovision the fleet) and unscoped decrypted env reads; and
  `verify_agent_token` ignores scope (registry.ex:4238), so reuse costs zero verify-side change
  while a dedicated token would rebuild mint/rotate/deliver machinery that already exists.
- **D5 — Box-scoped claim NEVER ships before the queue-age alarm.** Same release train, alarm
  first (wave rounds encode it). Why: box-scoping strands queued rows on plane-less boxes and
  the reaper never ages repo-backed queued rows — the alarm is that orphan class's ONLY surfacer.
- **D6 — The alarm is a CP-side read-only query, not a reaper pass and not a builder report.**
  New Registry aggregate (max queued container-deployment age per barkpark, one GROUP BY — no
  N+1), surfaced as `queued_deploy_age_seconds` (number, nil when none) on `barkpark_json/3`;
  Go + SPA own the 5-minute threshold. Why: the builder is structurally silent on failure, and
  the 15-min reaper is a MUTATING builder-lease mechanism at 3× the alarm horizon — reusing
  either would be wrong twice.
- **D7 — The attention state is named `deploy_stalled`, warn tone, inserted after `degraded`,
  before `behind` (attention bucket), tail renumbered in Go + SPA + attention_order.json.**
  Why: the string `queued` is already mapped to the info/blue tone in semrole.go:93 (silent
  wrong tone), and a degraded box's stuck queue is a symptom, so degraded outranks it. Same
  slice makes the node harness read `attention_order.json` (today Go is the fixture's ONLY
  asserter — the "three-speaker seam" was disproven; verify_probes.json at __app.test.mjs:4156
  is the template).
- **D8 — Provision lane is CHAIN-FIRST, not bake.** A conditional site-plane step lands in
  `configureHost` between 7b (agent) and 8 (health), running `deploy/site-runtime-install.sh`
  on the box; it narrates loudly and degrades to stderr like 7b (the alarm is the backstop)
  rather than failing the go-live. Why: the bake is a `set -euo pipefail` silent-death pipeline
  with 2-generation irreversibility (PDF-D103) and Azure never sees the warm image; the chain
  reaches exactly the boxes that host sites, and ordering is safe — the verify gate runs
  strictly AFTER configureHost (acquireHost:423 precedes runVerifyGate:497).
- **D9 — Script preconditions first:** site-runtime-install.sh:41's hardcoded arm64 Go tarball
  becomes arch-aware (it ABORTS a bare default cx23 x86 box), git is installed explicitly (the
  clone lane makes git load-bearing at BUILD time), and builder/runtime systemd units are staged
  in `deploy/systemd/` instead of heredocs. Why: every lane (chain, cp-ops, future bake) reuses
  these steps; heredoc-only units are why supervision looked unowned.
- **D10 — Board lane: do NOT rebuild dedup birth (#8136 landed bounded 5s fetch + fail-loud +
  bypass); bound its unowned twin.** `Content.DedupWall` (the publish half of the same default
  `bp task create`) gains the same discipline: 5s query budget, `catch :exit`, degraded →
  `{:error, {:dedup_unavailable, …}}` (errors.ex:443 already maps it to 409). Why: the default
  create pays TWO dedup scans across two requests; #8136 bounded the create door and left the
  publish door open with a silent rescue-only fail-open — the literal failure mode its own
  commit body warned about, still live on the same verb.
- **D11 — EdgeProjector: error-not-snooze plus query-budget collapse; no pool-size change this
  wave.** The three rescue `{:snooze, 60}` sites return `{:error, e}` (snooze increments
  max_attempts — immortality proven in vendored Oban 2.21.1: basic.ex:266 `inc: [max_attempts:
  1]` exactly refunds fetch's `inc: [attempt: 1]`; error discards at attempt 5 with backoff);
  `add_edges` is batched (4 queries/edge × ~2850 edges ≈ 70% of a ~16k-query rebuild); the
  per-doc `list_schemas` N+1 gets the `schemas:` prefetch `/v1/graph` already uses; the hydrate
  N+1 is batched outside the transaction; the rebuild transaction gets an explicit chosen
  timeout. Why: the loop is structurally unable to converge (20s of work in a default-15s
  transaction) and raising POOL_SIZE just moves contention into Postgres — sizing waits for
  guerrilla-db-probe evidence (backlog).
- **D12 — The `e2.id == e1.id` upsert contract survives batching.** Batched inserts reload
  surviving rows by triple; canonical-row semantics (edges.ex fetch_content_edge!) are a pinned
  test contract (edge_extract_test.exs:298), not an accident.
- **D13 — limit-1000 is NOT raised and is NOT the graph-starvation cause.** Papers are 86.6%
  orphaned though never truncated; tasks 6.0% though truncated (measured on guerrilla
  production). Raising the cap multiplies the dominant per-doc cost and fixes the wrong 6%.
  Paper-orphan root cause is filed to backlog (`jpf-bl-paper-orphans-rootcause`).
- **D14 — App-auth (private repos) is an ADDITIVE credential provider, later, and lands only
  AFTER the identity flip.** gh-1 is an unfired human gate; the minting primitive exists but is
  installation-WIDE (empty access_tokens body) and has zero production callers — down-scoping
  via `repository_ids` plus a repo-visibility column belong to that follow-up
  (`jpf-bl-app-auth-clone-provider`), never this wave. Under `require_worker` any token holder
  receives any team's envelope; the flip must precede credentials riding the claim.
- **D15 — The e2e acceptance harness is a NEW script (`deploy/site-push-live-proof.sh`),
  assembled from pdf-mvp0's provision/teardown front half + the site-spawner judge dialect —
  next wave, once the spine is on main.** Why: none of the four existing proofs provisions a
  box or triggers via push, and the fresh-box framing dissolves the site-leak problem for free.
- **Coverage note (recorded, not hidden):** the verify harness declared assignment
  `builder-identity-decision` never-reported after four attempts; a full report with runnable
  proofs was nonetheless present in Decide's input and its ruling (D4/D5) was adopted after
  spot-checking its rerun anchors against origin/main. If the report's provenance is ever
  doubted, its every claim carries a `git show origin/main:` rerun command.

## Roadmap

Wave 1 (this wave — 8 slices; ROUNDS ARE LAW: a round-N slice dispatches only after its `after:`
deps MERGE):

| # | Task id | Round | Size | Model | What |
|---|---|---|---|---|---|
| 1 | `jpf-w1-push-cp-lane` | 1 | large | fable | CP push lane: repo-present predicate, claim-envelope `source`, born-queued webhook, full test blast-radius rewrite (incl. the inverted same-sha test at webhook_test 478-508) |
| 2 | `jpf-w1-builder-git-clone` | 1 | large | fable | Go builder git-ref source ladder: sha-first shallow clone, terminal error classification, env hygiene |
| 3 | `jpf-w1-siteplane-script` | 1 | medium | opus | site-runtime-install.sh: arch-aware Go, explicit git install, staged systemd units in deploy/systemd/ |
| 4 | `jpf-w1-edgeprojector-tame` | 1 | large | fable | EdgeProjector: error-not-snooze, contract-preserving add_edges batching, schemas prefetch, hydrate batching, explicit transaction timeout |
| 5 | `jpf-w1-dedupwall-bound` | 1 | medium | opus | DedupWall: 5s budget, catch :exit, fail-loud dedup_unavailable, stale-comment fix |
| 6 | `jpf-w1-queue-age-alarm` | 2 | large | fable | Watchdog: Registry queued-age aggregate, barkpark_json field, Go `deploy_stalled` state, SPA + fixtures, node harness reads attention_order.json. AFTER jpf-w1-push-cp-lane merges (router.ex) |
| 7 | `jpf-w1-builder-identity` | 3 | large | fable | Five /v1/builder/* routes → require_agent + box scope; claim_queued_deployment_for_barkpark; worker.token preference removed. HIGH-FLIP-RISK (security/tenancy). AFTER jpf-w1-queue-age-alarm + jpf-w1-siteplane-script merge |
| 8 | `jpf-w1-siteplane-chain` | 4 | medium | opus | configureHost step 7c: conditional site-plane install on go-live via the hardened script, agent.token, loud-degrade narration. AFTER jpf-w1-builder-identity + jpf-w1-siteplane-script merge |

Wave 2 (sketch): `jpf-bl-e2e-push-proof` (the acceptance run — fresh box, real push, watchdog
rung, teardown), `jpf-bl-siteplane-verify-probe` (needs a new HTTPS-visible surface first — no
host-capability field exists anywhere today, and any probe also fires on the restore path),
`jpf-bl-app-auth-clone-provider` (gh-1-gated), `jpf-bl-box-credential-hygiene` (WORKER_TOKEN
rotation + token-file re-read). Full backlog: published `jpf-bl-*` children of the epic task.

## Wave log

### Wave 2026-07-31 — founding wave, round 1 of 4 (grade A-)

**Landed (5/5 round-1 slices, all gates re-run green at review, all PRs open):**

- `jpf-w1-push-cp-lane` → PR #8400 (`loop-epic/cp-push-lane-repo-present-predicate-flip-0`).
  Predicate flip + claim-envelope `source` %{kind,url,ref} + born-queued webhook rows with
  same-sha dedup. Tenancy independently re-derived at review: `builder_claim_source/1` has ONE
  call site (worker-gated claim 200) and none of the three deployment serializers carry a clone
  recipe. 117-test gate green. No review fixes.
- `jpf-w1-builder-git-clone` → PR #8401 (`loop-epic/builder-git-ref-source-ladder-sha-first--1`).
  Source ladder (artifact wins → git sha-first shallow clone → honest empty-artifact error),
  GIT_TERMINAL_PROMPT=0 + credential.helper= prompt kill, two proven-stderr TERMINAL
  classifications. Bare-repo fixtures prove checkout at a NON-TIP sha. No review fixes; temp
  workdir accumulation filed as `jpf-bl-builder-clone-hygiene`.
- `jpf-w1-siteplane-script` → PR #8402 (`loop-epic/site-runtime-install-sh-hardened-arch-aw-2-r`).
  Arch-aware Go tarball (the x86 abort fixed), explicit git ensure, staged units in
  deploy/systemd/ with a behavioural offline parity test (drift tripwire proven red).
  One review fix on the -r branch: expected tarball URLs derive from the script's GO_VERSION.
- `jpf-w1-edgeprojector-tame` → PR #8405 (`loop-epic/edgeprojector-converges-error-not-snooze-3`).
  Error-not-snooze (drain test: 4 failures + 1 discard, 0 snoozes — the immortal loop is dead),
  contract-preserving add_edges batching (D12 e2.id==e1.id pinned), schemas prefetch, hydrate
  batching, explicit 60s txn budget. 73-test gate green. No review fixes. CI note: the enqueue
  test is sensitive to leftover committed oban_jobs rows in a dirty test DB.
- `jpf-w1-dedupwall-bound` → PR #8406 (`loop-epic/dedupwall-gets-the-8136-discipline-bound-4`).
  5s budget on all 3 Repo calls, rescue + catch :exit + rollback branch, fail-loud
  `dedup_unavailable` forwarded through AuthoringWall, `content.dedup_bypass` escape, tags-only
  JSONB projection. 35-test gate green x3. No review fixes. The wave itself reproduced the
  incident live twice: filing tasks 500'd until `dedup_bypass` was set — including the review's
  own backlog filing.

**Stalled:** nothing. Charter PR #8317 open awaiting lead merge.

**Next wave / lead dispatch order (rounds are law):** (1) merge the five round-1 PRs + charter
PR #8317; on merge close each slice's merge-gated criterion. (2) Dispatch `jpf-w1-queue-age-alarm`
(round 2) after #8400 merges. (3) Dispatch `jpf-w1-builder-identity` (round 3) after the alarm +
#8402 merge — HIGH-FLIP-RISK: send a genuinely independent second reviewer for the identity/scoping
judgment before merging it. (4) Dispatch `jpf-w1-siteplane-chain` (round 4) after identity + script
merge. Then wave 2: `jpf-bl-e2e-push-proof` — the single end-to-end acceptance run on a fresh box.
Watch on deploy of `jpf-w1-dedupwall-bound`: publishes now 409 under real dedup outages
(fail-loud by design); the GitHub Intake 2xx-on-halted drop hazard now covers the publish side
too (tracked with the 503 upgrade).
