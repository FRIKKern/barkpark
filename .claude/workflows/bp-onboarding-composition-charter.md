# Onboarding composition — make team + instance + alias + credential + onramp ONE explicit transaction (onboarding-composition epic charter)

Source of truth: the maintainer field report **`barkpark-onboarding-painpoint-audit-2026-07-13`** (Revision 5,
on guerrilla). It documents one real Windows onboarding journey across Cloud → multi-team identity → custom
instance hostname → Codex/Cursor MCP → Studio → publishing. 22 catalogued pain points (BP-ONB-01..22), a
10-item root-cause map, acceptance criteria, and a regression matrix. Server: guerrilla.barkpark.cloud.

## Vision

A first-time Windows user goes from nothing to an authenticated, MCP-connected, correct-team instance with a
read-only tool call proven — in under five minutes, under two for an existing Cloud user — with **no** raw token
handling, direct REST, manual JSON edits, DNS spelunking, or product-source reading. The whole thing is **one
transaction that emits one trustworthy receipt** (target instance ID, team, URL + aliases, auth tier, tool
catalog version + names, read-only call result, exact client-reload instruction) and NEVER prints the bearer.

The audit's own conclusion is the thesis: Barkpark already has the hard parts (secure device auth, team-scoped
backend contracts, manifest capabilities, a useful `whoami`, reliable MCP transport, a live-write paper surface).
The failure is **missing composition** between them. This epic builds the composition layer, not new primitives.

## Non-negotiable grounding facts (builders read FIRST — VERIFIED against origin/main 2026-07-13)

- **THREE audit findings are already closed by shipping, not code.** The audit ran against a hand-built `dev`
  binary while the installer resolves the month-stale `cli-v1.14.0`. `cli-v1.15.0` was cut 2026-07-13 from
  origin/main (`86f69b1c`) and closes:
  - **BP-ONB-01** Windows binary — cross-compile lands `bp-windows-amd64.exe` / `-arm64.exe` since #118 (13 Jun).
  - **BP-ONB-08** MCP catalog 5→8 — `task_prime/pulse/stamp` are on main (`internal/cli/mcp_tasks.go`).
  - **BP-ONB-06** `onramp --write` print-only — `--write` shipped on main (`internal/cli/onramp_cmd.go`).
  Re-run the audit against the 1.15.0 binary before building anything scoped to these; several P1/P2s may
  already be gone.
- **The root failure is release cadence.** origin/main was 2,391 commits past `releases/latest`. `install-cli.sh`
  and `bp upgrade` resolve `releases/latest`, so a month of drift shipped a stale product to every new user.
  A guard belongs in this epic (see Slice 0).
- **BP-ONB-04's backend EXISTS.** `mint_studio_link/1` is live at `cloud/lib/barkpark_cloud/registry.ex:2246`
  (swappable `:studio_link_http_client`, team-admin-gated). The gap is SURFACE only: a "Continue with Barkpark
  Cloud" entry on the instance login page + the console path. Do NOT rebuild the mint; wire it.
- **BP-ONB-02/03 are WIRING, not backend build (D6 REVERSED by wave-1 verification).** The seed charter warned
  the team-credential backend might not exist. It does — verified on origin/main tip (9183d5fd, 0 behind): PR
  `7b14b8d9` (merged 2026-07-13, ancestor of main) shipped `GetCredentialsForTeam(ctx,id,teamID)` at
  `internal/cloudclient/client.go:528` (sets `X-Barkpark-Team` at :536), server `resolve_team/2`
  (`cloud/lib/barkpark_cloud/web/auth.ex:60`) honors the header for MEMBERS with safe fallback, and
  `bp barkparks --all` cross-team fleet is live. The seed's `client.go:491` line number is stale. Surviving work
  is pure CLI surface: `bp teams` / `bp team use` (no such verb exists; `cfg.CloudTeam` is login-only, not
  switchable) + a `--team` flag on `bp instance credentials` (still plain `GetCredentials` at `cloud12_cmd.go:1386`).
  CAVEAT (verified): `X-Barkpark-Team` is honored for SESSION-token auth (the `bp login` device flow) but NOT for
  PAT auth (PATs are hard-bound to `pat.team_id`); and `Accounts.get_team/1` is UUID-only, so `bp team use <slug>`
  must resolve slug→UUID client-side from the `/v1/me` teams list.
