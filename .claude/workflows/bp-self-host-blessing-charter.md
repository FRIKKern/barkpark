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

**Ground-truth corrections from the wave-1 verify round (2026-08-08, all measured):**
the compose install is not merely trapped — it is **unbuildable, and has been since 2026-07-06**
(PR #1201 added `:expty`; six independent build walls, see D17). Plug's 64-byte floor is LAZY:
a short `SECRET_KEY_BASE` serves `/api/schemas` 200 and 500s only on `/login` (`/studio` 302s,
it never touches the session) — so any green arm probing `/api/schemas` is structurally blind to
the headline trap. The env census numbers quoted at epic open were grep artifacts (D14). The
"zero auto-deploy exposure" sentence below in Sequencing is corrected by D9.

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

- **D9 — Deploy-exposure CORRECTION (reverses the "zero auto-deploy exposure" sentence in
  Sequencing; evidence: `.github/workflows/deploy.yml:11-12,79,84-93` read directly).**
  `api/config/runtime.exs`, `api/Dockerfile`, `api/config/config.exs` ride `api/**` → guerrilla
  instance deploy; `cloud/docker-compose.yml` and `cloud/.env.example` ride `cloud/**` →
  control-plane deploy. Root `docker-compose.yml`, root `.env.example`, `.github/workflows/**`
  and `scripts/**` are inert. Merge-order law for any wave touching the refusal: inert files
  first, `api/config/runtime.exs` LAST, with an open-PR collision re-scan on
  runtime.exs/Dockerfile/root-compose immediately before that merge. Blast radius, measured: a
  runtime.exs raise surfaces at instance-deploy's `build ecto.migrate` (exit 13 →
  `git reset --hard $OLD`, active slot keeps serving) — a wrong refusal WEDGES future deploys but
  causes zero downtime.

- **D10 — Live-secret verification is DONE and the refusal predicate is pinned.** Guerrilla's
  running BEAM (`/proc/<MainPID>/environ`, slot blue): `SECRET_KEY_BASE` is EXACTLY 64 raw bytes;
  `BARKPARK_KEK` is 44 chars = base64 of exactly 32 bytes. The control plane has NEITHER variable
  and no Phoenix endpoint — the refusal structurally cannot touch it. Predicate:
  `is_binary(raw) and byte_size(raw) >= 64` on the RAW env string — never `> 64`, never trim,
  never decode-then-measure (each of those bricks the next guerrilla deploy; the four
  `api/test/config/runtime_*_test.exs` fixtures also pin exactly 64). Boundary measured in a
  container: 63 bytes → `/login` 500; 64 bytes → 200.

