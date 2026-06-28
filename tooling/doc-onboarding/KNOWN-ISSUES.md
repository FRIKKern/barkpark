<!-- doc-tier: human | canonical-for: onboarding-known-issues | budget: 1200tok -->
# Onboarding — mined issues backlog

> **Gate discipline (every tick):** before committing doc edits, run
> `bash scripts/check-doc-budgets.sh` and `bash scripts/docs-anchors-check.sh`.
> The byte caps are tight and CI-enforced — adding onboarding content usually
> means trimming/retiring elsewhere in the same doc. Never raise a cap.


Issues the Onboarding/Time-to-Value sweep found that **need a decision or a code change**,
so they are NOT auto-fixed in the docs loop. Ordered by leverage. Tick-dated.

## BLOCKER-1 — CLI `--plan` validator out of sync with the server ✅ FIXED 2026-06-28

Synced `billingPlans` (cloud12_cmd.go) to the authoritative server set
`{free, supporter, support_plus}`; updated all usage/help strings and the ~6
tests asserting the old `starter|pro|business|dedicated` names. `go build` +
`go vet` + full `go test ./internal/cli/` green; gofmt clean. `bp subscribe
--plan supporter` now reaches the server. This unblocks DOC-1 + DOC-2.
Also fixed the now-valid `--plan supporter` command in the go-live runbook.

---

### (original) BLOCKER-1 — CLI `--plan` validator is out of sync with the server (code bug)

- **Where:** `internal/cli/cloud12_cmd.go:477` — `billingPlans = {"free","starter","pro","business","dedicated"}`.
- **Truth:** the control plane validates `@plans ~w(free supporter support_plus)`
  (`cloud/lib/barkpark_cloud/billing/subscription.ex:34`, `validate_inclusion(:plan,@plans)`).
- **Effect:** `bp subscribe --plan supporter` is **rejected client-side** (not in the stale set);
  `bp subscribe --plan pro` passes the CLI but the server 422s `plan_invalid`. The documented
  happy path cannot be written correctly until the validator is fixed.
- **Blast radius if fixed:** the validator's own comment says it "mirrors the control plane's @plans"
  — so this is a drift bug, not a design choice. But the fix flips CLI behavior and rewrites tests
  that assert `pro`/`starter` pass the guard (`cloud12_cmd_test.go:388,452,463,469,519,522,597`),
  plus usage/help strings at `cloud12_cmd.go:515,521,836,959,969` and go-live examples at `448,810,941,950`.
- **Decision needed (user):** confirm the canonical user-facing tier names (display: Supporter $69 /
  Support++ $499 USD; slugs `supporter` / `support_plus`), then sync the CLI + tests in one PR.
- **Until then:** no `bp subscribe --plan …` / `bp go-live --plan …` examples in user docs.

## DOC-1 — Cloud pricing doc is wrong ✅ DONE 2026-06-28

Fixed go-live runbook Gate 4: euro tiers (Free €0 / Starter €69 / …) → Supporter
$69 / Support++ $499 USD + `free` (signup-only); env names `STRIPE_PRICE_STARTER/
_PRO/...` → `STRIPE_PRICE_SUPPORTER` / `STRIPE_PRICE_SUPPORT_PLUS` (verified in
cloud/config/runtime.exs:62-63). The `--plan` command was fixed with BLOCKER-1.
Runbook re-verifies clean (22 confirmed, 0 false/stale).

### (original) DOC-1 — Cloud pricing doc is wrong (gated on BLOCKER-1)

- **Where:** `docs/ops/barkpark-cloud-go-live.md` Gate 4 (line 74) — "Free €0 / Starter €69 /
  Pro €149 / Business €399 / Dedicated €999+"; flow at line 100 uses `bp subscribe --plan pro`;
  env vars `STRIPE_PRICE_STARTER/_PRO/_BUSINESS/_DEDICATED` (75-76).
- **Truth:** shipped tiers are `free` / `supporter` ($69) / `support_plus` ($499), **USD**
  (`subscription.ex`, `#280`). Wrong currency, wrong names, wrong count.
- **Why deferred:** the corrected `--plan supporter` command is broken until BLOCKER-1 lands, so
  fixing the prose without the command would leave a half-correct runbook. Fix pricing + command + env
  vars together after BLOCKER-1.

## DOC-2 — Cloud onboarding surface ✅ DONE 2026-06-28

Wrote `docs/setup/CLOUD-QUICKSTART.md` — the verified `bp signup → subscribe
--plan supporter → go-live` waterfall (+ BYO-provider `bp provider add` / `bp
launch`). Every path + command doc-truth-verified (10/10, 0 false/stale).
Linked from QUICKSTART's decision tree + INDEX; added to the analyzer's scanned
set. Onboarding currency-coverage 80→100, path-completeness 82→100, overall →93.

