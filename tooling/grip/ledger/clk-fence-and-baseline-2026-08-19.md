# clock-semantics wave — fence correction + attributable baselines (2026-08-19)

Verifier lane `fence-and-baseline`. Pin: `origin/main` = `1f981ec42d837a46de228283d4c6d8762ba38988`.
Every row below re-derives from that sha. No fixes here; this row exists so a builder's red is attributable.

## 0. THE BASELINE TRAP — the primary checkout is NOT origin/main

    git rev-parse HEAD origin/main
    git rev-list --count HEAD..origin/main          # -> 19
    git diff --name-only HEAD origin/main -- api/lib cloud/lib

`/Volumes/SATECHI/github/barkpark` sat **19 commits behind** origin/main, and the gap contains the
three files this wave cites as its motivating precedent:
`api/lib/barkpark/rate_limiter.ex`, `cloud/lib/barkpark_cloud/accounts/two_factor_rate_limiter.ex`,
`cloud/lib/barkpark_cloud/device_auth/rate_limiter.ex`, plus a new
`cloud/test/barkpark_cloud/sweep_bound_reset_test.exs`.
A `mix test` run in the primary checkout is therefore a baseline of a tree WITHOUT #12579/#12628.
Baselines must be taken in a worktree detached at origin/main. api/ and cloud/ were otherwise
clean (`git status --porcelain -- api/ cloud/` -> 0 lines), so the other session's uncommitted work
is entirely outside this wave's fence.

    git worktree add --detach <path> origin/main    # detached: moves no branch, safe under concurrency

## 1. THE `cc` TRAP — a fresh worktree cannot compile either project until CC is set

Both mix projects have a C-NIF dependency (`argon2_elixir` in api, `bcrypt_elixir` in cloud).
In this environment `cc` resolves to the Claude CLI wrapper, which rejects the compiler flags:

    cc -g -O3 ... -o .../argon2_nif.so
    error: unknown option '-g'
    make: *** [.../argon2_nif.so] Error 1
    ** (Mix) Could not compile with "make" (exit status: 2).

Fix, required in EVERY builder worktree before any `mix` invocation:

    export CC=/usr/bin/clang

## 2. SETUP CONTRACT — api has a `test` alias, cloud does NOT

    sed -n '/defp aliases/,/^  end/p' api/mix.exs      # test: ["ecto.create --quiet","ecto.migrate --quiet","test"]
    sed -n '/defp aliases/,/^  end/p' cloud/mix.exs     # setup/ecto.setup/ecto.reset ONLY — no `test`

So in cloud, `mix ecto.create && mix ecto.migrate` must run before `mix test`, or the run dies with a
DB error that looks like a code failure. Both projects interpolate `MIX_TEST_PARTITION` into the
database name (`barkpark_test#{...}`, `barkpark_cloud_test#{...}`) — set a session-scoped partition
so concurrent sessions do not share a test DB.

## 3. BASELINES (worktree at 1f981ec42d, MIX_TEST_PARTITION=_cs19, CC=/usr/bin/clang) — ALL GREEN

| suite set | command | result |
|---|---|---|
| api session_pages + accounts + webhooks/ + paper_revision_headers | `cd api && mix test test/barkpark_web/controllers/session_pages_test.exs test/barkpark/accounts_test.exs test/barkpark/webhooks/ test/barkpark_web/plugs/paper_revision_headers_test.exs` | `181 tests, 0 failures` |
| api MFA family | `cd api && mix test test/barkpark_web/controllers/session_controller_test.exs test/barkpark_web/controllers/org_require_mfa_test.exs test/barkpark/tenancy_org_require_mfa_test.exs` | `27 tests, 0 failures` |
| api github | `cd api && mix test test/barkpark_web/plugs/github_webhook_signature_test.exs test/barkpark_web/controllers/github_webhook_{controller,integration,adopt_controller,status_controller}_test.exs test/barkpark/plugins/github_test.exs` | `67 tests, 0 failures` |
| cloud sites_deploy + receiver + sweep_bound_reset | `cd cloud && mix ecto.create && mix ecto.migrate && mix test test/barkpark_cloud/sites_deploy_test.exs test/barkpark_cloud/sites/content_publish_receiver_test.exs test/barkpark_cloud/sweep_bound_reset_test.exs` | `106 tests, 0 failures` |

There are NO api test files matching `*user_session*`, `*two_factor*` or `*mfa*` beyond the three above
(`find api/test -iname ...`) — the MFA-family slice has no dedicated `UserSession` suite to extend.

