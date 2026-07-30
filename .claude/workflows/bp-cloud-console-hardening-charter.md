# Cloud Console Hardening — epic charter

Successor to the Cloud GUI Remake epic (SEALED 2026-07-21, PR #5226). Inherited 58 re-parented
survivors + 10 natively-filed rows = 69 open children. This file is the epic's memory: every wave
reads it first.

## Vision

**The console stops lying.**

Nearly every row worth building names a place where the console tells somebody something untrue.
It tells the network 40 requests are 5. It tells every user their session came from `172.18.0.1`
(measured: 48 of 49 production session rows). It tells the access log a bearer token is part of a
URL. It tells the rate limiter all users are one user. It tells a HEAD prober a session token in a
`location` header. It tells the developer a revoke succeeded on a route the mock never called, and
that a CSS check passed on code it just deleted.

After this epic, what the console SHOWS and what it DOES match — and the instruments asserting that
match are themselves able to fail.

This is also the epic's **triage predicate**: a row survives if it names a claim/reality divergence;
it closes when the divergence is gone. That single predicate generates all three movements, because
a lying harness and a lying rate limiter are the same defect class pointed at different audiences.

## Standing laws

1. **Cite MERGE SHAs, never branch SHAs.** `origin/main` is a linear squash chain, so
   `git merge-base --is-ancestor <branch-head> origin/main` always false-negatives. Get the SHA from
   `gh pr view <n> --json mergeCommit`. Inherited from the GUI epic; re-proved this wave (five
   worktree branches read NOT-merged while their PRs were MERGED).
2. **No row closes without a reproduction attempt.** The false-done pattern (11 tasks fake-done,
   then reopened) is this repo's most expensive recurring defect. A merge SHA plus a `file:line` is
   the minimum evidence.
3. **The census is L4, not L1.** The epic description carries a six-band disposition census written
   at seal round 10. It is a *hypothesis ranking*. Wave 1 measured it: roughly one third was stale —
   always in the SAFE direction (rows more done than claimed, never less). Keep the bands; re-derive
   truth values before building.
4. **Roster reads have exactly two safe routes.** `GET /v1/tasks?filter[parent_id]=…` silently
   returns foreign rows with a 200 (re-proved 2026-07-21: 0 of 15 rows in a default page actually
   carried the requested parent) — never source a roster from it. Use `bp task get <epic> -o json` →
   `.children` for the roster, and a per-row `bp task get <id>` for evidence. `.children` carries no
   `updated_at`/`closed_at`, so it cannot answer close-time questions. `bp task ls` has no
   `--parent` flag.

   **Wave-2 correction — the `/v1/data/query` bracket story was wrong.** Wave 1 recorded that bare
   curl with unencoded `filter[parent_id]` brackets returns "200 with 140 rows from another epic".
   Executably refuted: that command never reaches the server. curl's own URL-globbing parser rejects
   `[parent_id]` as a malformed range and **aborts client-side with exit 3 (`bad range in URL`)**,
   writing no output file. Under `curl -g` or Python urllib — where literal brackets really do go on
   the wire — `/v1/data/query/production/task` filters **correctly** (91/91 rows, matching
   `.children` exactly). The `140` traces to `gr-p5r5-successor-seal`'s roster-delta note for the
   *predecessor* GUI-Remake epic. The real hazard on this route is a **stale-file misread**: a script
   that reuses a fixed output path and skips the exit-code check reports yesterday's bytes as a live
   200. So the rule is not "encode the brackets or get wrong rows" — it is:

   ```bash
   # Route A (preferred): bp task get <epic> -o json | .children
   # Route B (raw HTTP): -G --data-urlencode, fresh mktemp path, and CHECK THE EXIT CODE.
   OUT=$(mktemp)
   if curl -sf -G -H "Authorization: Bearer $TOK" \
        'https://guerrilla.barkpark.cloud/v1/data/query/production/task' \
        --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' \
        --data-urlencode 'limit=500' -o "$OUT"; then
     python3 -c "import json; print(json.load(open('$OUT'))['result']['count'])"
   else
     echo "FETCH FAILED (curl exit $?) — \$OUT was NOT written by this run; do not read it" >&2
   fi
   ```
   The bracket-abort is generic to curl, not to `parent_id`: `filter[lifecycle_status]` and
   `filter[type]` reproduce it identically.

7. **A gate's classification is a claim like any other — write it, never cite it.** Wave 2 caught
   itself asserting "per the repo's standing advisory classification for Vercel" when
   `grep -in vercel docs/ops/merge-gates.md` returns nothing and
   `gr-blk-vercel-checks-ungoverned` is 0/2. Asserting a rule that does not exist, inside the epic
   whose frame is "the console stops lying", is the same defect pointed at ourselves. If a gate needs
   a classification, land the sentence.
5. **MERGE-GATED criteria are stamped by the LEAD, never the builder.** `autostamp_merge_gate`
   (`api/lib/barkpark/tasks/close.ex`) only fires on a criterion literally carrying
   `merge_gate: true`; this epic's criteria do not carry the flag (systemic gap, tracked in
   `pds-bl-merge-gated-criteria-carry-the-flag`, out of fence). The lead pastes the merge SHA by hand.
6. **Never branch from the primary checkout.** `/Volumes/SATECHI/github/barkpark` is shared by many
   concurrent sessions, is routinely ahead/behind origin, and at the time of writing carried an
   uncommitted comment-corrupting edit to `cloud/priv/static/app.css`. Cut every branch from
   `origin/main` explicitly; diff files against `git show origin/main:<path>`, never a working tree.
   Do not clean, stash, or reset that checkout — it holds other sessions' work.

## Surface fence

**In fence:** `cloud/`, `api/lib/barkpark_web/live/`.

**Standing dispensations** (granted wave 1, narrow, do not widen):
- `api/lib/barkpark/content/mutations.ex` + its tests — the ledger close-bypass guard. Proven
  two-clause, one-file; `api/lib/barkpark/tasks/` never calls `apply_mutations`, so the sanctioned
  CAS path is structurally immune.
- `design/emit.mjs`, `design/check.mjs` — the emit-marker fence. A correct fix cannot live inside
  `cloud/`; 15 of the 18 emitted artifacts are outside both fenced paths.
  **Wave-6 widening (exactly two files, D75):** `design/exemptions.json` and
  `design/emit-manifest.json`. Any tokenization of an app.css hand-stamp SHRINKS the literal ledger
  and reds `check.mjs` Part E unless the baseline moves in the same diff; the manifest is a
  `--write` by-product. Do not widen further.
- `.github/workflows/console-harness.yml` — CI wiring for console instruments.

**Wave-2 dispensations** (granted at wave-2 Decide, narrow, stated out loud):
- `docs/ops/merge-gates.md` + `api/.sobelow-skips` — the gate ledger's own honesty. Both are
  claim/reality divergences in the instruments this epic merges through: merge-gates.md never
  classifies Vercel, and the Sobelow baseline pins a finding to `router.ex:2505` that now sits at
  `:2530`, so a stale entry reds `main` itself. Dead centre of the frame; nothing in `cloud/` can fix
  either.