- **Shared checkout is diverged & volatile** (ahead/behind by 100s; other sessions write here; bp gets repointed).
  Worktrees from `origin/main` after `git fetch`. Claim your bp task BEFORE working. `.ex/.heex` changes WAIT for
  the Elixir Test CI gate before merge. `cc` is a Claude wrapper — always `CC=/usr/bin/clang`. `bp task create`
  is NOT on the stale local binary — file via HTTP mutate (`_type:task`, `kind:task`, `lifecycle_status:open`,
  flat fields, publish) or a fresh binary.

## Scope

**IN (Initiative A — the identity transaction):** BP-ONB-02 (multi-team login + `bp teams`/`bp team use`),
BP-ONB-03 (team-aware `instance credentials`), BP-ONB-04 (Cloud→Studio signed-link login surface), BP-ONB-05
(instance-ID identity with URL aliases), BP-ONB-07 (auth-hidden vs unsupported command classification), BP-ONB-09
(decompose fleet health into agent/API/Studio/probe), plus P2 recovery BP-ONB-10..14 (PATH postcondition, name
collisions, UTF-8 BOM tolerance, non-interactive device flow, tracker-policy conflict detection), and the unifying
**onboarding `bp doctor`** + one-command journey receipt.

**Slice 0 (do first): release-cadence guard.** `make doctor` warns when `releases/latest` drifts N commits / D
days behind origin/main. This is the root-cause fix; it prevents recurrence of BP-ONB-01/06/08.

**OUT (Initiative B — folds into authoring-excellence, NOT this epic):** BP-ONB-15,16,17,18,20,21,22 — the
publishing/authoring parity findings surfaced by the audit's SECOND journey (body_html vs blocks read parity,
converter `<br>` truncation, publish-wall schema, target-mismatch receipts, bulldocs get/list/export, duplicate
compare). These overlap the open authoring-excellence wave 2. Cross-link, don't duplicate.

## Decisions (seed — the wave's Decide phase ratifies/extends)

- **D1 Ship-first.** Slice 0 (guard) + confirming the 1.15.0 re-audit precede any feature slice. Close the three
  shipped findings on the ledger with the release as evidence before building.
- **D2 Wire, don't rebuild.** BP-ONB-04 uses the existing `mint_studio_link/1`. BP-ONB-03 reuses whatever
  team-header support the control-plane route already exposes (survey first). Every slice names the existing
  primitive it composes.
- **D3 One receipt is the deliverable.** The epic's success is a single `bp` command family that produces the
  audit's receipt shape. Individual verbs (`bp teams`, `bp team use`, `--team`) are means; the receipt is the end.
- **D4 Identity keyed by instance ID, not URL string** (BP-ONB-05). Canonical + custom hostnames are aliases on
  one instance record with one credential. This is the fix for the "gyldendal-2 / phantom second server" class.
- **D5 Acceptance is the audit's own criteria + regression matrix.** Every slice cites the BP-ONB id it closes and
  stamps met:true with file:line + PR + run-proof. The regression matrix (OS × account × instance × auth × client
  × version × MCP × config × paper) is the coverage target.

## Wave shape

Survey (does the control-plane credentials route take a team header? does device-approval have any team-selection
seam? what does `bp doctor` cover today?) → digest → verify claims with run output → decide + file the BP-ONB task
tree under the epic anchor with acceptance_criteria → build Slice 0 + the ratified P0 slices in worktrees → review,
stamp, grade, close the wave Paper.

## Wave 1 — ratified decisions (Decide, 2026-07-13)

