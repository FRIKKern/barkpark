# cch wave-32 — roster false-open sweep (2026-08-05)

Verifier lane `roster-false-open-sweep`. **No task was closed by this sweep.** Every row below stays
open until the LEAD disposes it. Each entry records the refuting SHA, the criteria that are already
satisfied on `origin/main`, and the command that re-derives the reading.

## Denominator correction

The wave quotes **"91 open rows"**. The server says **92**.

    bp task get cloud-console-hardening-epic -o json \
      | python3 -c "import json,sys;from collections import Counter;print(Counter(c['lifecycle_status'] for c in json.load(sys.stdin)['children']))"
    # Counter({'done': 221, 'open': 92, 'cancelled': 35, 'considering': 1})

`task-b4b3edfc4b8838cf` (the router route-table lie) was filed by the digest during this wave, which
accounts for the drift. **Defensible genuinely-open count after this sweep: 88** (92 minus the four
FULL false-opens below). Three further rows are PARTIALLY paid and are mis-sized, not false.

## HAZARD that produced two wrong readings before I caught it

The primary checkout is **447 commits behind `origin/main`** (`git rev-list --count HEAD..origin/main`
= 447). A working-tree grep or a working-tree `node __css_check.mjs` run reads a tree that is a week
stale. Every reading below is taken from `git show origin/main:` / `git grep origin/main` or from a
`git archive origin/main` export.

---

## FULL false-opens (every criterion satisfied on origin/main)

### 1. `cch-cloud-app-has-no-plug-errorhandler` — filed 2026-08-02, refuted 2026-08-05

Premise: *"The grep for Plug.ErrorHandler or handle_errors across ALL of cloud/lib returns NOTHING."*

REFUTED by **`467f7e283`** (2026-08-05, `fix(cloud): a control-plane crash stops rendering as the
user's mistake (#9521)`), an ancestor of `origin/main`.

    git grep -n 'Plug.ErrorHandler\|handle_errors' origin/main -- cloud/lib
    # router.ex:241  use Plug.ErrorHandler
    # router.ex:7756 @impl Plug.ErrorHandler
    # router.ex:7757 def handle_errors(conn, %{kind: kind, reason: reason}) do

- **c1 (two raise-shaped surfaces reproduced end to end)** — SATISFIED. `cloud/test/web/crash_envelope_census_test.exs`
  moduledoc records THREE, measured at L1 against a booted control plane with `curl -w`: malformed
  JSON `400 size_download=0`, `text/plain` `415 size_download=0`, 20 MB body `413 size_download=0`.
- **c2 (a decision recorded, with the reason)** — SATISFIED. `Plug.ErrorHandler` with a shaped body
  `%{error: crash_slug(...), request_id: ...}`, an `x-request-id` response header, and a
  `crash_envelope request_id=… status=… method=… path=… kind=…` Logger line at `:error` for 5xx /
  `:warning` for 4xx. The reason is written out at router.ex:7745-7756 (the SPA's `ERRORS` map needs a
  registered slug and a JSON content-type or `api()` throws the body away).
- **c3 (a guard that can lose)** — SATISFIED. The same census test, 8 tests, side A **derived** from
  the router's own route declarations (177 routes, 119 with a body), and the mutation is named in the
  moduledoc: *"deleting `use Plug.ErrorHandler` from the router turns every census row into
  `:no_response`"*.

**RESIDUAL LIE THIS SWEEP FOUND, not owned by any row:**
`cloud/lib/barkpark_cloud/registry/env_var.ex:98` still says *"with no `Plug.ErrorHandler` anywhere
in this app"*. That sentence is now FALSE on `origin/main`. Re-derive:
`git show origin/main:cloud/lib/barkpark_cloud/registry/env_var.ex | sed -n '92,101p'`

### 2. `gr-backlog-css-check-missing-classes` — filed 2026-07-18, refuted 2026-08-02

Premise: *"6 class families without CSS + 2 unclassifiable var-then-concat sites."*

REFUTED by **`22c42b219`** (`feat(cloud): six shipped class families finally get CSS (gr-p5r5) (#4733)`)
and **`c6107095a`** (2026-08-02, `fix(cch): stop demoting the bp-lc- gap, and pin the closed role set
with a leg that can lose (#9301)`). Both ancestors of `origin/main`.