**Out of fence, hands off:** `tooling/grip/` (truth-grip **wave 5** running, PR #5314), `scripts/pds-*`
and `api/lib/barkpark/tenancy/` (PDS **wave 15** running — paper `pds-wave-15-2026-07-21`; wave 2's
survey wrongly reported no wave 15 exists, it does).

## The dark crown

`PLATFORM_ADMIN_EMAILS` is unset on prod. It lives in a gitignored `.env`; zero deploy scripts
reference it; **no commit can set it**. Every authenticated user gets 403 on the operator console.
This is a HUMAN GATE belonging to the repo owner. Note it where relevant; never build around it,
fake it, or file work that depends on it being lit. Same disposition for the QR live-scan proof.

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Keep the six-band census; re-verify rather than re-derive it | A prior Fable wrote it with full seal context; re-deriving burns the whole budget reproducing a worse version. Re-verification is the cheap part and the only part genuinely missing. |
| D2 | Refetch storm is fixed by **scope-narrowing**, never debounce | Repeats are evenly spaced (1 cold boot + 7 ticks = 40, reproduced from code alone), so a time window suppresses nothing. Four registered types funnel into one 5-endpoint `loadOverview()`. |
| D3 | The narrowing must also cover the `barkpark.*` **prefix fallback** | `app.js:12076` routes ANY unregistered `barkpark.*` type into the same monolith; a synthetic `barkpark.unknown_skew` fired the full 5. Enumerating the four known types leaves the skew path storming. |
| D4 | The refetch protective test fixture must carry **≥1 instance** | An empty fleet short-circuits `loadOverview()` to 2 requests; an empty-fleet fixture would assert "2" and pass forever while the storm rages for every real user. Vacuous green by construction. |
| D5 | Peer-IP: **PIN** the gateway, do not widen to `172.16/12` | Measured: widening let peer `{172,18,0,77}` forge `203.0.113.5`. `cloud-postfix-1` sits on `172.18.0.2` publishing `0.0.0.0:587` — widening hands an internet-facing SMTP container the ability to forge any client's IP and rate-limit bucket. |
| D6 | The pin ships with a compose `networks:` subnet block **in the same PR** | `docker-compose.yml` has no `networks:` block at all; the subnet is allocation-order-dependent (it landed on `.18` only because the default bridge took `.17`). A bare hardcoded tuple rots silently into a no-op with a test asserting it works. |
| D7 | Do **not** touch RemoteIp's `proxies:` list | Measured: widening `loopback_peer?/1` alone is sufficient. RemoteIp resolves from the header chain and never consults `conn.remote_ip`; a builder reasoning from peer-as-last-hop makes a wrong second edit. |
| D8 | SSE ticket: **strict single-use + a client reconnect rewrite** (option b) | Measured in headless Chrome: ANY 401 is terminal (`readyState 2`, browser never retries again). Short-TTL multi-connect shares the identical cliff on TTL expiry, so the client change is mandatory under BOTH designs — and (b) is strictly stronger security for the same client work. |
| D9 | The SSE slice must add a **fourth liveness-chip state** | The chip documents exactly three states and shows `reconnecting` whenever `evtErrored`, which after a 401 is permanently false. Fixing the leak without it trades a security defect for an honesty defect — inside an epic whose frame is "the console stops lying". |
| D10 | Remint on `readyState 0`, never rely on native retry | Under strict single-use the browser's own retry is a guaranteed 401: ~3.0s of dead stream per flap plus one 401 per flap in the access log (noise that reads like credential stuffing). |
| D11 | HEAD fix is a **router-level deny-list plug placed BEFORE `plug(Plug.Head)`** | `Plug.Head.call/2` is `%{conn \| method: "GET"}` and stashes nothing — by the time control reaches the route, HEAD-ness is destroyed, so per-route short-circuits are impossible, not merely inferior. One greppable list is mutation-testable; a scatter of route-local guards is not. |
| D12 | Answer **405 with `allow: GET`**, not 404 | 404 is the lie that `plug(Plug.Head)` (#4481) was landed to remove. "This path exists, that method is refused" is the honest answer. |
| D13 | Deny-list, not opt-in route tagging | Opt-in requires auditing all 56 GETs now plus every future one, and inverts the default so a forgotten new route silently 404s again. Deny-list fails open on a NEW mutating GET — the milder failure. |
| D14 | Match on `conn.path_info` segment lists, never a string prefix | The initiator and callback share a prefix and `path_params` are unpopulated at plug time (this runs before `:match`); a `starts_with?` guard is either over- or under-broad. |
| D15 | The HEAD slice also **prunes `oauth_states`** | Both GET legs `Repo.insert!` a row per unauthenticated hit and the ONLY delete anywhere is the single-row `consume_state`. No reaper references `OAuth.State`; the Oban crontab schedules none. Unauthenticated unbounded table growth. |
| D16 | Frame slice D as a **response-header leak**, not CWE-598 | The token rides the Location *fragment*, so it does not propagate via Referer or the next hop's access log. Writing CWE-598 into the brief makes a builder fix the wrong thing. |
| D17 | cssom-parity wires as a **separate Node-22 job**, not a fourth step | `console-unit` pins `node-version: 20`; the instrument needs global `WebSocket` (Node 22+). Bumping the whole job would silently change the runtime under two currently-working gates to buy nothing. |
| D18 | No `setup-chrome` action; set `CHROME=/usr/bin/google-chrome` explicitly | Proven on a real runner (PR #5242, run 29801714262): ubuntu-latest ships Chrome 150 at all four candidate paths, parity PASS in 5.9s. `findChrome()` honours `CHROME` but NOT the runner's own `CHROME_BIN`. Pinning turns a future missing binary into an honest exit-2 guard instead of a silent fallthrough. |
| D19 | The wiring must make an env failure exit **2 (guard)**, not 1 (miss) | Under Node 20 the instrument prints `!! PARITY ERROR: WebSocket is not defined` and exits **1** — a misconfigured runner reds the PR with a message that reads like a stylesheet defect. Self-defeating for this epic. |
| D20 | Assert a minimum authored-rule-head **count floor** | Mutation-proving found a blind spot: INSERTING a stray `/*` passes with MISSES 0 (both sides swallow symmetrically, 1201→1188). The gate is proven able to fail only for the de-opened direction. One line closes the hole. |
| D21 | Fix the emit-marker fence in **`emit.mjs`**, not via `check.mjs`-vs-origin/main | `evaluate()` already computes `current` and `expected` in the same pass and knows `drift` before `writeFileSync` — zero new I/O. `check.mjs` compares `build()` to itself after a write (tautological PASS) and a git-diff variant is after-the-fact DETECTION of an already-destroyed file, plus a new external dep in a repo that runs out of worktrees. |
| D22 | Guard the ledger bypass at **both** patch clauses, keyed on `source:` | The compound clause (`:266`) is exploitable via its OWN `set` merge, independently of the plain clause (`:298`); guarding one leaves the other fully open. `source: :sync`/`:api` is already threaded AND read with a safe default — no new plumbing. |
| D23 | Do not reopen `gr-blk-shootsh-scen-suggester` | Its successor `gr-bl-shootsh-scen-suggester-false-done` is already open under this epic. Blind reopening creates a duplicate pair for one fix. Land under the successor; reference the original when disposing of it. |
| D24 | Do not re-parent `gr-blk-studio-presence-perf-flake` | L1-verified: its `parent_id` is already `task-96a908af98698118` ("Felix pristine initiative"), exactly where the epic's own criterion 1 sends it. Stamp the evidence; leave it. |
| D25 | **Wave 1's "AFTER X merges" serialization is RETIRED.** HEAD and SSE build in parallel from `origin/main` | It was file-truth (three slices touch one 10k-line router) mistaken for semantic dependency. Proven by an actual merge, not line arithmetic: all four stranded branches merge into `origin/main` with **exit 0, zero CONFLICT lines, and a byte-identical tree in reverse order**. The whole peer-ip change is ONE hunk `@@ -349,34 +349,81 @@`, so `plug(Plug.Head)` stays at **284 unchanged** and everything below shifts exactly **+47**. The ordering cost is paid once, at merge, by the lead. |
| D26 | The joint-defect fence is **"the mint PATH has no GET route"**, NOT "the mint is a POST" | The lead's stated mechanism is wrong and the wrong version does not protect. `Plug.Head` rewrites HEAD→GET *unconditionally, before matching*; it has no notion of POST. Counterexample measured: `HEAD /v1/tokens` returns **401, not 404**, because `get "/v1/tokens"` exists beside the POST — and authenticated, it returns **200 with 0 PATs created**, having reached the *list* handler. POST-only 404s only because no GET clause matches. A future `get "/v1/auth/sse-ticket"` would silently reopen the trap while every route was still a POST. |
| D27 | SSE mint route: **`post "/v1/auth/sse-ticket"` at `router.ex:1283`** | Between `delete "/v1/auth/logout"` (ends :1282) and the `# GET /v1/account/sessions` comment (:1284) — the authenticated session-lifecycle cluster, authenticated by the session bearer exactly as logout is, ~137 lines above its consumer `get "/v1/events"` (:1420). `POST /v1/tokens` (:3921) is the exact sibling shape. No `get` exists at that path, so D26 holds. |
| D28 | **The consume is MATCHED-ROW-ONLY. Do not copy the prescribed template.** | The wave-1 brief orders the builder to copy `reset_password_by_token`'s consume. Measured: it calls `revoke_reset_tokens(uid, now)` whose WHERE is `user_id + context + is_nil(revoked_at)` — **no `token_hash`** — so consuming one token revokes every live sibling (proven: 2 live → consume 1 → other stamped, count 2→0). The reset *mint* supersedes too. Under D10's remint that is a **two-tab mutual-eviction storm**: tab B mints → A's ticket dies → A 401s → A remints → B dies → forever, one 401 per iteration, the exact log noise D10 exists to prevent. Sibling-wide is right for `reset` (a credential-reset *event*, one link at a time); an SSE ticket is a *per-connection* artifact and the user legitimately holds one per tab. |
| D29 | Take **mint from `2fa_pending`, verify from `verify_user_session_token`, consume from NEITHER** | All three prescribed templates were measured. `create_two_factor_pending_token` is matched-row-only (2 mints → 2 live, both verify) — safe. `delete_two_factor_pending_tokens` is `delete_all` by user_id — sibling-wide. And `verify_two_factor_pending_token` **does not filter `revoked_at`** (proven: a token stamped `revoked_at` still verifies), so a builder copying it ships a ticket whose single-use guarantee is unenforceable. `verify_user_session_token` (:548-568) filters context + `revoked_at` + `expires_at` and is the correct verify. |
| D30 | TTL = **60 seconds**, as `@sse_ticket_validity_seconds 60` (seconds, not the house `*_minutes`) | The live window is only mint→connect: an XHR POST returns it and `new EventSource(...)` opens within one RTT. 20× Chrome's measured ~3000ms retry, satisfying criterion 7's "do not tune tightly against 3s". Shortest-lived credential in the codebase (`@two_factor_pending_minutes 5`, `@state_ttl_seconds 600`, reset 60min, sessions 30d) — correct for a single-use credential consumed in one RTT. Expiry is **self-healing** under D10 (one extra mint round-trip, never a dead stream), so "too short" is bounded and invisible and there is no reason to buy margin. Minutes-granularity invites "round up to 5" and a silent 5× exposure. |
| D31 | **`cloud/priv/static/app.css` joins the SSE slice's fence** | D9's fourth state does not render "unstyled" — it renders **grey**, which is worse, because grey is plausible. Measured in headless Chrome against `origin/main`: a fourth `data-state` matches **0 author rules** and falls back to `.live-dot { background: var(--dim) }` = `rgb(95,106,123)` — a static neutral dot, **visually calmer than the less-severe `reconnecting`** (amber + `live-breathe` animation + amber chip). The most severe state would paint the calmest. `--danger`/`--danger-soft` exist in both light (:69-70) and dark (:106-107) token blocks, so the rule is append-only with zero token edits. |
| D32 | The decisive argument for D31 is the **gate gap**, not the pixel | No gate catches a missing attribute-state rule. `__css_check` E2 extracts only class emissions (`/\.className\s*=\s*"…"/`, `/classList\.(?:add\|remove\|toggle)\(…/`); the chip sets state via `chip.setAttribute("data-state", state)` (app.js:11871), invisible to both regexes. `cssom-parity.mjs` contains **zero** `data-state` references — it proves authored rules reach the browser, never that emitted states have rules. A builder shipping the fourth state without app.css gets a **fully green board on a dead-looking state**: a false green on the fix for a false green. |
| D33 | The SSE slice must widen `__bpTestHook` and add a **closed-enum** test | Measured vacuous-green: `liveDotState`'s 4 existing tests are pure 3-arg equality checks and **no test asserts the return is a closed set**, so JS's permissive arity keeps them all green after a 4th state lands — `node --test` would report green while asserting zero new behaviour. Worse, the DOM assertions are *unwritable today*: `renderLivenessChip()` takes zero params and reads `evtErrored`/`lastEventMs` from private closure state with no setter, and `LIVE_CHIP_COPY`/`LIVE_CHIP_ARIA` are not exported at all. Also: an unknown state falls through `LIVE_CHIP_COPY[state] \|\| "Live"` (:11874) and `LIVE_CHIP_ARIA[state] \|\| "Live updates"` (:11881) — the chip **announcing "Live" over a permanently dead stream**. |
| D34 | The HEAD deny-list **does not grow**, and the floor is **45, not ~36** | Measured over the real `Plug.Head` pipeline: every authenticated GET writes `user_tokens.last_used_at` — **unthrottled** on the session path (`touch_last_used/2` is a bare `update_all`, two HEADs 11ms apart both wrote), throttled to 60s on the PAT path. Census: 56 GETs, 50 authenticated, 5 agent/worker → **45 writers**. The `~36` figure could not be reproduced by any method and is **retired**, not reconciled; the undercount came from 9 routes authenticating only via local wrappers (`with_team_role`, `with_team_site`, `require_user_sse`, `proxy_instance_webhook`) that a grep for `Auth.require_` cannot see. Denying HEAD across 80% of the API reinstates the 404 lie #4481 removed. |
| D35 | The write is not even gated on **authorization** — say so in the evidence | Unclaimed by anyone before wave 2: `HEAD /v1/operator/fleet` with a valid session and a non-operator email answers **403 and still moved `last_used_at`**, because `require_platform_operator/2` calls `require_user/2` first. The touch is a property of *authentication*, not of any route, so there is no subset to carve out. This sharpens D34 rather than weakening it. |
| D36 | Ledger guard extends to `createOrReplace` + `replace` only; **`create`/`createIfNotExists` are EXEMPT by structure** | Measured on all four: `createOrReplace` and `replace` close an existing claimed open task unfenced; `create` returns `{:error, :conflict}` and `createIfNotExists` a silent `noop`. The exemption is structural, not preference: **there is no prior revision on a fresh create**, so D22's `ifRevisionID` escape hatch is undefined and the same guard shape degrades from *fence* to *unconditional ban* — breaking importers the substrate explicitly anticipates (migration `20260528100000`). `existing == nil -> :ok` expresses the whole fork. |
| D37 | These two doors **erase the claimant**, and `ifRevisionID` does not save it — so the guard must also refuse a claim-drop | Strictly larger blast radius than the patch door D22 fences. The patch clause computes `merged = existing.content \|> Map.merge(set)`, so `claim` **survives**; `createOrReplace`/`replace` write `attrs["content"]` **wholesale**, so `after = {"done", nil}` — the claim is *gone*, not stale. Measured: with a **correct** `ifRevisionID` the result is still `lifecycle="done" claim=nil`. Rev is a concurrency fence, never an attribution one. The row is then permanently uncloseable through the sanctioned path (`Tasks.Close` rejects an already-terminal row as `stale_claim`). |
| D38 | The click oracle is **BUILT**, and its scope is the enumerated **8 unfixtured DELETEs**, not the charter's "six" | Prototyped and run: +184/−10 across two files, all 86 pre-existing scenarios still green, and the decisive mutation — changing the per-row Revoke from `addEventListener("click")` to `("mousedown")`, a genuinely dead button with **every source string preserved** — is caught by the oracle (exit 1) and **missed by the 9,074-line `__app.test.mjs` (exit 0)**. That is the capability gap: existing guards assert source strings, this one asserts behaviour. The charter's "six" matches the count of routes that *have* fixtures; there are **14** `api("DELETE"…)` call sites and **8** unfixtured. |
| D39 | The oracle's per-row leg needs a **stateful** fixture, or it plants the defect it exists to remove | Measured limitation: disabling the per-row DELETE fixture stays **green**, because app.js's success arm only calls `loadSessions()` with no toast, so a stateless `route()` returns a byte-identical list. Only revoke-*all* interpolates a server value (`r.data.revoked \|\| 0`) and is text-observable. Shipping the per-row leg as "covered" would be a second false green **inside the anti-false-green slice**. Require a per-boot session store so the list shrinks 2→1. |
| D40 | The sibling-class law is **narrowed to enforcement mechanisms**, not universal | Proposed as "every slice states the CLASS its fix covers and the siblings it does NOT". Only 3 of 6 wave-1 residue rows are genuinely instance-vs-class; two do not fit at all (`cch-w1-emit-fence-regression-test` is a *reflexive* gap — the fence has no test proving it can fail; `cch-bl-overview-subscription-band-stale` is an adjacent pre-existing bug w1 never touched). Stating it universally would **force false evidence onto two slices** — the exact defect this epic removes. Ratified form: **every enforcement mechanism states its own coverage boundary.** `__css_check` E2's boundary (class emission only, attribute-driven state is OUT) is the cheapest first payment. |
| D41 | **A coverage boundary must be MACHINE-CHECKED. A comment is not a tripwire.** This COMPLETES D40 by citing `bp-honest-gates` D1/D5/D11 — it is not an independent ruling | D40 required a boundary to be *stated*. Wave 3 proved stating is not sufficient: the HEAD fence's boundary comment (`router.ex:501`, "this list fences exactly TWO routes… 2 is a FLOOR, not a ceiling") went factually wrong **two commits later, inside the same wave**, from that wave's own sibling slice. Careful, scoped, hedged prose still decayed — because prose cannot ratchet. This law already exists in the repo and must be cited, never re-minted: `bp-honest-gates` **D1** (cause + population + ratchet; a fix without a ratchet regrows, citing a documented-boundary-went-stale case), **D5** (a hand-maintained key list mis-matches both ways — ban the SHAPE, do not enumerate), **D11** (where a full structural predicate is too expensive, a committed baseline count CI forbids increasing is the sanctioned fallback). `truth-grip`'s `screen.mjs` is a shipped implementation of the same law; the citation could not be re-located in this workspace's charter copy, so it is recorded as corroboration, not evidence. |
| D42 | **The HEAD-burns-ticket defect is REAL, PROVEN BY EXECUTION, and the one-line deny clause closes it with zero collateral** | Not a code reading. On a four-way composite of the wave-2 PR heads: `HEAD /v1/events?ticket=<live>` answers **422** (auth SUCCEEDED — the teamless discriminator), stamps `revoked_at`, and the user's subsequent legitimate `GET` gets **401**. `defp side_effecting_get?(["v1","events"]), do: true` → HEAD **405 + allow: GET**, `revoked_at = nil`, legitimate GET **422**. Mutation-killed BOTH directions (a probe asserting the broken behaviour positively went GREEN pre-fix, RED post-fix). Full suite 2182→**2188 tests, 0 failures** (+6 = exactly the new file). Architecturally right, not merely adequate: `consume_sse_ticket/1` takes a bare binary (`accounts.ex:2047`) and is structurally method-blind; `Plug.Head` rewrites the method and stashes nothing; the fence at `:304` is the LAST layer that still sees HEAD-ness and halts before `plug(:match)`, so the 405 costs zero DB access. Threading `conn` into `Accounts` would break the layering. `consume_sse_ticket` has exactly ONE call site in `lib/`, so one clause is SUFFICIENT, not a sample. |
| D43 | **Severity is PROVENANCE, not CVSS. The instance is PREVENTIVE; the tripwire carries the law** | Two independent sweeps agree: **nothing first-party HEADs this console.** The only real monitor (Uptime Kuma) targets the legacy `api/` app on :4000 with GETs; the deploy gate and `verify.ex` use GET; no `Req.head` in `cloud/lib`; no docker healthcheck on app services; `gr-backlog-head-requests`' own brief cites only an internal surveyor's `curl -sI` as the measured trigger. So there is no standing exploitation pressure and the 405 breaks no known consumer. That does **not** weaken the row: this is an **ACCEPTED RISK (D13, in writing) that fired inside the wave that accepted it, from that wave's own sibling slice.** That justifies the tripwire regardless of the instance's exploitability. Argue severity from the mechanism, never from an observed prober. |
| D44 | **`cch-bl-head-denylist-tripwire`'s AC#1 was VACUOUS and is REWRITTEN. The check is a D11 census pin, NOT a Repo-write detector** | The criterion as filed demanded enumerating "router GET clauses whose bodies reach a **Repo write**, directly or one call deep." **That set is EMPTY** — measured: 0 of 62 GET routes reach a `Repo.` write at depth 0 or 1. The entire 10,507-line router has **five** textual `Repo.` refs: one comment, one `Repo.preload` (a read), a `transaction`/`rollback` pair no GET reaches, and one `get_by_uuid` (a read). Every write goes through a context module — the 62 GET blocks reach **103 distinct callees across 29 modules** at depth-1. A check built to AC#1 enumerates ∅, passes forever, and is a textbook vacuous green: **the exact disease this epic exists to remove.** Replaced by a census pin (`{total, session, agent_or_worker, public}` + the deny-clause set), which satisfies the old AC#3 for free — it never asks about writes, so it never has to exclude the auth path. |
| D45 | **Do NOT build an AST walker. Corrected regex-over-source is EXACT, and AST buys nothing** | Measured head-to-head. A `Code.string_to_quoted!` + `Macro.prewalk` census (27ms parse + 2ms walk) is **route-for-route IDENTICAL** to the regex census — `diff` of the two 62-row TSVs is empty. The accuracy problem was never syntax; regex parses this file perfectly. The prior probe's `/v1/me` + `/v1/audit` misclassification was the **end-matcher variant**, root-caused: strict `^  end` = **0/56 wrong**; `^\s*end$` truncates 44; "scan to next route macro" overshoots all 56 and swallows the NEXT route's doc comment, which is where the write vocabulary came from. One character of regex discipline. Building `cloud/`'s first AST check for a tie is pure cost, and there is no Credo in `cloud/`. |
| D46 | **The `62` census is NOT a phantom — it is a SECOND CORRECT POPULATION. Do not "retire" it; SEE it** | `56` = block-form `^  get "`. `62` = 56 + **6 parenthesized one-liners** (`get("/", do: send_dashboard(conn))` at `main:494/495/502/510/6314/6315`). Both reproduce on `origin/main` by grep. This is a live blind spot, not trivia: a `^  get "` regex is **invisible to 6 real routes today**, so a future side-effecting GET written in the parenthesized form would never enter the census. The pin must use the moduledoc test's `[\s(]+` form and see all 62. D34's `56/50/5/45` reproduces byte-identically and stands. |
| D47 | **The 45-writer floor does NOT become 44 when the SSE slice lands** | Refuted by running the identical enumerator on both trees: both give **session = 45**. `require_user_sse` tries `Auth.bearer_token(conn)` **first** and still calls `verify_user_session_token`, which still calls `touch_last_used`. `consume_sse_ticket` is an **additional fallback branch, not a replacement** — and it makes the route *worse*: `Repo.update(… revoked_at)` is a harder write than a timestamp touch. |
| D48 | **The SSE mint's unbounded growth is REAL and its shape is a REAPER, not a throttle** | Proven by run, not grep-absence: 3 mints for one user → **3 rows** (non-superseding by design, to avoid the two-tab eviction storm D28/D10 exist to prevent); consuming one leaves the count at **3** (soft-marks `revoked_at`, never deletes); **15 consecutive mints → 15 rows, all 200, zero 429**. No worker in `cloud/lib/barkpark_cloud/workers/` references `UserToken`; no Oban crontab entry mentions `sse`. Reaper, not throttle, for three reasons: (a) the sibling defect D15 was paid with a reaper (`oauth_state_reaper`), and `device_auth_reaper` is the doubled precedent on main; (b) this surface's existing throttles (`@confirm_throttle` 1/300s, `@change_email_throttle` 3/3600s) guard **email DELIVERY**, a different justification than a bare authenticated row insert; (c) a per-user throttle risks 429-ing a legitimate second tab's reconnect — reintroducing exactly the failure mode the non-superseding mint was designed around. The row's 60s TTL already bounds its useful life, so growth is purely hygiene. |
| D49 | **`__css_check` E2 is NOT extended. The ruling is NO — and the fence for this instance is ALREADY BUILT by the sibling** | Both shapes were built and mutation-killed. Option A (a `__app.test.mjs` assertion calling the real `liveDotState` and checking each returned state has a `.live-chip[data-state="X"]` rule) is 26 lines. Option B is 35 lines and is **not an "extension" of E2 at all** — E2's technique is literal class-string extraction and has no path to attribute values fed by a variable, so any attribute check in `__css_check.mjs` is a bespoke parallel bolt-on with its own regex. Decisively: **PR #5377's `-r` branch already ships the equivalent, stronger fence** (`liveness chip: app.css carries a paint rule for EVERY chip state` plus a CLOSED-enum test pinning the return set), with its own documented mutation-kill, and it never touches `__css_check.mjs`. A second Option-A test would be duplicate coverage of the identical `liveDotState`/`app.css` pair. What remains is the **header disclaimer + the recorded ruling**. Correct the count while you are there: there are **4** `setAttribute("data-*")` sites, not 3 (the missed one is `app.js:16178 coherenceStampTheme`), and **3 of 4 are `data-theme`/`data-bp-theme`, already covered by E5's contrast engine** — only `data-state` is genuinely E2-blind. Known granularity limit, measured: both shapes prove SELECTOR-PREFIX presence, not per-property survival — deleting one of a state's two rules reds neither. |
| D50 | **`replace`'s `with`-chain MUST NOT be touched. The bind-nil probe is a documented-contract break with ZERO test coverage** | The wave's own premise was half wrong. Confirmed: `replace` against a fresh id returns **404 / `{:error, :not_found}`** and creates nothing, so D36's `existing == nil` fork is genuinely unreachable for `replace`. **Refuted:** the inference that a control-flow change is therefore needed. The guard call sits INSIDE the `with`-chain, after `existing` is bound to a `%Document{}` — so for `replace` the nil clause is harmless dead code, and for `createOrReplace` (which binds `existing = nil` via a `case`) it is load-bearing. Wiring the guard into both create-family clauses with **zero** change to `replace`'s control flow works (measured: the createOrReplace probe went 200 → 422 with the row unchanged, while `replace`-on-fresh-id stayed 404). With the bind-nil probe applied, `replace` on a fresh id returns **200 and CREATES the document** — silently an upsert, against `docs/api-v1.md:105` ("overwrites an *existing* draft, `not_found` if none") — and **nothing catches it**: `mutate_controller_test` + `writer_fence_test` ran 29 tests / 0 failures with the regression in place. |
| D51 | **The claim-drop guard is a SEPARATE `ensure_claim_not_dropped/4`, wired at ALL FOUR sites — NOT a new branch in `ensure_task_close_is_cas`** | Proven by mutation, not by reading. A claim-drop branch appended to that function's `cond` is **DEAD**: the `is_binary(if_rev(patch))` escape short-circuits `:ok` above it — and that escape is exactly the case D37 names. A probe with a correct rev + a claim drop stayed **HTTP 200, claim=nil**. The first `cond` branch (`now == was or now not in @terminal`) separately kills claim-theft coverage. Both short-circuits are load-bearing for D22's own proven tests, so they cannot be reordered. A separate orthogonal guard turns **all six** measured exploits into 422 with state intact, keeps `replace`-on-fresh-id at 404, leaves `create`/`createIfNotExists` untouched, and runs **1291 tests / 0 failures** — byte-identical to the pristine baseline (also 1291/0). ~24 lines, 6 hunks. |
| D52 | **D37's premise that the PATCH door is claim-safe is FALSE — three siblings measured open on today's `main`** | The charter said the patch clause computes `merged = existing.content \|> Map.merge(set)` "so `claim` survives." Counter-examples, all HTTP 200: (a) `patch` + `unset: ["claim"]` + terminal set + **correct rev** → claim key **removed** (`"claim"` is absent from the `protected` list at `mutations.ex:273`; `Map.drop(unset_keys -- protected)` deletes it); (b) `patch` + `set: {"claim": null}` + terminal set + correct rev → `claim=nil` straight through the merge; (c) `patch` + `unset: ["claim"]` + **no rev, no lifecycle change** → `lifecycle` stays `in_progress`, `claim=nil` — **pure claim theft, completely unfenced today.** This is the wave's own thesis firing on the wave's own charter: D37 was scoped to the two instances observed, and three siblings on the already-"fixed" door stayed open. |
| D53 | **`create`/`createIfNotExists` stay EXEMPT — and D36's exemption carries MEASURED residual harm the slice must name** | The exemption is confirmed structurally, not by trust: against an existing claimed task, `create` → **HTTP 409 conflict** (never writes) and `createIfNotExists` → **HTTP 200 silent noop** with `lifecycle` still `open` and `claim` intact. Neither can drop a claim or flip a lifecycle on an existing row, so wiring them is dead code. But the residual harm is real and now measured: a forged **fresh** `create` with `lifecycle_status: "done"` (exempt, correctly — no prior rev to fence on) **unblocks a dependent task in the ready queue**. `Tasks.Queue.ready` gates dependency satisfaction on `lifecycle_status == "done"` (`queue.ex:57-59`); `drafts.probe-dependent` was absent from `ready` before and present after, with a dependency-free control in both lists so the query is not vacuous. Name it, and either add a compensating control or admit there is none. |
| D54 | **The confirm sheet breaks the click oracle exactly ONCE, the remedy is ONE line, and the tier is pinned to `danger`** | Measured: probe-adding a DANGER-tier `openConfirmModal` gate to `#sessions-revoke-all` reds `account-modal-revoke` at exactly the predicted assertion (`actual=0 expected=1`) — the click now only opens the sheet. Remedy: `assert.equal(reg.get("cm-confirm").click(), 1, …)` between `all.click()` and `ctx.settle()` → **all 87 scenarios rendered**. The tier is pinned because **DESTROY costs THREE lines, and `click()` still returns 1** — so the harness's own `fired == 1` idiom does **not** catch a disarmed destroy gate. `danger` is also the honest analogue and the 2FA-disable precedent (`app.js:955-980`). The per-row leg is genuinely unaffected — measured: implementing the success toast + pending state on it with **zero** oracle amendment kept all 87 green. |
| D55 | **The smoke shim can and DOES manufacture a false green on this exact change — assert on `#modal-body`, never `#sessions-box`** | In a real browser `#sessions-box` is a descendant of `#modal-body` (`index.html:554` ← `accountModalHtml`), and `openModal` does `bodyEl.innerHTML = html` — mounting the confirm sheet **destroys** it; `ctl.succeed()` → `closeModal()` empties the body; the post-success `loadSessions()` then bails at `if (!box) return`. The shim keeps every `#id` in a **flat registry** with `isConnected: true`, so the node is immortal. Measured with a naive `onConfirm`: **all 87 green** while `#modal-body innerHTML` is `""`, `#sessions-box` still reports 1 row and "This device", and the GET count reads **3** where a real browser reads 2. The remedy is mutation-killed BOTH ways: asserting `reg.get("modal-body").innerHTML` contains `id="sessions-box"` is GREEN when `onConfirm` re-renders via `openAccountModal()` (the `app.js:975` precedent) and RED when it does not — while the existing `#sessions-box` assertions are green in both and do not discriminate. |
| D56 | **AC3 must be proven by asserting `disabled === true`, never by a second click — the shim has the INVERSE hazard** | The shim's `dispatchEvent` has **no `disabled` guard**. Measured: after the pending state sets `b.disabled = true`, a second `click()` still fires **1** handler and the run goes RED at "the click must issue exactly one DELETE". So a **correct** AC3 fix looks broken if anyone writes the obvious double-click test. State the assertion shape in the criterion rather than leaving the trap. |
| D57 | **The census tripwire's marginal value is ONE narrow case, and the slice ships knowing it** | Two mutations, both decisive. M1 (plant a new side-effecting GET): the census pin reds and names the route — **but `router_moduledoc_table_test.exs` ALSO reds and also names it**, so the add-a-route case is already paid for on `main`. M2 (silently drop auth from an existing route, count unchanged): the moduledoc test is **BLIND** (3 tests, 0 failures) and the census pin reds correctly — **but the behavioural suite also catches it** (12 `RouterAuditTest` failures). Net unique coverage: a new GET route is added, the author dutifully documents it in the moduledoc table, and nobody rules on `side_effecting_get?/1`. Real, but far narrower than "the deny-list can no longer fail open." Ship it with that stated; do not sell it as more. |
| D58 | **Act 1 is a MERGE QUEUE, not a rebase, and the branches were never literally rebased** | The direction and the first surveyor both measured zero remote branches and zero PRs; a live re-read found **all four pushed with OPEN PRs** (#5377 SSE ticket `-r`, #5378 HEAD fence, #5379 click oracle `-r`, #5380 gate ledger), all `mergeable=MERGEABLE`, every blocking gate SUCCESS including the `Test (Elixir 1.18.1 / OTP 27.0)` gate the digest called the sole blocker. `main` carries **no branch protection and no rulesets** (404 "Branch not protected"), so `UNSTABLE` gates nothing **[MEASUREMENT RETIRED 2026-07-30, wave 9 — see D106.** `main` IS branch-protected since 2026-07-28T22:42:10Z: required contexts exactly `["Elixir gate","PR references an active task"]`, both `app_id 15368`, `enforce_admins: true`, `strict: false`. This row's RULING stands on its other grounds; only the protection fact is retired.] — it is the three known-advisory reds (Format, which `main` itself fails; Sobelow, `continue-on-error` at `security.yml:55`; Vercel ×2, repo-wide). But `git merge-base` for all four is **3bbd5637d, 11 commits behind** — they were never rebased; each tip is a trivial re-fire commit. They merge and test clean only because GitHub's `pull_request` CI checks out the **ephemeral merge commit** and `mergeable` is recomputed live. Record it: a future PR touching `router.ex`/`app.js`/`mutations.ex` before these land could still surface a conflict a genuine rebase would have caught earlier. **`integ-check` was never pushed and must not be landed** — its graph carried FIVE merges including both the superseded non-`-r` click oracle and its `-r` replacement. |
| D59 | **Remote and ledger state in this checkout is POINT-IN-TIME. Re-read immediately before every mutating call — including from this charter** | Three honest reports contradicted each other on the same facts within one hour, each correct at its timestamp: PRs went zero → one → four; claims went live → lapsed-to-null → re-claimed by `steward-resume` at 09:06:29Z with epochs 9/7/8/7. `main` advanced twice mid-verification under an unrelated PDS cycle. No epoch quoted anywhere — including in this charter — may be reused; re-fetch before `stamp`/`close`. A foreign targeted claim on a live `in_progress` task 409s `not_ready` (lease TTL 2700s), so the lead either acts as the holding worker or waits out the lease. |
| D60 | **THE CHARTER ITSELF WAS INVISIBLE — D25-D40 never reached `origin/main`. Fixed by this commit** | Every wave-3 verifier independently reported `.claude/workflows/bp-cloud-console-hardening-charter.md` **DOES NOT EXIST**, and one concluded "every downstream reference to that path is unresolvable." The truth is worse and more instructive: the file **is** on `origin/main` — but only the **D1-D24** version (`#5289`). D25-D40 live solely in local commit `ac1fb3beb`, which `git merge-base --is-ancestor … origin/main` reports **NOT an ancestor**. The primary checkout's local `main` was **46 commits behind origin** and sitting on a *different* epic's uncommitted charter commit, so `ls` there answered for a tree nobody builds from. This is the epic's own predicate turned on its own memory: the ledger said the charter existed; `origin/main` said it stopped at D24. **A charter commit that is not PUSHED is invisible to every builder.** From now on the Decide charter commit is branched from `origin/main`, pushed, and PR'd — never committed to the shared local `main`. |
| D61 | **Retire `cch-w2-pr-task-gate-backtick-trailer` as a duplicate of `cch-bl-pr-task-gate-backtick-regex`** | Same defect, same file, same prescribed fix, filed 12 minutes apart by authors who did not find each other. Keep the earlier row — it is grounded in a measured CI failure with a citation (PR #5290 backtick-wrapped id RED vs #5307 unwrapped GREEN, run 29804094521). Port the later row's stronger criterion ("the test case is shown to FAIL against the pre-fix script before passing after it") onto the survivor before closing the duplicate. The bug reproduces exactly against the real regex (`.github/workflows/pr-task-gate.yml:142`): the plain trailer matches, `Task: \`slug\`` produces **NO MATCH**. |
| D62 | **Gate commands must be dry-run from a worktree cut off `origin/main`, never from the primary checkout** | Wave 3 nearly filed a false gate on this. `node cloud/priv/static/__css_check.mjs` **FAILS** in the primary checkout (`E10 app.css:1034 orphan '*/'` + an E2 miss) and **passes clean (0 errors)** in a worktree at `origin/main` — because that checkout is 46 commits behind and carries another session's state. Same class as D60. Every gate in this charter's wave plan was dry-run in an `origin/main` worktree: `__app.test.mjs` 640/640, `smoke.mjs` 86/86, `__css_check` 0 errors, `scripts/pr-task-gate.test.sh` 20/20, and both targeted `mix test` forms green. |
| D63 | **Wave 5 pays D41 across the epic's documented-but-unenforced boundaries, and every payment DOUBLES as a close** | The theme is D41, so the sweep is the spine; the wave-5 unlocking insight is that *every filed boundary in this epic is also a backlog row*, so paying D41 where a row is filed makes hardening and shrinking the SAME motion. Each Movement-1 slice = boundary comment + a machine check keyed to its type + a mutation-proof it can fail, and closes its own backlog row on merge. Finishing beats eleganza this wave (wave 4 died at Digest carrying too much); the reflexive-registry capstone is FILED, not built (D68). |
| D64 | **`#5434` was never stranded — it is MERGED, and Movement 0 is a provenance-honesty STAMP, not a build** | Confirmed by content: `a7b5284c4` is an ancestor of `origin/main`, `side_effecting_get?(["v1","events"]), do: true` at `router.ex:546`, plus `router_head_fence_census_test.exs` + `router_sse_ticket_head_burn_test.exs` both on main. It never blocked anything: `main` has **no branch protection** (`gh api …/branches/main/protection` → 404), and `pr-task-gate` is advisory. The red gate was real (the PR trailer cites a phantom slug `cch-bl-sse-ticket-head-burn`, 404 in the ledger) but toothless. **[MEASUREMENT RETIRED 2026-07-30, wave 9 — see D106.** `main` IS protected with `enforce_admins: true`, and `PR references an active task` is one of exactly two required contexts, so "pr-task-gate is advisory … toothless" is FALSE today. D64's RULING — that `#5434` was never stranded and Movement 0 is a provenance stamp — is unaffected. D104 corrected D89 only; D64 and D58 had no corrector until now.] The real row is `cch-bl-head-denylist-tripwire` (#5376) — already flipped `done` mid-session by `steward-land` but its final MERGE-GATED criterion is evidence-empty. Movement 0: stamp that criterion with `a7b5284c4`, evidence-close `cch-bl-get-census-rederive` (subsumed, per that row's own instruction), and **cancel `task-2200bea3796a4e84`** as a duplicate stub (filed 3h after the real row, 0/4, unclaimed). |
| D65 | **`cssom-floor-decays`: the ratchet is an EXACT-MATCH committed sidecar (equality, not floor); NOT git-derived, NOT relative-tolerance** | `MIN_AUTHORED_HEADS = 1201` (`cssom-parity.mjs:184`) is a static absolute floor; a stray `/*` swallowing 50 rules at 1300 heads "sails over 1201 with MISSES 0, PARITY PASS" because `heads == CSSOM rules` is symmetric. Design (a) git-derived floor breaks the file's own `ZERO DEPENDENCIES / runnable-in-a-worktree` law; (c) relative-tolerance is impossible (CI keeps no cross-run state). The feasible zero-dep ratchet is (b) as **exact equality**: a committed sidecar count, and the gate asserts `authoredHeads() == sidecar` (not `>=`), so every legitimate CSS change must touch the sidecar in the same commit and any swallow reds. Mutation-proof PERMANENT (not the one-time reverted D20 proof): a committed fixture whose head count sits above the current baseline, with a swallow shown to red against that new baseline. |
| D66 | **`state-rule-per-declaration-gate`: the fix is ~18 lines appended to the ALREADY-WIRED `__app.test.mjs`, NOT a new browser cssom-parity CI job** | Proven by run: deleting only `app.css:3470` (the `.live-chip[data-state="stale"] .live-dot` background) reds NOTHING today — the existing fence at `__app.test.mjs:4713` substring-matches the bare `.live-chip[data-state="stale"]` prefix, which survives on the sibling `.live-chip-label` line. A per-declaration probe (for each `hooks.liveDotStates` state, slice the `.live-dot {…}` block and assert it contains `background:`) reds on that exact deletion and greens otherwise (3-phase mutation-proven). `cssom-parity.mjs` is browser-backed and UNWIRED (0 workflow refs); routing the fix through it needs net-new Chrome CI — rejected for the zero-dep in-harness probe. |
| D67 | **`source-citation-line-drift`: BAN THE SHAPE, do not build a verifier; scope to `cloud/priv/static/*.{js,mjs}`, host in `__css_check.mjs`** | Every live `<file>.(js\|ex):<line>` citation in these files is WRONG right now (all 4 distinct claims point at unrelated code after a +39 sibling shift), so ban-the-shape (`bp-honest-gates` D5, "ban the SHAPE, do not enumerate") is strictly stronger than a per-citation verifier. The re-anchor convention already exists informally — cite the enclosing function name (`applyTheme`, `mountUsageTab`), optionally + a regrep — formalize it as the ban condition. Host the check in `__css_check.mjs` (in-fence, already CI-wired via `console-harness.yml`) rather than `docs-anchors-check.sh` (out of fence, and its `--include`/`doc-gates.yml` paths omit `.js/.mjs` anyway). The cross-language `router.ex`-side citations are a FILED follow-up (`cch-bl-citation-drift-cross-language`), not this slice. Fix the live drifts while there (`7cde45b0f` is a clean cherry-pick for the `__css_check.mjs` occurrence). |
| D68 | **The reflexive `@boundary`-marker registry capstone is DEFERRED to a FILED round-2 row — it is the scope that killed wave 4 at Digest** | `docs-anchors-check.sh` §8 (`@canonical capability:` slug-uniqueness + public-entry-point-within-6-lines) is a real, CI-wired mirror; the capstone reuses §8a's grep and adds a NEW invariant — a `test:<path>#<name>` field that RESOLVES (`[ -e ]` + `grep -qF`). Greenfield (0 `@boundary` markers today). Two must-design corrections: §8's `--include` and `doc-gates.yml` paths omit `.mjs/.js` where THIS epic's boundaries concentrate (a naive copy silently never fires), and static grep proves PAIRING-exists, never mutation-kill (necessary-not-sufficient — say so, do not oversell). Filed as `cch-bl-boundary-marker-registry`, round 2, template `#5434`. A wave that SHIPS per-boundary payments + a filed capstone beats a wave that DIES carrying an unbuilt one. |
| D69 | **Three "D41-violation" candidates are ALREADY ENFORCED/LANDED — they are triage-CLOSES, not builds** | `cch-bl-css-check-states-boundary` (#5438): the D49 "IF #5438's E2 comment is unenforced prose" conditional is **FALSE** — the comment is paired to `__app.test.mjs:4713` (paint-rule loop) + `:4360` (closed-enum), mutation-proven (delete `app.css:3470-3471` → #313 reds "no paint rule for stale"). Evidence-close on `069c6e986`. `cch-bl-replace-upsert-tripwire`: the test `"replace against a non-existent id is 404 and creates NOTHING"` landed via #5435 (`a893c3821`); reverting the `mutations.ex` with-chain guard flips it 404→200 (upsert). Evidence-close, do not rebuild. `cch-bl-get-census-rederive`: subsumed by #5434 (D64). Dispatching any of the three as a build burns an opus slice on shipped work. |
| D70 | **`close-fence-epoch-only` + `task-birth-attribution` stay BACKLOG; `claim-overwrite-fence` ships (in-fence via the `mutations.ex` dispensation)** | `cch-bl-close-fence-epoch-only` targets `api/lib/barkpark/tasks/close.ex` (`check_fencing/2` compares epoch only, never `worker_id`) — that path is `barkpark` CORE, out of this epic's fence (`cloud/` + `web/live/`) and inside felix-pristine's active surface; do not touch it this wave. `cch-w3-task-birth-attribution` is an explicit design task (three undecided attribution shapes) — not a mechanical D41 payment. `cch-w3-claim-overwrite-fence` pays D52's residue at the `ensure_claim_not_dropped/4` "A REPLACED claim is out of scope" boundary — `mutations.ex` + `mutate_controller_test.exs` are the standing wave-2 dispensation, so it is in-fence and ships. |
| D71 | **The smoke-shim boundary is TRIPLE-FILED — keep the combined row, cancel the two splits, DEFER the build** | `cch-bl-smoke-shim-fidelity` (both defects) + `cch-bl-shim-models-no-detachment` + `cch-bl-shim-dispatches-to-disabled` (filed 9s apart) cover ONE fix-pair in one file (`smoke.mjs`). Cancel the two narrow splits as duplicates; keep the combined row. Defer its build off this wave — it collides with `source-citation-line-drift`'s `smoke.mjs` comment re-anchor (D67) and needs the detachment-vs-declare-the-gap design call. |
| D73 | **The `--ok`/`--danger` hue invariant is CUT as chartered — it is a VACUOUS GREEN over a token the destroy button does not wear, and the only working fix overturns GR6/GR77/GR90 by stealth** | Three verifiers converge. `--danger` is `var(--cc-red-strong)` (`app.css:69`) / `var(--cc-red)` (`:106`) and is **NOT** derived from `--danger-hsl`, which feeds only `--danger-soft`; mutating `--danger-hsl` left `__css_check` at **exit 0**. `--ok-hsl` sits INSIDE app.css's generated region (45-232), so a hand edit is *also* a fence break (`design/check.mjs` exit 1 `UNATTRIBUTED cloud SPA`, `emit --check` exit 1). The invariant as filed would therefore pass over a hue the operator's destroy button never wears — the exact disease inside the row meant to cure it. The only fix that works is an emit-side `--ok` fallback, and that reverses GR90's explicit written ruling ("`--ok-hsl` is NOT touched (it must keep tracking the brand)"), made after a ~1,585-shot accent matrix, whose census also found "no other genuinely colour-only case". The residual question — does ember's success chip going green while its accent stays orange *look* right — is open-ended aesthetic judgment, and Fable is unavailable. **REWRITE the row with the measured facts and the three options (overturn GR6 / gate a perceptual distance / ratify as decision-not-defect); do not build it this wave.** Worst-case proof that it is unguarded today: emitting ember's `--ok-hsl` as PURE RED (hue 0, mode-correct lightness) keeps `check.mjs`, `emit --check` and `__css_check` all at exit 0. |
| D74 | **`--ring-soft` is PROMOTED into `design/emit.mjs`; the in-place fix is VACUOUS and silently reskins evergreen** | Mutation-proven both ways. With the cheap in-place fix applied, re-pointing it at `--warn-hsl` — an AMBER focus ring under every identity — leaves `check.mjs`, `__css_check` and `emit --check` **all exit 0**: the ledger ratchet guards literal-vs-var, never WHICH var. Under promotion, re-hardcoding evergreen green into the ember block reds the fence (`emit --check` exit 1, `DRIFT cloud SPA`). Two further grounds: `--primary-hsl` is NOT the ring channel (evergreen light ring `163 42% 30%` vs primary `151.96 71.81% 29.22%` — different hue AND +30 saturation), so the in-place route smuggles an unratified reskin of the DEFAULT identity inside an invariant; and `emit.mjs:1651` already derives `--ring-soft` from `c.ring` for the login surface, so this applies a shipped convention rather than inventing one. Derive all 19 consumers — carve out nothing: every non-focus consumer (`.tier-current`, `.prov-overall-track`, the step-dot conic-gradient, `new-next-pulse`, `.new-step-spin`) is paired with a `--primary`/`--ring` consumer in the same rule and none carries a GR57-style freeze comment. Name the evergreen-DARK shift in the brief: today's hand-stamped `160 42% 62%` matches NEITHER channel — it is unowned drift, and promotion reproduces evergreen LIGHT byte-for-byte while moving dark. |
| D75 | **The `--ring-soft` diff MUST carry `design/exemptions.json` 33→31 in the SAME commit — this is the single most likely way the slice stalls** | Measured three ways (in-place var swap, outright delete, full promotion): all produce the identical Part E red, `SHRANK 33 → 31 (-2) — a literal was tokenized (good!). LOWER the baseline to 31 … IN THIS SAME DIFF`. The ratchet fires on the GOOD direction, and a builder will read it as an unrelated break. With the baseline at 31 the full promotion is green end to end: `check.mjs` PASS, `emit --check` 19/19 in sync, `__css_check` 0 errors (91→92 tokens), `emit-fence` 5/5, `derive` 48/48, `theme-emit` 13/13. Correction to a prior belief: `--ring-soft` is **not** unguarded — deleting both declarations reds `__css_check` with 19 `E1 … consumed but not defined` errors. It is EXISTENCE-guarded and VALUE-unguarded, which is why the hand-stamps cannot simply be dropped without an emitted replacement in the same diff. |
| D76 | **`gr-p5r7`'s contrast criterion is DOWNGRADED off the slice and FILED** | Its criterion 2 ("focus-ring contrast clears the declared accessibility threshold in light and dark for all five identities") is asserted by NOTHING today: `check.mjs` Part H covers 27 curated Studio pairings and `--ring-soft` over `--bg` is not among them, and an alpha-0.15/0.2 tint's effective contrast is not derivable from that pair table. Building a contrast engine for a tint is open-ended work, not an invariant — the category this wave defers. The slice ships the derivation invariant + the ledger shrink; the contrast assertion is a filed row. Do not let the slice close claiming it. Criterion 1 ("the ruling is recorded in the charter") is satisfied by D74/D75/D76 — the charter mentioned `--ring-soft` **zero** times before this wave. |
| D77 | **The providers slice EXECUTES GR44 — it does not overturn GR36 — and its true scope is 5 client sites + `updated_at` + a rotation audit flag** | GR44 (`bp-cloud-gui-remake-charter.md:67`, git-shown on origin/main) already ruled: "connect_provider becomes an UPSERT … G-02's 'Connected — disconnect to replace' copy **relaxes to allow re-connect in place**." GR36 was a stopgap that cited the then-live backend state as its reason and named its own successor row in the same sentence. **Cite the GUI-Remake charter BY PATH** — this charter carries zero GR numbers, so a bare "GR44" is a phantom wearing a number. Scope corrections, all measured: (a) the pins are on `providerConnectModel`'s `connected` flag — mutating it reds `__app.test.mjs:5999` and `:6013`; mutating the armed-selection filters (the prescribed mutation) left **699/699 green**, i.e. the prescribed proof was itself a vacuous green. (b) BOTH armed filters must change — a one-sided fix ships **699/699 green** because `wireConnectCard`/`submitInlineProviderCred` are not exported to the test hooks and have ZERO unit reachability. (c) `provider_json/1` must gain `updated_at`: the payload is byte-identical before and after a successful rotation, so without it the console trades the lie "you must disconnect first" for the lie "nothing happened". (d) The rotation signal is FREE — `DateTime.compare(inserted_at, updated_at) == :lt` ⟺ the conflict branch, structural because Ecto fills both timestamps from ONE grouped autogenerate entry and both `replace` arms include `:updated_at`. |
| D78 | **Rotation carries `rotated: true\|false` in audit METADATA, never a new `provider.rotated` ACTION — and the replace path takes NO confirm modal** | `action` lives in `base_attrs`, computed BEFORE the transaction, so an outcome-dependent action requires restructuring `Accounts.audit/3`; and a new action string widens the closed `noun.verb` vocabulary that `list_audit_events`' `:action_prefix` filter reads. `target_fun`'s map already merges OVER `base_attrs` (`accounts.ex:394`, proven), so the whole change is one line and `audit/3` is untouched. Prefer the timestamp signal over a `Repo.exists?` pre-read: the pre-read costs a round trip and reads PRE-state, so under a concurrent connect it mislabels a rotation as a first connect. No modal, for three measured reasons: `preflight_provider` (`router.ex:8364`) runs a live authenticated call BEFORE any write, so a dead credential returns 422 and nothing is saved; POST and DELETE `/v1/providers` carry the IDENTICAL `require_team_admin` gate (`:3560`/`:3581`) and `connect_provider` is already `~w(owner admin)`; and adding friction to the SAFE one-step path while removing the two-step destructive path inverts the gradient. The residual risk (a VALID token for the WRONG cloud account) is real, but a modal asks "are you sure", not "is this the right account" — the honest mitigation is identity ECHO, which is NOT cheap (the Provider schema has no account-identity column and the hetzner preflight returns none, while Azure's `verify/1` returns meta the router discards). FILED, not built. |
| D79 | **Session provenance ships WHOLE at all six write sites, and its acceptance criterion is an END-TO-END ROUND TRIP — never column-existence or suite-green** | The six-site set is CLOSED and every site funnels through `Accounts.create_user_session_token/2` (`accounts.ex:524`), each caller holding its answer as a literal; no impersonation and no magic-link path exists (`grep -rni 'impersonat\|magic_link'` → zero). The "three or fewer sites" go/no-go was a proxy for plumbing cost, and the measured cost is one keyword per site inside an opts list that already exists. **THE TRIPWIRE, mutation-proven both directions:** `UserToken.changeset/2`'s cast allowlist does not include `:origin`, so a slice that lands the migration + schema field + write-site attr and forgets the cast list runs **141 tests / 0 failures while writing NULL on every row** — no Ecto warning, no compiler warning, `cast/3` silently discards it. Adding the cast gives 144/0 including an e2e probe driving the real device-link exchange; removing it again reds that probe with `left: nil / right: "device_link"`. So the criterion must assert the value round-trips out of Postgres (raw SQL leg included — it is the only assertion a struct default cannot satisfy), plus a never-invent assertion (no `:origin` opt ⇒ column stays nil) which passes in BOTH the dead and live states and therefore can never be the slice's only test. |
| D80 | **`origin` must NOT be pushed into `session_opts/1`; backfill NOTHING; render ONLY when present** | Five of the six sites share that helper, so pushing origin into it makes ONE shared helper answer for FIVE different origins — a complete provenance that invents, inside the wave that exists to remove invention. Append at each call site instead. `session_json/2` emits the key ALWAYS (null when unknown) so the client can tell "unknown" from "old client". The PAT surface cannot leak it: `pat_changeset/2` has a separate cast list, `pat_json/1` and `session_json/2` are explicit-key maps, and `UserToken` has no `@derive Jason.Encoder`. "approved 2d ago" uses the token's OWN `inserted_at` — the device request row carries no approval timestamp and is DELETED before the mint, so mint time is the only available clock and it is the token's own truth; do not add an `approved_at` column to chase it. Migration is additive-nullable with in-tree precedent (`20260629120100` added seven columns to this table), and blue/green-safe in ONE direction only: an OLD node against the NEW schema is fine, a NEW node against an un-migrated DB fails every `UserToken` select — so the migration lands before or with the deploy, never after. |
| D81 | **The two Overview honesty rows ship as ONE slice, and the freshness fix is CHIP-SIDE, not a body repaint** | Three measured collisions force the merge: both fixes edit `app.js`; both tests need the SAME two new fixture capabilities (a per-path failure switch inside `overviewNet()` and a topbar-capable DOM merged with `fakeDom()`, so `#billing-chip` and `#liveness-chip` live in one document); and they are one defect class stated twice. Two builders would collide on the fixture on their first commit. On the silent-refresh half the SILENCE IS CORRECT — a background blip must not blank a working screen — but the justifying comment ("the liveness chip already reports a broken stream") is measurably FALSE for a REST failure: at the instant of the failure the chip reads `data-state="live"`, label `"Live"`, ago `"· just now"`, because `es.onmessage` stamps `lastEventMs` and repaints BEFORE dispatching the refetch. **The console does not merely fail to report staleness; it CERTIFIES freshness it lacks.** Mutation-proven: a `markRefreshStale()` seam in the `!full` arm reds the chip assertion while the body-unchanged assertion stays GREEN. On the band half use `paintOverviewData(overviewData.list)` — it covers the slots meter, the instances grid (also sub-dependent, also stale) AND the state band — not `paintOverviewState`; 3 lines, and it passes all **699** existing tests, which means **no committed test pins the lie today**. E11 binds: cite by function name, never `app.js:<digits>`. |
| D82 | **`cch-bl-get-census-rederive` does NOT close on D64/D69's "subsumed by `#5434`" rationale — it closes as SUPERSEDED BY D46, or not at all** | Its criterion 0 demands "the classifier committed as a re-runnable script (`scripts/` or `tooling/`) rather than a one-off grep". `git ls-tree -r --name-only origin/main scripts tooling \| grep -i census` returns four files — a PDS schema-row census doc, `tooling/grip/census.mjs`, a grip ledger row and its test — **none of them a router GET classifier**. Criterion 2 ("state whether the 45-writer class GREW") is unanswered anywhere on main. `#5434` shipped the deny clause and two tests; it shipped no classifier. Closing on the stated rationale would be a vacuous close inside the epic whose vision sentence is "the console stops lying" — the second reflexive instance this epic has caught (standing law 2 was written for the first). D46 already reconciles 56 vs 62 as two correct populations and records that D34's `56/50/5/45` reproduces byte-identically and stands; **that** is the honest close text. |
| D83 | **Naming a successor does NOT clear the seal predicate's clause (a) — forwarding is MEMBERSHIP IN THE SUCCESSOR'S ROSTER, so the residue must be RE-PARENTED** | Run live, not read: `seal-predicate.mjs --successor cloud-console-hardening-epic` still reports **4 orphans, exit 1**, because `:131` resolves forwarding via `fetchRoster(SUCCESSOR)`. Filing a charter and passing a flag is not a forwarding address to this program. Two corrections to D72 while here: (a) the predicate calls `task-47bc4168392dec17` "the SEALED predecessor", but its own predicate returns **NO SEAL** at origin/main today (76 done / 4 open / 2 cancelled, clause (a) blocking) — D72's substantive claim (no retarget flag) is correct, the word SEALED is not; (b) the unbanded census target is **60** (53 `cch-*` + 7 misc), not 50, and the `gr-*` band is FROZEN at 69 — no new `gr-*` row has been filed since D72, so that band only shrinks. Also: clause (a)'s live set is `open\|\|in_progress` ONLY, so this epic's 2 `considering` rows are invisible to it and would seal SILENTLY. And 4 of the live rows are not console rows at all (branch protection, async test modules, a pr-task-gate trailer) — re-parent them to their true owners, which is a free reduction before anyone builds. |
| D84 | **The seal predicate's null-successor silent seal is REAL, fires exactly at the moment of SUCCESS, and ships this wave** | Reproduced against five fixtures. With ≥1 live row a null successor orphans it and reds — the behaviour a code-read sees, and the half that does not matter. With **ZERO** live rows `forwarded` is never consulted, `ok=true`, **exit 0**, and the SCOPE paragraph prints "0 forwarded by name **to null**". A fixture omitting the key prints a THIRD rendering, "to undefined", also exit 0. A bogus `--successor task-DOES-NOT-EXIST-9999` is accepted verbatim, exit 0, and printed as the forwarding address. Separately, a copy with `KNOWN_DEFECTS = []` seals at exit 0 having spawned NO guard at all. The defect fires on the one run anybody will ever quote, and next wave files the successor — so an unfixed predicate would manufacture the epic's first false seal. NOT-FOUND recorded: the console predicate has **ZERO tests** anywhere in the repo (`tooling/grip/test/seal.test.mjs` covers grip's predicate only), so every prior claim about its behaviour was contract-read. Port grip's shape while there: three exit codes (0/1/**2 = infra fault**, whose header names THIS predicate as the prior art whose exit 1 carries two meanings) and a machine-readable `VERDICT-TOKEN:` line. |
| D72 | **Movement-2 seal verdict: NOT YET SEALABLE — and that is a pre-authorized, honest outcome** | This epic has **no seal predicate of its own** — the only `seal-predicate.mjs` hardcodes `EPIC = 'task-47bc4168392dec17'`, the SEALED predecessor, with no retarget flag. 121 children = 113 open / 7 done / 1 cancelled; 69 `gr-*` (banded by the six-band census in the epic description) + 50 `cch-*` (entirely UNBANDED) + 2 misc. The shortest sealable path: (a) Movement 0 closes ~15 landed slices + their `gr-*` twins with SHAs, (b) Movement 2 censuses+bands the 50 `cch-*`, (c) a NAMED successor forwards genuine live residue (mirroring GUI-Remake→this epic). Filing that successor + retargeting the predicate is NEXT wave, not this one. Do not chase a false green by widening scope (the wave-4 death pattern); NO SEAL is acceptable and non-negotiable. |

| D85 | **Movement 0 is a SLICE with a PRE-ADJUDICATED disposition table, not a lead chore — and wave 6's thirteen named evidence-closes are ~60% payable, not 100%** | Wave 6 wrote a thirteen-row close list and never paid it; all thirteen are still `open` today. Two verifiers re-adjudicated ALL 88 non-done rows by content and the list does not survive intact: `gr-blk-cssom-parity-harden` REPRODUCES (COUNT SKEW still advisory at `cssom-parity.mjs:657`, `process.exit(0)` at `:705`, no nesting fixture in `__preview__/fixtures/`), and `gr-blk-console-refetch-storm`'s citation is half-wrong — its second SHA `82eb84a37` is NOT an ancestor of `origin/main` (squashed away) so citing it writes a dangling SHA, while `481d6f231` IS the sole introducer of `OVERVIEW_FULL` (`git log -S`) and DOES close the row. Closing all thirteen mechanically would be the exact fabrication this epic exists to cure. Against that, the sweep found **four closes nobody had listed**: `gr-blk-ledger-close-bypass-audit` (guard shipped two waves ago, `mutations.ex:177/268/312/341` + `mutate_controller_test.exs:78/175`), `gr-blk-primary-checkout-reconcile` (blocking state dissolved — 0 dirty, ahead 0), `cch-bl-overview-background-refresh-fails-silently` (closed by wave 6's OWN `576107987`), and `task-04054d483ae95bd1` (paid by a SIBLING epic's `16453cf65` — all seven `async: true` modules now `async: false`, and the row's own body already carries an unread "PREMISE REFUTED" annotation). The adjudication is DONE; only the ledger writes remain, so it is a builder slice, not lead work — and it does NOT gate the spine, because the spine's register is frozen from the vision paragraph, not from the roster. |
| D86 | **Ledger writes go through `bp task stage` / `close` / `move` ONLY. `bp doc patch` for a disposition is BANNED — it strands the reason in a draft AND freezes the row's GitHub mirror** | Rehearsed end-to-end on seven scratch rows. After `bp doc patch task <id> --set disposition_reason=…`, the PUBLISHED perspective still read `None` while drafts held the string — and `bp task get` is published-first, so a verifier reading back sees nothing and loops. Republishing DOES land it, but re-fires the publish wall (422 `label_spine` proven), and **three open children carry no tags at all** (`pp-b-branch-protection`, `task-1f8bcab494ac0a3a`, `cloud-console-operator-audit-log`) so they would 422 on republish. Worse: `mirror_job.ex` `load_task/3` is explicitly **draft-first**; a probe whose published row was staged, cancelled AND re-parented kept its issue at `status:open` indefinitely because the mirror rendered the stale draft. By contrast `stage --note`, `close <reason>` and `move` each wrote the PUBLISHED doc directly, bypassing the wall. Two more rehearsal facts the slice must carry: a RELEASED claim still refuses a foreign close (`fenced_off` on a stale epoch, `not_holder:<w>` on the right one) and needs `--set holder_override="<why>"`; and `bp doc delete` ORPHANS the GitHub issue (it stayed OPEN with no ledger row behind it) — cancel, never delete. |
| D87 | **`gr-backlog-e02-deploy-actor` CLOSES on the ratification already landed; `gr-blk-worktree-registry-bloat` CANCELS out of this epic. Neither carries an eighth wave** | All eight of the charter's e02 grounds re-derive EXACTLY on `origin/main`: five deployment-creating call sites (`deploy.ex:140`, `router.ex:6021/10273/11388/11460`), only two writing `site.deploy_requested` (`router.ex:6034/10165`), the coalesced arm at `:10186` stamping nothing, promotion writing `deployment.promoted` at `:10262`, no `target_id IN (…)` filter in `list_audit_events` (`accounts.ex:429-448`), the 90-day cliff (`config.exs:125`), and the attribution already existing in Activity (`app.js:12180`). Standing law 7 is satisfied — the sentence EXISTS at charter `:429-437`. The one thin leg (deleted-user behaviour) is closed by a sentence in the close evidence, not by a build: the FK survives, `preload(:actor_user)` yields nil, so the join's only honest render is the `system` fallback Activity already shows — no new information, which IS the ruling. Worktree bloat re-measured a THIRD time: 1,553 registrations (1,511 → 1,545 → 1,553, growing), `git worktree prune --dry-run -v` prints **ZERO** lines in 0.72s, **ZERO** of 1,544 paths missing on a FULL census. The filed remedy is a measured no-op and the row's own text already names the real defect as a `.claude/` harness leak — outside this fence. Cancel here, re-file against the harness owner. **NEVER run `git worktree prune`.** |
| D88 | **The frozen `KNOWN_DEFECTS` register is SIX entries drawn from the vision paragraph, and clause (b) gets a THREE-RUNG measurement ladder — guard / measured-by-a-named-CI-job / neither. "Neither" FAILS, loudly, by name** | The register is frozen HERE, before Movement 0's result is known, from the charter's own enumerated lies — not from whatever survives triage. Merge SHAs verified as ancestors AND by diff (never by subject: `#5308`'s subject is a sign-out cleanup while its squash body carries the coalescing fix — judge these by `git show`, never `%s`). Entries: **(1)** refetch storm 40→5, `481d6f231`, guard-measurable (`__app.test.mjs:328` counts requests: "seven fleet ticks after one boot cost 12 requests, not 40"); **(2)** session peer-IP `172.18.0.1`, `8fd00b6afb1eca55d3c991f7921ed6ec2b7d77b4`, measured_by `cloud/test/…/router_test.exs:2212-2310`; **(3)** bearer token in the access log, `d157d098c78bc6604d00d84e22d038bdb176ef58`, measured_by `router_oauth_test.exs`; **(4)** HEAD prober gets a session token, `26acc7a91be0f0352efdb3e89b2017accb786367`, measured_by `router_head_and_favicon_test.exs` + `router_oauth_test.exs`; **(5)** rate limiter sees all users as one, same root fix as (2), **measured by NOTHING anywhere** — `grep -rn peer_ip cloud/test` returns exactly one hit and it is a COMMENT (`router_test.exs:2215`); **(6)** a CSS check passing on deleted code, guard `design/emit-fence.test.mjs` (node, exit 0, wired in `doc-gates.yml:380`). `guard:` is contractually a repo-relative **node executable** (`seal-predicate.mjs:280` literally spawns `node`), with no cwd and a 300s timeout, so an ExUnit measurement CANNOT be expressed as a guard — proven: a `#!/bin/sh` guard that `exit 0`s is reported as `guard exited 1 — the defect is still measurable`. Hence rung 2 (`measured_by` + the CI job that runs it, `cloud.yml` job `test` on `cloud/**`) and the day's law: what the predicate cannot itself measure it must SAY it cannot, in the same breath. Entry (5) therefore makes clause (b) **FAIL** — that is true, and the measurement gap is filed. The mock-revoke divergence is NOT a register entry: it is still LIVE, so it is clause-(a) residue and this wave's slice; it must appear by name in the SCOPE "NOT asserted" list anyway. |
| D89 | **The permanent-human-gate bucket is THREE, not five. `cloud-console-billing-live-gate` is DROPPED as a tombstoned address, and `cch-hg-register-cssom-required-check` is NOT a human gate and LEAVES this epic** | Billing's parent is `cloud-console-goal`, whose lifecycle is **done** — an open row hanging under a closed goal. An address that exists but no longer accepts mail is not a forwarding address, and a gate belonging to a different, closed goal can neither block nor unblock THIS epic's seal. The cssom row is worse than mis-classified: `gh api repos/FRIKKern/barkpark --jq .permissions` returns `{"admin":true,"push":true}` — the fleet's own token can discharge it, and a SIBLING epic cancelled the identical row the same day with the title corrected to "NOT A HUMAN GATE … this fleet's token already carries repo admin". And its criterion as filed is ACTIVELY DANGEROUS: `console-harness.yml` is WORKFLOW-LEVEL paths-filtered, a paths-filtered workflow emits no check run at all, and `elixir.yml`'s own header records the measured consequence — `Required status check "X" is expected. <- never reported: deadlock`, refused even to `gh pr merge --admin`. Satisfying it literally would permanently deadlock every docs-only, api-only and js-only PR in the repo. It is REWRITTEN to the buildable shape ("registered by name ONCE `console-harness.yml` drops its workflow-level paths filter behind an `elixir.yml`-style `changes` dispatcher") and re-parented to the Honest Gates epic, which owns the protection flip. The surviving three: `gr-ops-platform-admin-emails`, `gr-backlog-qr-live-scan-proof`, `cch-hg-compose-network-recreation`. Measured today for the record: `branches/main/protection` → **404 Branch not protected**, `rulesets` → `[]`, so SR-1 still holds and no required-by-name pin can deadlock this wave's own fence. **[MEASUREMENT AND INFERENCE BOTH RETIRED — 2026-07-30, wave 9.** D104 retired the 404 and declared SR-1 DEAD but left the trailing clause standing. That clause is now the load-bearing error: a required-by-name pin CAN deadlock, `--admin` is refused server-side under `enforce_admins: true`, and wave 9's M3 registers exactly such a pin. See D106 and D111.] |
| D90 | **The retarget ships R4 (a successor that IS the epic is REFUSED) and a FOURTH clause-(a) shape (TERMINAL), and it COUNTS `considering` rows. Without all three the epic is architecturally required to spawn a child forever, and the one-flag false green is left armed** | Measured live against the real ledger: `--epic cloud-console-hardening-epic` with no successor REFUSES (`reason=NO-SUCCESSOR`), and R3 blocks any placeholder id — so "zero residue, terminal epic" is UNREACHABLE today. Then the trap nobody named: `--successor <the epic itself>` is ACCEPTED, and it makes clause (a) STRUCTURALLY UNFAILABLE, because `forwarded = fetchRoster(SUCCESSOR)` becomes the epic's own roster which contains every live row by construction. Run live: 83 live rows → `forwarded under successor: 79`, 4 gates, `UNNAMED RESIDUE (orphans): 0`, **`a=PASS`**. Shipping `--epic` without R4 hands the epic a one-flag path to a false clause (a) — precisely the class the predicate exists to kill. TERMINAL is accepted ONLY on a post-condition READ of the roster showing live==0 AND considering==0, never on prose. And `considering` is silently exempt today (`live = open || in_progress`, `:235`) — a fixture with one `considering` row SEALS at exit 0 with the row disclosed nowhere. Counted or disclosed by name; never silently exempt. Two more the retarget must not leave behind: test 4's emptiness sentinel hardcodes `/GR108-tablet-topbar-overflow/`, so retargeting the register makes that assertion VACUOUSLY TRUE while the test stays green (proven: `sentinel holds on UNMUTATED source: true`, suite still 11/11) — repoint it at `KNOWN_DEFECTS[0].id`; and the header still prints `=== SEAL PREDICATE — Cloud GUI Remake phase 5 ===` above `epic cloud-console-hardening-epic`, so a constants-only retarget produces a verdict that mislabels its own subject. **The guard's exit-2 collapse is NOT ours to fix**: `overflow-guard.mjs` exits 2 for "unknown `--defect`" and the predicate launders that into "the defect is still measurable at origin/main"; the fix is owned by the OPEN foreign row `hg-overflow-guard-refusal-exits-1`, whose own "wait for the terminal verdict" gate lifted 2026-07-21. The retarget teaches the PREDICATE to read exit 2 as REFUSED (its own file, its own three-code discipline) and NAMES that row rather than re-implementing it. |
| D91 | **D76 is AMENDED, not overturned — its ground was TRUE of `design/check.mjs` and FALSE of `__css_check.mjs` — and the focus ring ships as a live WCAG SC 1.4.11 DEFECT fix in three parts, of which part (c) is load-bearing** | D76 correctly downgraded and FILED the contrast criterion; the filed row then generalised D76's ground ("needs alpha compositing the engine does not do") to the wrong instrument. `__css_check.mjs:926` reads `contrastRatio(compositeOver(fg, bg), bg)` with source-over at `:891`, and six existing pairs already use `over:`. So this was never an engine gap. Measured inside the REAL checker with five probe rows: **60 of 60 cells FAIL**, range 1.18:1 → 1.52:1 against a 3.0 threshold, across 12 theme states (not 10 — five identities × two modes plus base). And it is an ARITHMETIC CEILING, not a palette problem: brute-forced over every ring colour × every opaque backdrop, α=0.15 tops out at **1.617:1** and α=0.20 at **1.918:1**, so no accent present or future can ever green it. That converts the row from an assertion gap into a live defect on **19** `:focus-visible` selectors (not the filed "~28"; and `.form-input:focus` is NOT one of them — it carries an opaque `border-color: var(--ring)`, as do `.fleet-row` `:1409` and `.site-row` `:1520`). THE DECISIVE FINDING: on UNMODIFIED main, with all five `--ring` pairs added, `__css_check` exits **0** while 19 rules still paint a 1.19–1.52:1 band — `CONTRAST_PAIRS` asserts TOKENS, never which token a rule CONSUMES. Ship the pairs alone and the epic manufactures the disease it exists to cure. Hence three parts: **(a)** repoint the 11 declaration lines to `var(--ring)`, **(b)** five `CONTRAST_PAIRS` rows on `--ring` (mutation-proven: lightening `--ring` to L92% reds 6 cells), **(c)** a rule-level detector refusing any `:focus`/`:focus-visible` rule whose SOLE indicator band resolves to an alpha<1 token. The route matters: rewriting the alpha literals to `/1` greens the same cells at the same 3.31:1 worst case but reds `design/check.mjs` (8 drift lines — `--ring-soft` sits in a generated region), forces an `emit.mjs --write` that regenerates `api/lib/…/session_html.ex`, and turns four legitimately-decorative consumers solid. The var-reference repoint instead leaves `design/check.mjs` PASSING and `cssom-heads.baseline` at **1235 UNCHANGED with MISSES 0** — so this wave's CSS touch does NOT fire the baseline-bump constraint. Do NOT add `--ring-soft` pairs after the repoint: the four decorative uses are legitimately translucent and would red the build. |
| D92 | **The smoke red is a STALE EXPECTATION repairable by deleting ONE string — quarantine is unnecessary and would be dishonest — and the "415 tests" claim is DELETED, never updated** | `smoke.mjs:2076` excludes `data-step="secure"` from `fleet-support-provisioning`, but `app.js:13277` reads `SUPPORT_STEP_ORDER = ["create","secure","configure","content","verify","ready"]`; `secure` joined legitimately in `1b71a4d09` (2026-07-26), **two days AFTER** the expectation was authored in `f021b4cd4` (2026-07-24). The product is right, the assertion is stale. Deleting the string takes the harness from `1 scenario(s) failed`/exit 1 to `all 98 scenarios rendered`/exit 0, mutation-proven both directions. The repair MUST carry two prose corrections in the same diff (`smoke.mjs:2072` "the 5-rung SUPPORT theater, never a secure rung" and `scenarios.mjs:2877` "SUPPORT theater (5 rungs, no secure)") or it manufactures this epic's own disease; `freshen` stays main-only, so that half of the exclusion survives. Wiring is IN FENCE by a standing wave-1 dispensation (`console-harness.yml`, "CI wiring for console instruments") — no widening needed — and the "needs net-new Chrome CI" objection is STALE: `console-harness.yml`'s `cssom-parity` job has run node 22 + `CHROME=/usr/bin/google-chrome` since wave 5. Both zero-dep instruments run green on node 20 (the `console-unit` job's pin) and `seal-predicate.test.mjs` is proven HERMETIC — a sentinel `curl` shim first on `PATH` never fired, with `BP_TOKEN` unset and `BP_SERVER` pointed at a dead port, 11/11. Wire the TEST, never a LIVE seal run: under `actions/checkout@v4`'s depth-1 default (which BOTH console-harness jobs use, bare, no `with:`) `git merge-base --is-ancestor 0261ace15 origin/main` exits **128 `fatal: Not a valid object name`**, and `seal-predicate.mjs:262-264` catches ANY non-zero as "not an ancestor" — a shallow checkout would manufacture a clause-(b) NO SEAL that is an artifact of checkout depth. The header's count is wrong twice over (`:7` and `:83` both say 415; the suite is **714**) and the filed row's own 699 decayed by 15 within a day — DROP the number, do not restate it. |
| D93 | **Honest post-wave residue is ~35–45 live rows = six to eight more waves. NO successor is filed this wave, and when one is finally needed it is an ADDRESS, not an EPIC** | The residue is **86**, not 83: three OPEN rows (`gr-bl-seal-predicate-provenance-gap`, `gr-bl-task-write-cap-breaks-briefs`, `gr-bl-reap-orphaned-preview-port-squatters`) are parented to `gr-p5r5-successor-seal`, and clause (a) reads DIRECT children only — closing `gr-p5r5` without re-parenting them first re-commits the self-orphan trap one level down. `gr-p5r5` is itself the 15th unpaid close: its work was EXECUTED by its `done` 15/15 child `gr-p5r12-terminal-act`, and its own 13 criteria read 0/13 purely because nobody stamped the parent. Arithmetic: 86 − 15 closes − 3 gates − ~10-14 foreign re-parents − ~6 wave-7 builds − ~8-12 more closed-by-content from the ~50 never swept ≈ 35-45. Anyone claiming wave 8 finishes this is claiming a 40-row wave. A vision dies BY FORWARDING: the GUI Remake's successor inherited a charter, a thesis and a roster to grow into, and died of it. But clause (a) does not ask for a vision — it asks `forwarded.has(c._id)`, pure roster MEMBERSHIP. So the eventual successor is a **no-vision residue bucket**: one named parent, no charter, no thesis, whose only contract is that the rows are addressed and enumerable. Decision rule ratified here: **file nothing until the post-adjudication residue is ≤ one wave's build capacity (~10 non-gate rows)**. Filing a bucket at ~40 converts adjudication into dumping, and that starts the moment the bucket exists. |
| D94 | **D70's scope is CORRECTED: it is a per-row backlog ruling, not a general `api/**` bar. The FENCE section is the authority — and the 7-row `api/**` family plus the 5-row worktree-hygiene cluster are re-parented or DISCLOSED, never silently carried** | Premise smoke caught this wave about to cite D70 as "the api/** code bar". Read on `origin/main`, D70 rules on exactly two rows (`close-fence-epoch-only`, `task-birth-attribution`) and grounds them in the fence; it authorises nothing general. The fence itself (`cloud/`, `api/lib/barkpark_web/live/`, plus the named standing dispensations) is what bars `api/**` — cite THAT. The consequence is unchanged but the reasoning is now honest, and it exposes a structural problem the seal cannot survive: seven open rows whose ENTIRE surface is `api/**` (`gr-blk-ledger-close-bypass-audit` — now closable by content, `cch-w3-task-birth-attribution`, `gr-bl-tasks-route-parent-filter-ignored`, `gr-bl-task-move-noop-help-drift`, `gr-backlog-webhook-testsend-http-test`, `cch-w1-mirror-direct-write-unfenced`, `gr-bl-close-time-audit-vacuous-green`) can NEVER be built inside this fence, so unre-parented they are permanent orphans that make SEAL structurally impossible. Re-parent only into a NAMED epic that EXISTS (D83 makes an invented address worse than none); where no owner exists — the worktree-hygiene cluster, `gr-bl-github-mirror-reparent-residue` — DISCLOSE by name rather than invent one. And note the hazard the re-parents themselves create: `content.github.parent_marker` is re-stamped ONLY on the cap-flatten branch and never cleared, so a native re-parent leaves the old epic named in the issue body — an instance of `gr-bl-github-mirror-reparent-residue`, the one row with no owner. The label a human reads (`goal:<parent>`, derived live from `parent_id`) IS correct and converges in ~40s. |
| D96 | **Premise smoke voided FIVE inherited premises and the wave's own framing. Movement 0 WAS executed; the disease is live at a NEW site — the merge-gate stamp — and its census is FOUR, not six, seven or thirteen** | Wave 8 inherited a wish written from wave 6's horizon. Re-derived live against `origin/main`: Movement 0 ran (wave-7 REVIEW: 46 ledger writes, 17 closes, 14 re-parents); `gr-backlog-e02-deploy-actor` is CLOSED (D87); `gr-blk-worktree-registry-bloat` is CANCELLED on a third zero-prunable census; `cch-bl-seal-predicate-retarget-and-reparent` SHIPPED as #6695 (`799ed3241cb00babd2a6a320dba58fca5a9fd530`); `gr-blk-vercel-checks-ungoverned` closed into a foreign epic. None reaches a builder. **But the disease reproduced within 48h at the merge boundary**: five rows carried a BYTE-IDENTICAL unmet criterion (sha1 `f34f36da1a47`) whose only gap was the lead pasting a merge SHA. THE COUNT IS FOUR, not the direction's six: `cch-bl-mockjs-revoke-stateless` was PAID LIVE during verification (claimed on epoch 7, stamped, closed `done` 8/8 at 14:04:25Z, GitHub issue 5373 closed 43s later), and the roster now reads 132 children / 64 live. The 6/7/13 disagreement across three surveyors is a POPULATION CONFLATION, not a measurement conflict: 13 is D85's wave-6 evidence-close list, 7 counts n-1 rows including two that are not SHA-payable. **THE SELECTION PREDICATE IS `met == total-1` AND an ancestor-verified merge SHA — never the criterion string**: THREE live rows carry that same byte-identical stamp at **0/N with no PR at all** (`cch-bl-auth-touch-unthrottled` 0/7, `cch-bl-destroy-verbs-stateless-family` 0/4, `cch-bl-styleguide-inline-css-uncertified` 0/4), so a string-keyed sweep would fabricate-close this wave's own M2 headline row. |
| D97 | **The console harness has NEVER been green in CI, and test 23's failure is a STALE MUTATION whose truth turns on ABSOLUTE PATH LENGTH. Fix it with one literal — do NOT exclude the step. D92's "11/11 hermetic" claim is CORRECTED** | Four consecutive main runs since the step landed (`612ab542b`, `08437ad14`, `2c94b0ba7`, `e99e7cd63`) all fail on the identical `not ok 23`, 29/30, while `__app.test.mjs` passes 720/720 and `cssom-parity` passes on the same red run. Forensics: #6694 added the `seal-predicate.test.mjs` step and ran green against the **11-test wave-6 file**; #6695 replaced that file with the 30-test suite and its own main run had **zero** occurrences of `seal-predicate` (`grep -c` = 0). Neither PR ever ran the combination — a textbook stale-base green, two honestly-green PRs whose union is red, nobody's post-condition read. So **D92's "seal-predicate.test.mjs is proven HERMETIC … 11/11" was measured on the PREDECESSOR file and does not hold for the 30-test file on linux.** The ruling stands; the measurement does not (the D89 pattern). MECHANISM, measured at one commit: test 23 deletes BOTH the `GUARD_ENV` scrub and `maxBuffer: 16 * 1024 * 1024`, then demands the mutant report `NEVER RAN (ENOBUFS)` — which only fires if the guard's V8-serialised stream exceeds spawnSync's 1 MiB default. That byte count is driven by checkout path length and platform, NOT by any code in the repo: macOS n22 deep path **1,173,861** (OVER → passes); macOS n22 short path **978,921** (UNDER → fails); linux n20 **896,566** (UNDER → CI's red); context unset **156,673**. Node major is a red herring — macOS n20 passes 30/30, linux n20 fails. This resolves the flat contradiction between three verifiers who reported 30/30 and one who reported 29/30 on the same commit: they ran from different-length paths. THE FIX IS ONE LITERAL — replace the mutation's option-deletion with `, maxBuffer: 64 * 1024 });` — proven green in all four configurations INCLUDING the script mode that reproduces CI's red today, and proven STILL SENSITIVE (inverting to `64 * 1024 * 1024` reds test 23 again). Excluding the step by name would disarm the only instrument clause (b) rests on, inside the wave whose thesis is that instruments must be able to fail. **File the unfiled row**: #6694 merged titled "green the smoke harness" while its own merge run went red, and no row records it. |
| D98 | **M1 SPLITS and the required-check flip is STRUCTURALLY UNAVAILABLE this wave — three independent forcings, not a taste cut — and `scripts/console-path-escape-check.sh` is a PREREQUISITE, not a nicety** | The wave-6 "cut the open-ended slice" move applies again, but here it is forced by mechanism. (1) **The sampling rule**: `.github/required-checks.json`'s `_readme` requires ≥2 POST-SHIM heads on which `Dispatch (changed-path sets)` succeeded; a brand-new aggregator name renders on NO existing head, so the generator cannot sample it until after the dispatcher merges. Proven: with one pre-shim head in the sample, S1 intersection drops `Console gate` entirely and the generator then selects the two HEAVY job names directly — the exact registration shape the shim exists to avoid. (2) **The floor**: a console-scoped regeneration is `FLOOR BREACH … LOST Elixir gate / LOST PR references an active task`, exit 1. (3) **It is already filed, cross-epic**: `cch-hg-register-cssom-required-check` is OPEN 0/3 under the Honest Gates root, classified a HUMAN GATE ("no commit can satisfy this … note it, never build around it"), and the check it names is a JOB INSIDE `console-harness.yml`. So this epic files nothing new; it ships the buildable half D89 already authorised and hands Honest Gates a registrable name. Add (4): the harness is red on main (D97), and requiring an aggregator today would block every cloud PR with an honest `is failing.` under `enforce_admins: true`, where `--admin` is refused. **The order is: fix test 23 → dispatcher lands → flip stays FILED.** And the dispatcher MUST call a committed path-set ratchet: `scripts/console-path-escape-check.sh` does NOT exist on `origin/main` (`elixir-path-escape-check.sh` does, at `:44-50`, and its `--print-set`/`--match` seam is what stops workflow and ratchet drifting). Inlining the four globs reproduces the #4393 golden-path hole that `console-harness.yml`'s own header documents — with a would-be-required context on top. |
| D99 | **Deleting the workflow-level `paths:` key auto-clears the S4 exclusion with ZERO generator edits — and silently makes both LEAF console jobs promotable, so the aggregator must SUBSUME them via `needs` in the same diff** | Run through the real `scripts/required-checks-generate.sh` with only the workflow dir swapped: BEFORE, `exclude Console client unit harness — S4 PATHS-FILTERED` and the same for `CSSOM parity`; AFTER, all four names kept past S4, then S3 subsumes the three upstreams and the emitted spec carries **exactly one** context, `{"context": "Console gate", "app_id": 15368}`. The generator's `build_workflow_index()` derives `pf` from a workflow-level `on: pull_request: paths:` key at exactly one line — deleting the key is the whole fix, and the builder writes YAML only. THE HAZARD NOBODY NAMED: that same flip makes `Console client unit harness` and `CSSOM parity (authored CSS vs browser)` eligible SELECTION candidates, and neither is `needs`-subsumed today because no aggregator exists in that file. The next regeneration by anyone, for any reason, would promote them at exit 0 — verbatim the failure mode D69 already named, and compounded by D97 (promotion would install a permanent red). Both leaf jobs go into the aggregator's `needs` in the landing diff. Name collision checked by census, not by eye: `grep -rn 'name: Dispatch' .github/workflows/` returns exactly one hit (`elixir.yml:86`), and every rendered job name in the repo is unique — `Dispatch (console paths)` and `Console gate` are both unclaimed. |
| D100 | **The aggregator is a TRANSPLANT with an ENUMERATE-AND-FAIL allow-set, proven on a 6/6 truth table — and `exit 2` laundering is a NAMED residual the flip must clear before it registers anything** | `elixir.yml:606-678` runs this exact pattern in production under this exact protection config, including the trap its header records verbatim: a job skipped because its `needs` FAILED also reports `skipped`, which GitHub counts as passing, so `if: always()` buys the right to decide but does not decide. The extracted `decide()` was driven over six upstream shapes: docs-only (dispatcher success, gate literally `'false'`, both heavy jobs skipped) → exit 0; **dispatcher FAILED so both jobs report `skipped` with an EMPTY gate** → three FAIL lines, exit 1; `cancelled` → red; a job dropped from `needs` yielding an EMPTY result → red. A skip is accepted ONLY against the literal string `false`. THE RESIDUAL, measured and unresolved: `cssom-parity.mjs` and `seal-predicate.mjs` use `exit 2` to mean *I REFUSED to measure*, and a boolean aggregator launders that into a defect claim — under a required context a runner image dropping Chrome would brick main with a manufactured red. Worse, that lane is BROKEN in CI's exact configuration: `console-harness.yml` pins `CHROME=/usr/bin/google-chrome` and its header claims a missing binary "exits 2 as a GUARD naming the missing path", but `findChrome()` returns `process.env.CHROME` **unchecked**, bypassing the `accessSync` loop that feeds the guard — measured `CHROME=/nonexistent` → **exit 1**, uncaught `Error: spawn /nonexistent ENOENT`, raw node stack. The sibling guard on the same file works correctly (`HEADS_BASELINE=/nonexistent` → exit 2 with a guard line), which proves the lane exists and only the CHROME branch skips it. One `accessSync` + one test; the workflow's own pin is the path that disables the guard the workflow documents. |
| D101 | **CCH-D5's registration is round 2 behind the test-23 fix, because measuring the rate limiter INVERTS four assertions in the same test file — and the discriminating mutation is the KEY COLLAPSE at `router.ex:766`, never the plug deletion at `:261`** | `seal-predicate.test.mjs:326-329` asserts, by name, that `CCH-D5-rate-limiter-sees-every-user-as-one` sits at **rung 3** and is *"the reason for the red"*. So the slice that lands the measurement must rewrite those assertions in the same diff — the same file the D97 fix touches. Sequenced, not merged: the fix is one literal and unblocks the dispatcher, the registration is a bigger piece. THE BUILDER TRAP, caught by running it: `device_auth_test.exs:281` already proves distinct ETS KEYS get independent budgets, so a builder will find it and close the row as already-done. What is unmeasured is the COMPOSITION — that two distinct CLIENT ADDRESSES arriving at the router produce two distinct keys through `trust_forwarded_ip → conn.remote_ip → peer_ip/1 → "start:" <> ip`. Deleting `plug(:trust_forwarded_ip)` (`router.ex:261`) does red the new test, but it ALSO reds four existing cases in `router_test.exs`'s "front door" describe block — citing it would stamp evidence the test structurally cannot own. The discriminating mutation is collapsing the bucket key at `router.ex:766` to a constant: the new test reds 2/2 while `device_auth_test.exs` + `router_test.exs` together run **203 tests, 0 failures**. That invisibility IS the gap. Restoring returns all three files to **205 tests, 0 failures**. Rung-2 registration resolves clean (`cloud.yml` has a top-level `test:` job and filters `cloud/**`), and the predicate's rung-2 classifier genuinely re-verifies file/workflow/job/paths existence — with ONE hole: it raises only when EVERY `measured_by` path is missing, so name exactly one path. Fix the register's own stale cite in the same edit (`router_test.exs:2215` → the live line is **2374**), or the instrument that exists to catch stale measurements ships one. |
| D102 | **`cch-bl-auth-touch-unthrottled`'s FILED FIX IS REFUTED BY MUTATION: the 60s throttle does not pay the row's title. Retarget to authorization-awareness; four of its five anchors are stale and the fifth is CORRECT** | Proven twice at the router level, before and with the filed fix applied verbatim: a user idle **3600s** (60× the window) fires ONE request, is REFUSED `403 {"error":"forbidden"}`, and `last_used_at` still jumps a full hour — the sessions card would render an 11ms-old stamp, "Active just now", for a DENIED device. With the throttle in place the identical probe produced the identical result (403, stamp advanced, 12ms age): the throttle's own guard is SATISFIED by an idle device, so it is structurally incapable of touching this case. The row would close green at 7/7 with the operator-visible lie fully intact. STRUCTURALLY: `require_platform_operator` (`auth.ex:270`) calls `require_user` FIRST, which calls `verify_user_session_token`, which calls `touch_last_used` unconditionally at `accounts.ex:609` — and only THEN evaluates the allowlist and `forbidden(conn)` at `:276`. `auth.ex` has SIX `forbidden(conn)` sites, every one downstream of that write; a throttle at the write site cannot see any of them. The fix cannot live inside `verify_user_session_token/1` at all: it has THREE call sites (`auth.ex:46`, `auth.ex:109`, `router.ex:11060`) and returns a `User`, not a `Conn`. Stamp downstream of the response decision — `Plug.Conn.register_before_send/2` writing only when `conn.status < 400` — which pays BOTH the title and the write-amplification the throttle was aimed at. TWO CORRECTIONS the brief must carry: the filed predicate `> 60` REDS an existing green test (`accounts_test.exs:296` backdates by exactly −60s; `60 > 60` is false; baseline 85/0 becomes 85/1), so specify `>=` or widen the backdate; and **`list_audit_events` is at `:429-443` on `origin/main` — the row's existing anchor is CORRECT and must NOT be retargeted**, while `verify` `:584→:595`, `touch_last_used` `:597→:622`, the constant `:712→:737` and `stamp_last_used` `:1740→:1764` all ARE stale. |
| D103 | **The modal-census tripwire is CHARTER-BANNED at the exact call site it would guard (GR56) — CUT. The two invariant slots go to the cssom CHROME guard and an E10 fixture, both mutation-proven disjoint** | `app.js:18393-18396` reads verbatim: *"openModal / closeModal are IMPURE and exported here by explicit charter permission — proving the pin FAIL-OPENS behaviourally is the only honest gate, and **a source-regex guard is banned (one already passed on a commented-out line)**."* That is this epic having already run the bakeoff, lost it, and written the ruling into the source; filing an `openModal` census would be re-litigating a decided ruling with a probe. Corroborating softness: the census reads 15+ (row), 30 (digest), 32 and 33 (two verifiers) — three surveys, four numbers, the signature of a regex census whose extractor is the thing in dispute. And `modal-oracle.mjs` contains **ZERO** occurrences of `openModal`: it certifies that the authored `.modal-root` rule survived into the CSSOM, so the row is mis-premised at the root, not merely mis-counted. THE REPLACEMENTS ARE BOTH ASSERTABLE AND TASTE-FREE. (a) The CHROME exit-2 guard (D100's residual) — the epic's own law at the epic's own instrument. (b) An E10 fixture: the full brace matrix was RUN and the two instruments are DISJOINT, not redundant — unclosed `{` and stray `}` are MISSED by `__css_check` and CAUGHT by `__app.test.mjs:1315`; an orphan `*/` is CAUGHT by E10 (`FAIL E10 app.css:4707`) and MISSED by the brace tripwire (`ok 52`, 720/720). What is missing is the PIN: `__css_check.fixture.css` is E9-only, its own header names a proof command (`--swallow-check`) that appears NOWHERE in `console-harness.yml`, and `orphanCommentErrors` has zero consumers beyond one main-run call. A regression fixture nobody runs is an instrument that cannot fail. Wire the proofs into `__app.test.mjs` (already CI-run) rather than the workflow, so this slice does not collide with the dispatcher. |
| D104 | **D89's RULING stands and its MEASUREMENT is now false; D93's arithmetic HOLDS at 64 live rows; and `bp task claim` SUCCEEDS on a released/expired claim, so M0 needs no `holder_override`** | D89 recorded "measured today for the record: `gh api …/protection` returns 404 Branch not protected, rulesets []". Live today: contexts `["Elixir gate","PR references an active task"]`, both `app_id 15368`, **`enforce_admins: true`**, `strict: false` — installed by a single attributable PUT at 2026-07-28T22:42:10Z (Honest Gates `hgw2-s7`, merged as `40d5cddcc`/#6926), and it has already refused four merges. Repo memory "SR-1: no CI check can block a merge" is DEAD. The ruling D89 made survives on its other grounds; only the fact is retired. D93 projected ~35–45 post-adjudication residue; the live board reads **132 children / 64 live (63 open + 1 considering)**, of which **53 sit at ZERO criteria met** — above the band, but the derivative is what matters: M0 is a ONE-TIME inventory correction, and after it the board falls only at build rate (~5 PRs/wave), so ≤10 non-gate remains five to seven waves out. **M0 IS ~11 WRITES, NOT ~55**: 42 of the 53 zero-criteria rows were adjudicated against `origin/main` and the payable rate is **~2% fully / ~7% with partials**, not wave 6's 60% and not a surveyor's 25-30% — wave 7 already harvested the stock. MECHANICS, run end-to-end on a live row: D86's "a RELEASED claim refuses a foreign close" is about a foreign CLOSE, never a CLAIM, and all these rows carry the EXPIRED shape D86 explicitly left untested. `bp task claim` SUCCEEDS, **BUMPS the epoch** (6→7 — never hardcode it), flips the row to `in_progress` (so a crashed sweep hides rows from an `open`-only census), and the one-call atomic `close --set 'criteria:=[…]'` reaches the identical published end state without tripping the work-digest fence. The GitHub mirror is NOT frozen by this path — issue 5373 closed 43s later. THE SWEEP HAZARD: `bp` fetches `/v1/capabilities` on EVERY invocation and 429s under modest polling, failing as **EMPTY STDOUT** — 33 of 53 first-pass fetches returned a rate-limit body, and a liveness test keyed on well-formed JSON accepts every one of them. Validate on the `"doc"` key, never on `{`. |
| D105 | **D95 has REGRESSED from partial to a WHOLESALE document-CREATE outage, measured with a control — so wave 8 pays Movement 0 with the LEAD's own hands and dispatches only slices that already have a published home. Two fully-specified slices are DEFERRED for want of a filable row, and say so rather than being smuggled in** | Wave 7 recorded D95 as "partially RECOVERED: `bp task create` works again (intermittent timeouts remain)". It does not. Measured 2026-07-30 across FOUR verbs — `bp task create`, `bp doc create`, `bp doc create-or-replace`, `bp doc create-if-not-exists` — every one returns HTTP **500 `internal_error`** with a `request_id`, or a client timeout. The decisive control: raw `curl` with an absolutely minimal five-field task doc returned **HTTP 500 at 33.9s**, while a `patch` against the SAME `/v1/data/mutate/production` endpoint returned **200 in 1.3s**. So it is the CREATE path specifically, not payload size, not auth, not the server as a whole — and later in the run even `GET /v1/capabilities` began returning 500, so the degradation is widening. 14 retries over ~11 minutes at 45s intervals never recovered. CONSEQUENCES, all taken rather than worked around. (1) **Movement 0 is LEAD work, not a builder slice** — which is what standing law 5 and the criterion's own wording ("LEAD closes this criterion") said all along, and at ~11 payable writes (D104) it never justified a builder. Seven rows closed with published read-backs. (2) **Every dispatched slice must map to a row that ALREADY EXISTS**, and the mapping must be honest: a row means what it says, so repurposing an unrelated row to host a slice is forbidden. `gr-blk-cssom-parity-harden` was examined as a host for the CHROME guard and REFUSED — its three criteria are about `GROUPING_AT` modelling and the stylesheet roster, and overwriting them would destroy live content to buy a dispatch slot. (3) **The test-23 fix is MERGED INTO the rate-limiter slice** rather than filed separately, because both edit `seal-predicate.test.mjs` and one file should have one owner per wave; the brief orders the fix FIRST, as its own commit, so the lead can cherry-pick the unblocker if the Elixir half stalls. (4) **The dispatcher/aggregator + `console-path-escape-check.sh` (D98/D99/D100) and the cssom CHROME refusal guard are DEFERRED** — fully specified here, dispatchable the moment `create` recovers, and NOT counted as this wave's work. (5) The owed independent review for the two flip-risk slices could not be filed as a row, so it is stamped as an ACCEPTANCE CRITERION on both — a gate a merge cannot skim past, which is the point the lead notes make. Also observed and cleaned: a STRANDED DRAFT TWIN (`drafts.gr-bl-delivery-keyset-tiebreak`, 7/8) appeared in the roster as a SEPARATE CHILD shadowing its published parent at `done` 8/8, inflating the census by one — D86's draft-first hazard reaching the roster read itself. `bp doc discard-draft` removed it with the published row verified unchanged. Any future census must count `drafts.*` entries as duplicates, never as rows. |

| D106 | **The epic's founding premise FLIPPED and three decision rows still asserted the old one. Corrected BY CONTENT at D58, D64 and D89 — not by appending a fourth row that silently contradicts them** | Re-measured 2026-07-30 at `origin/main` `74a88d1cd`: `gh api repos/FRIKKern/barkpark/branches/main/protection` → `{"contexts":["Elixir gate","PR references an active task"],"enforce_admins":true,"strict":false}`. D104 had already retired D89's 404 and declared repo memory SR-1 DEAD, but it named **D89 and only D89** — `sed -n 229p | grep -c 'D64\|D58'` returns **0** — so D58 and D64 stood uncorrected, and D89's trailing inference (*"no required-by-name pin can deadlock this wave's own fence"*) survived D104 untouched. All three now carry inline dated retractions preserving their rulings. Two more live spans are a build slice (`cch-w9-stale-protection-claims`): `docs/ops/merge-gates.md` item 7 still ends *"**Currently advisory** until made required-by-name"* while §"Making `pr-task-gate` binding" in the SAME FILE already says *"This gate is now BINDING"*; and `.github/required-checks.json` `_readme[4]` says `console-harness.yml` remains *"structurally disqualified regardless"* — a sentence wave 9's own shim falsifies. **ZERO-EDIT, stated so nobody invents a diff:** `.github/workflows/pr-task-gate.yml` is ALREADY correct (`grep -c "no branch protection"` → 0; :36-40 read *"THIS CHECK IS BINDING"*). A prior brief listed it as stale; that listing is REFUTED. |
| D107 | **M1 and M4 are ONE DIFF for the cloud half, and the coupling is BIDIRECTIONAL — there is no ordering in which they land separately without a manufactured NO SEAL on protected main** | `seal-predicate.mjs:478` does `src.includes(d.measured_in_ci.paths)` against cloud.yml's RAW TEXT, and `cloud/**` appears in cloud.yml at exactly lines **11 and 22** — both inside the `on:` paths key M1 deletes. Measured both directions. **M1 without M4:** deleting the key flips that substring true→false while job `test` still matches; all four rung-2 entries print *"does not filter on `cloud/**`"*, the token goes `b=PASS` → `b=FAIL`, and 7 of 31 `seal-predicate.test.mjs` tests invert. **M4 without M1:** a prototype of the replacement resolver, run against origin/main as it stands, reds the same four with *"cloud.yml job `test` rolls into NO always()-aggregator — nothing can require it"*. Only the two together are green, and green then MEANS something. **THE CHEAP ESCAPE IS FORBIDDEN AND WAS MEASURED:** inserting one YAML *comment* containing `cloud/**`, with the real paths key still deleted, restores `b=PASS`. That would make the epic's honesty instrument pass on prose. M4 therefore replaces the substring grep with a three-leg STRUCTURAL read — required-set is real (`enforced === true` or REFUSE), aggregator found by `needs` + `if: always()`, aggregator is in the required set — which a comment cannot satisfy. **AND THE LEGS IT REPLACES WERE NEVER TESTED:** deleting BOTH rung-2 problem-pushes leaves `seal-predicate.test.mjs` at **31/31 green**. M4 adds a fifth leg to four untested ones and must ship a mutation proof per leg. |
| D108 | **THE CONSOLE AND CLOUD SHIMS SHIP TWO SEPARATE ESCAPE-CHECK SCRIPTS, and the censuses are BIGGER than the declared filters — one is a live #4393-class hole today** | Two scripts (`console-path-escape-check.sh`, `cloud-path-escape-check.sh`), not one with three sets: it mirrors `elixir-path-escape-check.sh`'s one-script-per-workflow precedent AND it gives the two shim slices disjoint file sets so they build in parallel. **CONSOLE census, measured by mutation:** `seal-predicate.test.mjs` passes `--repo <real repo root>`, so the harness READS `.github/workflows/cloud.yml` (deleting its paths key reds **7 of 31**), EXECUTES `design/emit-fence.test.mjs` (moving it reds **1 of 31**), and `existsSync`es five `cloud/test/barkpark_cloud/web/*_test.exs` (moving one reds **6 of 31**). None of the three is in the declared filter — a PR editing only `cloud.yml` never triggers console-harness and main reds on the next unrelated console PR. **CLOUD census:** `internal/cli/cloud/providers_capabilities.json` (byte-equality contract) and `scripts/async_env_seam_scan.exs` (`Code.require_file`) are both undeclared and dispatched on by NO workflow. **`api/test/**` is DELIBERATELY EXCLUDED** — the scanner derives `default_roots/0` at runtime as `[repo_root()/cloud/test, repo_root()/api/test]`, and declaring it would run the full cloud suite plus Postgres on every api-only PR; declare the SCANNER and name the residue. **THE CENSUS MUST WALK `seal-predicate.mjs` ITSELF**: those reads come from a data table by template interpolation (`${REPO}/${d.measured_in_ci.workflow}`), so a literal-string scanner reports "0 uncovered" while three holes stand open. Symmetric residue filed as backlog: `elixir-path-escape-check.sh` declares NO `cloud/**` path although api's own async guard asserts on the `cloud/test` root — the ratchet that is the model here currently certifies the exact hole it exists to catch. |
| D109 | **M2 IS A PRECONDITION, NOT A NICETY — and the workflow's own comment documents the opposite of the measured behaviour** | Measured at `74a88d1cd`, in CI's exact configuration: `CHROME=/nonexistent-chrome node cssom-parity.mjs` → **exit 1**, raw `Error: spawn … ENOENT` node stack, **no guard line**; the control `HEADS_BASELINE=/nonexistent` → **exit 2** with a clean `!! GUARD` block. Cause is one line replicated three times — `findChrome()` returns `process.env.CHROME` **unchecked** (`cssom-parity.mjs:386`, `modal-oracle.mjs:187`, `overflow-guard.mjs:125`), making the exit-2 no-Chrome branch dead code whenever CHROME is set. `console-harness.yml:135` pins `CHROME: /usr/bin/google-chrome`, and :129-132 asserts *"a future runner image dropping the binary then exits 2 as a GUARD naming the missing path"*. **That comment is FALSE.** Under a required context a Chrome-less runner image bricks protected main with a manufactured red naming no CSS defect. **SCOPE CORRECTION:** only `cssom-parity.mjs` runs in any workflow — `modal-oracle.mjs` and `overflow-guard.mjs` are run by NO workflow at all, so fixing them is cheap and blast-radius-free. **POLARITY, decided against the wish's framing:** a refusal stays RED, differentiated by an `::error::` annotation, never green. `elixir.yml` encodes every one of its five dispatcher refusals as `::error::` + `exit 1`; greening on "I could not measure" is this epic's named sin. The aggregator boundary carries no exit code (`decide()` branches only on `needs.*.result` strings, and **zero** workflows in the repo capture `rc=$?`), so the .mjs fix alone is necessary and INSUFFICIENT — the console-harness step needs a `case` wrapper under `set -uo pipefail` (never `-e`). **CROSS-EPIC:** `hg-overflow-guard-refusal-exits-1` is a live open Honest Gates row covering `overflow-guard.mjs`'s `die()` default; wave 9 PAYS it rather than duplicating it. |
| D110 | **M3 ACQUIRES A HARD PREREQUISITE NO PRIOR WAVE HAD: `cp-ops.yml` POISONS THE GENERATOR into promoting four deliberately-excluded contexts, at exit 0** | `.github/workflows/cp-ops.yml` (added `952106581`, 2026-07-30, #8093 — one day AFTER the protection flip and after every charter measurement of the generator, **D99 included**) declares `jobs.run.name: ${{ inputs.operation }}`. `tmpl_to_regex()` maps `${{ … }}` → `.+`, so that job's regex is `^.+$` and matches EVERY rendered name; `job_for_name()` returns the FIRST glob match, and `cp-ops.yml` sorts ahead of `doc-gates.yml`, `elixir.yml`, `pr-task-gate.yml` and `reland-check.yml`. Every name from those files is misattributed to *"cp-ops.yml job 'run'"* carrying `pf=0, coe=0, needs=""` — erasing the exact properties S2/S3/S4 exclude on. **MEASURED:** regenerating today against the spec's own documented sample shas emits **SIX** contexts, promoting `Doc budgets + anchors` (S4 paths-filtered), `Re-land advisory` (S2 advisory), `Dispatch (changed-path sets)` and `Elixir path-escape ratchet` (S3 subsumed) — D69's named failure mode, silently. Applying that pins a PATHS-FILTERED name and deadlocks main with a permanent `is expected.` that `--admin` cannot bypass. **MUTATION PROOF:** delete `cp-ops.yml` from the workflow dir and the identical run reproduces the committed 2 contexts with correct provenance and all six exclusions restored. `required-checks.test.sh` is structurally blind to it — it builds a hermetic fixture workflow dir and never reads `.github/workflows/`. **CONSEQUENCE: D99's "the post-shim run emits exactly one context, `Console gate`" is STALE and must be re-run post-fix.** Fixing `cp-ops.yml` is a round-1 slice; M3 does not fire until it merges. |
| D111 | **M3 IS ROUND 2 BY SEQUENCING, NOT A FOURTH DEFERRAL — and the regeneration must JQ-MERGE, never overwrite** | D98 called registration "structurally unavailable". That is a SEQUENCING claim, not a structural one, and the scripts settle it: S5 explicitly EXEMPTS names absent from main (*"a pull_request-only check is NOT disqualified"*) and S1 samples ARBITRARY shas, so **PR heads of the shim branches are a legal sample**. Live corroboration that the pattern satisfies R2: on **ten** recent PR heads touching no Elixir paths, `Elixir gate` concluded **success** while all three gated leaves concluded `skipped` — green-by-skip, never absent. **THE OVERWRITE IS A REGRESSION, measured:** the generator emits a **5-entry `_readme` and `enforced: false`** against the committed **9 and true**, so a plain regeneration silently deletes FIVE hand-authored paragraphs (the enforced/reversal paragraph, THE SAMPLING RULE, THE FLOOR IS A SEPARATE ARTIFACT, EXCLUSIONS ARE WHAT THE SAMPLE SAW, MERGE PROTOCOL) plus the exclusions census — and `required-checks-floor.sh` is BLIND to both (`grep -c` for either returns 0). `apply.sh:177` refuses `enforced:false` LOUDLY, so the reversal fails at apply; the prose loss is the silent half, and `verify.sh:324` then SKIPS the live-protection diff on such a spec. **The proven shape** is regenerate-to-scratch then `jq -s` merging only `generated_from_shas`, `protection.required_status_checks.checks` and a union of `exclusions` onto the committed file as base — verified to keep `_readme` byte-identical at 9, `enforced` true, and pass the floor. **AND M3 REDS ITS OWN HARNESS UNLESS IT WIDENS IT:** with a 4-context spec, `required-checks.test.sh` goes **63 passed / 5 failed**; THREE are OFFLINE and unfixable by ordering — sections 6 and 7 derive the spec from the committed file (:370) but pair it with heredoc fixtures hardcoding both current context names (:385-386, :400-401, :444-445, :456-458). Widen them in the same diff. The other two are live drift and ARE fixed by applying BEFORE the harness runs. `verify.sh --selftest` is spec-independent and stays 16/16. |
| D112 | **NO SEAL, and not close — clause (b) is PASS, clause (a) fails on RESIDUE, and there is no successor epic at all. The wave's contribution is making (b) MEAN something, never moving (a) by rhetoric** | Live at `74a88d1cd`: `SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=58 considering=1`, roster **135 children / 60 open / 1 considering**. **THREE CORRECTIONS to prior phases, all re-derived here.** (1) The digest's *"clause (b) is FAIL live"* and *"CCH-D5 sits at rung 3"* are **REFUTED** — stale-checkout artefacts; wave 8's registration landed and **b=PASS**. (2) There are **FOUR** `measured_in_ci` entries, not three — CCH-D2/D3/D4/**D5** at `seal-predicate.mjs` :162/:177/:188/:213, **all naming the identical `{cloud.yml, job test, cloud/**}`**. So M1's blast radius is four, and four of six registered defects are certified by a job that is not a required context and that sat red on main across SEVEN consecutive merges (not three) over 14h19m. (3) `orphans=55` was never measured — it is a misquote of wave 8's OPEN-row count (*"roster 138 to 129, open 80 to 55"*); `grep -n "orphans="` over the charter and the wave-8 Paper returns nothing. **orphans=58 is the FIRST measured datum; stop citing 55.** D83 binds: all three legal successor invocations REFUSE with three DISTINCT reasons (`NO-SUCCESSOR`, `SELF-SUCCESSOR`, `TERMINAL-CLAIM-REFUTED` naming 60 live rows), so no clause even evaluates without a diagnostic address. **A MEASUREMENT-HYGIENE RULING:** the loop form `for s in '' '--successor X'; do node … $s; done` is BROKEN under zsh 5.9 — it does not word-split unquoted expansions, so all three iterations degrade to `NO-SUCCESSOR` and read as agreement. Write successor invocations out literally. **FREE LEAD CLOSE:** `cch-bl-ability-matrix-red-on-main` is open at 0/4 though #8139 (`ce8d855167`) merged 46 minutes after it was filed and main's cloud.yml went green at that commit — closing it drops orphans 58 → 57. |
| D113 | **THE CVE HEADLINE IS UNSOURCED, THE TRUE COUNT IS TWO, AND THE GATE IS NOT REGISTERED THIS WAVE** | Re-derived with mix_audit 2.1.5's own semantics over `api/mix.lock` (75 locked deps): the DB holds **108** advisories TOTAL, **3** match our locked versions, **2** survive the documented esaml suppression — `req 0.5.17` GHSA-655f-mp8p-96gv (**high**, decompression bomb, patched 0.6.1) and GHSA-px9f-whj3-246m (moderate, multipart header injection, patched 0.6.0). CI agrees exactly: the failing run prints `Name: req` twice and nothing else. **`task-18f0492ac550561b`'s "seven deps / 12 advisories / 4 HIGH" has NO reproducible derivation** — not version-aware (3), not name-only over those seven (19/10), not name-only over the whole lock (35/18). Five of the seven are already patched above every range they hit and **swoosh has ZERO advisories at any version**. That is the 107-vs-16 miscount class; the row is retargeted, not merely rescoped. **NOT REGISTERED THIS WAVE, on two independent grounds:** S4 (security.yml is paths-filtered to `api/**`) and S5 (its self-titled *blocking* job is red on 8 of the last 10 main runs). The debt is **one direct constraint** — `api/mix.exs:68 {:req, "~> 0.5"}` cannot reach 0.6.1 — but `api/mix.exs` and `api/mix.lock` sit inside the concurrently-running PDS wave's `api/**` fence, and the Req call-site inventory is UNMEASURED. Filed as `cch-bl-req-bump-clears-two-live-cves` → `cch-bl-security-gate-shim-and-register`, in that order. Registering before the bump would install a permanent CORRECT red on protected main, which is worse than a wrong one. |
| D114 | **HALF ONE CLEARS — the registration precondition is MET, and both the strategy's "one qualifying head" and the digest's "NOT MET, and now fully explained" are STALE by five commits** | Re-derived twice independently at `origin/main` `21ab0e50d` (2026-07-30 21:00Z), by name, classifying every head with the escape-check scripts' own `--match` mode rather than by hand. **FOUR qualifying heads** (both `Console gate` and `Cloud gate` RENDERED and concluded `success`): `dc17c949e` (touches BOTH path sets), `65a9e1bdd`, `bfd3e50a2`, `21ab0e50d` — and the last **three are NEITHER-shape**, the exact shape wave 9's own precondition demands and the survey found zero of. The bar is `>=2` qualifying with `>=1` neither-shape; the measurement is `qualifying=4 of-which-NEITHER=3 unsettled=0 shim-defects=0`. Nothing was manufactured: the three heads are by-products of foreign merges (#8217, #8177, #8218) that happened to be spaced. `1dd553b09`'s `Cloud gate` FAILURE stands and is a **true positive** read from the job log — `RouterHeadFenceCensusTest total 62 -> 64, agent_or_worker 5 -> 7`, #8182's un-moved baseline, paid by `dc17c949e`/#8216. **The shim caught a live escape on its first rendering head; that is the epic's thesis, measured.** |
| D115 | **THE PRECONDITION STOPS BEING PROSE: `scripts/registration-sample.sh` is a committed, mutation-proven instrument, and ABSENCE HAS FOUR CAUSES, not three** | The highest-stakes sentence in the epic — "may this wave install a new merge-stopper" — was, in every prior wave, a paragraph a later phase re-measured by hand. It becomes a script that exits non-zero below the bar. It never re-implements path logic: it shells out to `console-path-escape-check.sh --match console` / `cloud-path-escape-check.sh --match cloud`, the same code the dispatchers call, so sampler and workflow cannot disagree. Absence of a named check run resolves to: `NO-RUN` (path filter or the workflow did not exist yet — `5ddae0dc2` cloud), `CADENCE` (a workflow run exists with `conclusion=cancelled`; a run evicted while PENDING emits NO check run, so `always()` cannot rescue it and the refusal is `is expected.` = DEADLOCK, not `is cancelled.` = RERUN), `SHIM-DEFECT` (the run concluded success/failure yet the name is absent — the only cause that is a bug), and **`IN-FLIGHT`**, which the assignment did not name and measurement forced: at 22:50 local, `21ab0e50d` read Console=success / Cloud ABSENT although the cloud run had completed at 20:51:13Z — the commits check-run feed lags. An IN-FLIGHT head is UNSETTLED and leaves numerator AND denominator; a sampler without that exclusion silently under-counts and refuses a legal registration — the mirror of the deadlock it exists to prevent. Two defects found in the prototype and fixed there: an abbreviated sha returns ZERO workflow runs from `actions/runs?head_sha=` (mis-diagnosing CADENCE as NO-RUN), and quoted non-ASCII paths misclassify a head as NEITHER — i.e. the sampler would certify registration on a head it read wrong. |
| D116 | **THE DISPATCHER FIX IS `-z --no-renames`, NOT the proposed `core.quotepath=false` — and it is a SIX-SITE change across THREE workflows, one of which is the ALREADY-REGISTERED `Elixir gate`** | Reproduced against the real extracted `jobs.changes.steps[id=sets].run` body, not a paraphrase. (1) `core.quotepath=false` is an INCOMPLETE fix that would look like a pass: it stops octal-escaping non-ASCII, but git still quotes any path containing `"`, `\` or a newline — measured, `cloud/priv/static/we"ird.js` emits `"cloud/priv/static/we\"ird.js"` under BOTH settings and the ratchet says `false` under both. (2) A THIRD false-green nobody named: `--name-only` with rename detection (default-on since git 2.9) prints only the DESTINATION, so `git mv cloud/priv/static/app.js docs/app.js` yields `console=false` and the harness skips while the file it tests moved out from under it. The complete line is `changed="$(git -c core.quotepath=false diff -z --name-only --no-renames "${base}...HEAD" | tr '\0' '\n')"` — five false-green classes closed, **zero regressions across 14 measured PR shapes**. (3) **BLAST RADIUS:** `elixir.yml:148` is the byte-identical line and `Elixir gate` is registered and enforced TODAY, so these are live defects on a currently-blocking gate, not merely wave-10 preconditions. Residual risks priced and accepted: `tr '\0' '\n'` splits a literal-newline filename (over-triggering only), and `--no-renames` widens the set so `elixir.yml`'s `compile ⊆ test` containment is preserved by construction. |
| D117 | **THE EMPTY-DIFF BRICK FLIPS POLARITY — "fail closed when you cannot tell" does NOT cover "you can tell, and the answer is nothing"** | A legal PR with a net-empty three-dot diff (a revert pair, a branch-sync PR) hits `[ -z "$changed" ]` -> `::error::` -> exit 1 -> permanently red with **no self-service fix**. Measured end to end on a synthetic revert-pair repo against the shipped step body. The honest polarity is a loud `::warning::` plus `<set>=true` — run everything, expensive, never wrong. **The brick is PINNED BY A COMMITTED TEST in all three harnesses** (`console-path-escape-check.test.sh:779`, `cloud:655`, `elixir:661`, each `dispatch "empty diff (base == HEAD)" 1` + a `gate_says "changed-file set is EMPTY"`), and each workflow carries prose asserting the old polarity. A partial flip reds the unfiltered `path-escape` job, which is a `needs` of every aggregator — i.e. it reds the gate being fixed, on main. So the flip is six sites minimum plus three comment blocks, in one diff. A FOURTH shape is fixed in the same block: a no-merge-base PR fails with `rc=128` and a raw `fatal:` and **zero annotation** — a `git merge-base` precheck emitting `::error::` costs one call. A two-dot fallback is FORBIDDEN: measured, it sweeps in the base's entire content. Cost accepted and named in the warning text: a revert-pair PR now runs the full Elixir suite (9m31s-16m29s). |
| D118 | **REGISTRATION IS ROUND 2 BY SEQUENCING — dispatched from the sampler's exit code, behind the dispatcher fixes and a toolchain that can survive its own success. And `required-checks-floor.sh` EXISTS; the "survey-brief phantom" claim is REFUTED three times** | Three independent verifiers found the file on `origin/main` (163 lines, since #6926) and one drove it: dropping `Elixir gate` -> `FLOOR BREACH ... LOST Elixir gate 15368`, exit 1; a count-preserving swap -> same breach, exit 1; ADDING `Console gate` + `Cloud gate` -> **exit 2** with *"Re-run with --acknowledge-growth once a human has decided each added name belongs"*. Registration is therefore already an explicitly-acknowledged act. **But the floor is DEAD CODE:** `grep -rn required-checks-floor .github/` returns no workflow hit and `required-checks-apply.sh` contains no reference to it — the only brake today is `apply.sh:177` refusing `enforced=false`, which a human flipping the flag in the same PR satisfies while a name loss rides along. WIRE IT into `apply.sh` before any PUT. Two generator defects ride the same slice: (a) `generate.sh` builds with `jq -n` and writes `> $OUT` — a pure OVERWRITE that today DROPS `PR references an active task` (structurally: `pr-task-gate.yml` is `on: pull_request` only, so its name never appears on a main head and the strict S1 intersection erases it without even an exclusion reason), plus `_readme` 9->5, `enforced` true->false and three hand-authored exclusions; D111's JQ-MERGE remains UNIMPLEMENTED. (b) **S5 reads the OLDEST head in the window** — `main_conclusions()` appends per-sha rows in `gh`'s newest-first order and S5 takes `tail -1`, contradicting both its own comment and the exclusion string it prints. MUTATION-PROVEN on identical fixtures: newest-first -> `exclude Cloud gate — S5 RED ON MAIN`, oldest-first -> `keep Cloud gate`. Unfixed, a JQ-MERGE would still refuse to add the very name this wave wants. A third hazard: an S5 exclusion of an aggregator **PROMOTES its leaves** (S3 runs after S5, against survivors), emitting matrix-suffixed rendered names — the D20 shape the aggregator pattern exists to abolish — at floor exit 2, i.e. acknowledgeable. |
| D119 | **THE DRIFT WORKFLOW SPLITS, IT DOES NOT FLIP — but the availability rationale is REFUTED and DELETING THE PATHS KEY IS THE PAYMENT, not the blocking flag** | Three corrections, all measured. (1) **REFUTED:** the header argues advisory-by-intent because "an API blip would stall the fleet"; across **67 non-cancelled runs** (2026-07-28 -> 2026-07-30) every step concluded success — the admin read works today on `BREAKGLASS_TOKEN`. The defensible rationale is **credential lifetime and scope**: it is a broad gh OAuth user token that rotates on re-login, with the fine-grained PAT filed as human gate `hg-breakglass-token-fine-grained`. A blocking admin read deadlocks main on an expiry, and the fix requires a browser. (2) **REFUTED, and it inverts the priority:** the survey's "#8093 matched none of drift.yml's four globs" is wrong — drift.yml has FIVE pull_request globs including `.github/workflows/**` since its creation (`43fab05c9`), and `Required-check spec drift (advisory)` **rendered and concluded `success`** on both #8093's head and its merge commit. It sailed past the poisoning because the detector did not exist yet (#8093 merged 16:17, the catch-all guard `a56f93131` landed 21:24 the same day). So blocking is the collectible; the paths key must still go, because a paths-filtered workflow emits no check run and an absent required context routes to `is expected.` = deadlock. (3) **The split line is §10+§11, five assertions of 75, and the remaining 70 are provably offline** — proven with a `gh` shim on PATH, because `env -u GH_TOKEN -u GITHUB_TOKEN` does NOT deauthenticate `gh` (keyring), making the briefed MUST-RUN vacuous. `sed '622,704d'` -> **70 passed, 0 failed** offline; restoring the real #8093 poison into `cp-ops.yml` sends that same split suite to `rc=1` naming `cp-ops.yml job 'run'` in ~39s. §11's middle clause **passes when the network is down** — a clause that cannot distinguish its own claim from an outage, the exact vacuous green this epic exists to kill. **NO RATCHET, refused:** the detector is a whole-directory real-tree scan that never consults the diff, so a declared path set adds a maintenance liability and zero coverage; copy `elixir.yml`'s `path-escape` precedent (*"DELIBERATELY UNFILTERED ... It costs a few seconds of bash"* — measured 3.85s + 39.20s) instead. **COUPLING:** with a 4-context spec the split suite goes 67/3 OFFLINE (§6/§7 heredocs hardcode the two current names) — widen before or with registration. **CROSS-EPIC:** `hgw5-bl-required-checks-test-honesty` (honest-gates, open 0/4) already owns this criterion verbatim; wave 10 PAYS it rather than duplicating it. |
| D120 | **THE `needs.<job>.result` LAUNDERING IS REAL AND UNDETECTABLE — so `Security gate` must EXCLUDE sobelow BY NAME, and "or explicitly tolerating" is UNIMPLEMENTABLE** | Measured for the first time in this repo, on a throwaway probe repo (`FRIKKern/probe-coe-launder`, run `30580474385`): a job with `continue-on-error: true` that exits 1 concludes **failure**, renders a **RED check run**, and `needs.<job>.result` reads **`success`** — byte-identical to a genuine pass. `failure` and `skipped` are cleanly distinguishable; **`success` is not decomposable**, and no `decide()` rewrite can fix it because the information is destroyed before the aggregator's shell starts. A verbatim `decide()` transplant therefore greens over a failed Sobelow BY ACCIDENT and unfalsifiably. The aggregator omits `sobelow` from `needs` entirely, and the shape is forced by a ratchet the repo already owns three copies of (`*-path-escape-check.test.sh` `coe_in_needs ""` + `blocking_not_in_needs ""`). **The row's blocker #3 is STALE:** felix w24 made `sobelow-inline-overlap` blocking; exactly ONE `continue-on-error` remains, at `security.yml:56`. **The req bump is ALREADY BUILT AND OPEN as #8222** (`req 0.5.17 -> 0.6.3`, `api/mix.exs` + `api/mix.lock`), and on its head `6a188e5a0` the blocking `Dependency CVE audit` concluded **success** — the bump clears the gate, live. Do NOT cut a duplicate slice; adopt it. Its red `Elixir gate` is ONE unrelated flake — `workspace_bundle_test.exs:1281`, a 24KB disk-free race between two statvfs reads, PDS-fenced. **THE FENCE RESOLVES IN THE WAVE'S FAVOUR:** `api/mix.*` untouched on main since 2026-07-11 and the LIVE PDS wave is 25, a ledger round touching zero `api/` paths (the row's own fence paragraph cites wave 23 and is stale). One one-directional coupling remains: an `api/**` merge auto-redeploys guerrilla, which PDS w25 round 2 gates on. **NOT REGISTERED THIS WAVE:** ship the shim mutation-proven; registering over a still-red sobelow-or-audit installs a permanently CORRECT red on protected main, worse than a wrong one. |
| D121 | **THE OAUTH ROW'S TITLE IS REFUTED BY A COMMITTED TEST — the threat is RESPONSE-HEADER DISCLOSURE, and the decided design is a one-time exchange code in `user_tokens`** | The `state` nonce is single-use (`oauth_states` insert at mint, DELETE in `verify_state/2`), pinned by `router_oauth_test.exs:91-107`: a replayed callback 302s to `/#oauth_error=oauth_failed` and mints nothing. A builder proving the fix "against the title" would ship a test pinning something already true. The real defect is that the ONE legitimate 302 carries a live 30-day session token in the `location` header, visible to any header-logging intermediary, plus **a SECOND leak nobody named**: `app.js:13175` clears the fragment with `location.hash = "#fleet"` — a history PUSH — so the live token survives in history and the back button restores it, while the closest analogue (the billing return at :13095/:13100/:13134) uses `history.replaceState`. **DECIDED:** a one-time exchange code stored in `user_tokens` under `context: "oauth_exchange"`, **120 seconds** (sized for a cold SPA boot: `app.js` is 959,628 bytes and `app.css` 198,954, `Plug.Static` is configured with NO `gzip:` and no `.gz` on disk — the SSE ticket's 60s was sized for a same-tick `EventSource`), hashed, burned matched-row-only under `FOR UPDATE`, provider carried in `sent_to: "oauth:<provider>"` so the honest `origin: "oauth:<provider>"` survives; traded at `POST /v1/auth/oauth/exchange` with **deliberately no GET twin on the path** (`plug(Plug.Head)` rewrites HEAD->GET before matching — the invariant is already written at `router.ex:1458-1463`, transplant it verbatim); rate-limited on `"oauth_exchange:" <> peer_ip` via the existing `DeviceAuth.RateLimiter` with an explicit entry of 30 (the unlisted-prefix fallback is 10/min/IP, which starves corporate NAT). **THE REAPER CLAUSE IS IN THE SLICE, NOT AFTER IT:** `reap_sse_tickets/0` is `where: t.context == "sse"` STRICTLY, so a new context with no reap clause accretes forever — repeating D48's and D15's exact omission under a new name, inside the anti-lie epic, is the worst possible outcome. **POST-BACK IS REFUSED, not weighed:** `index.html` is a static file served by `Plug.Static` and cannot read its own request body, so POST-back degenerates to token-in-a-GET-body. **NO MIGRATION** (`UserToken.changeset` casts `:context` with no `validate_inclusion`), **NO CSP question** (`grep -rni 'content-security-policy|script-src' cloud/` -> 0 hits; the exchange is a same-origin fetch). **CRITERION 2 IS RELAXED BY RULING:** `cloud/test` has no raw-socket client harness, so "a raw-wire capture" is unsatisfiable with current tooling; the honest proof is `get_resp_header/2` with a positive control, and silently substituting `Plug.Test` for "raw wire" would be the manufactured-evidence failure this epic exists to stop. **HIGH-FLIP-RISK: the security judgment (disclosure vs replay) and the async-bootstrap ruling.** |
| D122 | **THE TWO REVOKE ROWS FUSE INTO ONE SLICE, and the blocker is the SMOKE SELECTOR GRAMMAR, not `PARSED_TAGS`** | `cch-bl-destroy-verbs-stateless-family` (server-side fixtures, `scenarios.mjs`) and `cch-w2-revoke-oracle-round2` (client-side clicks, `smoke.mjs`) are two halves of ONE proof: the oracle's criterion 3 requires the stateful fixture the other slice builds, **and both rows record `dependency_count: 0`** — the ledger does not know. Dispatching them concurrently repeats wave 9's standing lesson verbatim: each half reports a clean ratchet alone and only the merged pair exposes the hole. **THE GRAMMAR IS THE REAL WALL AND IT REDS NOTHING:** `CLASS_SEL`/`ID_SEL_SUB` accept only `.class` and `#id`, and `ATTR_RE` requires `="value"`, so every destructive list-row control except `.session-revoke` resolves to `[]`. Widening element-level `querySelectorAll` to `[attr]`/`[attr="v"]` plus valueless-attribute capture leaves **all 98 pristine scenarios green** and brings **22 attribute selectors alive, 18 with hits** — refuting the expectation that slice B is far larger than the wave thinks. Measured split of the "12": FOUR unblocked by one `CLASS_SEL` line (tokens, members, invitations, env-vars), ONE more by the `ATTR_RE` line (providers), ONE needing an `app.js` change (webhooks), ONE needing a DESTROY-tier typed-confirm driver (barkparks), FOUR honestly flag-shaped (2FA, logout, github installation, site github). **WEBHOOKS IS DEFERRED, and the row must stop promising six:** `wireWebhookCard` bails at `findWhCard`, which needs a `.wh-card` DIV, and `PARSED_TAGS` is `button|a` with a committed prohibition on widening it (the `mountUsageTab` detached-stub hazard). Three unexecuted-inference legs FIRED under probe (`#modal-logout`, `#github-disconnect`, `#inst-remove-retry`), plus two the survey misclassified. **TWO TRAPS FOR THE BUILDER:** `fired == 1` is UNSAFE for a re-opened modal (handlers accumulate on the immortal `#id` registry node — a probe measured `fired=2`); and the destroy-tier disarm is observable ONLY on `#modal-body`'s PARSED child, never on `reg.get("cm-confirm")` (different objects; the registry stub defaults `disabled=false`), so the naive assertion is a false green inside the anti-false-green scenario, correcting D54. **`smoke.mjs` never reads `SCENARIO_NAMES`** — parity is 100/100 by discipline alone and a fixture without an expectation greens silently. |
| D123 | **THE "LEDGER LIE ON THE FOUNDING PARAGRAPH" IS REFUTED — and the wave gets THREE free closes, not one** | The digest's worst finding was that `gr-blk-console-refetch-storm` and `gr-blk-revoke-harness-gap` are done at 0/3 with empty evidence. Both carry a merge-SHA-bearing `close_reason` AND a `close_override.criteria` with actor, ts and reason; the refetch-storm override reads verbatim *"The criterion's literal wording ... is unachievable by design and is NOT flipped ... Criteria stay 0/3 on the record."* `criteria_progress {met:0}` is the honest rendering of a deliberate override, and this epic's own done row `gr-bl-close-convention-unmet-criteria` already adjudicated the class (*"NOTHING HERE IS A BARE UNEVIDENCED CLOSE"*, `terminal_with_unproven_criteria=0` across 2,203 terminal tasks). **Re-stamping them is FORBIDDEN: flipping `met:true` would destroy the honest record and manufacture the exact lie the wave hunts.** Standing law 1's never-executed sweep RAN: 242 candidate SHAs over 66 done rows, 192 ancestors, **50 NOT-ANCESTOR — every one a squash artifact**, 19 reconciling by subject and the rest by content anchor, with zero genuine absences. Its real product is a smaller finding: **31 done rows cite branch SHAs where law 1 demands merge SHAs**, and subject matching cannot reconcile them because squash titles are rewritten — reconcile by CONTENT ANCHOR. Free closes: `cch-bl-ability-matrix-red-on-main` (paid by `ce8d855167`/#8139 and a duplicate of the already-done `task-b5ae203ee8a5dcb2`), `task-ffd9625205f3c1a9` (paid in full by `dc17c949e`/#8216, carries no `acceptance_criteria` at all), `gr-bl-doneset-merge-sha-reaudit` (criterion 1 IS this sweep; criterion 3's standing rule already exists at charter :25-30). A fourth, `cch-w9-emit-fence-guard-red-on-main`, is 1.5/2: `node design/emit-fence.test.mjs` exits 0 and the seal suite is 43/43, but the **nine-line "INHERITED RED" comment at `seal-predicate.test.mjs:396` survives and is now FALSE on green main** — a stale-sentence lie inside the epic's own seal instrument. Deleting it is folded into the revoke slice (same directory), converting the row into a close. |
| D124 | **NO SEAL — and the clause letters are UNEVALUATED, so stop quoting `a=FAIL b=PASS c=PASS`** | Live at `origin/main`: `node cloud/priv/static/__preview__/seal-predicate.mjs --successor TERMINAL` -> `SEAL-PREDICATE REFUSED reason=TERMINAL-CLAIM-REFUTED a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED`, **66 live rows + 1 considering** (`cloud-console-operator-audit-log`). The predicate refuses BEFORE evaluating any clause under that invocation; bare, it refuses earlier at `NO-SUCCESSOR`. The quoted "a=FAIL b=PASS c=PASS orphans=55" line cannot be reproduced by this invocation and must not be carried forward. Roster reconciles: 151 children = 70 done + 68 open + 12 cancelled + 1 considering; 68 open minus the two `drafts.*` twins = 66, so the predicate's live filter is excluding drafts correctly. **One of those twins, `drafts.cch-bl-floor-blind-to-readme-and-uncalled`, has NO published parent in the roster** — an orphan draft, not a D86 shadow, so discarding it as a duplicate would destroy the only copy. D83 binds. This wave moves clause (b)'s honesty by registration and moves residue by three free closes; it does not manufacture a successor. |
| D125 | **A FIFTH MEASUREMENT-HYGIENE RULING: the primary checkout was 110 commits behind and SIX independent surveyors hit the trap, so every wave-10 read is `git show origin/main:` or a `git archive origin/main` tree** | The local charter topped out at D105 while `origin/main` carried D110-D113; the local `console-harness.yml` was the PRE-shim file with a workflow-level `paths:` key and no `Console gate`; `scripts/console-path-escape-check.sh` did not exist locally at all; and `seal-predicate.test.sh` measured **30/1** locally against **43/43** on an extracted origin tree. A surveyor quoting a local path this hour reports wave-8-era facts as today's. Two corollaries now standing: (1) the same trap produced the "`required-checks-floor.sh` is a phantom" claim that reached the digest and three verifiers had to refute; (2) a builder worktree must be cut from `origin/main` explicitly, and the merged-pair review tree must be constructed on `origin/main`. |

## Roadmap

### Wave 10 — the instruments stop needing a human to believe them, and the vision's last lies get paid

Weight 1: the two aggregators become required — but only behind a committed sampler, a dispatcher that
cannot false-green, and a toolchain that survives its own success. Weight 2: OAuth and the destroy
verbs, the founding paragraph's last two live classes. Weight 3: NO SEAL, honestly (D124).

| Slice | Task | Round | Size | Builder | Surface |
|---|---|---|---|---|---|
| Dispatcher hardening — five false-green classes + the empty-diff brick, across three workflows | `cch-w10-dispatcher-hardening` | 1 | large | opus | `console-harness.yml`, `cloud.yml`, `elixir.yml`, 3 escape harnesses |
| `registration-sample.sh` — the precondition becomes a script that can refuse | `cch-w10-registration-sample-instrument` | 1 | medium | opus | `scripts/registration-sample*.sh`, `scripts/lib/check-runs.sh` |
| The required-checks toolchain gets honest and registration-survivable | `cch-w10-required-checks-toolchain-honest` | 1 | large | opus | `scripts/required-checks-*.sh`, `required-checks-drift.yml` |
| `Security gate` shim — shimmed and mutation-proven, NOT registered | `cch-w10-security-gate-shim` | 1 | medium | opus | `security.yml`, `scripts/security-gate-shape.test.sh` |
| OAuth: the session token leaves the response header | `cch-w10-oauth-exchange-code` | 1 | large | opus | `router.ex`, `accounts.ex`, `app.js`, oauth tests |
| The destroy verbs shrink a list, and the clicks are real | `cch-w10-destroy-shrink-oracle-merged` | 1 | large | opus | `__preview__/{smoke,scenarios,seal-predicate.test}.mjs` |
| Register `Console gate` and `Cloud gate` | `cch-w10-register-console-and-cloud-gates` | **2** | medium | opus | `.github/required-checks.json` |

Round 2 dispatches ONLY after slices 1, 2 and 3 are MERGED, and ONLY if `scripts/registration-sample.sh`
exits 0 on the post-merge window. Registering behind an unfixed dispatcher would install a repo-wide
merge-stopper whose fail-closed polarity bricks a legal PR shape (D116, D117); registering ahead of the
§6/§7 fixture widening reds the split suite OFFLINE on protected main (D119).

HIGH-FLIP-RISK slices, owed an independent re-derivation at review: `cch-w10-oauth-exchange-code`
(security — is header disclosure the real threat, and does the async bootstrap preserve the three
`didOAuth` branches?) and `cch-w10-register-console-and-cloud-gates` (blast radius — every foreign
session's PR is gated the moment this merges).

Adopted, not rebuilt: PR **#8222** (`req 0.5.17 -> 0.6.3`) already clears both live CVEs; the lead
lands it rather than cutting `cch-bl-req-bump-clears-two-live-cves` a second time (D120).

Free closes this wave (lead, on merge or immediately): `cch-bl-ability-matrix-red-on-main`,
`task-ffd9625205f3c1a9`, `gr-bl-doneset-merge-sha-reaudit`, and `cch-w9-emit-fence-guard-red-on-main`
once the false INHERITED RED comment is deleted (D123).


### Wave 9 — the instruments stop being decorative

Weight 1: make what this epic measured able to STOP a merge. Weight 2: keep paying the console lies. The seal: NO SEAL, honestly.

| Slice | Task | Round | Size | Builder | Surface |
|---|---|---|---|---|---|
| Console shim + `Console gate` aggregator + escape ratchet | `cch-w9-console-gate-shim` | 1 | large | opus | `console-harness.yml`, `scripts/console-path-escape-check.sh(+.test.sh)` |
| Cloud shim + `Cloud gate` + M4 structural rung-2 resolver | `cch-w9-cloud-gate-shim-rung2` | 1 | large | opus | `cloud.yml`, `scripts/cloud-path-escape-check.sh(+.test.sh)`, `seal-predicate.mjs(+test)` |
| Guard refusal vocabulary — REFUSED is not DEFECT | `cch-w9-guard-refusal-vocabulary` | 1 | small | opus | `__preview__/{cssom-parity,modal-oracle,overflow-guard}.mjs` |
| The generator catch-all poison (M3 prerequisite) | `cch-w9-generator-catchall-poison` | 1 | medium | opus | `cp-ops.yml`, `required-checks-generate.sh`, `required-checks.test.sh` |
| Two stale protection claims, by content | `cch-w9-stale-protection-claims` | 1 | small | opus | `docs/ops/merge-gates.md`, `.github/required-checks.json` |
| The PAT twin of the session-touch lie | `cch-bl-pat-touch-not-authz-aware` | 1 | medium | opus | `cloud/lib/barkpark_cloud/{accounts,web/auth}.ex` + new test |
| Register `Console gate` and `Cloud gate` | `cch-w9-register-console-and-cloud-gates` | **2** | medium | opus | `.github/required-checks.json`, `required-checks.test.sh` |

Round 2 dispatches only after slices 1, 2 and 4 are MERGED — and only if the wave's own merge train produced a legal sample (≥2 post-shim heads on which both aggregators rendered and concluded success, at least one of them touching neither path set). **If it did not, M3 does not fire and the Paper says so.**

Seeded backlog: `cch-bl-req-bump-clears-two-live-cves`, `cch-bl-security-gate-shim-and-register`, `cch-bl-elixir-ratchet-blind-to-cloud-test`, `cch-bl-cssom-count-skew-is-advisory-only`, `cch-bl-floor-blind-to-readme-and-uncalled` (filed as a draft — the publish wall refused it repeatedly under a degrading ledger; the LEAD must publish or re-file it).

### Wave 7 — the board stops lying about how much is left

| Slice | Task | Round | Size | Surface |
|---|---|---|---|---|
| Movement 0 — adjudicate all 88 non-done rows by content | `cch-bl-bands-136-reproduce` | 1 | large | bp ledger only (no repo files) |
| Instrument liveness — repair the stale smoke red, wire what gates | `cch-bl-smoke-harness-red-on-main-and-ungated` | 1 | medium | `__preview__/smoke.mjs`, `scenarios.mjs`, `console-harness.yml` |
| The spine — retarget the seal predicate at THIS epic | `cch-bl-seal-predicate-retarget-and-reparent` | 1 | large | `__preview__/seal-predicate.mjs` + test + fixtures |
| The focus ring stops failing SC 1.4.11 | `cch-bl-ring-soft-focus-contrast-unasserted` | 1 | medium | `app.css`, `__css_check.mjs` |
| The browser preview stops reporting a revoke it never performed | `cch-bl-mockjs-revoke-stateless` | 1 | small | `__preview__/mock.js`, `__app.test.mjs` |
| The delivery/audit feeds stop dropping rows on a stamp tie | `gr-bl-delivery-keyset-tiebreak` | 1 | medium | `accounts.ex`, `notifications.ex`, `app.js` |
| A refused 403 stops printing "Active just now" | `cch-bl-auth-touch-unthrottled` | 2 | small | `accounts.ex` |

Wave 7 files NO successor (D93). NOT built and filed instead: the twelve remaining stateless destroy
verbs in `scenarios.mjs` (`cch-bl-destroy-verbs-stateless-family`), the eight dangling charter commits
one `git gc` from destruction (`cch-bl-rescue-dangling-charter-commits`), and `styleguide.html`'s ~194
uncertified inline CSS lines (`cch-bl-styleguide-inline-css-uncertified`).

**D95 — guerrilla's task CREATE verb was DOWN at Decide, and the wave adapted rather than stalled.**
Measured, with a control: `create` on a minimal four-field task doc returned **HTTP 500
`internal_error` at 27.7s**, reproducibly, across the `bp` CLI (31s client timeout) and raw curl at
240s; the identical-shaped `patch` on an existing task returned **HTTP 200 in 0.49s**, and a 160KB
paper patch also returned 200. So it is the CREATE path specifically, not payload size and not the
server as a whole — which REGRESSES the survey's "create is HEALTHY, 10/10 HTTP 200" finding within
the same day. Consequences, both honest: Movement 0 is carried by `cch-bl-bands-136-reproduce`, an
existing open row whose own subject IS census reproduction and whose embedded arithmetic was stale a
third time (it asserts 91 children / 85 open against a measured 135/83/41/9/2) — reuse, not a
workaround, and better than minting a duplicate. And **one planned backlog row could not be filed**:
the rate-limiter bucket-separation measurement (D88 register entry 5). It is NOT lost — it is written
into D88, into the seal-retarget slice's brief as the reason clause (b) fails, and into the wave
Paper — but it has no ledger row yet, and wave 8 must file it the moment `create` recovers.

### Wave 1 — the four lies on the wire, plus the instruments that must hold them

| Slice | Task | Round | Size | Surface |
|---|---|---|---|---|
| Refetch storm — scope-narrow the SSE→overview monolith | `cch-w1-refetch-storm` | 1 | medium | cloud SPA |
| Peer IP — pin the bridge gateway, kill the collapsed identity | `cch-w1-peer-ip-pin` | 1 | medium | cloud router + compose |
| cssom-parity → CI, mutation-proven, able to fail honestly | `cch-w1-cssom-ci-wiring` | 1 | medium | workflows + instrument |
| emit.mjs refuses to silently delete hand-written content | `cch-w1-emit-marker-fence` | 1 | medium | design/ |
| Ledger close-bypass guard at both patch clauses | `cch-w1-ledger-close-guard` | 1 | medium | api content |
| Census truth pass — dispose 8 verified rows, record the tooling contract | `cch-w1-census-disposition` | 1 | small | ledger |
| HEAD side-effect fence + `oauth_states` prune | `cch-w2-head-sideeffect-fence` | 2 (after peer-ip) | medium | cloud router |
| SSE ticket + client reconnect rewrite + 4th chip state | `cch-w3-sse-ticket` | 3 (after HEAD + refetch) | large | cloud router + SPA |

Rounds exist because three slices touch `cloud/lib/barkpark_cloud/web/router.ex` and two touch
`cloud/priv/static/app.js`. Sequencing is file-truth, not doubt about the work. **Retired at wave 2
by D25** — file-truth is a merge-order concern, not a build-order one.

#### What wave 1 actually landed (verified BY CONTENT on `origin/main`, 2026-07-21)

The wave log said five slices shipped. `origin/main` said otherwise, and this epic's own triage
predicate — *a row survives if it names a claim/reality divergence* — turned on the epic itself.
Recorded so no future wave re-inherits the error:

| Slice | Claimed | Actually | Evidence |
|---|---|---|---|
| `cch-w1-emit-marker-fence` | shipped | **LANDED** | `#5306` merged `60a4f90ef`; `design/emit.mjs:2099` `export function lostLines(...)` |
| `cch-w1-cssom-ci-wiring` | shipped (real reds) | **LANDED** — via `#5307`, not `#5290` | `console-harness.yml:90 cssom-parity`. `#5290` is CLOSED as a duplicate; its "genuine reds" were **cancelled** check-runs from a concurrency collision with its own `-r` sibling — a SUCCESS pair existed on the same SHA, and a clean rerun of the cancelled run returned `conclusion=success` for both named checks. There was never a fix to make. |
| `cch-w1-peer-ip-pin` | shipped | **NOT LANDED** | `router.ex:377-379` still the original three `loopback_peer?/1` clauses. Open `#5305`. |
| `cch-w1-ledger-close-guard` | shipped | **NOT LANDED** | `grep -c lifecycle_status` on `mutations.ex` = 0. Open `#5309`. |
| `cch-w1-refetch-storm` | shipped | **NOT LANDED** *(row STALE — corrected wave 6)* | Was: "no `OVERVIEW_FLEET` on main. Open `#5308`." **It landed**: `481d6f231` (#5308), `OVERVIEW_FLEET` at `app.js:4905`, scope machinery `:4910-5018`. |

Two corrections a future wave must not re-inherit: **`#5307` reverted nothing live** (origin/main's
`app.css` was clean; its net `app.css` diff is empty — the break-and-revert both happened inside the
PR's own history). And **no PR carried a real red**: `#5309`'s Sobelow is the stale-baseline
line-drift (skip pinned at `router.ex:2505`, finding at `:2530`) which reproduces on `main` itself,
5/5 of the last api-touching commits.

**Movement 0 (lead-owned, off the critical path):** merge `#5305`, `#5308`, `#5309` on advisory reds.
Proven safe to do in any order — all four branches merged into `origin/main` with exit 0 and zero
conflicts, and forward vs reverse order produced a byte-identical tree. Verify **by content** after
merge, never by PR state. Then evidence-close `gr-blk-emit-marker-fence` **and**
`cch-w1-emit-marker-fence` criterion 6 citing merge SHA `60a4f90efa1bed4cb5eecade5a57a0f246b3d589`
+ `design/emit.mjs:2099` — the census row was never touched by `cch-w1-census-disposition`, so
nobody closed either.

### Wave 2 — finish the four lies on the wire

| Slice | Task | Round | Size | Surface | Model |
|---|---|---|---|---|---|
| SSE ticket + reconnect rewrite + 4th chip state | `cch-w3-sse-ticket` | 1 | large | cloud router + accounts + SPA + CSS | opus |
| HEAD side-effect fence + `oauth_states` prune | `cch-w2-head-sideeffect-fence` | 1 | medium | cloud router | opus |
| Click oracle over the 8 unfixtured destructive DELETEs | `cch-w2-revoke-click-oracle` | 1 | medium | preview harness | opus |
| The gate ledger stops lying (Vercel class + Sobelow re-pin) | `cch-w2-gate-ledger-honesty` | 1 | small | docs/ops + baseline | opus |
| Ledger guard reaches the create family | `cch-w2-ledger-close-guard-create-ops` | 2 (after `cch-w1-ledger-close-guard` MERGES) | medium | api content | opus |
| Destructive controls confirm and confess | `cch-w2-revoke-ux-honesty` | 2 (after `cch-w2-revoke-click-oracle` MERGES) | small | cloud SPA | opus |

Round 1's four slices are file-disjoint except `router.ex`, which SSE and HEAD touch in regions
~8,400 lines apart (HEAD inserts before `plug(Plug.Head)` at **284**; SSE edits `require_user_sse` at
**9705-9707** and adds a route at **1283**). Merging `#5305` first shifts SSE's coordinates **+47**
and leaves HEAD's **unchanged** — grep for anchors at build time, never trust a line number.

### Wave 3 — the bearer leaves the URL, and the sibling-class law gets paid

**Act 1 (LEAD, first, mechanical — not builder budget).** All four wave-2 slices are pushed with
OPEN PRs and every blocking gate SUCCESS: **#5377** `cch-w3-sse-ticket` (`-r`), **#5378**
`cch-w2-head-sideeffect-fence`, **#5379** `cch-w2-revoke-click-oracle` (`-r`), **#5380**
`cch-w2-gate-ledger-honesty`. Merge the `-r` variants (already the PR heads). Verify **by content**,
never by PR state. Re-claim before closing — claims lapse and re-claim under a foreign worker (D59).
Two close steps carry side-stamps: **#5379** → evidence-close `gr-blk-revoke-harness-gap` **and**
`gr-blk-smoke-click-inert`; **#5380** → stamp `gr-blk-vercel-checks-ungoverned` **criterion index 1
(0-based)** — its brief says "criterion 2" in 1-INDEXED prose against a 0-INDEXED array; index 0
(root cause via `vercel inspect --logs`) stays UNMET and that task stays OPEN. Then close
`cch-bl-unpushed-base-branches`. **Act 1 gates dispatch: every wave-3 slice carries a
verify-by-content PRECONDITION line and must report BLOCKED rather than build against an unmerged
base.**

**Act 2 (the wave's content) — pay the class at the three doors the headline itself opened.**

| Slice | Task | Round | Size | Surface | Model |
|---|---|---|---|---|---|
| HEAD stops burning a live SSE ticket — instance + census pin | `cch-bl-head-denylist-tripwire` | 1 | medium | cloud router + tests | opus |
| The SSE ticket table gets a reaper | `cch-bl-sse-ticket-mint-rate-limit` | 1 | small | cloud workers + config | opus |
| `__css_check` E2 states its boundary; the ruling is NO | `cch-bl-css-check-states-boundary` | 1 | small | console instrument | opus |
| The ledger's claim survives every door | `cch-w2-ledger-close-guard-create-ops` | 1 | large | api content | opus |
| Destructive controls confirm and confess | `cch-w2-revoke-ux-honesty` | 1 | medium | cloud SPA + oracle | opus |
| The task gate stops choking on a backtick | `cch-bl-pr-task-gate-backtick-regex` | 1 | small | CI gate | opus |

All six are **file-disjoint** — verified path-by-path, no two slices name a shared file. All are
round 1 because their only dependency is Act 1 (a lead merge), not another wave-3 slice.

**Act 3 — composite proof, absorbed, not deferred.** No separate slice and no new CI wiring:
`cloud.yml`'s test job runs a bare `mix test` with a Postgres service and **no path filter**, so the
committed `router_sse_ticket_head_burn_test.exs` from slice 1 becomes a standing gate the moment it
lands. That test is the existence proof this round earns its cost — invisible to every branch-local
gate, visible in ten seconds side by side.

**Narrow dispensations granted this wave** (do not widen): `.github/workflows/pr-task-gate.yml` +
`scripts/pr-task-gate.{sh,test.sh}` for the backtick slice — the epic's own instrument-honesty frame
reaches its own merge gate.

### Backlog still queued (filed, not built)

The epoch-only close fence (`cch-bl-close-fence-epoch-only` — the CAS path is itself stealable, the
worker id is never compared), the header-borne OAuth token redesign
(`cch-bl-oauth-token-header-redesign`), `cssom-parity` hardening, the two Overview honesty rows, and
the Bands 1/3/6 reproduction pass — **re-sized from "~42" to 22** (5 Band-1 + 15 Band-3 + 2 Band-6,
counted directly), of which 1 is already `done`, 1 (`gr-blk-emit-marker-fence`) is provably fixed on
main, and 2 are permanent human gates → **~18 genuinely unknown**. The `~42` and the "38 of the
epic's 69 rows" arithmetic behind it were borrowed from the *predecessor* epic's GR112 audit
(`Counter({'open': 69, …})` under `task-47bc4168392dec17`) and mislabelled as this epic's — this
epic has **91** children (85 open / 6 done). Do not size a slice against the old figure. **Wave-5
correction:** the epic now carries **121** children (113 open / 7 done / 1 cancelled) — 69 `gr-*` +
50 `cch-*` + 2 misc; the 50 `cch-*` are UNBANDED and Movement 2 censuses them.

### Wave 5 — pay D41 across the boundaries; every payment is a close

Builder model is **`opus` for EVERY slice** — Fable 5 is spend-limited this cycle (hard constraint).

**Movement 0 (LEAD, mechanical — the finishing bulk, not builder budget).** `#5434` is MERGED (D64),
`main` has no branch protection, so there is nothing to "unblock." Stamp `cch-bl-head-denylist-tripwire`'s
final MERGE-GATED criterion with `a7b5284c4`; evidence-close `cch-bl-get-census-rederive` (subsumed);
**cancel `task-2200bea3796a4e84`** (duplicate stub). Then evidence-close the ~15 landed-but-unstamped
`cch-*` slices — each SHA-proven ancestor of `origin/main`, sole open criterion the boilerplate
MERGE-GATED text — and pair-close their `gr-*` census twins. Cite MERGE SHAs, never branch SHAs
(D-standing-law-1); for `#5435/#5436/#5437` the task-note branch SHA is NOT the merge SHA (use
`a893c3821 / 0ed73651f / a601fae3e`); `cssom-ci-wiring` merged as `#5307 / c43d75d60`, NOT `#5290`
(closed unmerged). Claims are lapsed — re-claim (`bp task next`) if a CAS close 409s. Three are
triage-closes not builds (D69): `css-check-states-boundary` (`069c6e986`), `replace-upsert-tripwire`
(`a893c3821`), `get-census-rederive` (`#5434`).

**Movement 1 (the wave's content) — 5 round-1 opus slices, DISJOINT files, dispatched in parallel.**

| Slice | Task | Round | Size | Surface | Model |
|---|---|---|---|---|---|
| cssom floor stops decaying — exact-match sidecar ratchet (D65) | `cch-bl-cssom-floor-decays` | 1 | medium | `cssom-parity.mjs` + sidecar | opus |
| per-declaration paint fence — the sibling-line miss (D66) | `cch-bl-state-rule-per-declaration-gate` | 1 | small | `__app.test.mjs` | opus |
| ban the line-number citation shape + re-anchor the live drifts (D67) | `cch-bl-source-citation-line-drift` | 1 | medium | `__css_check.mjs` + `app.js` + `smoke.mjs` | opus |
| the emit `--write` fence gets a standing regression test (reflexive D40) | `cch-w1-emit-fence-regression-test` | 1 | small | `design/emit.mjs` + new test + `doc-gates.yml` | opus |
| the claim survives a REPLACED claim too — pay D52's residue (D70) | `cch-w3-claim-overwrite-fence` | 1 | medium | `mutations.ex` + `mutate_controller_test.exs` | opus |

All five are file-disjoint (verified path-by-path). Every check is mutation-proven able to fail
(remove clause → red → restore) BEFORE merge — this repo ships vacuous greens.

**Narrow dispensation granted this wave** (do not widen): `.github/workflows/doc-gates.yml` for the
emit-fence regression test's CI wiring (the `design/emit.mjs`+`check.mjs` dispensation already covers
the fence itself; a new `design/emit-fence.test.mjs` rides it).

**Movement 2 (triage to seal — Paper spine, no build slice).** Census+band the 50 `cch-*` rows in the
wave-5 Paper; state the honest seal arithmetic (D72): NOT YET SEALABLE, and the shortest sealable
count. The `d34-wrapper-list-correction` charter edit is folded here, not dispatched.

**Deferred, FILED as backlog (not built this wave):** the reflexive `@boundary`-marker registry
capstone (`cch-bl-boundary-marker-registry`, round 2, template `#5434` — D68); the smoke-shim
fidelity build (`cch-bl-smoke-shim-fidelity`, its two splits CANCELLED — D71); the epoch-only close
fence (`cch-bl-close-fence-epoch-only`, out of fence — D70); `task-birth-attribution` (design task);
`cch-bl-lifecycle-token-reaper`; the cross-language citation-drift follow-up
(`cch-bl-citation-drift-cross-language`).

### Wave 6 — the console stops lying to its OPERATOR

Waves 1-5 spent themselves on INSTRUMENTS. That was right and it is finished (wave 5 landed all five
D41 payments, green and mutation-proven). Wave 5's own review instructs the successor plainly: *"then
triage the remaining LIVE claim/reality divergences over further instrument hardening."* Wave 6 obeys.
Builder model is **`opus` for EVERY slice** — Fable is unavailable and forbidden this cycle, which is
why the two design candidates were re-judged on the invariant axis and one of them was CUT (D73).

**Movement 0 (LEAD, mechanical — the finishing bulk, not builder budget).** Evidence-close each row
below with a MERGE SHA + `file:line` (standing law 2). Thirteen confirmed, re-derived at Verify:

| Row | Merge SHA | Anchor |
|---|---|---|
| `cch-bl-close-fence-epoch-only` | `448749cf1` (#6420) | `close.ex:319` `check_close_holder/3`. D70 bars TOUCHING `api/`; an evidence-close is a ledger write, not a code touch — close, never build. |
| `gr-backlog-provider-reconnect` | `382f23540` (#4481) | `registry.ex:2635` upsert + `20260719203000_unique_provider_per_team_kind.exs` |
| `gr-blk-oauth-head-mint` | `26acc7a91` (#5378) | `router.ex:547` and `:551` — both oauth legs fenced |
| `gr-blk-console-refetch-storm` | `481d6f231` (#5308) | `app.js:4905` `OVERVIEW_FLEET`. **Close text says 40→12, NOT "each endpoint once"** — the landed pin is `__app.test.mjs:302` "…cost 12 requests, not 40"; the criterion's literal wording (5) is not met. |
| `gr-blk-smoke-click-inert` | `8c9c116c5` (#5379) | `smoke.mjs:35`/`:155-169`; residue already forwarded to `cch-bl-smoke-shim-fidelity` |
| `gr-blk-revoke-harness-gap` | `8c9c116c5` (#5379) | `smoke.mjs:461` click oracle, honest-failure text `:486-489` |
| `gr-blk-cssom-parity-harden` | — (content) | `cssom-parity.mjs:97` count-mismatch is fatal + `:92` `CSS=…` widens past app.css. Pull criteria before stamping. |
| `gr-backlog-cssom-parity-count-skew` | — (content) | the decision shipped as D65's committed sidecar (`:209`/`:476`) |
| `gr-backlog-css-brace-detector` | — (content) | E10 implemented `__css_check.mjs:421-474` with a live error emitter |
| `cch-bl-appcss-wound-owner` | point-in-time | tree clean, app.css diff vs origin/main **0 lines**. Closes at **2 of 3** — criterion 2's RED half needs a worktree mutation. Say so. |
| `cch-bl-appcss-orphan-comment-live` | point-in-time | delimiters **289/289 balanced** (filed as 274/275); `__css_check` 0 errors AND `cssom-parity` PARITY PASS 1233/1233 MISSES 0 — cite the output, it satisfies criterion 2 |
| `gr-blk-primary-checkout-reconcile` | point-in-time | `HEAD == origin/main`, 0 ahead / 0 behind, clean. Closes on the STATE, not the procedure — whether the 1095 lines of foreign work were preserved is unknowable from here. Say so. |
| `cch-bl-get-census-rederive` | — | **close as SUPERSEDED BY D46, never "subsumed by #5434"** (D82) |

Two are NOT free: `gr-blk-ledger-close-bypass-audit` has criteria 0/1 met by content
(`ensure_task_close_is_cas` at four call sites; `sync/applier.ex:177` passes `source: :sync`) but
criteria 0/2 both say *"proven by re-running the live probe"* — a five-minute lead action against
guerrilla. `cch-bl-unpushed-base-branches` has criteria 0 and 2 MET (all four base contents on main;
all four refs still at the recorded SHAs, so no sibling force-push) and criterion 1 NOT — all four are
still absent from origin AND each is prefixed `+` in `git branch --list`, i.e. **checked out in a live
worktree**, so a bare `git branch -d` refuses. Hygiene, not risk; not a one-liner.

**Movement 1 — five round-1 opus slices. All dependency-free; the lead pays merge order.**

| Slice | Task | Round | Size | Surface | Model |
|---|---|---|---|---|---|
| The providers card stops telling the operator to destroy a working credential (D77/D78) | `gr-bl-provider-reconnect-client-guard` | 1 | large | cloud SPA + router + tests | opus |
| Sessions carry honest provenance — column, six write sites, never a guess (D79/D80) | `gr-p5-session-provenance` | 1 | medium | cloud accounts + router + migration + SPA | opus |
| `--ring-soft` becomes identity-derived by PROMOTION, not in place (D74/D75/D76) | `gr-p5r7-ring-soft-accent-invariant` | 1 | medium | `design/emit.mjs` + app.css + exemptions | opus |
| Overview stops certifying freshness it lacks, and its band stops going stale (D81) | `cch-bl-overview-subscription-band-stale` | 1 | medium | cloud SPA + harness | opus |
| The seal predicate refuses a null or unresolvable successor (D84) | `gr-bl-predicate-null-successor-silent-seal` | 1 | small | `seal-predicate.mjs` | opus |

**File truth (D25 governs — merge order is a lead cost, not a build-order one).** Slices 3 and 5 are
fully disjoint from everything. Slices 1, 2 and 4 share `cloud/priv/static/app.js` and
`__app.test.mjs` at genuinely distant regions — sessions ~`1076-1087`, providers ~`1980-2210`,
overview ~`4931` and ~`12727`; slices 1 and 2 share `router.ex` at `~8322/8377` vs
`652/713/1061/1535/7848/10714`. Grep for anchors at build time; never trust a line number.

**HIGH-FLIP-RISK (E2) — two slices, named for the reviewer.** Slice 1: *"rotation claims no new
authority surface and needs no confirm step"* — a security/authz judgment (D78). Slice 2: *"each of
the six write sites reports its own true origin"* — the `session_opts/1` trap (D80), where a wrong
call makes every test pass while five sites report one answer. Both warrant a genuinely INDEPENDENT
second re-derivation before merge; that dispatch is a manual lead step.

**Movement 2 (Paper spine, no build slice).** The honest seal arithmetic after Movement 0 (~82 → ~69
open), D83's re-parenting requirement, and the `gr-backlog-e02-deploy-actor` ruling: **RATIFY
TRIGGER-ONLY**. Grounds, measured: five code paths create deployments and only TWO write
`site.deploy_requested` (a coalesced manual deploy stamps nothing; promotion writes a different verb;
the GitHub push webhook writes no audit at all), so the join can never attribute more than 2 of 5;
`list_audit_events` has no `target_id IN (…)` filter, so a page of deployments is N+1 or a misaligned
200-row sweep — a new server-side batch filter, not a UI join; it acquires a 90-day retention cliff
the deployment row does not have; and the attribution operators want ALREADY exists, backend-true and
filterable, in Activity (`ACTION_LABELS["site.deploy_requested"]`, the `site.deploy` filter chip, actor
chips built from the member list, falling back to `"system"`). GR27/GR28 ratified trigger-only *for
that wave only*, so this is a genuinely new decision — do not cite them as having made it. If a future
wave wants ladder attribution anyway, the honest build is an `actor_user_id` column on `deployments`
stamped where the write site already holds it and rendered only when present — same rule as D80 — not
the join.

**Handed OFF, deliberately not adopted:** the repo-wide Vercel red is **diagnosed** and belongs to
Honest Gates (`hg-bl-vercel-legacy-statuses-red-repo-wide`, open, unclaimed, 1/8) — adopting it would
recreate the duplicate-ownership defect that cancelling `gr-blk-vercel-checks-ungoverned` cured. The
diagnosis, run with `vercel inspect --logs --scope guerrilla` (the default scope
`frikk-jarls-projects` cannot see these deployments, which is probably why nobody got the log): six
`Module not found` on `@barkpark/react` and `@barkpark/core`, because their entry points are `./dist/*`,
`dist/` is gitignored, and nothing builds the workspace packages before `next build` — diff-independent,
hence red on every sha. The complete fix is `workspace:*` (in-tree precedent:
`apps/mobile/package.json:15-16`) **plus** a `prebuild` in `web/package.json`; `prebuild` alone leaves
2 errors because pnpm INJECTS a copy of `@barkpark/react` (it has peerDependencies + `files:[dist]`)
while `@barkpark/core` is symlinked and heals. Both red checks are two Vercel projects rooted at the
same `web/` directory — deleting one removes a permanent red with no code change.

**Deferred, FILED as backlog:** the `--ok`/`--danger` ruling (D73, row rewritten with the measured
facts, awaits Fable); focus-ring contrast across 5 identities × 2 modes (D76); provider identity echo
on rotation (D78); the seal predicate's epic retarget + its first tests (D84); `smoke.mjs` red on main
and CI-invisible; `console-harness.yml:7` claiming 415 tests for a 699-test suite. Also unchanged and
NOT built: `gr-blk-worktree-registry-bloat` does not reproduce as filed — 1511 registrations, **ZERO**
prunable, all directories present, 260 dirty of which ~170 hold real tracked edits, and the safe
`clean AND merged` predicate bites **18 (1.2%)**. It is a source-side leak (the agent harness never
removes what it creates, growing ~1 entry per few minutes under load) wanting a rewrite, not a build.

## Wave log

<!-- one entry per wave: date, slices shipped, grade, what the next wave must know -->

### 2026-07-31 — wave 10 REVIEW — six round-1 slices shipped, grade A−; half one is LEGAL but NOT YET DONE

**Landed, all six pushed with PRs open** (the lead merges; every task's last criterion is
merge-gated and stays open for them):

| slice | branch | PR | gate on the final tree |
|---|---|---|---|
| `cch-w10-dispatcher-hardening` | `…close-five-false-green-classes-and-the-e-0` | #8251 | 144 / 121 / 113, 0 failed |
| `cch-w10-registration-sample-instrument` | `…the-registration-precondition-becomes-a--1` | #8252 | 43 / 0 |
| `cch-w10-required-checks-toolchain-honest` | `…the-required-checks-toolchain-becomes-bl-2` | #8253 | 82 / 0 hermetic + selftest OK |
| `cch-w10-security-gate-shim` | `…security-yml-renders-a-check-run-on-ever-3-r` | #8255 | 68 / 0 |
| `cch-w10-oauth-exchange-code` | `…a-leaked-oauth-callback-response-header--4-r` | #8256 | 732 JS + 2571 cloud, 0 failed |
| `cch-w10-destroy-shrink-oracle-merged` | `…the-preview-s-destroy-verbs-shrink-a-rea-5` | #8257 | 98 scenarios + 43 + 722 |

**HALF ONE: the sample is legal; registration is still unshipped.** Review re-derived it
independently — `registration-sample.sh --since 5ddae0dc2 --limit 12` → qualifying 5, of which
NEITHER-shape 4, unsettled 0, shim defects 0, **exit 0**. D114 holds and is now a script's exit code
rather than a paragraph. But `cch-w10-register-console-and-cloud-gates` is round 2 by the
sequenced-rounds law and did not build: it waits on #8251/#8252/#8253 merging, then on the sampler
exiting 0 on the POST-MERGE window. The wish's first priority therefore lands one wave late, for a
reason review judges sound — the same verify round found live false-green classes in the dispatchers
and a brick that permanently reds a legal revert-pair PR, and registering over either installs a gate
that can green while never running, on `Elixir gate` which blocks main today.

**HALF TWO: the thesis paid, one layer out.** `required-checks-drift.yml` lost both workflow-level
`paths:` keys and gained a blocking, unmatrixed, dispatcher-free `Required-check spec gate`;
`security.yml` got the same treatment plus an unmatrixed `Security gate` that EXCLUDES `sobelow` by
name, because `needs.<job>.result` reads `success` for a `continue-on-error` job that concluded
FAILURE and the information is destroyed before the aggregator's shell starts.

**WAVE 9'S STANDING LESSON EARNED ITS KEEP — twice.** Review built the merged tree of all six
branches and ran every ratchet on it (all green, including the hermetic suite that scans the real
workflow tree while two other slices rewrite workflows). And the per-slice gates hid a genuine
cross-slice hole: **`security.yml`'s shim was transplanted from the PRE-FIX wave-9 shape**, so it
shipped the byte-identical defective diff producer and empty-diff brick that slice 1 removed from the
other three workflows *in the same wave*. Every slice gate was green over it. Fixed in review on the
owning branch, mutation-proven (64/2 against the pre-fix line).

**Two more reviewer fixes.** `security-gate-shape.test.sh` was run by no CI job (D26 — a harness
nobody runs is not a ratchet); an unfiltered `gate-shape` job now runs it and sits in the
aggregator's `needs` and `decide()`. And `bootOAuth`'s `.then` had no `.catch`: a throw in the
handler swallowed `done()` and left the user on "Signing you in…" forever.

**Ledger: clean.** Six slice tasks, all `in_progress`, every non-merge-gated criterion MET with
concrete run output, every merge-gated row OPEN for the lead, `wave_paper` set on all seven. No
fabricated done, no batched honesty. No foreign task touched.

**NO SEAL, honestly.** The seal predicate REFUSES before evaluating anything under `--successor
TERMINAL`; a=b=c=UNEVALUATED, 66 live rows. D83 binds. This wave moved clause (b)'s honesty and
three free closes; it did not move the verdict by rhetoric.

**What the next wave must take, in order.** (1) Merge round 1, then dispatch
`cch-w10-register-console-and-cloud-gates` — re-run the sampler on the POST-MERGE window first, and
STOP on a non-zero exit. It is HIGH-FLIP-RISK on blast radius: every foreign session's PR is gated
the moment it merges. (2) `Required-check spec gate` and `Security gate` are new names that have
never rendered; they become registrable only after they render on qualifying heads, and `Security
gate` additionally waits on #8222 clearing mix-audit. (3) The residue this wave named rather than
hid: `cch-w10-diff-producer-sweep` (`reland-check.yml` still carries the forbidden two-dot fallback;
`deploy.yml:72` decides whether the CONTROL PLANE deploys), `cch-bl-nul-native-path-matcher` (the one
residual false-green class — a newline inside a directory prefix), `cch-w10-required-checks-generate-jq-merge`
(the generator still OVERWRITES, D111), and criterion 1 of
`cch-w10-merge-gates-doc-drift-security-topology`, deliberately left to the registration PR because
it owns `.github/required-checks.json`. (4) Weight 2 took two slices this wave; the vision still has
rows. Do not let the instruments crowd it out again.

Paper: `cloud-console-hardening-wave-10-2026-07-30`.

### 2026-07-30 — wave 10 DECIDE — 7 slices cut (6 round-1, 1 round-2), half one CLEARS on re-derivation

The wave's own headline reversed under measurement. Strategize and Digest both concluded the
registration precondition was NOT met — one qualifying head, and the single head of the required
"touches neither path set" shape concluded FAILURE. Re-derived at `origin/main` `21ab0e50d`, five
commits later: **four qualifying heads, three of them NEITHER-shape, zero shim defects** (D114). The
missing sample was not manufactured; it arrived as a by-product of three foreign merges that happened
to be spaced. So registration is legal this wave — and it is still round 2, because measurement also
found two live false-green classes in the dispatcher that corrupt the sampler's own verdict and sit on
the ALREADY-REGISTERED `Elixir gate` (D116), plus a brick that permanently reds a legal PR shape
(D117).

Five inherited premises failed smoke and were corrected rather than built on. `core.quotepath=false`
is an INCOMPLETE fix that would have looked like a pass (D116). The drift workflow's availability
rationale is refuted by 67/67 green runs, and its paths key — not its advisory flag — is what let
#8093 through (D119). The `needs.<job>.result` laundering was measured for the first time in this repo
and is UNDECOMPOSABLE, so "explicitly tolerating" a continue-on-error job is unimplementable (D120).
The OAuth row's TITLE is refuted by a committed replay test, and the real threat is response-header
disclosure plus an unnamed `location.hash =` history push (D121). And the digest's worst finding — two
vision lies "done with empty evidence" — is refuted: both carry deliberate `close_override` records,
and re-stamping them would manufacture the lie the wave hunts (D123).

Two rows FUSE: the destroy-verb fixtures and the revoke click oracle are two halves of one proof whose
dependency the ledger does not record, and wave 9's standing lesson is exactly that each half reports a
clean ratchet alone (D122). One row is ADOPTED rather than rebuilt: PR #8222 already ships the req bump
(D120). `required-checks-floor.sh` EXISTS, works, and is wired into nothing — that wiring is a
precondition of registration, not a follow-up (D118). NO SEAL, and the clause letters are UNEVALUATED
under the only legal invocation, so the quoted `a=FAIL b=PASS c=PASS` line is retired (D124).

Seven slices, six round-1, all file-disjoint, all opus (fable unavailable this wave — a fable selection
would be a silent remap). Paper: `cloud-console-hardening-wave-10-2026-07-30`.


### 2026-07-30 — wave 9 REVIEW — grade A, six slices shipped, all PUSHED with PRs open, NO SEAL confirmed honest

**All six round-1 slices landed green and are on `origin` with PRs open.** Every final branch is the `-r` branch: the reviewer changed something on all six.

| Slice | Task | Final branch | PR |
|---|---|---|---|
| Console shim + `Console gate` | `cch-w9-console-gate-shim` | `…renders-a-check-run--0-r` | #8201 |
| Cloud shim + `Cloud gate` + structural rung 2 | `cch-w9-cloud-gate-shim-rung2` | `…and-the-seal-1-r` | #8202 |
| Guard refusal vocabulary | `cch-w9-guard-refusal-vocabulary` | `…not-defect-wh-2-r` | #8203 |
| Generator catch-all poison | `cch-w9-generator-catchall-poison` | `…poisons-the-r-3-r` | #8204 |
| Stale protection claims | `cch-w9-stale-protection-claims` | `…is-unprote-4-r` | #8205 |
| PAT twin of the session-touch lie | `cch-bl-pat-touch-not-authz-aware` | `…touch-lie-a--5-r` | #8206 |

**THE WAVE'S OWN FINDING — a hole that existed only in the MERGE.** `cch-w9-cloud-gate-shim-rung2` gives the seal predicate a rung-2 leg A that reads `` `${REPO}/.github/required-checks.json` ``. The console harness runs that predicate's tests. With both branches merged, `console-path-escape-check.sh` still printed **"OK: 9 reads"** — a backtick template carries no comma and no quotes, so the `join(REPO, "…")` grep could not see it. A ratchet reporting OK over a live escape is the exact vacuous pass it exists to remove, and **neither builder could observe it**: each half looks complete on its own branch. Fixed on #8201 (census learns the `${REPO}/…` idiom; the path is declared AHEAD of the read so main stays green whichever slice lands first; three assertions pin both directions). **Standing lesson: a per-slice gate cannot see a cross-slice census hole. Review must run the merged pair.**

**Four more reviewer fixes, each an honesty defect inside an honesty instrument.** (1) Rung-2 Leg C resolved to `usable[0]`, so an ENFORCED job could read rung 3 purely on job order in a file — now prefers the REGISTERED aggregator, mutation-proven. (2) Leg A reads the COMMITTED spec, not live GitHub; the output now says which of the two it read. (3) `cssom-parity.mjs`'s own header still asserted *"main is NOT branch-protected"* — the retracted premise, inside a wave-9 file. (4) `required-checks.test.sh`'s real-tree tripwire passed on the ABSENCE of a string, so it would pass if the generator died before the scan; now paired with a planted-catch-all control.

**THE SEAL, HONESTLY: NO SEAL, and it is now honest for a BETTER reason than before.** Wave 8 shipped clause (b) so it could pass. It does not pass, twice over: (a) `Cloud gate` is not yet a required context, so all four rung-2 entries correctly read rung 3 — that is the instrument working, and it clears the moment round 2 registers; (b) **CCH-D6's rung-1 guard `design/emit-fence.test.mjs` exits 1 on real design-token drift**, and registration does NOT fix that. That red is INHERITED — measured identical on pristine `origin/main` — and it also keeps `Design-token drift gate (blocking)` red on main itself. **A seal is not reachable until the emit-fence drift is paid** (`cch-w9-emit-fence-guard-red-on-main`). D83's ruling that a null successor is a manufactured seal still binds.

**Three criteria stay honestly OPEN because they embed that inherited red** (`cch-w9-console-gate-shim` #6, `cch-w9-cloud-gate-shim-rung2` #5, `cch-w9-guard-refusal-vocabulary` #4 all demand `seal-predicate 31/31`). Each carries a reviewer miss-note. **Do not stamp them met on merge — re-word them against the emit-fence row.**

**What stalled, by design:** `cch-w9-register-console-and-cloud-gates` is round 2 and did not dispatch. It is unblocked only when #8201, #8202 and #8204 are all MERGED **and** the merge train produced ≥2 post-shim heads on which both aggregators rendered and concluded success. If it did not, **do not register** — a partial registration is worse than none.

**Next wave must know.** (1) **Nothing in the two shims has run on GitHub.** The property they exist for — that `Console gate` / `Cloud gate` publish check runs of those exact names on a docs-only head — is measurable only on #8201/#8202. Read the check-run list **by name**, never the rollup. (2) **HIGH-FLIP-RISK, independence owed:** rung-2 Leg B/C decides whether a seal certificate can be issued over a job nobody has to pass. The reviewer re-derived it independently and endorses it, naming two residues: Leg B certifies STRUCTURE (`needs` + `if: always()`), not that the aggregator ASSERTS — D19's measured false green is covered for these two workflows by the `needs_without_decide` emitters in the path-escape harnesses, not by the predicate; and Leg A is L3 (a committed file), with live drift owned by `required-checks-verify.sh`, which is itself advisory and paths-filtered. (3) **D99 is stale and must be re-run** after #8204 lands. (4) `required-checks-drift.yml` is `continue-on-error: true` AND paths-filtered, so the generator's new catch-all tripwire is ADVISORY today — the same defect class this wave attacked, one layer out. (5) Filed, not smuggled in: `cch-bl-bp-graph-drift-stale-protection-claims-2` — two more files still cite the `404 "Branch not protected"` measurement, out of fence. (6) `pat_touch`'s shared `:barkpark_session_touch_deferred` key is safe only while session and PAT are mutually exclusive branches of one `cond`; that is a comment, not an assertion.

### 2026-07-30 — wave 9 DECIDE — 7 slices cut (6 round-1, 1 round-2), charter premise corrected by content

**The founding premise flipped and the charter still asserted the old one.** D58, D64 and D89 now carry inline dated retractions (D106); D104 had corrected D89 alone. Two more live spans are a build slice.

**What the verify round settled, and what it overturned.** FOUR `measured_in_ci` entries, not three, and CCH-D5 is rung 2 — so **clause (b) is PASS live**, refuting the digest. M1 and M4 are ONE diff by arithmetic, not taste (D107), and the cheap escape — a YAML comment containing `cloud/**` — was measured to restore `b=PASS`, which is why M4 goes structural. The rung-2 legs it replaces are **100% untested**: deleting both problem-pushes leaves the suite 31/31 green. A NEW blocker nobody had: `cp-ops.yml` (#8093, merged the day before) poisons the required-checks generator into promoting four excluded contexts at exit 0 (D110) — so M3 gains a round-1 prerequisite and D99's measurement is stale.

**Instrument health, all mutation-proven at `74a88d1cd`:** console harness **722** tests (not 720), smoke 98 scenarios, seal-predicate 31/31, `required-checks.test.sh` 68/0, `verify --selftest` 16/16, `cssom-parity` PARITY PASS on real Chrome with both fatal legs proven. Neither target gate is flaky — cloud.yml's SEVEN main reds (not three) over 14h19m are one byte-identical `RouterAbilityMatrixTest` regression, deterministic, fixed by #8139.

**Next wave must know.** (1) `orphans=58` is the FIRST measured orphan datum — `55` was a misquote of an OPEN-row count; stop citing it. (2) `cch-bl-ability-matrix-red-on-main` is a free lead close (58→57). (3) The ledger degraded mid-Decide: `bp task create --publish` in one call times out at bp's 30s client ceiling, while **create-as-draft then `bp doc publish` succeeds** — use that pattern. An unknown field in `--set` (e.g. `distinct_from`) leaks into `content` and makes the publish wall refuse with a generic `label_spine`. (4) The zsh loop form for successor invocations is broken and manufactures agreement; write them out literally.

### 2026-07-30 — wave 8 REVIEW — grade A−, three slices shipped, all PUSHED with PRs open

**All three round-1 slices landed green, were re-derived rather than re-read, and are on `origin`
with PRs open — the first thing to say, because six consecutive waves ended with reviewed work
stranded on local branches.** PR #8125 (`…clause-b…-r`, `task-43f7662b33e8e0b7`), PR #8126
(`…refused-403…`, `cch-bl-auth-touch-unthrottled`, untouched by review), PR #8127
(`…unrunnable-guard…-r`, `gr-backlog-css-brace-detector`).

**What shipped.** Clause **(b)** of this epic's own seal predicate PASSES on a live run for the
first time — `NO-SEAL a=FAIL b=PASS c=PASS orphans=55 considering=1`. Test 23's ENOBUFS mutation is
path-independent (D97 executed: one literal, 64 KiB), so the console harness stops being red on
`main` in both `--test` and script mode. CCH-D5 is registered at rung 2 behind a real
`Router.call/2` proof that two forwarded clients get separate sign-in buckets. The sessions card
stops claiming a REFUSED device was "Active just now": the `last_used_at` stamp moved downstream of
the response decision via `register_before_send` gated on `conn.status < 400` (D102 executed), which
pays both the operator-visible lie and the write amplification the refuted throttle was aimed at.
And two CSS regression fixtures that nothing had ever executed now run inside a harness CI actually
runs, with the E10 orphan class given its first fixture at all.

**Every high-flip judgment was re-derived independently, not read.** The reviewer applied the
`router.ex:766` key collapse in a fresh tree: 2 failures, both in the new file, `device_auth_test`
+ `router_test` still 203/0 — the composition was genuinely unmeasured. The auth boundary's three
structural claims (before_send fires on every terminal refusal; the once-per-conn `put_private`
guard cannot drop a stamp on plug re-entry, because every re-entrant gate threads the *same* conn;
exactly three `verify_user_session_token` call sites exist) were re-derived from the source.

**Three review fixes, each of the epic's own disease found on the epic's own instruments.** (1) The
rung-2 registration emptied the register of rung-3 entries, leaving `seal-predicate.mjs`'s
`unmeasuredWaivers` branch live with **no test** — paid by mutation in both directions, non-vacuity
proven by disabling the branch (the new test is the only one that reds). (2) Two fixture `_comment`
blocks had inverted with the measurement and still asserted clause (b) fails. (3) `--swallow-check`
printed `E9 app.css:13` while scanning a *fixture* — a report misnaming its own subject — now
labelled and pinned, mutation-proven.

**Two things `main` must own, neither caused by this wave.** `router_ability_matrix_test.exs:221`
and `:236` are RED on `origin/main` today (POST `/v1/sites/:id/artifact` answers 404 where 403 is
expected), re-derived by the reviewer on a detached `origin/main` checkout — filed as
`cch-bl-ability-matrix-red-on-main` (P1). And **D105 IS REFUTED**: task create is *not* a wholesale
outage. A minimal create succeeds; every field the builders needed succeeds individually; the same
full payload 500s four times and then succeeds unchanged on the fifth. It is INTERMITTENT, and the
operational rule is RETRY, not "conclude an outage". Both rows two builders abandoned were filed by
retrying. Filed as `cch-bl-task-create-intermittent-500` (P1). This matters beyond one bug: three
consecutive waves shrank their scope on a capability outage nobody had measured.

**Ledger.** All three slice tasks in_progress, published, `wave_paper` set, every provable criterion
stamped with real run output, and only the merge-gated + independent-reviewer rows left open for the
lead. No tasks outside the wave were touched. Three new rows filed and published
(`cch-bl-pat-touch-not-authz-aware` P2 — the PAT twin of the session-touch lie, still live).

**Grade A−.** Every slice is invariant-shaped and mutation-proven in both directions; two of the
three fix the epic's disease on the epic's own instruments; nothing was guessed and the one thing
that could not be verified (`b=PASS` rests on four MEASURED-ELSEWHERE entries this run did not
execute) is said out loud rather than quoted as "the defects are fixed". Held short of A by scope:
three slices against ~58 live rows, with the required-check flip structurally unavailable (D98), and
by the fact that the wave's own premise about `bp task create` was wrong and cost two builders their
follow-up rows.

**MERGE ORDER IS LOAD-BEARING — #8125 FIRST.** The three slices are file-disjoint (verified by a
clean octopus merge: 722/722 + 31/31 + 2539 Elixir tests, 2 pre-existing failures on the union), but
they are NOT order-free in CI. Read from the live check runs, not assumed:

- **#8125's `Console client unit harness` is GREEN — the first time that job has ever passed.** It
  carries the test-23 fix.
- **#8127's is RED at 29/30 on `not ok 23`**, for a reason that is not #8127's: its branch predates
  the fix. It goes green the moment #8125 lands. Do not read it as a defect in the CSS slice.
- **`Cloud control-plane (test)` fails on both #8125 and #8126 at 2537 tests / 2 failures**, and the
  two are `router_ability_matrix_test.exs:221` and `:236` — the pre-existing `main` red, confirmed
  from the CI log itself, not inferred. Every cloud PR will carry this until
  `cch-bl-ability-matrix-red-on-main` is paid.

**What the next wave must take.** Merge #8125, then #8127 and #8126 in either order, then dispatch
the two D105-deferred slices, which now have no excuse: the aggregator
transplant (D99/D100) and the `console-path-escape-check.sh` prerequisite (D98). Take
`cch-bl-ability-matrix-red-on-main` FIRST — a red `main` poisons every subsequent wave's baseline.
Then `cch-bl-pat-touch-not-authz-aware`, which is the same lie in the other credential and whose fix
shape is already built and merged. `gr-backlog-e02-deploy-actor` and the seal-predicate retarget
(`cch-bl-seal-predicate-retarget-and-reparent`) were NOT taken an eighth time and must not survive a
ninth.

### 2026-07-30 — wave 8 DECIDE (build in flight)

**The wave's first act was voiding its own brief.** Five inherited premises were stale (D96) and the
wish's Movement 0 had already run. But the disease it describes reproduced within 48 hours at a new
site: five rows sat at n−1 with a byte-identical unmet criterion whose only gap was the lead pasting
a merge SHA it already had. One of the five was PAID LIVE during verification — claimed on a released
claim, stamped, closed 8/8, GitHub issue closed 43s later — which is why the census is FOUR and not
the six the direction inherited (D96). The verification round then produced three refutations that
each changed a slice rather than confirming it:

- **D97** — the console harness has never been green in CI. Two honestly-green PRs whose union is
  red, four consecutive main failures on the same assertion, and a root cause nobody would guess:
  test 23's ENOBUFS mutation turns on the checkout's ABSOLUTE PATH LENGTH (1,173,861 B from a deep
  path, 896,566 B on linux — 1 MiB is the line). That also resolves a flat contradiction between
  verifiers reporting 30/30 and 29/30 on the same commit. One literal fixes it, proven green in four
  configurations and proven still sensitive. D92's "11/11 hermetic" is corrected — it measured the
  predecessor file.
- **D102** — `cch-bl-auth-touch-unthrottled`'s filed 60s throttle does NOT pay its own title, proven
  by applying the fix verbatim and re-running the probe: a device idle 3600s, refused 403, still
  prints "Active just now". The row would have closed green at 7/7 with the lie intact.
- **D103** — the modal-census candidate is banned by GR56 in `app.js` itself, at the exact call site
  it would guard. Cut, and replaced by two invariant slices whose sensitivity was measured in both
  directions.

**The flip is FILED, and for once that is not a judgment call.** Three independent mechanisms forbid
registering a console context this wave — the generator's ≥2-post-shim-head sampling rule, the
superset floor, and the fact that the registration is ALREADY filed as a human gate in a sibling
epic (D98). Wave 6 was graded A for cutting an open-ended slice; here the same cut is structural.
What ships instead is the buildable half D89 already authorised: the paths key comes off, a
transplanted dispatcher and an enumerate-and-fail aggregator go on, and the two leaf jobs get
subsumed so the next regeneration cannot promote them behind anyone's back (D99, D100).

**Then the server took the wave's filing hand off (D105).** Document CREATE is wholesale down — four
verbs, HTTP 500, proven against a `patch` control that returns 200 in 1.3s on the same endpoint, and
still down after 14 retries. So the wave did the honest thing twice over: **Movement 0 was paid by the
lead's own hands**, which is what standing law 5 said all along — seven rows closed, every merge SHA
re-verified as an ancestor of `origin/main` today, every write confirmed by a published read-back, and
the board went 65 → **58 live**. And the build wave was cut to slices that already have a published
home, because a row means what it says and repurposing an unrelated row to buy a dispatch slot is
the same lie this epic exists to kill (`gr-blk-cssom-parity-harden` was examined as a host and
refused on exactly that ground).

**THREE slices dispatch, all round 1, all file-disjoint:** the rate-limiter measurement — which also
owns and repairs test 23, so main goes green and clause (b) can PASS for the first time
(`task-43f7662b33e8e0b7`); the authorization-aware session stamp (`cch-bl-auth-touch-unthrottled`);
and the E10 fixture that makes an unrunnable guard runnable (`gr-backlog-css-brace-detector`). Two
carry HIGH-FLIP-RISK — the auth/authz boundary, and the "is this already measured?" judgment — and
because no row could be filed for it, the owed INDEPENDENT second review is stamped as an acceptance
CRITERION on both, where a merge cannot skim past it.

**DEFERRED, fully specified, not smuggled in:** the console-harness dispatcher + aggregator +
`scripts/console-path-escape-check.sh` (D98/D99/D100), and the cssom-parity CHROME refusal guard
(D100's residual). Both are dispatchable the moment `create` recovers; neither is counted as this
wave's work. Movement 0 is closed (`cch-bl-bands-136-reproduce`, 11/11). Paper:
`cloud-console-hardening-wave-8-2026-07-30`.

### 2026-07-28 — wave 7 REVIEW (the board got short, five instruments got honest — grade A)

**Six slices dispatched in round 1, six green, zero failed.** The seventh
(`cch-bl-auth-touch-unthrottled`) was deferred to round 2 by design — same file as the keyset slice,
different region — and is untouched, `open`, 0/7, exactly as the sequenced-rounds law intends.

- **`cch-bl-bands-136-reproduce` (Movement 0, ledger-only, no branch)** — 46 writes across 46
  distinct rows, every one confirmed by a PUBLISHED re-read rather than a printed `rev`. 17 closes
  (16 done + 1 cancelled), 14 re-parents into two destinations both looked up and confirmed open
  first, 15 durable dispositions. Wave 6's dangling `82eb84a37` was confirmed NOT an ancestor and
  named as the citation being REFUSED; refetch-storm closed on `481d6f231` alone.
  `gr-p5r5-successor-seal`'s three invisible grandchildren were re-parented at 14:12:30Z BEFORE the
  parent closed at 14:15Z, so the self-orphan trap was not re-committed one level down.
  `gr-backlog-e02-deploy-actor` CLOSED on the landed trigger-only ratification (D87);
  `gr-blk-worktree-registry-bloat` CANCELLED, and `git worktree prune` was never run.
  **Verified by the reviewer against the live ledger: roster 138 -> 129, open 80 -> 55.** Six of the
  brief's pre-adjudicated dispositions disagreed with the tree, and in all six the tree won.
- **`cch-bl-smoke-harness-red-on-main-and-ungated` -> PR #6694** — the smoke red was one stale string
  (`secure` joined the product two days AFTER the assertion was authored). Deleted, and `secure`
  MOVED INTO the includes so the scenario asserts the rung its prose claims instead of nothing. Both
  prose corrections ride the same diff; the `415 tests` count is DELETED from `console-harness.yml`
  (:7 and :83), never restated. `smoke.mjs` + `seal-predicate.test.mjs` wired into the node-20
  `console-unit` job — the TEST, never a live seal run (depth-1 checkout launders exit 128 into a
  false NO SEAL). Reviewer changed nothing.
- **`cch-bl-seal-predicate-retarget-and-reparent` -> PR #6695** — `--epic` plus the PROSE, the frozen
  six-entry D88 register verified by ancestry AND diff (`git show --format=`, so the subject is
  structurally unreachable), the three-rung ladder with rung 3 FAILING by name (the rate limiter),
  R4, TERMINAL-on-a-post-condition-read, `considering` counted, guard exit 2 read as INFRA FAULT.
  Suite 11 -> 30. **Reviewer fixed three same-class defects in the instrument itself**: a "verified by
  ancestry + diff" note printed beside a diff MISMATCH, a rung-2 MEASURED-ELSEWHERE note suppressed
  by an unrelated earlier problem, and `--successor " <epic> "` slipping past R4 on a space.
- **`cch-bl-ring-soft-focus-contrast-unasserted` -> PR #6696** — D91's three parts, all load-bearing:
  11 declaration sites repointed to the opaque `--ring`, five CONTRAST_PAIRS rows (43 -> 47 pairs,
  516 -> 564 evaluations, worst new cell 3.31:1), and **E12**, the rule-level detector without which
  (b) is a proven vacuous green. `cssom-heads.baseline` stayed 1235 with MISSES 0, `design/check.mjs`
  PASS. Reviewer re-ran the E12 mutation independently. Reviewer changed nothing.
- **`cch-bl-mockjs-revoke-stateless` -> PR #6697** — one missing argument: mock.js called
  `route(scen, method, path)` while the stateful DELETE handlers are guarded `if (state)`. The
  browser preview toasted "Device signed out" over a byte-identical refetch. Fixed with a per-boot
  bag + a `snapshot()` (route hands back the LIVE array by reference), and the real work is the gate:
  a contract half plus a balanced-paren WIRING tripwire proven red on clean origin/main. **Reviewer
  fixed an infinite loop** in that scanner (unterminated block comment -> `indexOf` -1 -> i=0) and a
  scenarios.mjs comment the fix itself falsified.
- **`gr-bl-delivery-keyset-tiebreak` -> PR #6698** — both feeds ordered by `(inserted_at, id)` and
  paged on half of it, so a boundary mid-tie dropped the far side permanently and silently. Now
  strictly lexicographic, `before_id` threaded through both routes and both client builders,
  backward compatible by construction (`when is_binary(before_id)`, `Ecto.UUID.cast` first).
  Reviewer re-ran the full ExUnit file (168/0) and the mutation independently.

**Cross-slice**: all five branches merge onto `origin/main` CLEAN in any order, and on the integrated
tree every instrument is green — `__app.test.mjs` 720/720, smoke 98/98, `__css_check` 0 errors,
seal-predicate 30/30. That integrated run matters more than the per-slice ones, because #6694 is what
makes smoke.mjs a blocking gate for every later console PR.

**Ledger**: honest, with one nit and one recovery. Five code slices `in_progress`, claims still held,
every provable criterion stamped as the builders worked, every merge-gated criterion left open for
the lead, no foreign row touched. The nit: Movement 0's now-line still reads "44 ledger writes / 15
done-closes" where the true figure is 46 / 17 — stale embedded arithmetic in the row whose own
subject is stale embedded arithmetic. It is corrected in that row's criterion-6 evidence; the
reviewer did NOT rewrite the now-line, because impersonating a live builder claim on an honesty
ledger is worse than a stale sentence. **D95 has partially RECOVERED**: `bp task create` works again
(intermittent timeouts remain), so the reviewer filed the three follow-ups the builders could not —
`task-5acf9b5ad30f9a74` (E12 coverage gaps: styleguide inline CSS + band-less `:focus` rules),
`task-4a591a26279e7d24` (no gate stops a hardcoded population count re-entering console-harness.yml),
`task-43f7662b33e8e0b7` (the rate limiter's bucket separation is unmeasured — the single rung-3
register entry, and therefore the reason clause (b) fails on every predicate run). Publishing 422s on
`label_spine` until the tag RATIONALES are substantive; the strengths were already distinct.

**Next wave takes**, in this order: (1) merge round 1 — #6694/6695/6696/6697 are node/CSS-only, #6698
waits for the CI Elixir gate; (2) dispatch `cch-bl-auth-touch-unthrottled` the moment #6698 lands,
rebased on it; (3) the ~55 open rows the sweep did NOT touch — Movement 0 executed a pre-adjudicated
table of ~31 and left the rest unswept, and the base rate says several are already fixed on main;
(4) build `task-43f7662b33e8e0b7`, because it is the ONLY thing standing between this epic and a
clause-(b) PASS; (5) `gr-blk-vercel-checks-ungoverned`, still reddening every PR repo-wide and
governed by nobody — standing law 7 says LAND the sentence. Still held for a Fable-available wave:
D73's `--ok`/`--danger` hue question. D93's rule holds — no successor is filed until residue is
≤ ~10 non-gate rows.

### 2026-07-28 — wave 7 DECIDE (build in flight)

Wave 6 graded A for pointing the predicate at the operator — and then never paid its own Movement 0.
All thirteen of its named evidence-closes are still `open`, so a wave that shipped five real fixes
moved the open count by zero. Wave 7's thesis is the mirror image: **the board stops lying about how
much is left, and then the board gets short.** Ten decisions. D85 turns Movement 0 into a slice with
a pre-adjudicated table and corrects wave 6's list to ~60% payable — `cssom-parity-harden` still
REPRODUCES and `refetch-storm`'s second SHA is not an ancestor — while adding four closes nobody had
listed, one of them paid by a SIBLING epic whose own "PREMISE REFUTED" annotation sat unread in the
row. D86 bans `bp doc patch` for dispositions on a rehearsed proof that it strands the reason in a
draft AND freezes the row's draft-first GitHub mirror. D87 rules the two carried rows: e02 closes on
eight exactly-re-derived grounds, worktree-bloat cancels on a THIRD zero-prunable census. D88 freezes
a six-entry register from the vision paragraph with a three-rung measurement ladder, and accepts that
rung three — the rate limiter, measured by NOTHING, its only `peer_ip` hit in `cloud/test` being a
COMMENT — makes clause (b) fail. D89 shrinks the human-gate bucket to three: billing hangs under a
**done** goal, and the cssom gate is not a human gate at all (the fleet token carries repo admin) and
would DEADLOCK the repo if satisfied literally. D90 arms the retarget against its own one-flag false
green — `--successor <the epic itself>` measured `a=PASS` over 83 live rows. D91 amends D76 rather
than overturning it: the deferral ground was true of `design/check.mjs` and false of `__css_check.mjs`,
which has composited since `:891`; 60 of 60 cells fail at an ARITHMETIC CEILING (α=0.15 tops out at
1.617:1), so the ring is a live SC 1.4.11 defect, and the token-pair ratchet ALONE is a vacuous green.
D92 repairs the smoke red as the stale expectation it is — `secure` joined the product two days AFTER
the assertion was written. D93 refuses to file a successor at ~40 rows of residue. D94 is premise
smoke catching this wave in the act: D70 does not say what this wave was about to cite it for.

Seven slices, six in round 1, all opus (fable unavailable). HIGH-FLIP-RISK: the retarget's clause-(b)
measurement ladder, Movement 0's close-by-content calls, and the auth-touch throttle.
Paper: `cloud-console-hardening-wave-7-2026-07-28`.

### 2026-07-28 — wave 6 REVIEW (five slices land on the OPERATOR, grade A)

The first wave in six to point the epic's own predicate at the user rather than at the
instruments. **All five round-1 slices green, all five pushed, all five PR'd** (#6538-#6542) —
which is itself the wave's second result: six consecutive waves ended with reviewed,
gate-passing work sitting on local-only branches in a shared checkout. That stopped here.

- **gr-bl-provider-reconnect-client-guard** → `loop-epic/the-providers-card-lets-an-operator-rota-0`
  (#6538, no fixes needed). Executes GR44 nine days after the server shipped the upsert: all five
  client sites, BOTH armed filters (the one-sided fix ships 700/700 green), plus the half the JS
  harness cannot see — `provider_json/1` gains `updated_at` and the roster a "credential updated"
  line, because without it the console trades "you must disconnect first" for "nothing happened".
  Audit carries `rotated:` metadata, no new action string. **HIGH-FLIP-RISK re-derived
  independently in review**: `POST` and `DELETE /v1/providers` carry the identical
  `require_team_admin` gate and `preflight_provider` sits ahead of every write, so D78's no-modal
  ruling holds. The residual — a VALID token for the WRONG account — is real, unmitigated, and
  filed; it deserves higher priority than its current filing.
- **gr-p5-session-provenance** → `…-ori-1-r` (#6539, 2 review fixes). Six write sites, six
  literals, nothing inferred and nothing backfilled; the cast-allowlist tripwire is proven by a
  raw-SQL round trip. Review moved `originLabel()` out from between `sessionRowHtml`'s doc comment
  and `sessionRowHtml` (the GR63/GR81 block, REVERT instruction and all, had been re-anchored onto
  the wrong function) and added the closed-set source guard the builder himself named as the soft
  spot — six call sites, each carrying an `:origin`. **Lead: the migration lands BEFORE or WITH the
  deploy. A new node against an un-migrated DB fails every `UserToken` select, i.e. all
  authenticated traffic. Nothing in CI enforces that ordering.**
- **gr-p5r7-ring-soft-accent-invariant** → `…-pr-2` (#6540, no fixes needed). D74/D75 executed
  exactly: promotion into `cloudAccentVars()`, 19 consumers, zero carve-outs, exemptions 33→31 in
  the same diff. The VALUE mutation was re-derived independently in review — re-pointing
  `--ring-hsl` at the primary channel reds `emit --check` and `check.mjs DRIFT`, which the in-place
  home provably could not do. Dark evergreen MOVES (unowned drift corrected); D76's contrast
  assertion is NOT claimed.
- **cch-bl-overview-subscription-band-stale** → `…-l-3-r` (#6541, 1 review fix). The fifth
  `live-dot` state, `refresh_failed` / "Not current", with the "as of" suppressed — the console
  stops certifying freshness it lacks — plus the subscription band's missing `overview` arm. Review
  scoped the claim: `refreshStale` is set only by `loadOverview`, so an un-scoped chip disclaimed
  currency on **Fleet**, a view that had just fetched successfully. A new lie wearing the fix for an
  old one, now `currentView() === "overview"`-gated and pinned.
- **gr-bl-predicate-null-successor-silent-seal** → `…-unr-4-r` (#6542, 1 review fix). Four
  refusals before any clause runs, grip's exit triad ported, and the instrument's FIRST tests — 11
  over 4 committed fixtures, all 10 originals verified RED against the pre-fix copy. Review closed
  the `--guard-cmd` hole the builder named and could not file (mutate was down): the override is
  now REFUSED without `--ledger`, so the live run cannot substitute a stub for the browser guard.

**Cross-slice**: three slices share `app.js`, three share `app.css`, three share `__app.test.mjs`.
All five merge sequentially with **zero conflicts**, and the integrated tree is green on every
gate (710/710 node, 386/0 elixir, `check.mjs` PASS, `emit --check` 19/19, `__css_check` 0 errors,
seal 11/11, design 66/66). No shared helper was duplicated and no two slices contradict each other
in copy or state.

**Ledger**: clean on everything that matters, with two corrections. Five tasks `in_progress` and
published, every provable criterion stamped with real evidence as the builders worked, every
merge-gated criterion left open for the lead, and the epic roster shows exactly those five in
flight — no foreign row was touched. But two builder claims had LAPSED by the end of Review
(`cch-bl-overview-subscription-band-stale`, `gr-bl-predicate-null-successor-silent-seal`), each
leaving a now-line reading "Not pushed" over work that is now pushed and PR'd — our own board
telling a small version of the lie this epic exists to remove. Both were re-claimed as
`wave-reviewer-cch-w6` and corrected. **Lead consequence**: those two hold a REVIEWER claim, not the
builder's, so their merge-gated close needs `wave-reviewer-cch-w6` at the CURRENT epoch — read it
from `bp task get`, never from a remembered number.

**Server defect, isolated during Review and recorded because it will cost the next wave the same**:
on `guerrilla`, **creating a `task` document fails every time** — 500 or client timeout on
`POST /v1/data/mutate`, reproduced with a four-field minimal task doc, so it is not payload size.
Everything else on that endpoint is healthy: PATCHING an existing task (the epic heartbeat landed
fine), patching and publishing the wave Paper, `bp task pulse`, `bp task stamp` and every read all
return in well under a second. Two builders hit the same wall mid-run — one lost two criterion
stamps and re-stamped after verifying STATE, one could not file a follow-up at all — and both read
it as flaky rather than isolating it. Consequence for the board: **four real follow-ups this wave
surfaced are named in the debrief Paper instead of filed as rows.** The next wave files them the
moment task create recovers and must not read their absence as an oversight. (Separate and
self-inflicted, worth the line: several early `bp doc mutate` calls returned `malformed` because
the patch payload omitted the required `type` key — `docs/api-v1.md` §6 documents it; that was not
the outage.)

**Next wave takes**, in this order: (1) merge round 1 — no inter-slice deps, but land #6539's
migration with its deploy; (2) `cch-bl-seal-predicate-retarget-and-reparent` plus the actual
re-parenting D83 demands, because the predicate is now honest and the successor is filed, so this
is the wave that can genuinely move the seal; (3) the two operator-truth rows this wave did not
reach — `gr-backlog-e02-deploy-actor` and `gr-blk-vercel-checks-ungoverned`, the latter still
reddening every PR repo-wide and governed by nobody, which standing law 7 already says must be
LANDED as a sentence rather than asserted; (4) FILE the four follow-ups the Paper names and task
create could not — 2FA origin granularity, refresh-staleness beyond the Overview, the
`.form-input:focus` channel, and the provider identity-echo mitigation (promoted).
Held for a Fable-available wave: D73's `--ok`/`--danger` hue question and D76's focus-ring contrast
engine — both open-ended aesthetic judgment, which is exactly the category this wave deferred.

### 2026-07-28 — wave 6 DECIDE (build in flight)

The thesis survived; most of its detail did not. Direction: **the console stops lying to its
OPERATOR** — five consecutive instrument waves left the user-facing lies untouched, and wave 5's own
review said to triage those next. Confirmed and about twice its apparent size: the providers card
still instructs a human to destroy a working cloud credential, nine days after the server shipped safe
one-step rotation, and it is held by THREE client pins whose NAMES encode the false rationale, so the
slice rewrites a specification (D77). Session provenance came in CHEAPER than feared — all six write
sites funnel through one function, the set is closed, and its one silent-failure mode is now a test
that reds on command (D79).

**Three of four slice framings were refuted, and one slice was CUT.** The `--ok`/`--danger` invariant
would have been a vacuous green over a hue the destroy button does not wear, inside a generated region
a hand edit cannot touch, and its only working fix reverses a written GR90 ruling made after a
~1,585-shot accent matrix — so it is rewritten and deferred to a Fable-available wave (D73), which is
exactly the wish's own instruction about open-ended aesthetics. `--ring-soft` was aimed at the right
token but the wrong home: the cheap in-place fix is provably vacuous (an AMBER focus ring passes all
three gates) and silently reskins evergreen, so it is PROMOTED into the emitter, where re-hardcoding
one identity reds the fence (D74) — and the diff must carry the exemptions baseline 33→31 or the
ratchet fires on the good direction (D75). A fifth candidate arrived from the survey and is sharper
than two of the originals: the Overview **certifies freshness it lacks** — the liveness chip repaints
to "Live · just now" at the instant a failed background refetch freezes the dashboard, because the SSE
frame that dispatched it advanced `lastEventMs` first (D81).

Two reflexive catches, both the epic's own predicate turned on itself: the planned Movement-0 close of
`cch-bl-get-census-rederive` on the "subsumed by #5434" rationale is **unsupported** — that PR shipped
no classifier, and the row's criterion demands one (D82); and the seal predicate **silently seals with
a null successor at exit 0, printing "to null"**, precisely when there are zero live rows — the one run
anybody quotes — while naming a successor does NOT clear clause (a) at all, because forwarding means
membership in the successor's ROSTER (D83/D84). Next wave files the successor, so that predicate is
fixed this wave or the epic's first seal is manufactured.

Five round-1 opus slices, two flagged HIGH-FLIP-RISK. Movement 2 ratifies deploy-actor as
trigger-only permanently, on measured grounds (the join can attribute at most 2 of 5 creation paths).
Fable unavailable — every slice opus. Paper: `cloud-console-hardening-wave-6-2026-07-28`.

### 2026-07-21 — wave 5 DECIDE (build in flight)

Wave 4 died at Digest (spend limit) carrying too much — the full D41 sweep PLUS the reflexive-registry
capstone PLUS triage. Wave 5 re-weights toward FINISHING: the D41 sweep is the spine, but every
payment doubles as a close (D63), the capstone is FILED not carried (D68), and the wave opens on the
one concrete blocker wave 4 never faced — which evaporated on contact: **`#5434` was never stranded,
it is MERGED** (`a7b5284c4` on main, clause at `router.ex:546`), and `main` has no branch protection,
so Movement 0 is a provenance stamp, not a build (D64). Verification refuted three "build" candidates
as already-enforced triage-closes (D69 — the D49 "IF #5438's comment is unenforced prose" conditional
is FALSE, its comment IS paired to mutation-proven tests) and moved two "reflexive" candidates
off-fence/off-mechanical to backlog (D70). Five round-1 opus slices filed, all file-disjoint, each a
boundary + a machine check keyed to its type + a mutation-proof it can fail: the cssom exact-match
sidecar ratchet (D65), the per-declaration paint fence that catches the sibling-line miss the current
substring fence sails over (D66), the ban-the-shape citation-drift gate (D67 — every live citation is
wrong TODAY), the standing emit-fence regression test (reflexive D40 gap), and the REPLACED-claim
fence paying D52's residue (D70). Movement 2's honest verdict: **NOT YET SEALABLE** (D72) — no seal
predicate exists for this epic, 50 `cch-*` rows are unbanded, and a named successor must be filed next
wave to forward genuine residue. Model constraint: `opus` on every slice (Fable 5 spend-limited).
Paper: `cloud-console-hardening-wave-5-2026-07-21`.


### 2026-07-21 — wave 5 REVIEW (five boundaries paid, grade A-)

Fresh wave after wave 4 died at Digest. Thesis: pay D41 (a coverage boundary must be MACHINE-CHECKED,
a comment is not a tripwire) across five documented-but-unenforced fences. All five built on opus,
all round 1, file-disjoint, **all green and mutation-proven**, reviewed and re-gated on the review
worktree with **zero fixes needed**:

- **cch-bl-cssom-floor-decays-as-css-grows** — static `MIN_AUTHORED_HEADS=1201` floor (which a
  2-rule swallow already sailed over at 1203) → committed `cssom-heads.baseline` asserted with
  EQUALITY; permanent committed proof (`fixtures/cssom-floor/proof.sh`, green=0 red=1). Gate re-ran
  green (1203==1203, MISSES 0).
- **cch-bl-state-rule-per-declaration-gate** — selector-prefix fence → per-declaration probe (test
  314) asserting each state's `.live-dot` block declares a `background`. Gate 662/662; mutation reds
  exactly the new probe. Residual: passes `background:transparent` (documented).
- **cch-bl-source-citation-line-drift** — E11 bans the `app.js:<digits>` citation SHAPE (bp-honest-
  gates D5) + re-anchored every live drift to function names. Gate 0 errors; mutation reds naming the
  citation. Cross-language `router.ex:<line>` cites are OUT (follow-up `cch-bl-citation-drift-cross-language`).
- **cch-w1-emit-fence-regression-test** — the live `emit --write` attribution fence gets its first
  test (real-CLI-against-throwaway-tree), wired into `doc-gates.yml`. 5/5 + `check.mjs` PASS; mutation
  reds the two REFUSE tests.
- **cch-w3-claim-overwrite-fence** — D52 residue: `ensure_claim_not_dropped/4` predicate `not is_nil(now)`
  → `now == was`, refusing claim SUBSTITUTION (theft-by-overwrite) at the mutate door. Compiled + gated
  green in-worktree (36/0), `mix format` clean; mutation reds the substitution tests. **Lead: cch-w3
  WAITS for the CI Elixir Test gate before merge (full suite not run locally, OOM).**

Ledger fully honest: every task `in_progress`, published, all provable criteria stamped, only the
explicit MERGE-GATED row left open for the lead. **Process gap (not code):** the wave Paper was never
opened mid-flight — the Reviewer created `cloud-console-hardening-wave-5-2026-07-21` at close as the
debrief. Epic **NOT yet sealable** (~110 open children). Next wave: land these five, then triage the
remaining LIVE claim/reality divergences (HEAD-burns-a-live-ticket, the `172.18.0.1` session-IP lie,
the rate-limiter single-user lie) over further instrument hardening; pick up `cch-bl-citation-drift-cross-language`.
### 2026-07-21 — wave 3 DECIDE (build in flight)

**The charter itself was the wave's first finding (D60).** Every verifier reported this file missing;
it was on `origin/main` at D24 while D25-D40 sat in an unpushed local commit, and the shared checkout
was 46 commits behind on another epic's charter commit. The epic's predicate turned on the epic's
memory. This commit is branched from `origin/main` and pushed so D25-D62 finally exist where builders
look.

Act 1's premise moved twice under the wave: zero PRs → one → **all four open and merge-ready**
(D58). The HEAD-burns-ticket defect went from a code reading to a **run** — 422 + `revoked_at`
stamped + the legitimate GET 401'd, closed by one clause, mutation-killed both directions, 2188
tests 0 failures (D42) — and its severity was correctly re-argued from **provenance, not CVSS**
(D43): nothing on earth HEADs this console, but it is an accepted risk (D13) that fired inside the
wave that accepted it. Four filed criteria were refuted by measurement and rewritten rather than
built: the tripwire's Repo-write population is **empty** (D44), AST buys **zero** accuracy over
corrected regex (D45), `62` is a second correct population rather than a phantom (D46), the 45-floor
does **not** drop to 44 (D47), and `replace`'s `with`-chain must **not** be touched — the probe the
brief asked for silently converts `replace` into an upsert with zero test coverage (D50). D52 is the
sharpest: **D37's own claim that the patch door is claim-safe is false**, with three siblings
measured open. D41 completes D40 by *citing* `bp-honest-gates` D1/D5/D11 instead of re-minting a law
the repo already has. Six slices filed, all round 1, all file-disjoint, all opus.
Paper: `cloud-console-hardening-wave-3-2026-07-21`.

### 2026-07-21 — wave 2 DECIDE (build in flight)

Wave 1's ledger claimed five slices shipped; content said two. The epic's triage predicate turned on
the epic. D25 retires wave 1's serialization (proven by an actual clean merge, not line arithmetic);
D26 corrects the joint-defect fence from "the mint is a POST" to "the mint PATH has no GET route"
(refuted by `HEAD /v1/tokens` → 401, not 404); D28-D29 refuse the consume template wave 1 prescribed
(sibling-wide — a two-tab eviction storm); D31-D33 widen the SSE fence to `app.css` and the test hook
because the fourth chip state would otherwise paint **calmer than reconnecting** with a fully green
board; D34 retires the `~36` HEAD figure for a measured **45**; D40 narrows the proposed sibling-class
law to enforcement mechanisms, because stating it universally would force false evidence onto two
slices. Six slices filed, four in round 1. Paper: `cloud-console-hardening-wave-2-2026-07-21`.
