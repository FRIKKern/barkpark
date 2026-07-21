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
   returns foreign rows with a 200 (re-proved 2026-07-21: 11-way-foreign parents in a 15-row page) —
   never source a roster from it. Use `bp task get <epic> -o json` → `.children` for the roster, and
   a per-row `bp task get <id>` for evidence. `.children` carries no `updated_at`/`closed_at`, so it
   cannot answer close-time questions. `bp task ls` has no `--parent` flag.
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

**Out of fence, hands off:** `tooling/grip/` (truth-grip wave 4 running), `scripts/pds-*` and
`api/lib/barkpark/tenancy/` (PDS wave 14 running).

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
`cloud/priv/static/app.js`. Sequencing is file-truth, not doubt about the work.

### Wave 2 candidates (filed, not built)

The revoke-harness gap and the inert smoke click are **one deliverable** — a click oracle scoped to
the six dangerous buttons satisfies both rows' criteria. Also queued: the epoch-only close fence
(the CAS path is itself stealable — worker id is never compared), the header-borne OAuth token
redesign, `cssom-parity` hardening (fatal COUNT SKEW + multi-stylesheet), and the ~42 Bands 1/3/6
rows still at census-grade L4 confidence.

## Wave log

<!-- one entry per wave: date, slices shipped, grade, what the next wave must know -->

### Wave 2026-07-21 (1) — round 1 built and reviewed, grade A−

First wave against the successor. Six round-1 slices built, all six green, all six reviewed. Rounds
2 and 3 (`cch-w2-head-sideeffect-fence`, `cch-w3-sse-ticket`) were **not** built — deferred by the
sequenced-rounds law, not stalled.

| Slice | Final branch | Reviewer verdict |
|---|---|---|
| `cch-w1-refetch-storm` | `…/overview-stops-refetching-everything-sco-0-r` | 40→12 requests, mutation-proved. Reviewer cleared the per-account `overviewData` snapshot on sign-out. |
| `cch-w1-peer-ip-pin` | `…/the-console-stops-telling-every-user-the-1-r` | D5/D6/D7 all honoured; the `{172,18,0,77}` anti-widening test is the deliverable. Reviewer made nil config fail closed and wrote the deploy step into the compose file. |
| `cch-w1-cssom-ci-wiring` | `…/wire-cssom-parity-into-ci-as-a-node-22-j-2` (PR #5290) | Job green on the real runner; D20 floor re-mutation-proved by the reviewer (1201→1188, MISSES 0, exit 1). No fixes needed. |
| `cch-w1-emit-marker-fence` | `…/emit-mjs-write-stops-silently-deleting-h-3-r` | Fence refuses and names the lines, on both artifact classes. Reviewer added `check.mjs` Part I so the fence's own predicates can red the gate. |
| `cch-w1-ledger-close-guard` | `…/close-the-ledger-s-back-door-v1-data-mut-4-r` | Both patch clauses fenced per D22. Reviewer added a behavioural tripwire pinning the copied terminal set to `close.ex`'s own list. |
| `cch-w1-census-disposition` | none (ledger-only by design) | 6 rows evidence-closed; three brief claims measured WRONG. |

**Grade: A−.** Every slice mutation-proved its own gate before claiming green, and every builder
volunteered its own blind spots unprompted. Held back from A by two things: the peer-IP fix is
unproven above unit level and needs a one-time operator step before it can be proven at all, and
four of five branches arrived unpushed because the spawn prompt and the task brief gave opposite
push instructions.

**Three things the next wave must carry.**

1. **LAW 3 HAS A COUNTEREXAMPLE — amend your priors.** The charter says census staleness is always
   in the safe direction (rows more done than claimed). `cch-w1-census-disposition` found the
   opposite on `gr-backlog-provider-reconnect`: the DB half shipped while `app.js:1959-1964` still
   asserts "no unique index, no 409", so the census claimed MORE done than reality. Three of the
   fourteen rows that pass named were mis-stated — roughly one in four. Treat the untouched ~55
   Band 1/3/6 rows as unreliable in **both** directions.
2. **THE PUSH INSTRUCTION MUST BE SINGULAR.** Four of five builders held their branches because the
   spawn prompt said "do not push" while the task brief said "push and open a PR". Every one of them
   flagged it, correctly, and every one chose the restrictive reading. The reviewer pushed all four
   `-r` branches. Fix the prompt, not the builders.
3. **`bp doc create` NESTS UNDER `content` AND THE CLI SWALLOWS THE WALL'S `details`.** A publish
   rejection reports only "label spine" with a generic hint; the actual rule ("a rationale must be
   at least 20 characters") is present **only** in the `details` object returned by
   `POST /v1/data/mutate` over HTTP. Two builders lost time to this; so did the reviewer. File rows
   over HTTP with the flat fields inside `content`, and read `details` from the raw response.

**Next wave takes round 2 then round 3, in dependency order** — `cch-w2-head-sideeffect-fence`
rebased onto the merged peer-IP pin, then `cch-w3-sse-ticket` rebased onto both that and the merged
refetch slice. Alongside them: the epoch-only close fence (the CAS escape this wave shipped is not
authorization — anyone who can read a task can still close it), `cch-w2-ledger-close-guard-create-ops`
(the `createOrReplace` door is still open), and `cch-hg-compose-network-recreation`, which gates the
only production proof the peer-IP pin can ever get.