- c1, c2 were already stamped met.
- **c3 (`node cloud/priv/static/__css_check.mjs` exits 0)** — SATISFIED, and NOT green-by-demotion:

      rm -rf /tmp/om && mkdir -p /tmp/om && git archive origin/main cloud/priv/static | tar -x -C /tmp/om
      cd /tmp/om && node cloud/priv/static/__css_check.mjs > /tmp/cc.txt 2>&1; echo "EXIT=$?"
      # EXIT=0
      # __css_check: 865 classes checked, 96 tokens checked, 576 contrast pairs,
      #              87 allowlisted, 0 known gap(s) demoted (R3), 0 error(s)

  Note the **0 demoted**. The STALE working tree still prints `1 known gap(s) demoted (R3) … owned by
  gr-backlog-css-check-missing-classes`, which is exactly how this row would have been read as open by
  anyone who ran the checker in place. `c6107095a` moved `bp-lc-` from the demotion list to the
  allowlist (`__css_check.mjs:320`).

### 3. `cch-w28-s1-empty-roster-control-asserts-clause-a` — 6/7, filed 2026-08-03

- **c7 (MERGE-GATED: PR #9356 green on Console gate and merged to main)** — SATISFIED.

      gh pr view 9356 --json number,state,mergedAt,mergeCommit
      # 9356  MERGED  2026-08-03T14:53:51Z  0a1b4d2ea53be3cb507834f0663faae998e13de3
      git merge-base --is-ancestor 0a1b4d2ea origin/main   # ANCESTOR

All 7 criteria now satisfied.

### 4. `cch-w12-s5-successor-split-and-letterbox-fence` — 8/10, filed 2026-07-31

- **c7 (both charters carry the filing law)** — SATISFIED.

      git grep -n 'more live rows than it began' origin/main -- .claude/workflows
      # bp-cloud-console-hardening-charter.md:27   (Law 0)
      # bp-cloud-console-instruments-charter.md:63

- **c10 (PR merged, MERGE sha on origin/main)** — SATISFIED. PR #8500 MERGED 2026-08-02,
  merge commit `0b425c7e841c7ac55b7cc1f91e266be06571c7c7`, confirmed ancestor of `origin/main`.

All 10 criteria now satisfied.

---

## PARTIAL false-opens (mis-sized, not false — do NOT close, DO re-scope)

### 5. `cch-w11-s1-flip-behind-a-generator-that-cannot-lose` — reads 9/13, at least 11/13 true

- **c10 (THE PUT — live protection is EXACTLY four contexts)** — SATISFIED:

      gh api repos/FRIKKern/barkpark/branches/main/protection -q '.required_status_checks.contexts'
      # ["Elixir gate","PR references an active task","Cloud gate","Console gate"]

- **c13 (PR merged)** — SATISFIED. PR #8394 MERGED 2026-07-31, merge commit `dcd8c9ceff0e4505e5071ce8dbae7ee01aa0ac28`, ancestor of `origin/main`.
- c11 (`gh pr view 8222 --json mergeStateStatus` immediately after the PUT) and c12 (mutation proof that
  the gate can both stop and not-stop a merge) are the only two I could not re-derive. The row is a
  2-criterion residue wearing a 13-criterion coat.

### 6. `cch-w14-bl-site-open-phone-overflow` — reads 3/5

- **c5 (PR MERGED, SHA recorded)** — SATISFIED. PR #8743 MERGED 2026-08-01, merge commit
  `b1c80eda5c0afcd31d532c554d7872024d353b1e`, ancestor of `origin/main`.
- **c4 (the phone-width leg drives a site-detail route)** — PLAUSIBLY satisfied, by `c3d7fe30d`
  (2026-07-31, #8660): `breakpoint-sweep.mjs:314-315` now carry `site-rollback` / `site-states` at
  `#site/${SITE}`, and `overflow-guard.mjs:381-382` carry the same two routes alongside
  `PHONE_WIDTHS = [320,360,375,390,412,430,480,495,496,620]` (`:400`). I did not run either instrument,
  so this is a shape reading, not a run — the LEAD should demand one run before disposing.

      git show origin/main:cloud/priv/static/__preview__/overflow-guard.mjs | sed -n '381,382p;400p'

### 7. `task-79aa75e4be7a0067` — "two stale quotes of the retired Hetzner capacity literal" — ONE of the two is already gone

Filed 2026-08-03. **`f50f48b83`** (2026-08-04, `fix(cloud): the capacity arm stops naming a provider
and a resource it cannot tell (#9464)`) removed the `cloud/DESIGN.md:145` quote — the row asserts that
commit *deliberately did not touch it*, which is false for the DESIGN.md half:

    git log --oneline -S'Hetzner ran out of server capacity' origin/main -- cloud/DESIGN.md
    # f50f48b83 …#9464     a9b461746 …#1063
    git show origin/main:cloud/DESIGN.md | sed -n '145p'
    # | — example | "A capacity or quota limit was reached…" | `SERVER_LIMIT_EXCEEDED` |

The row's single criterion is *"a repo-wide grep for the old sentence returns only the intentional
HISTORY quotes."* On `origin/main` the grep returns three hits and **all three are past-tense history**:

    git grep -n "Hetzner ran out of server capacity" origin/main -- cloud internal web api scripts
    # router.ex:10313              "… which is exactly what happened while an E_ABSOLUTE_PATH … rendered here as"
    # router_sites_test.exs:711    "… (then "Hetzner ran out of server capacity", now the …)"
    # typed_refusal_render_test.go:131   (the row itself rules this one correct as history)

`router.ex:10313` is byte-identical to what it was at filing (`git show $(git rev-list -1
--before=2026-08-03T23:59 origin/main):cloud/lib/barkpark_cloud/web/router.ex | sed -n '10197,10205p'`),
so it is genuinely untouched — but it is stale as an EXAMPLE (humanize/1 no longer emits that string at
all), not as a claim about the present. **LEAD RULING NEEDED**: one line in router.ex, or close.

### 8. `cch-w30-bl-api-status-aware-envelope` — reads 0/5, c1 and c2 are satisfied

Premise: *"api() … parses a response body ONLY when the content-type contains application/json and
substitutes {} otherwise, discarding whatever the server actually said; and it collapses a dead
network, a DNS failure and an aborted request into a single status 0."*

REFUTED by **`88e3c3cb0`** (2026-08-05, #9594) — `cch-w31-s4` made the envelope additive:

    git show origin/main:cloud/priv/static/app.js | sed -n '99,108p'
    # `text` carries the bytes of a non-JSON body (an upstream proxy's HTML 502 page
    #  used to vanish into `{}` …), and `transport` names WHY a request never got an answer.

- **c1 (non-JSON body preserved)** — SATISFIED (`text`).
- **c2 (transport failure modes distinguished)** — SATISFIED (`transport`).
- c3 (the decision made ONCE at the boundary; faultCopy reduced or retired) — NOT satisfied:
  `git grep -c 'faultCopy' origin/main -- cloud/priv/static/app.js` = **15**. This is the live residue.
- c4/c5 unverified.

### 9. `cch-w30-s5-followup-vague-fallbacks` — reads 0/2, c1 is satisfied

Premise names `app.js:5678` and `app.js:12530` as hardcoding `'Check your connection and retry.'` with
no status check. On `origin/main` **both are routed through `faultCopy`**, and a third site joined them:

    git grep -n 'Check your connection and retry' origin/main -- cloud/priv/static/app.js
    # :5822  faultCopy(fleetErr.status, fleetErr.data, "Check your connection and retry.", fleetErr.transport)
    # :9381  faultCopy(ev.status, ev.data, "Check your connection and retry.")
    # :12700 faultCopy(subErr.status, subErr.data, "Check your connection and retry.", subErr.transport)

c2 (the 29 vague `friendly()` sites triaged in writing) is the whole remaining row.

---

## Rows I checked and found GENUINELY OPEN (premise re-derived, still holds)

| Row | Re-derived premise | Command |
|---|---|---|
| `gr-backlog-d24-statusmeta-sweep` | `statusMeta` still absent from app.js — 0 hits | `git show origin/main:cloud/priv/static/app.js \| grep -c statusMeta` → 0 |
| `gr-backlog-operator-digest-send` | no `digest/send` route, no `deliver_fleet_digest` call in router | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| grep -n 'digest/send\|deliver_fleet_digest'` → empty |
| `gr-backlog-operator-palette-entry` | `paletteNavItems()` still argument-free at app.js:18278 | `git show origin/main:cloud/priv/static/app.js \| grep -n paletteNavItems` |
| `gr-backlog-tfa-confirm-throttle` | `TwoFactorRateLimiter.check` still has exactly ONE call site (router.ex:762, the LOGIN surface) | `git grep -n 'TwoFactorRateLimiter.check' origin/main -- cloud/lib` |
| `gr-backlog-console-redaction-allowlist` | `envSecretConsoleRe` is still the fixed 6-key list. **Row is mis-stated**: it asks to "mirror in internal/builder/console.go", but the BUILDER TWIN ALREADY HAS the generic shape the row wants — `builderEnvSecretRe` = `\b([A-Z0-9_]*(?:SECRET\|TOKEN\|PASSWORD\|PASSWD\|APIKEY\|API_KEY\|PRIVATE_KEY\|DATABASE_URL\|KEY)[A-Z0-9_]*)=(\S+)` at builder/console.go:229. The work is provisioner←builder, not builder←provisioner. | `git show origin/main:internal/builder/console.go \| grep -n 'builderEnvSecretRe'` |
| `cch-cloud-static-gzip-html` | still open BY NAME in the guard: `cloud-static-gz-guard.sh:76` says *"styleguide.html … is not on the cold-boot path — it stays on cch-cloud-static-gzip-html"* | `git show origin/main:scripts/cloud-static-gz-guard.sh \| sed -n '70,80p'` |
| `cch-w12-bl-session-touch-has-no-rescue` | `touch_session_last_used/1` → `touch_last_used/2` still has no `rescue` (accounts.ex:676-700) | `git show origin/main:cloud/lib/barkpark_cloud/accounts.ex \| sed -n '676,700p'` |
| `cch-email-format-missing-u-modifier` | `@email_format ~r/^[^\s@]+@[^\s@]+$/` still carries no `/u`, in BOTH copies (user.ex:31, team_invitation.ex:34) | `git grep -n '@email_format ~r' origin/main -- cloud/lib` |
| `cch-w29-bl-safe-url-resolver-seam-unguarded` | `:resolver` still accepted unconditionally at safe_url.ex:63 | `git show origin/main:cloud/lib/barkpark_cloud/notifications/safe_url.ex \| sed -n '60,65p'` |
| `cch-w29-bl-cli-usage-shows-crashed-vs-unmetered` | Go CLI still keys everything on `unmeteredValue`; zero `unavailable_reason` reads | `git show origin/main:internal/cli/cloud_usage.go \| grep -n 'unavailable_reason\|unmeteredValue'` |

## bp search was NOT down

Six of sixteen surveyors reported `bp search` failing, so their "no prior art" readings are tool
failures wearing an absence costume. Re-run at 2026-08-05, all three queries returned relevant rows:

    bp search query 'trial_expiring chat routing' -o json          # count 2111, top hit cch-w31-bl-trial-expiring-cause-is-email-only
    bp search query 'notification withhold suppressed status' -o json  # count 2832, top hit cch-w30-bl-silent-withholds-have-no-person-facing-trace
    bp search query 'delivery log retention index' -o json         # count 1955, top hits cch-w31-bl-delivery-log-unbounded-and-unindexed, gr-bl-delivery-keyset-tiebreak

`gr-bl-delivery-keyset-tiebreak` (status **done**, same epic) is uncredited prior art for
`cch-w31-bl-delivery-log-unbounded-and-unindexed` — it already reproduced the compound-key/half-key
paging defect on the SAME table at `notifications.ex:545`. Whoever builds the index should read it
before choosing the index columns.

## Shape of the failure, for the charter

Four of the six paid rows were paid by a commit that **post-dates the row's own filing** (467f7e283,
c6107095a, f50f48b83, 88e3c3cb0 — three of them within the last 72 hours). The remaining two are
MERGE-GATED criteria whose PR merged days ago and which nobody went back to stamp. Both classes are
invisible to a roster count and both inflate it. The cheap standing instrument is: for every open row
carrying a `PR is MERGED … THE LEAD CLOSES THIS ONE` criterion, resolve the PR number and ask GitHub.
