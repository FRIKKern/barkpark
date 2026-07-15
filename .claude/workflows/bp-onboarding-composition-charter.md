# Onboarding composition — one identity transaction, one trustworthy receipt (epic charter)

Epic anchor task: **`onboarding-composition-epic`**.
Source of truth for the pain: the maintainer field report **`barkpark-onboarding-painpoint-audit-2026-07-13`** (guerrilla) — one real Windows onboarding journey across Cloud → multi-team identity → custom instance hostname → Codex/Cursor MCP → Studio → publishing. 22 catalogued pain points (BP-ONB-01..22), a root-cause map, acceptance criteria, a regression matrix.

## Vision

A first-time Windows user goes from nothing to an authenticated, MCP-connected, correct-team instance with a read-only tool call proven — in under five minutes, under two for an existing Cloud user — with **no** raw token handling, direct REST, manual JSON edits, DNS spelunking, or product-source reading. The whole thing is **one transaction that emits one trustworthy receipt** (target instance ID, team, URL + aliases, auth tier, MCP tool-catalog version + names, read-only call result, exact client-reload instruction) and **NEVER** prints the bearer.

The thesis is the audit's own conclusion: Barkpark already has the hard parts (secure device auth, team-scoped backend contracts, manifest capabilities, a useful `whoami`, reliable MCP transport, a live-write paper surface). The failure is **missing composition** between them. This epic builds the composition layer, not new primitives.

## Non-negotiable grounding facts (builders read FIRST — verified against origin/main)

- **`bp task create` is NOT on the stale local binary.** File via `bp doc create task … && bp doc publish task …` (flat fields: `kind=task`, `lifecycle_status=open`, `parent_id`, `wave_paper`, `acceptance_criteria:=[…]`) or a fresh binary.
- **`CC=clang` is mandatory locally** — on macOS `cc` is a Claude wrapper, not the compiler. CI (`.github/workflows/go-tests.yml`) runs unscoped `go vet ./...` + `go test -race ./...` on Linux and does NOT need `CC=clang`; the local three-part gate is the fast pre-flight.
- **The shared checkout is diverged & volatile** (ahead/behind by hundreds; other sessions write here; `bp` gets repointed). Branch work happens ONLY in worktrees cut from `origin/main` after `git fetch`. The main checkout NEVER leaves `main`. Claim your bp task BEFORE working.
- **`.ex/.heex` changes WAIT for the Elixir Test CI gate** before merge; Go/doc-only merge on their own gate.
- **BP-ONB-04's backend + Studio render are DONE and merged.** `mint_studio_link/1` is live (`cloud/lib/barkpark_cloud/registry.ex`), the `/login` "Log in with Barkpark Cloud" button renders whenever `Application.get_env(:barkpark, :cloud_login_url)` is set (`session_controller.ex`, sourced from `BARKPARK_CLOUD_URL` at `runtime.exs`), and **provisioning stamps `BARKPARK_CLOUD_URL` on ALL paths** — the warm pool delegates to the canonical `setup.CaddySteps` (`warmpool.go` → `defaultCaddySteps.Steps` → `setup.CaddySteps`, `caddy.go:143`). Do NOT rebuild any of this.
- **BP-ONB-02/03 are WIRING, not backend build.** The team-credential backend is MERGED: `GetCredentialsForTeam(ctx,id,teamID)` sets `X-Barkpark-Team` (`internal/cloudclient/client.go`), server `resolve_team/2` (`cloud/lib/barkpark_cloud/web/auth.ex`) honors it for MEMBERS with a safe fallback, `bp barkparks --all` cross-team fleet is live. CAVEAT (load-bearing): `X-Barkpark-Team` is honored for **SESSION-token** auth (the `bp login` device flow) but **NOT for PAT auth** (PATs are hard-bound to `pat.team_id`); and `Accounts.get_team/1` is UUID-only, so `bp team use <slug>` must resolve slug→UUID **client-side** from the `/v1/me` teams list.

## Scope