api excludes these tags by default, so a proof carrying one of them silently does not run:
`[:bokbasen_integration, :phase8_demo, :requires_wi3, :requires_wi4, :flaky, :boot_test, :plugin_routes, :requires_vips, :idp_interop, :real_binary]`

## 4. FENCE CORRECTION — the declared exclusion list is blind to five files

The previous open-PR sweep used `--limit 60` and returned exactly 60. There are **68** open PRs, so it
truncated. Re-derive with a limit above that:

    gh pr list --state open --limit 200 --json number,title,files \
      -q '.[] | .number as $n | .files[].path | "\($n) \(.)"' | grep -E ' (api|cloud)/lib/'

Inside this wave's `api/lib/**` + `cloud/lib/**` fence, owned by an OPEN PR — add as
fence-excluded-and-CITED:

| file | open PR(s) | clock reads on origin/main | class |
|---|---|---|---|
| `api/lib/barkpark_web/request_stats.ex` | #12630 | `:196` `:398` `:448` monotonic; `:444` `DateTime.utc_now` display stamp | B done right + display |
| `api/lib/barkpark_web/controllers/tasks_controller.ex` | **#12629 AND #12526** | `:1304` `:1333` monotonic deadline / graph-slot TTL | B done right |
| `api/lib/barkpark/sharing/links.ex` | #12404 (**also in the 19-commit gap**) | `:54` `expires_at = utc_now + ttl`; `:86` `now` vs stored `l.expires_at`; `:117` `revoked_at` stamp | **A** (all three) |
| `api/lib/barkpark_web/controllers/share_link_controller.ex` | #12404 (also in gap) | none | — |
| `api/lib/barkpark/content/writer.ex` | #8465 | `:448` `:451` `Date.utc_today` dynamics; `:1222` `updated_at` stamp | A / display |