- **D11 — Refusal shape: hoist ONE validated `secret_key_base` binding** into the top-of-file
  region directly after the `BARKPARK_RELEASE_CAPTURE_HMAC_SECRET` length-raise precedent, and
  have BOTH existing consumers (the media-signing derive and the endpoint config) read it — the
  in-place double-edit is rejected because two raise messages drift. Prod-gated, like today. The
  only behavioral delta is raise ORDER (SKB now refuses before DATABASE_URL) — stated in the PR
  body. From this decision on, the charter cites this region by SYMBOL ("the hoisted
  secret_key_base case"), never by line number — the hoist shifts every downstream anchor.

- **D12 — The KEK guard graduates from S1-stretch to S1, hybrid-gated.** The nil branch stays
  prod-only (dev has a valid compile-time default); a SET value is validated in ALL envs:
  `Base.decode64` must yield exactly 32 bytes, else refuse at boot naming the variable and the
  command. Evidence: every KEK value present at runtime.exs-eval time (4 test fixtures, CI: none,
  compose `:?`, deploy mint, dev default) decodes to exactly 32 bytes; `""` bypasses today's nil
  check and would otherwise fail at the FIRST encrypted-field seal, an unbounded time after boot.
  Same slice fixes the two runtime.exs comments that teach `mix phx.gen.secret 32` — the exact
  command `deploy.sh:161-166` documents as boot-bricking; the correct command is
  `openssl rand -base64 32`.

- **D13 — `PREVIEW_JWT_SECRET` gets a non-empty check only, this wave.** `""` passes `|| raise`
  today (measured). No byte floor: its live length on guerrilla is unmeasured and the test
  fixtures pin exactly 32 — a floor is filed as backlog behind an ssh measurement.

- **D14 — The canonical env census denominator is DERIVED BY SCRIPT, never quoted as a literal.**
  At charter-update time the script reports 130 api (114 literal + 16 recovered from 7 declared
  dynamic call sites) / 55 cloud. The previously quoted 105/111/116/129 were all grep artifacts
  (call-site counts, commented-out phantoms, missing dynamic resolution). DoD wording everywhere:
  "the script's census equals the script's compose diff with zero undeclared dynamic sites."

- **D15 — Census-script contract (`scripts/env-census.py`, stdlib-only python3).** Fail-closed on
  any undeclared dynamic `System.get_env/fetch_env` site, keyed on (file, argument-expression);
  compose diff scoped per environment list (root `api:` service; cloud `x-control-plane` anchor —
  a whole-file diff false-positives on postfix's DKIM/MAIL vars); REFUSES a duplicate key inside
  one environment list (compose resolves duplicates last-wins with zero diagnostic, measured on
  v5.2.0 — a refusal is version-independent, an order rule is not); hard-fails a `:-` default on
  the five generated secrets and on `BARKPARK_PLUGINS`, WARNs elsewhere against a declared
  allowlist; asserts no `ENV NAME=` line in `api/Dockerfile` names a census member (the baked-ENV
  tripwire); exempt entries carry dated reasons — ratified baseline: BARKPARK_DEV_DATABASE,
  BARKPARK_ENV, BARKPARK_HOME, PATH, PHX_SERVER, plus build/deploy internals (TMPDIR,
  BARKPARK_BUILD_GATE_LOCK, BARKPARK_BUILD_VERSION/_COMMIT/_DATE) with reason "not an operator
  knob".

- **D16 — The `env_file:` pivot (Strategize candidate C) is REJECTED by number, on measured
  evidence.** env_file values are interpolated — an unescaped `$` in a hand-typed secret is
  silently truncated with exit 0; Coolify hoists env_file contents into a project-wide file and
  would materialize a bare name as empty string, which IS the plugin kill switch. Adopted from C:
  its authoring rules only — the root `.env.example` never ships a bare `NAME=` line for a knob
  (comment the whole line out), and documents "generated secrets only; never `$` in a hand-typed
  password".

- **D17 — The docker build is broken at SIX measured walls and the fix shape is decided (fence
  widening, subject-scoped: `api/Dockerfile`, `api/Dockerfile.dockerignore` (new),
  `api/config/config.exs` — the `:229` regex `/E` modifier only — `scripts/env-census.py` (new),
  `scripts/compose-smoke.sh` (new)).** Walls, each reproduced: (1) no cmake for `:expty`'s
  vendored libuv on musl (broken since 2026-07-06, #1201); (2) alpine 3.23's cmake 4.x rejects
  it — needs `CMAKE_POLICY_VERSION_MINIMUM=3.5`; (3) `status_vocab.ex:19` reads repo-root
  `design/` at compile time, unreachable from the `./api` build context; (4) root `.dockerignore`
  excludes `api` wholesale; (5) `api/assets/` is never COPYed (`stylesheet.ex` compile-time
  read); (6) `config.exs:229` stores a regex without `/E` — `mix release` fails on Elixir 1.19
  for ANY target, Docker or not. Fix: build context moves to REPO ROOT
  (`build: {context: ., dockerfile: api/Dockerfile}`) with a per-Dockerfile
  `api/Dockerfile.dockerignore` (BuildKit prefers it over the root file), cmake + the policy env,
  `COPY api/assets assets`, and the one-character `/iE` fix. `BARKPARK_SKIP_IMAGE` is FORBIDDEN in
  the gate — vix/`:image` builds fine on musl with no libvips (measured; the old hypothesis is
  refuted), and skipping it would be the D4 anti-pattern inside the D1 gate. Measured after fix:
  cold `--no-cache` build 114s, image 144MB, `up -d` → serving `/api/schemas` in ~25s.

- **D18 — The three prod-raise-shadowing Dockerfile ENVs are DELETED:** `SECRET_KEY_BASE`
  (30-byte placeholder — defeats any compose fix for bare `docker run`), `DATABASE_URL` (encodes
  a hostname that only resolves inside this compose network), `PHX_HOST=localhost` (makes the
  Past-Mistake-#11 check_origin guard structurally unreachable in ANY container). `PHX_SERVER`
  and `PORT` stay — release behavior, not identity/secrets. Root compose additionally converts
  `DATABASE_URL` to `${DATABASE_URL:-ecto://postgres:postgres@db/barkpark_prod}` (today it is
  hardcoded — a self-hoster cannot point at external Postgres) and `PHX_HOST` to a `:?` require
  whose message says "your public hostname; `localhost` for local use" — a `:-localhost` default
  is the same silent-Studio-breakage shape D18 deletes from the image.

- **D19 — Healthcheck: `/api/schemas` via busybox wget (present in the runtime image; curl is
  not), asserted IN-CONTAINER.** Shape:
  `test: ["CMD-SHELL","wget -q -O /dev/null http://localhost:4000/api/schemas || exit 1"]`,
  `interval: 30s, timeout: 5s, retries: 5, start_period: 300s` (cold local boot measured 25s;
  upgrade migrations are the 25-minute class, and plain compose never kills on unhealthy — no
  `service_healthy` consumer may ever be attached to the api service). One vocabulary with the
  fleet's deploy scripts, which already gate on `/api/schemas`. A dedicated `/up` endpoint is
  DECLINED this wave: it would be new `api/**` surface and couples to E2's anonymous-metering
  work; the anon read budget (300/min) dwarfs the 2/min probe today.

- **D20 — S6 lives in its OWN workflow, `.github/workflows/compose-smoke.yml`, in the
  dispatcher/aggregator idiom — NOT a cloud.yml graft.** Evidence: the cloud dispatcher's output
  set is pinned by EXACT harness assertion (`dispatcher_outputs "cloud"`); its path set
  dispatches `cloud=false` on precisely S1/S2's files (measured), so a grafted job would skip on
  the PRs it exists to gate while `Cloud gate` publishes green; root `docker-compose.yml` is a
  deliberate exempt phantom on a zero-growth list; and PR #10155 owns cloud.yml's append points.
  Aggregator job publishes the static literal name `Compose smoke`, `if: always()`, no matrix,
  explicit per-upstream allow-set (copy cloud-gate's), `::notice` on dispatched==0. Dispatcher:
  unfiltered trigger, head-sha checkout, fail-closed changed-path verdict, job-level `if:` on its
  output. BOTH arms are mandatory: the MUTATION arm (short/unset SECRET_KEY_BASE → container
  exits non-zero at the migrate step with the refusal's first line in the logs — NEVER an HTTP
  probe: Plug's floor is lazy and `/api/schemas` is structurally blind) and the GREEN arm
  (generated secrets → compose healthy → `docker compose exec api wget` of `/api/schemas` AND
  `/login`, both 200 — never a host-port curl: a host beam.smp on :4000 produced a measured false
  200). Fail-before evidence comes from a recorded branch run, never a red main (guard+fix
  co-merge law). It also runs `python3 scripts/env-census.py` both roots and the D23
  blessing-word grep. Registration as a required check is a separate HUMAN GATE after the name
  renders on ≥2 settled heads: generate → deadlock sweep → floor → apply `--confirm`, app_id
  15368 pinned.

- **D21 — Fence widening, subject-scoped: `cloud/.env.example`, LIMIT_* documentation only.**
  Required because `pdf-bl-limit-env-passthrough` AC1 names that file and the fence did not.
  Rides `cloud/**` deploy (D9 ordering applies). Not to be widened again.

- **D22 — Cross-epic absorb-close protocol (authored here; the crown ruled absorb-and-close, the
  mechanics were unwritten anywhere).** The absorbed task (`pdf-bl-limit-env-passthrough`, open,
  unclaimed, GitHub-synced issue 6065): claim LATE (just before closing) with the S1b builder's
  worker id; the close flips BOTH criteria in one write, each entry carrying the criterion's
  EXACT stored wording (the server refuses a done close with unmet criteria — the CLI help's
  "never block" sentence is false, `close.ex` `check_criteria_proven`); never edit the brief
  mid-claim (409 `doc_changed_since_claim`); `parent_id` and `wave_paper` stay UNTOUCHED — the
  pointer lives in `close_reason` + criterion evidence, pinned citation form:
  `absorbed-by: self-host-blessing/<slice-task-id> — PR #<n>; wave paper
  self-host-blessing-wave-2026-08-08`. Never hand-close the GitHub issue first (desync).

- **D23 — Hedge vocabulary pinned: the word is "experimental".** No blessing language
  (supported / blessed / production-ready / official(ly)) in any wave-1 file. The D6 gate trigger
  is `gh pr view 10835 --json mergedAt` non-null (E1 slice 2's PR) — NOT that slice task's
  lifecycle, which stays in_progress through post-merge criteria. The compose smoke carries a
  blessing-word grep over the fenced files with a per-file allowlist (known false positives:
  deploy/README.md exit-code `not_supported`, PROD_OPS.md "official ARM64 binary", README.md
  "supports the work").

- **D24 — `BARKPARK_PLUGINS` kill-switch law, confirmed server-side and generalized.** `""` —
  and whitespace-only, and comma-only — legitimately means REGISTER NOTHING (single read site,
  `runtime.exs` → `EnvConfig.parse` → Discovery `[] ->` short-circuit); it must NEVER receive a
  boot refusal. The widened cloud compose passes it as a BARE line (it is absent there today);
  `.env.example` comments the whole line out, never blanks it. Docker-side semantics proven live
  on Compose v5.2.0: a bare line with the host var unset is ABSENT in the container (not empty).
  A boot log line naming the active kill switch is backlog, not a refusal.

## Fence

**In fence:** `docker-compose.yml` · `.env.example` (new, root) · `cloud/docker-compose.yml`
(LIMIT_* passthrough only) · `cloud/.env.example` (LIMIT_* documentation only, D21) ·
`api/entrypoint.sh` · `api/config/runtime.exs` (secret-refusal region) · `api/Dockerfile` +
`api/Dockerfile.dockerignore` + `api/config/config.exs` `:229` `/E` only + `scripts/env-census.py`
+ `scripts/compose-smoke.sh` (D17) · `api/lib/barkpark/application.ex` (floor-probe beside
check_pg_trgm) · `deploy/caddy/Caddyfile.example` (new) · `docs/setup/SELF-HOST.md` (new) ·
`docs/setup/SETUP.md` · `docs/setup/GO-LIVE.md` (cross-links) · `deploy.sh` (S5 pin only, D8) ·
`.github/workflows/` (new compose smoke) · CI workflow pg service images (floor alignment).

**Out, by design:** guerrilla box sizing and swap (deploy-reliability); the spawned-site deploy
pipeline (site-spawner); push-to-deploy artifact builds (dwb — parked epic, cite only);
Studio/console surfaces (cch); everything `api/**` that serves requests (E1/E2 territory). Every
fence widening is a numbered, subject-scoped, not-to-be-widened-again decision in this file.

**Doc contract:** SELF-HOST.md rides human-tier like GO-LIVE.md (no new agent card — the 7-card
cap stands). SETUP.md's collision status swept at wave 1: CLEAN — no open PR, no other charter,
and zero existing docker/compose prose in it (any cross-link is net-new text; keep it
cross-link-only, `canonical-for: standalone-setup` is owned).

## Roadmap

Dependency-honest order (D4): traps → truth → story → proof.

| # | Slice | Surface | Size | Wave | Status |
|---|---|---|---|---|---|
| S1 | Compose correctness: secret fail-fast (length-citing), env-allowlist widening + grep-proof, LIMIT_* in both composes, api healthcheck — split W1 into S1a image/compose (`shb-w1-s1a-image-and-compose`), S1b census script + cloud + pdf-bl close (`shb-w1-s1b-census-cloud-pdfbl`), S1c refusals (`shb-w1-s1c-secret-refusals`) | compose + `api/config` + `scripts/` | large | W1 | **building** |
| S2 | Tiered root .env.example with secret-gen commands verbatim (incl. the KEK exactly-32-bytes trap) — `shb-w1-s2-env-example` | root | small | W1 | **building** |
| S3 | TLS story: Caddyfile.example + nginx block + opt-in `--profile tls` sidecar (static ipam IP) | `deploy/**` + compose | medium | W2 | filed |
| S4 | SELF-HOST runbook: first boot, admin-token capture from docker logs, verify chain, upgrade (PG major-version volume trap), backup/restore, symptom table | `docs/**` | large | W2 | filed |
| S5 | One Postgres floor: 15 floor / 17 recommended, warn-probe, six sources aligned, deploy.sh PGDG pin (D8) | multi | medium | W2 | filed |
| S6 | CI compose smoke — api/Dockerfile's first-ever gate; the six-source version grep rides it — `shb-w1-s6-compose-smoke` (round 2, after S1a + S1c merge) | `.github/**` | large | W1–W2 | **building (round 2)** |
| S7 | Executed upgrade + restore drills on a clean VM from ONLY the runbook, recorded per wave | ops | medium | W3 | filed |

**Absorbs:** `pdf-bl-limit-env-passthrough` (personal-dev-fleet) — closed into S1b by name,
protocol D22.

**Not this epic:** header correctness (E1, `task-02ce7e5183108eb3`); metering and limiters (E2,
`task-8e9cac2018a7fe1c`); shared-box persona items (D2 — refused by number); CJK (filed
candidate); box sizing (deploy-reliability).

## Sequencing with the sibling epics

S1 + S2 run parallel from program day 1. Auto-deploy exposure per D9 (the original "zero
exposure" sentence was wrong): inert files merge first, `api/config/runtime.exs` merges LAST with
a fresh collision re-scan. The "supported" stamp waits for E1 slice 2 (D6, trigger per D23).
S6's smoke must be green before any prebuilt-image revisit (D7).

## Wave log

<!-- one row per wave: date · wave paper · slices merged · the cold-start transcript that proves it -->
- 2026-08-08 · `self-host-blessing-wave-2026-08-08` · W1 cut: round 1 = `shb-w1-s1a-image-and-compose`, `shb-w1-s1b-census-cloud-pdfbl`, `shb-w1-s1c-secret-refusals`, `shb-w1-s2-env-example`; round 2 (lead-dispatched after S1a+S1c merge) = `shb-w1-s6-compose-smoke`. Decisions D9–D24 recorded this wave. Merge order per D9: S1b/S2/S6 inert-or-cloud first, S1a next, S1c (runtime.exs) LAST.