**IN (the identity transaction):** BP-ONB-02/03 (multi-team login + `bp teams`/`bp team use` + team-aware `instance credentials`), BP-ONB-04 (Cloud→Studio login surface — code done, ops backfill backlogged), BP-ONB-05 (instance-ID identity with URL aliases), BP-ONB-07 (auth-hidden vs unsupported command classification), BP-ONB-09 (decompose fleet health), BP-ONB-10..14 (PATH postcondition, name collisions, UTF-8 BOM tolerance, non-interactive device flow, tracker-policy conflict), and the unifying **onboarding `bp doctor`** + one-command journey receipt.

**Slice 0 (shipped wave 1): release-cadence guard.** `make doctor` warns when `releases/latest` drifts behind origin/main. Root-cause fix; prevents recurrence of BP-ONB-01/06/08 (all closed by the 1.15.0 ship).

**OUT (folds into authoring-excellence):** BP-ONB-15,16,17,18,20,21,22 — publishing/authoring parity from the audit's second journey. Cross-link, don't duplicate (`onb-backlog-authoring-parity-crosslink`).

## Decisions

- **D1 Ship-first.** Slice 0 (guard) + the 1.15.0 re-audit precede feature work. *Why: the root failure was release cadence (2,391 commits past `releases/latest`), which shipped a stale product to every new user; three audit findings closed by ship alone.*
- **D2 Wire, don't rebuild.** Every slice names the merged primitive it composes. *Why: the gap is composition, not missing primitives; rebuilding risks a parallel wrong-axis store.*
- **D3 One receipt is the deliverable.** Success = a single `bp` command family producing the audit's receipt shape. *Why: verbs are means; the trustworthy envelope is the end.*
- **D4 Identity keyed by instance ID, not URL string** (BP-ONB-05). Canonical + custom hostnames are aliases on one instance record with one credential. *Why: URL-keying mints a phantom "-2 / gyldendal-2 second server" on a second hostname.*
- **D5 Acceptance = the audit's own criteria + regression matrix.** Every slice cites its BP-ONB id, stamps met:true with file:line + PR + run-proof. *Why: the regression matrix (OS × account × instance × auth × client × version × MCP × config × paper) is the coverage target.*
- **D6 (wave-1, headline) REVERSED.** The seed assumed no team-scoped credential backend; verification proved it MERGED. BP-ONB-02/03 re-filed as one WIRING slice. *Why: survey beat the seed assumption.*
- **D7 Slice 0 is highest-leverage.** *Why: same release-cadence root cause as D1.*

### Wave 2 decisions (2026-07-14/15)