Epic anchor: **`onboarding-composition-epic`**. Wave Paper: **`bp-onboarding-composition-wave-2026-07-13`**.
All builders/verifiers are Opus or Sonnet — never Fable (spend-exhausted this wave).

- **D6 REVERSED (headline).** The team-credential backend + Go primitives are MERGED and green (see grounding
  fact above). BP-ONB-02/03 re-filed as one WIRING slice, not a backend survey.
- **D7 Slice 0 is the highest-leverage change.** The root failure is release cadence; the drift guard
  (`scripts/doctor.sh` cli-v* check + hardening `bp upgrade`'s `latestReleaseVersion` with a GitHub cli-v* API
  fallback) ships first. cli-v1.15.0 already closes BP-ONB-01/06/08 by ship — confirmed by re-audit
  (Windows assets, 8-tool MCP catalog, idempotent onramp --write); no rebuild.
- **BP-ONB-04** is provisioning-only: inject `BARKPARK_CLOUD_URL=https://barkpark.cloud` in
  `setup.CaddySteps` (`internal/cli/setup/caddy.go`, right after the PHX_SCHEME step) — the single chokepoint both
  `provision.go` and the warm pool delegate to. Fleet backfill + the base_url-leaking gyldendal redeploy are ops
  backlog, not code.
- **BP-ONB-09 split.** The cheap CLI half (surface `last_seen_at`, stop the one-line `degraded` OR-collapse from
  hiding which signal failed) ships this wave; persisting a studio-verified signal onto the barkparks row (Elixir
  migration + `run_verify/3` UPDATE) is backlog.
- **BOM (BP-ONB-12)** splits by file to keep slices disjoint: the `config.go` LoadConfig BOM strip rides the
  instance-ID slice (which owns `config.go`); the `onramp_write.go` BOM + tracker-policy conflict is its own slice.
- **The unifying onboarding `bp doctor` + one-command receipt (D3)** is built as a section of `bp doctor`
  (`internal/cli/doctor_onboarding.go`, disjoint from the CLI verb-dispatch hot files) composing primitives already
  on main (PATH lookpath, `latestReleaseVersion`, `ListAllBarkparks` team+instance identity, `RunHealthGate`
  API/Studio, the 8-tool MCP catalog, a read-only `task_ready` call-proof) — richer as siblings merge; never prints
  the bearer.

### Wave 1 slice tree (all published under the epic, all carry the wave Paper id)

| Task | BP-ONB | Surface | Model |
|---|---|---|---|
| `onb-w1-release-cadence-guard` | 01/06/08 (close) + guard | doctor.sh + bp upgrade | opus |
| `onb-w1-team-aware-cli-identity` | 02/03 | bp teams / team use / --team creds | opus |
| `onb-w1-instance-id-aliases-receipt` | 05 + 12(config) | ServerEntry identity + whoami receipt | opus |
| `onb-w1-cloud-url-provision-inject` | 04 | provisioning CaddySteps | opus |
| `onb-w1-onramp-bom-tracker-safety` | 12(onramp) + 14 | onramp merge engine | opus |
| `onb-w1-command-discovery-classification` | 07 | unknown-command path | opus |
| `onb-w1-fleet-health-decompose` | 09 (CLI half) | bp cloud status / barkparks | opus |
| `onb-w1-onboarding-doctor-receipt` | D3 + 10 (client) | bp doctor onboarding section | opus |

File-collision notes (dispatch frontier serializes): `cli.go` shared by team-identity + command-classification;
`cloud12_cmd.go` shared by team-identity + fleet-health. Everything else disjoint.

Backlog filed (published children): `onb-backlog-studio-verify-persistence`, `onb-backlog-cloud-url-fleet-backfill`,
`onb-backlog-noninteractive-device-flow` (BP-ONB-13), `onb-backlog-installer-path-postcondition` (BP-ONB-10 installer
half), `onb-backlog-capabilities-base-url-alias` (D4 server side). BP-ONB-15..22 authoring parity cross-linked under
`authoring-excellence` via `onb-backlog-authoring-parity-crosslink` — not duplicated.
