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
| D58 | **Act 1 is a MERGE QUEUE, not a rebase, and the branches were never literally rebased** | The direction and the first surveyor both measured zero remote branches and zero PRs; a live re-read found **all four pushed with OPEN PRs** (#5377 SSE ticket `-r`, #5378 HEAD fence, #5379 click oracle `-r`, #5380 gate ledger), all `mergeable=MERGEABLE`, every blocking gate SUCCESS including the `Test (Elixir 1.18.1 / OTP 27.0)` gate the digest called the sole blocker. `main` carries **no branch protection and no rulesets** (404 "Branch not protected"), so `UNSTABLE` gates nothing — it is the three known-advisory reds (Format, which `main` itself fails; Sobelow, `continue-on-error` at `security.yml:55`; Vercel ×2, repo-wide). But `git merge-base` for all four is **3bbd5637d, 11 commits behind** — they were never rebased; each tip is a trivial re-fire commit. They merge and test clean only because GitHub's `pull_request` CI checks out the **ephemeral merge commit** and `mergeable` is recomputed live. Record it: a future PR touching `router.ex`/`app.js`/`mutations.ex` before these land could still surface a conflict a genuine rebase would have caught earlier. **`integ-check` was never pushed and must not be landed** — its graph carried FIVE merges including both the superseded non-`-r` click oracle and its `-r` replacement. |
| D59 | **Remote and ledger state in this checkout is POINT-IN-TIME. Re-read immediately before every mutating call — including from this charter** | Three honest reports contradicted each other on the same facts within one hour, each correct at its timestamp: PRs went zero → one → four; claims went live → lapsed-to-null → re-claimed by `steward-resume` at 09:06:29Z with epochs 9/7/8/7. `main` advanced twice mid-verification under an unrelated PDS cycle. No epoch quoted anywhere — including in this charter — may be reused; re-fetch before `stamp`/`close`. A foreign targeted claim on a live `in_progress` task 409s `not_ready` (lease TTL 2700s), so the lead either acts as the holding worker or waits out the lease. |
| D60 | **THE CHARTER ITSELF WAS INVISIBLE — D25-D40 never reached `origin/main`. Fixed by this commit** | Every wave-3 verifier independently reported `.claude/workflows/bp-cloud-console-hardening-charter.md` **DOES NOT EXIST**, and one concluded "every downstream reference to that path is unresolvable." The truth is worse and more instructive: the file **is** on `origin/main` — but only the **D1-D24** version (`#5289`). D25-D40 live solely in local commit `ac1fb3beb`, which `git merge-base --is-ancestor … origin/main` reports **NOT an ancestor**. The primary checkout's local `main` was **46 commits behind origin** and sitting on a *different* epic's uncommitted charter commit, so `ls` there answered for a tree nobody builds from. This is the epic's own predicate turned on its own memory: the ledger said the charter existed; `origin/main` said it stopped at D24. **A charter commit that is not PUSHED is invisible to every builder.** From now on the Decide charter commit is branched from `origin/main`, pushed, and PR'd — never committed to the shared local `main`. |
| D61 | **Retire `cch-w2-pr-task-gate-backtick-trailer` as a duplicate of `cch-bl-pr-task-gate-backtick-regex`** | Same defect, same file, same prescribed fix, filed 12 minutes apart by authors who did not find each other. Keep the earlier row — it is grounded in a measured CI failure with a citation (PR #5290 backtick-wrapped id RED vs #5307 unwrapped GREEN, run 29804094521). Port the later row's stronger criterion ("the test case is shown to FAIL against the pre-fix script before passing after it") onto the survivor before closing the duplicate. The bug reproduces exactly against the real regex (`.github/workflows/pr-task-gate.yml:142`): the plain trailer matches, `Task: \`slug\`` produces **NO MATCH**. |
| D62 | **Gate commands must be dry-run from a worktree cut off `origin/main`, never from the primary checkout** | Wave 3 nearly filed a false gate on this. `node cloud/priv/static/__css_check.mjs` **FAILS** in the primary checkout (`E10 app.css:1034 orphan '*/'` + an E2 miss) and **passes clean (0 errors)** in a worktree at `origin/main` — because that checkout is 46 commits behind and carries another session's state. Same class as D60. Every gate in this charter's wave plan was dry-run in an `origin/main` worktree: `__app.test.mjs` 640/640, `smoke.mjs` 86/86, `__css_check` 0 errors, `scripts/pr-task-gate.test.sh` 20/20, and both targeted `mix test` forms green. |
| D63 | **Wave 5 pays D41 across the epic's documented-but-unenforced boundaries, and every payment DOUBLES as a close** | The theme is D41, so the sweep is the spine; the wave-5 unlocking insight is that *every filed boundary in this epic is also a backlog row*, so paying D41 where a row is filed makes hardening and shrinking the SAME motion. Each Movement-1 slice = boundary comment + a machine check keyed to its type + a mutation-proof it can fail, and closes its own backlog row on merge. Finishing beats eleganza this wave (wave 4 died at Digest carrying too much); the reflexive-registry capstone is FILED, not built (D68). |
| D64 | **`#5434` was never stranded — it is MERGED, and Movement 0 is a provenance-honesty STAMP, not a build** | Confirmed by content: `a7b5284c4` is an ancestor of `origin/main`, `side_effecting_get?(["v1","events"]), do: true` at `router.ex:546`, plus `router_head_fence_census_test.exs` + `router_sse_ticket_head_burn_test.exs` both on main. It never blocked anything: `main` has **no branch protection** (`gh api …/branches/main/protection` → 404), and `pr-task-gate` is advisory. The red gate was real (the PR trailer cites a phantom slug `cch-bl-sse-ticket-head-burn`, 404 in the ledger) but toothless. The real row is `cch-bl-head-denylist-tripwire` (#5376) — already flipped `done` mid-session by `steward-land` but its final MERGE-GATED criterion is evidence-empty. Movement 0: stamp that criterion with `a7b5284c4`, evidence-close `cch-bl-get-census-rederive` (subsumed, per that row's own instruction), and **cancel `task-2200bea3796a4e84`** as a duplicate stub (filed 3h after the real row, 0/4, unclaimed). |
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

## Roadmap

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
