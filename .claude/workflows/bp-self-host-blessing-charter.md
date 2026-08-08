# Self-Host Blessing — Epic Charter

Epic task: `task-3ae717d5f9324399` · Program task: `task-21cd02088dd2f762` ·
Founding papers: `/papers/hobby-hardening-capstone` (crown) ·
`/papers/hobby-hardening-selfhost-packaging` (lane) · `/papers/barkpark-hobby-scale-swot` (frame)

This file is the epic's memory. Decisions (D#) are never silently reversed — a reversal is a new
numbered decision naming the old one and the evidence that moved.

## Vision

**A stranger stands up production Barkpark from the runbook alone.**

Falsifiable form: a scripted clean-VM cold start, driven only by the runbook, reaches a serving
instance — and the script can fail.

**Ground truth at epic open (2026-08-07):** no root `.env.example`, no SELF-HOST runbook, no TLS
story, no CI job has ever built `api/Dockerfile`, and the compose file carries two silent
booby-traps that boot clean and fail later: (1) `docker-compose.yml:23` defaults
`SECRET_KEY_BASE` to the 26-byte LITERAL `$(openssl rand -base64 48)` — compose-spec interpolation
preserves `$()` verbatim, never executes it; runtime.exs:737-740 checks presence only; Plug raises
under 64 bytes at first cookie/token derive (deps/plug cookie.ex:183-184) — app up, first session
500s. (2) The environment allowlist passes 10 of ~105 read env vars, making `PHX_SCHEME`,
`BARKPARK_TRUSTED_PROXIES`, `SMTP_*` and every TLS-relevant knob a silent no-op. Postgres version
truth is six sources with no two agreeing: compose 17-alpine · cloud compose 15-alpine · four CI
workflows 15 · SETUP.md "14+/tested 17.9" · deploy.sh unpinned apt (distro default 14/15/16/17) ·
no boot assertion.

## Decisions

- **D1 — The epic builds its OWN gate, because no blocking gate covers its files — and until that
  gate exists the charter says honestly that its proofs are a discipline, not a gate.** *Why:*
  root compose, `docs/**`, and `deploy.sh` sit in NO auto-deploy trigger set and NO required
  check's path population; honest-gates D18 proves paths-filtered workflows are structurally
  unrequirable. The gate is slice S6's CI compose smoke — `api/Dockerfile`'s first-ever gate —
  plus a recorded clean-VM proof re-run per wave (no cold-start harness exists to reuse; the
  nearest building block is the bp cloud hetzner client).

- **D2 — Scope is taken or refused by number, never drifted into. The shared-box persona items —
  schema prefix for the 183 public-schema migrations, vendor-domain purge from check_origin/CORS
  defaults — are REFUSED in this epic.** *Why:* they would swell E3 from ~3 to ~5 waves. Decided
  policy stands: dedicated database, never schema prefix (zero Ecto `:prefix` support,
  auto-migrate on every container boot); all three extensions are trusted contrib — a plain db
  owner suffices on PG13+. A future epic may take the persona items by name.

- **D3 — Postgres floor is 15; recommended install is 17. The floor equals what a meter actually
  tests.** *Why:* 15 is the only version CI has ever tested — claiming 17 would be a number
  without a meter (distrust vacuous green). Ship 17 in compose as the recommended install; bump CI
  to 17 in a follow-on BEFORE the floor ever rises. A warn-probe lands beside `check_pg_trgm`
  (application.ex:335-357 — the existing warn-and-continue pattern and seam); warn-vs-refuse teeth
  are a user call recorded as a D# when made. The six-source grep re-runs in CI so future drift
  REDDENS.

- **D4 — Fix the traps before documenting around them: compose correctness (S1) precedes the
  runbook (S4).** *Why:* a runbook that documents a booby-trapped compose blesses the trap. S1
  deletes the SECRET_KEY_BASE pseudo-default (hard-require it like the other four secrets, with a
  boot-time refusal citing LENGTH, not presence — the current presence-check is the vacuous-green
  baseline), widens the env allowlist with a grep-proof DoD (absorbing
  `pdf-bl-limit-env-passthrough` by name and fixing the cloud compose's LIMIT_* gap in the same
  slice), and adds the missing api healthcheck.