`tasks_controller.ex` has TWO concurrent owners — treat as hard-excluded.
Zero clock reads in the other PR-owned fence files checked: `oidc_controller.ex`, `saml_controller.ex`,
`social_controller.ex` (#12528), `auth_controller.ex` (#9530), `listen_controller.ex` (#12531),
`stuck_processing_sweeper.ex` / `plugins/media.ex` (#12464), `host_vitals/sampler.ex` (#2907),
`blobstore/s3.ex` (#12462), `renditions.ex` (#12463), `item_share.ex` (#12404), `bulldocs_live.ex` (#12380).
`search_controller.ex` (#9600) has only the `t0` monotonic telemetry idiom (`:38` `:67` `:96` `:117`).

## 5. AMBER SET — CLEARED

    git grep -nE 'System\.(system_time|os_time)|:os\.system_time|DateTime\.utc_now|NaiveDateTime\.utc_now|monotonic_time|Date\.utc_today' \
      origin/main -- cloud/lib/barkpark_cloud/web/auth.ex cloud/lib/barkpark_cloud/deploy_ledger.ex \
      cloud/lib/barkpark_cloud/accounts/authz.ex cloud/lib/barkpark_cloud/accounts/team_membership.ex

One hit, and it is PROSE: `deploy_ledger.ex:2042`, a comment inside `delivery/3` explaining why the
`:as_of` default was moved off `DateTime.utc_now()` onto the window's pinned edge `to`. `auth.ex`
(#9956) and `authz.ex` (#10154) — the highest-risk names in the amber set — contain **zero** clock
reads. Nothing to classify. `delivery/3`'s `:as_of` opt is a caller-supplied time, but it renders an
envelope stamp and bounds nothing: drop as display.

## 6. PATH CORRECTIONS for the caller-supplied-time ledger rows

The brief's shallower paths do not exist (`git ls-tree origin/main api/lib/barkpark/tenancy/`).
The real sites are one directory deeper:

| corrected path:line | text |
|---|---|
| `api/lib/barkpark/tenancy/workspace_bundle/janitor.ex:214` | `now = Keyword.get(opts, :now) \|\| System.os_time(:second)` |
| `api/lib/barkpark/tenancy/workspace_bundle/janitor.ex:273` | `{:ok, %File.Stat{mtime: mtime}} -> now - mtime > max_age` |
| `api/lib/barkpark/tenancy/workspace_bundle/archive.ex:121` | `mtime = Keyword.get(opts, :mtime, :os.system_time(:second))` |

`janitor.ex:273` compares a wall clock against a filesystem mtime — a STORED instant — so the
abandonment bound is **class A**, not B. Its `:now` opt has ZERO production callers: the only two
`Janitor.sweep` call sites in the tree are tests, and the module reaches production solely as a
supervised child (`api/lib/barkpark/application.ex:196`), arity-short on `:now`. `Archive.pack`'s one
production caller (`workspace_bundle.ex:645`) passes `dir:` only, arity-short on `:mtime`. Both
confirm the digest's refutation of the time-as-input thread.

## 7. THE tenancy/ DIRECTORY FENCE OVER-EXCLUDES 13 OF 14 FILES

    git ls-tree -r --name-only origin/main api/lib/barkpark/tenancy/ | wc -l    # -> 14

#12616 owns exactly ONE of them, `api/lib/barkpark/tenancy/auth.ex`. Excluding the whole directory
therefore fences off 13 uncontested files, `janitor.ex` and `archive.ex` among them. Narrowing the
exclusion from `api/lib/barkpark/tenancy/` to `api/lib/barkpark/tenancy/auth.ex` brings both
caller-supplied-time sites into scope at **zero collision cost** — no open PR touches any tenancy file
other than `auth.ex`. Given §6 (class A, no request-reachable `:now`), the value of narrowing is
completeness of the ledger, not a fix.

## 8. THE CITED-SAFE PRECEDENT — quote #12630's shape, do not re-derive it

    gh pr diff 12630

A 57-line comment above the telemetry handler in `request_stats.ex`, zero behavioural change. Its
transferable structure, in order:
1. Header naming the verdict, the wave, and the date, plus `Read this before re-deriving it.`
2. The candidate's provenance — which defect it was swept as a sibling of, and that defect's shape.
3. Ground **(a) STRUCTURAL** — why it is not that shape "before any argument about consequences".
4. Ground **(b) CONSUMER CENSUS** — every reader enumerated, in-tree AND off-box, ending in the
   negative grep that proves the enumeration closed (`grep -rn over_at cloud/lib` -> zero).
5. A complement offered "rather than an assertion", naming the residual hazard in the safe direction.
6. `WHAT THIS VERDICT DOES NOT REST ON` — explicitly disclaiming the earlier Felix "already-good"
   stamp, because that same reading was OVERTURNED for `Barkpark.RateLimiter`.

Item 6 is the load-bearing one for this wave: a prior green stamp is not evidence.

## 9. PRIOR ART ALREADY FILED BY THIS WAVE — two digest claims need amending

    bp search query "clock semantics monotonic wall clock bucket key"

The wave paper `clock-semantics-wave-2026-08-19` ("Most of these clocks are right") and four
`clk-bl-*` tasks already exist under parent `api-controller-plug-correctness-audit`:

- `clk-bl-cloud-health-serving-since-is-boot-local` — **amends the digest's "the inverse error does
  NOT exist".** It does: `cloud/lib/barkpark_cloud/health.ex:120-132` converts a boot-local
  monotonic quantity into a wall-clock `DateTime` and publishes it anonymously as `serving_since`;
  its own D417 moduledoc records the value moving FORWARD 6.4s across two back-to-back BEAMs.
  Cited residual — a monitoring gauge, no bound.
- `clk-bl-synonyms-week-key-misaligns-with-crystallizer` — a second quantisation misalignment
  (`synonyms.ex:200/:342` `Date.add(utc_today, -7)` vs `intelligence.ex:1080`
  `beginning_of_week(:monday) |> Date.add(-7)`; they agree only on Mondays). Filed explicitly as a
  correctness bug, NOT class C, so the "ONE class-C site outside the fence" count survives.
- `clk-bl-etag-bucket-constant-duplicated-in-test`, `clk-bl-idempotency-preview-token-sweeps-have-no-caller`.

Note the parent is the epic whose charter is UNTRACKED on origin/main — do not cite a D-number from it.

## 10. LEAD-SLICE SOURCE PINNED (classification is Decide's call, not this lane's)

    git show origin/main:api/lib/barkpark_web/controllers/session_controller.ex | sed -n '340,350p'

    def mfa(conn, params) do
      ...
      at = get_session(conn, "studio_mfa_at")
      fresh? =
        is_integer(at) and System.system_time(:second) - at <= 300

`at` is read from the signed session cookie, i.e. a stored instant transmitted from an earlier
request. That is the arithmetic the two surveyors used to refuse "class B", and the text confirms
their reading: the site is an absolute-instant comparison that is one-sided. Sidedness is orthogonal
to A/B/C/D.
