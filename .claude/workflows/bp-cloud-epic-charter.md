# HTTP controller + plug correctness epic — charter

Epic task: `api-controller-plug-correctness-audit` · wave Paper: `web-glue-robustness-wave-2026-08-18`
Pinned tree for wave 1: `origin/main` @ `cd75286b72d08e439adccf7a338e5c8e8e607641`

## Vision

The HTTP glue layer — 80 controllers and 49 plugs under `api/lib/barkpark_web/controllers`
and `api/lib/barkpark_web/plugs` — is where edge-case bugs hide: a param that arrives as a
list instead of a string, a status code that says 200 when the row was never found, a plug
that answers without halting, an error branch nobody wrote. This epic is an
improvement-only, evidence-first correctness ledger over that layer. Every candidate is
either a REAL defect carrying its concrete failing request (method + path + params → wrong
status or 500) and a conn test that reds without the fix, or a SAFE pattern cited by the
specific guard that makes it safe. The honest per-class count — stated even where it is
zero — is the deliverable, not a fix quota. This is a robustness lens, never a second pass
over the merged content-plane security campaign.

## Decisions

- **D1. The verdict is the deliverable; a cited zero outranks a manufactured fix.** Fourteen
  of sixteen survey lanes came back a swept zero with a NAMED guard (`Repo.uuid_or_nil` on
  every binary_id lookup, `min/max` clamps on every limit/offset, 22-of-22 emitting plugs
  pairing response with `halt`). Churn on an already-safe pattern is what the wish forbids.
- **D2. The surviving 500 surface is the DEEPER frame, not the action head.** Phoenix 1.8.9
  converts an action-head clause mismatch into a clean 400 via `Phoenix.ActionClauseError`
  (`pipeline.ex:144-152` → `exceptions.ex:69-72`, `status(_) → 400`). That refutes most of
  the wish's premise (1). What still 500s is a `FunctionClauseError`/`CaseClauseError` raised
  in a private helper or a context callee, where the top stack frame is not the action.
  Every wave-1 build slice is that exact shape.
- **D3. The unifying defect is one sentence: an unvalidated param TYPE, not a missing param.**
  Plug decodes `?x[]=v` to a list and `?x[k]=v` to a map. Five of six slices are the same
  bug — a list-valued param sails past a key-presence match and raises three frames down.
  Naming the class once is why six independent findings cost one review, not six.
- **D4. Fix at the boundary that OWNS the type, and let the framework do the rest.** For an
  action-head-reachable param, adding `when is_binary(x)` to the CONTROLLER HEAD makes the
  top frame the action, so Phoenix returns 400 for free. For a helper-internal shape, guard
  the element (`is_map/1`) or make the private helper TOTAL with a catch-all clause.
- **D5. A FILTER fails loud, a SCOPE SELECTOR fails soft.** `?kind[]=x` on task edges must
  400 — a silently-ignored filter is the dishonesty `query_controller`'s `invalid_filter_op`
  guard exists to refuse. `?dataset[]=x` falls back to the documented `"production"` default,
  matching that module's own `|| "production"` convention. Uniformity here would be wrong.
- **D6. Error CONSTRUCTORS must be total.** `cycle_fleet`'s `receipt_error/2` had clauses for
  two of the four keys it is called with, so any malformed body raised INSIDE the error
  builder before the `else` could render its 422. A partial helper on the error path is
  invisible to anyone scanning `else` blocks — this class gets a `_key` catch-all, never a
  dynamic-atom collapse (`:"#{key}_required"` is an unbounded-atom hazard).
- **D7. Concurrency races are FILED, never built here.** The RateLimiter ETS read-modify-write
  and the Quota count-then-compare TOCTOU are real and fail-open, but both fix loci sit
  OUTSIDE the fence (`lib/barkpark/rate_limiter.ex`, `lib/barkpark/tenancy/quota.ex`) and
  neither is deterministically provable by a single-process conn test.
- **D8. A finding with no possible mutation proof still ships — labelled.** `Plug.Adapters.Test.Conn.chunk/2`
  returns `{:ok, …}` on every clause, so no conn test can red `listen_controller.ex:62`. The
  fix lands on the 11-of-12 guard census as its evidence, and the task says so in writing.
  Claiming a red-without-fix proof there would be exactly the stamped-evidence-overstates trap.
- **D9. Two files are FILE-only for the whole epic while their PRs are open.**
  `share_controller.ex` (#12405) and `share_link_controller.ex` (#12404) are actively
  diverging. Correctness findings there are filed, never built, until those merge.
- **D10. Every builder brief carries the host bootstrap.** A fresh worktree needs
  `mix deps.get` then `CC=/usr/bin/clang MIX_ENV=test mix compile` once — `cc` on this host is
  aliased to a Claude wrapper and breaks the argon2 NIF. The wave's own verify round lost
  cycles to this. `mix test` auto-runs `ecto.create`/`ecto.migrate`, so the "run migrations
  first" folklore is wrong for the test path and is struck from the briefs.
- **D11. Instrument traps are findings, not footnotes.** Three of this wave's greps returned
  confident fake zeros: `\s` is undefined in POSIX ERE so `git grep -E` silently matches
  nothing; zsh does not word-split an unquoted scalar pathspec so git receives one argument
  and exits 1; a `Repo.get`-only census is blind to `where([x], x.id == ^param)`. RULE for
  every future wave: mutation-check a class grep against a KNOWN POSITIVE before quoting its
  zero.
- **D12. Coverage is accounted, and the remainder is filed by name.** Wave 1's censuses closed
  the Papers/meta block (18 modules), the auth/deploy long tail (17), and the hot core (5).
  What remains unopened is filed as a backlog task, not implied verified.

## Roadmap

### Wave 1 — the six proven 500s (this wave, all round 1)

| # | Slice | Surface | Size | Model |
|---|---|---|---|---|
| 1 | `receipt_error/2` totality — malformed release-gate body 500 → 422 | `cycle_fleet_controller.ex` | small | opus |
| 2 | SCIM scalar member/op element → 500 on 5 request shapes | `scim_groups_controller.ex`, `scim_users_controller.ex` | small | opus |
| 3 | Task `edges` `kind[]` CaseClauseError + `request_dataset/1` list dataset | `tasks_controller.ex` | medium | opus |
| 4 | SSO list-param 500 on OIDC/SAML/social callbacks (HIGH-FLIP) | `oidc_controller.ex`, `saml_controller.ex`, `social_controller.ex` | medium | fable |
| 5 | Bulldocs `?dataset[]=` → `Ecto.Query.CastError` 500 → 404 | `bulldocs_email_controller.ex`, `bulldocs_source_controller.ex` | small | opus |
| 6 | `listen_controller.ex:62` unguarded `chunk/2` hard bind | `listen_controller.ex` | small | opus |

### Wave 2 and beyond — candidate shape (not yet cut)

- Close the controller census remainder: the modules no wave-1 lane opened, swept for the
  same four classes with the D11-corrected instrument.
- The partial-private-helper census: `receipt_error/2` is unlikely to be the only error
  constructor called with more argument values than it has clauses. Grep the class, not the file.
- Conn-level coverage for routes that have none — `webhook_controller` replay/test-send and
  `tickets_attachments` both ship with zero controller tests, which is why their seams went
  unexamined for so long.
- The out-of-fence robustness items filed in wave 1 (rate-limit race, quota TOCTOU,
  `Accounts.get_user/1` uuid parity) if a later epic takes the contexts.

## Wave log

<!-- one row per wave: wave, date, slices merged, grade, paper -->