Remaining DOC-1 (now unblocked): the go-live runbook Gate 4 still prints euro
tiers (Free €0 / Starter €69 / …) and STRIPE_PRICE_STARTER/_PRO/... env names —
fix to Supporter $69 / Support++ $499 USD + STRIPE_PRICE_SUPPORTER/SUPPORT_PLUS
(verify exact env names in cloud/config/runtime.exs first).

### (original) DOC-2 — Cloud onboarding surface does not exist (biggest currency gap)

- ~30 `feat(cloud)` PRs (#251–#283) — `bp signup/login/subscribe/launch/go-live/barkparks/doctor/
  sites/deploy`, Stripe billing, SSE dashboard — have zero coverage in README/QUICKSTART/`bp.md`.
- **Plan:** new `docs/setup/CLOUD-QUICKSTART.md` + a Cloud row-block in `docs/cheatsheets/bp.md` +
  a Cloud-first path in the README "Get started" decision tree. **Gated on BLOCKER-1** for any
  `--plan` step; the signup/login/barkparks/doctor steps can be written now (verify each flag first).

## DOC-3 — `cloud/README.md` frozen at scaffold ✅ DONE 2026-06-28

- Was: "skeleton … identity (cloud-8) and the instance registry (cloud-9) land in later tasks."
- Now: describes the shipped control plane (Accounts/Registry/Billing/Events/Sites/Health + agent +
  provisioner + SSE dashboard) and the verified `bp` customer flow (signup/login/barkparks/launch/
  go-live/doctor — no `--plan` step, so BLOCKER-1-safe). Budget marker bumped 200→700tok.

## DOC-6 — prose-level issues the mechanical passes can't catch (deep-read vein)

The doc-truth/priority/waterfall passes only catch mechanical claims; substantive
prose errors need a careful read. Found + fixed so far:
- ✅ `tui.md` + README "Four ways in": "Launch `barkpark`" → `bp` (the dev-only
  binary name; installer ships `bp`); `bp setup connect` → `--target connect`.

Remaining to verify+fix (flagged by the original ASSESSMENT, NOT yet confirmed —
verify against code before editing):
- `sdk/README.md` — wrong-door: it's the Bulldocs **ingest** SDK (PortableDoc/
  pdrender), not the general `@barkpark/core` JS SDK (which is `js/packages/core`).
  A newcomer expecting "the SDK" lands in the wrong package.
- `js/README.md` — only command is `pnpm install`; no consumer happy path.
- `web/README.md` — claimed README vs `.env.example` API-default contradiction.
Each: read the package + its sub-READMEs, confirm the claim, fix only what's real.

## DOC-5 — high-reach modules with NO @moduledoc (doc-truth priority pass)

`tooling/doc-truth/priority.mjs` flags high-reach (p90+) files with zero doc
coverage. Most already carry a good `@moduledoc` (the tool measures .md coverage,
not in-code docs — a known blind spot). The genuine gaps are modules with NO
moduledoc at all:
✅ DONE 2026-06-28 — the priority queue now has **zero** no-moduledoc gaps.
Documented (all verified against code/config, `mix format` clean):
`vault.ex`, `encrypted_map.ex` (Cloak encryption), `repo.ex` (Ecto repo),
`content/document.ex` (the core documents schema), `auth/api_token.ex` (API
bearer tokens — SHA-256 hashed), `plugins/settings_record.ex` (encrypted
settings row) + `plugins/settings_audit.ex` (settings access audit log).
The rest of the priority list already carried moduledocs (the tool measures
`.md` coverage, not in-code docs — a known blind spot, not a real gap).

## DOC-4 — stale "skeleton / later task" language inside cloud moduledocs ✅ DONE 2026-06-28

- Fixed: `web/router.ex` ("dashboard is a later task" → live dashboard, SSE via `GET /v1/events`),
  `stripe_gateway.ex` ("SKELETON … human wires a real client in cloud-17" → HttpClient wired #281;
  only live keys/price-ids remain the human gate), `billing.ex` + `health.ex` "skeleton" wording.
- **Left intentionally:** stripe_gateway's `create_subscription/2` "sends a `plan` placeholder, not a
  real `price_…`" claim (lines ~14-16) — not fully traced; an unedited maybe-stale comment beats a
  wrongly-corrected one. Verify the subscription-creation price-id path before touching it.

## Done this loop (2026-06-28)
- README: led with a "Try it now" Studio CTA; demoted the self-grade table below the fold.
- QUICKSTART: stripped the vestigial "premium-setup branch / (wizard)" provisional stamp.
- INDEX: added the real-but-unlinked `ops/barkpark-cloud-go-live.md` runbook.
