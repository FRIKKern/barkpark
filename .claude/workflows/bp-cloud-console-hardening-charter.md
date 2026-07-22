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
| `cch-w1-refetch-storm` | shipped | **NOT LANDED** | no `OVERVIEW_FLEET` on main. Open `#5308`. |

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
epic has **91** children (85 open / 6 done). Do not size a slice against the old figure.

## Wave log

<!-- one entry per wave: date, slices shipped, grade, what the next wave must know -->

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
Paper: `cloud-console-hardening-wave-5-2026-07-21`.

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