- **D5 — TLS ships as host-Caddy-first, with an OPT-IN `--profile tls` sidecar — never inside the
  minimum install.** *Why:* the 2-process minimum (BEAM + Postgres) is program law; a third
  process in the minimum install requires an ADR. S3 extracts deploy.sh's inline Caddyfile as
  `deploy/caddy/Caddyfile.example` (host Caddy leads the runbook), adds one nginx block, and the
  sidecar uses a static ipam IP to satisfy the individual-IPs-only trusted-proxies doctrine
  without a carve-out.

- **D6 — The word "supported" is DAG-gated on E1: the runbook may ship early marked experimental,
  but the blessing lands only after E1's media-policy fix (its slice 2) merges.** *Why:* blessed
  must never mean blessed-with-known-leaks.

- **D7 — Prebuilt image publication is DEFERRED.** *Why:* Coolify and Dokploy build from source
  natively; only remote Portainer needs a registry image, and CI must gate the build (S6) before
  anything publishes it. Revisit by number after S6 is green for a full wave.

- **D8 — deploy.sh is edited only after reading the PDS wave notes.** *Why:* deploy.sh is active
  PDS territory (waves 48–49, go:embed banner). The S5 PGDG pin is a surgical edit that respects
  the live narrative there.

## Fence

**In fence:** `docker-compose.yml` · `.env.example` (new, root) · `cloud/docker-compose.yml`
(LIMIT_* passthrough only) · `api/entrypoint.sh` · `api/config/runtime.exs` (secret-refusal
region) · `api/lib/barkpark/application.ex` (floor-probe beside check_pg_trgm) ·
`deploy/caddy/Caddyfile.example` (new) · `docs/setup/SELF-HOST.md` (new) · `docs/setup/SETUP.md` ·
`docs/setup/GO-LIVE.md` (cross-links) · `deploy.sh` (S5 pin only, D8) ·
`.github/workflows/` (new compose smoke) · CI workflow pg service images (floor alignment).

**Out, by design:** guerrilla box sizing and swap (deploy-reliability); the spawned-site deploy
pipeline (site-spawner); push-to-deploy artifact builds (dwb — parked epic, cite only);
Studio/console surfaces (cch); everything `api/**` that serves requests (E1/E2 territory). Every
fence widening is a numbered, subject-scoped, not-to-be-widened-again decision in this file.

**Doc contract:** SELF-HOST.md rides human-tier like GO-LIVE.md (no new agent card — the 7-card
cap stands). SETUP.md's collision status was never independently swept — verify at wave 1.

## Roadmap

Dependency-honest order (D4): traps → truth → story → proof.

| # | Slice | Surface | Size | Wave | Status |
|---|---|---|---|---|---|
| S1 | Compose correctness: secret fail-fast (length-citing), env-allowlist widening + grep-proof, LIMIT_* in both composes, api healthcheck | compose + `api/config` | medium | W1 | filed |
| S2 | Tiered root .env.example with secret-gen commands verbatim (incl. the KEK exactly-32-bytes trap) | root | small | W1 | filed |
| S3 | TLS story: Caddyfile.example + nginx block + opt-in `--profile tls` sidecar (static ipam IP) | `deploy/**` + compose | medium | W2 | filed |
| S4 | SELF-HOST runbook: first boot, admin-token capture from docker logs, verify chain, upgrade (PG major-version volume trap), backup/restore, symptom table | `docs/**` | large | W2 | filed |
| S5 | One Postgres floor: 15 floor / 17 recommended, warn-probe, six sources aligned, deploy.sh PGDG pin (D8) | multi | medium | W2 | filed |
| S6 | CI compose smoke — api/Dockerfile's first-ever gate; the six-source version grep rides it | `.github/**` | medium | W1–W2 | filed |
| S7 | Executed upgrade + restore drills on a clean VM from ONLY the runbook, recorded per wave | ops | medium | W3 | filed |

**Absorbs:** `pdf-bl-limit-env-passthrough` (personal-dev-fleet) — closed into S1 by name.

**Not this epic:** header correctness (E1, `task-02ce7e5183108eb3`); metering and limiters (E2,
`task-8e9cac2018a7fe1c`); shared-box persona items (D2 — refused by number); CJK (filed
candidate); box sizing (deploy-reliability).

## Sequencing with the sibling epics

S1 + S2 run parallel from program day 1 — zero auto-deploy exposure. The "supported" stamp waits
for E1 slice 2 (D6). S6's smoke must be green before any prebuilt-image revisit (D7).

## Wave log

<!-- one row per wave: date · wave paper · slices merged · the cold-start transcript that proves it -->