- **D8 RECOVER, don't rebuild.** Wave 1's identity code is complete and gate-green but **STRANDED on unpushed local branches** — Decide committed to a diverged local main and never PR'd (the wave-1 charter itself was stranded the same way). The commits: `68d9cbe09` (instance-ID identity + URL aliases + BOM-tolerant config + whoami/servers fields + failing-first tests), `36eb52edd` (team-aware identity — `bp teams` / `bp team use` + `--team` credentials + `Client.Me()`), `5e941c128` (`bp doctor --onboarding` client-readiness receipt). Verification proved these **rebase cleanly onto current origin/main** (doctor: zero conflicts, `go build` green; config hunks untouched territory). *Why: re-landing gate-green code onto fresh worktrees off origin/main + re-gating is far cheaper and more honest than a rewrite. NEVER reuse the stale `wave-integration-check` branch wholesale (78 commits behind, other slices mixed in) — cherry-pick/re-apply the named commits onto a branch cut from `origin/main`.*
- **D9 Ship the activation, not just the plumbing.** Wave 1's `ServerEntry.InstanceID/Aliases` was built but **INERT** — no caller stamps a real ID, so the phantom-"-2" bug is NOT fixed in production. Slice 1 lands the config core AND wires the connect caller: `finishSingleBarkpark`/`finishMultiBarkpark` already hold the fleet row (`cloudclient.Barkpark.ID` + `.Team`) in scope; widen `connectToBarkpark` → `setup.SetupPlan` → `SavedConfig` → `ServerEntry` to carry the ID + team through. *Why: built-but-dormant is the exact wave-1 failure; the wish's headline (no phantom "-2") only lands when a real ID is stamped. Source the ID from the fleet row already in scope — NOT a new `DomainStatus` call.*
- **D10 whoami is the single receipt spine; doctor composes over it (no fork).** The stranded `doctor_onboarding.go` built a SEPARATE `onboardingReceipt` struct. Slice 3 lands the receipt tail (instance_id, aliases, MCP catalog version+names, read-only call result, reload instruction) on the `bp whoami -o json` payload (`builtins.go`) and has `bp doctor --onboarding` compose over that spine. *Why: the charter forbids a second receipt; one honest envelope, extended additively.*
- **D11 BP-ONB-04 is DONE in code; only ops backfill remains.** Fresh provision stamps `BARKPARK_CLOUD_URL` on all paths (warm pool → `setup.CaddySteps`); the button renders when `cloud_login_url` is set. *Why: the "warm pool skips it" survey claim was REFUTED at `warmpool.go` → `defaultCaddySteps` → `setup.CaddySteps`. The only gap is the ops fleet backfill for instances provisioned before the stamp merged (gyldendal) — human/ops-gated, stays backlog (`onb-backlog-cloud-url-fleet-backfill`).*
- **D12 'Catalog version' = `cliVersion`.** No separately-versioned MCP catalog exists; the 8-tool catalog ships in lockstep with the `bp` binary (`mcp_serve.go` `Implementation.Version = cliVersion`). *Why: don't invent a versioning scheme; names stay the compile-pinned `mcpTaskToolNames` literal, CI-guarded against registration drift by `TestOnboardingMCPCatalogMatchesRegistration`.*
- **D13 File-disjoint from cloud-build W6.** Onboarding wave-2 slices touch `internal/cli/**` and `internal/cloudclient/**` only — no `api/**`, no `cloud/**`, no `api/lib/barkpark/search/**` or `media/delivery/**`. *Why: the concurrent tenancy/search cycle owns those; zero collision surface.*
- **D14 Serial re-land order 1 → 2 → 3.** Slices collide on `cloud12_cmd.go` (1∩2) and `builtins.go` + `cli.go` (2∩3). Integration order: identity-core → team → receipt (the receipt needs the core's fields and the team's completion nouns). *Why: builders branch fresh off origin/main in isolated worktrees and commit locally without pushing; the steward merges in order, each rebasing on the prior. Slice-1 owns `config.go`/`config_test.go`/`servers_cmd.go` (drops `68d9cbe09`'s `builtins.go` hunk — that whoami tail belongs to slice 3 per D10).*

## Roadmap

| # | Slice (task) | BP-ONB | Surface | Size | Order |
|---|---|---|---|---|---|
| W1 | `onb-w1-release-cadence-guard` | 01/06/08 + guard | doctor.sh + bp upgrade | — | **shipped** |
| W1 | `onb-w1-cloud-url-provision-inject` | 04 | provisioning CaddySteps | — | **shipped (merged)** |
| W2-1 | `onb-w1-instance-id-aliases-receipt` (+ `task-e6b0bc97130bae89` activation folded in) | 05 + 12(config) | ServerEntry identity + connect activation | large | 1st |
| W2-2 | `onb-w1-team-aware-cli-identity` | 02/03 | bp teams / team use / --team creds | medium | 2nd |
| W2-3 | `onb-w1-onboarding-doctor-receipt` | D3 + 05(whoami tail) | whoami receipt spine + doctor compose | large | 3rd |
| later | `onb-w1-command-discovery-classification` | 07 | unknown-command path | small | backlog→wave |
| later | `onb-w1-fleet-health-decompose` | 09 (CLI half) | bp cloud status / barkparks | small | backlog→wave |
| later | `onb-w1-onramp-bom-tracker-safety` | 12(onramp) + 14 | onramp merge engine | small | backlog→wave |

Backlog (published children, not this wave): `onb-backlog-cloud-url-fleet-backfill` (BP-ONB-04 ops), `onb-backlog-capabilities-base-url-alias` (D4 server side), `onb-backlog-studio-verify-persistence` (BP-ONB-09 backend), `onb-backlog-noninteractive-device-flow` (BP-ONB-13), `onb-backlog-installer-path-postcondition` (BP-ONB-10 installer half), `onb-backlog-doctor-prefer-local-serverentry` (point `onboardingInstance` at the new local `ServerEntry.InstanceID/Aliases` instead of the live fleet fetch — fewer round-trips, works offline).

## Wave log

- **Wave 1 (2026-07-13, paper `bp-onboarding-composition-wave-2026-07-13`, grade A-):** 8 slices built + individually gated + proven to integrate on one branch — but the whole wave was **committed to a diverged local main and never pushed/PR'd**, so origin/main carries only `onb-w1-release-cadence-guard` and `onb-w1-cloud-url-provision-inject`. The identity core, team CLI, and doctor receipt are gate-green on stranded unpushed branches (`68d9cbe09`, `36eb52edd`, `5e941c128`). Load-bearing lesson: Decide MUST land its charter + builders MUST push via the steward; "done on a local branch" is not done.
- **Wave 2 (2026-07-14/15, paper `onboarding-composition-wave-2026-07-14`):** RECOVER wave (D8). Re-land the three stranded commits onto fresh worktrees off origin/main, activate the inert InstanceID plumbing (D9), fold the receipt tail onto the whoami spine (D10), serial merge order 1→2→3 (D14). Slices: `onb-w1-instance-id-aliases-receipt` (identity core + connect activation), `onb-w1-team-aware-cli-identity` (team CLI), `onb-w1-onboarding-doctor-receipt` (whoami receipt spine + doctor). BP-ONB-04 confirmed done in code (D11); only ops fleet backfill remains backlogged. All builders Opus (Fable exhausted).

### Wave 2 REVIEW (2026-07-15, grade A) — LANDED (pending lead merge)

All three RECOVER slices re-landed gate-green off origin/main and **integrate with ZERO conflicts** — the three feature commits (`557a87071`→`013af2330`→`999a54c24`) cherry-pick in charter order 1→2→3 onto one branch (`wave2-integration`, HEAD `946cc752f`); the full `CC=clang go build/vet/test ./internal/cli/... ./internal/cloudclient/...` gate is green. Every load-bearing test is protective (BOM red-without-strip, connect-seam collapse, X-Barkpark-Team value end-to-end, no-bearer with seeded secrets, live MCP-catalog match len==8, 403-not-rubber-stamped).

- **Reviewer fix (D9 activation, folded from `onb-backlog-doctor-prefer-local-serverentry`):** the whoami spine had shipped `localInstance` reading only URL/name/team — `instance.id`/`aliases` stayed EMPTY even after slice 1 makes `ServerEntry.InstanceID/Aliases` available. Since the wish names "instance ID … URL+aliases" as receipt fields, that inert plumbing was the exact wave-1 failure repeating. Fixed on `wave2-integration`: whoami now reads the stamped identity (prefers the entry's owning-team over the active session team), with two red-without-fix tests. The doctor-path offline optimization stays in that backlog task.
- **Ledger:** all 3 slice tasks + folded `task-e6b0bc97130bae89` honestly stamped `in_progress` with file:line/test evidence; the 4 merge-gated "PR merged" criteria stay OPEN for the lead. No out-of-wave task touched.
- **Next wave:** lead merges 1→2→3 (or `wave2-integration` as the wave) + closes the merge-gated criteria; then the backlog→wave candidates are command-discovery classification (BP-ONB-07), fleet-health decompose (BP-ONB-09 CLI half), onramp BOM/tracker safety (BP-ONB-12 onramp + 14); BP-ONB-04 ops backfill stays human-gated. Epic then rests on live end-to-end proof of the sub-5-min Windows journey against a real Cloud instance.
