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
  fix lands on the guard census as its evidence, and the task says so in writing.
  *(Corrected 2026-08-18 at review: the census is 11 sites / 10 guarded, not 12 / 11. The
  three `workspace_controller.ex` hits are a local `write_chunk/3` disk helper and `plugs/`
  has zero `chunk/2` sites. Substance unchanged — all but one were already guarded.)*
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

### Wave 2026-08-18 — wave 1, the six proven 500s

Grade **A-**. Paper `web-glue-robustness-wave-2026-08-18`. Charter PR #12471.

**All six slices landed and were pushed with PRs — including the one the harness reported
not-green.** Every fix is the same class D3 named: an unvalidated param TYPE, not a missing
param.

| Slice | Task | Final branch | PR | Verdict |
|---|---|---|---|---|
| `receipt_error/2` totality | `acpc-w1-cycle-fleet-receipt-error-totality` | `…cycle-fleet-make-receipt-error-2-total-s-0-r` | #12524 | clean; additive only, #11697 seal byte-identical |
| SCIM element shape | `acpc-w1-scim-scalar-member-guard` | `…scim-guard-the-element-shape-so-a-scalar-1-r` | #12525 | clean; 5 crash shapes + the false-refute pin |
| tasks `kind` / `dataset` | `acpc-w1-tasks-edges-kind-and-dataset` | `…tasks-controller-400-on-a-list-valued-ed-2-r` | #12526 | clean; D5 asymmetry built and commented at both sites |
| SSO list-param (HIGH-FLIP) | `acpc-w1-sso-list-param-guard` | `…sso-callbacks-guard-the-action-heads-so--3-r` | #12528 | clean; reachability re-derived by review, second reviewer still owed |
| bulldocs `?dataset[]=` | `acpc-w1-bulldocs-dataset-cast-guard` | `…bulldocs-guard-the-query-string-dataset--4-r` | #12529 | one review commit (test-discoverability pointer) |
| listen `chunk/2` bind | `acpc-w1-listen-chunk-hard-bind` | `…listen-controller-guard-the-welcome-fram-5-r` | #12531 | reported not-green, **is green** on a quiet host |

**Nothing stalled.** The one "stall" was an instrument artefact: every builder reported a
noisy wide gate (4-8 failures, a different failing set each run, always carrying
`Postgrex.Error FATAL 53300 too_many_connections` or `40P01 deadlock_detected`) because ~30
concurrent worktrees share one local test Postgres. Review re-ran all six wide gates on a
quiet host and every one is a literal zero: 1716 / 1720 / 1719 / 1722 / 1717 / 1714 tests,
0 failures. Two consequences worth carrying forward:

1. **The listen slice was misclassified.** Its gate failed only under that load. Its work
   was complete, committed, and correct; it is delivered as #12531. A wave that trusts its
   harness's green/not-green flag without re-running on a quiet host loses real work.
2. `acpc-preexisting-workspace-import-token-reds` (filed for 5 "pre-existing reds on clean
   origin/main") is refuted — those files are green here. Close it rather than chase it.

**A recurring incident, now three-for-three.** Three of six builders mis-popped a foreign
slice out of the repo-GLOBAL stash stack; the stash list already carried six historical
`MISPOP-RECOVERY` entries from prior waves. `git stash push` / `git stash pop` is shared
across every worktree in a checkout. RULE for every future wave, and it belongs in the
builder brief next to D10: a baseline probe uses `git diff > file` + `git checkout -- <paths>`,
or `git checkout origin/main -- <paths>` and restore from the branch — **never** bare
`stash push`/`stash pop`. Review used `git checkout origin/main -- <path>` for all six
mutation proofs and had no incident.

**Re-derived by review, not re-read** (each independently confirmed against `origin/main`):
the `:sso_browser` pipeline really is three plugs with no auth plug; `endpoint.ex` really
has `signing_salt` and no `encryption_salt`, so the OIDC arm is a same-session replay and
not an anonymous crash; the `chunk/2` census is 11 sites / 10 guarded (D8 corrected above);
and every one of the six mutation proofs reds exactly as claimed, including the source
controller's guard reverted **alone** (stack at `bulldocs_source_controller.ex:41`).

**One reachability precision the lead should carry into merge:** the SAML crash is
unauthenticated, but `Base.decode64/2` sits behind `%SamlConnection{} <- c || :no_conn`, so
it additionally requires an org slug with SAML *configured*. Anonymous, not arbitrary. The
bulldocs finding went the other way — the brief said AUTHENTICATED and it is in fact
anonymously reachable via the flat `:public_root` routes.

**Next wave should take** the charter's own wave-2 candidates, in this order: (a) the
partial-private-error-constructor census — D6's class, grepped repo-wide rather than
file-by-file, since `receipt_error/2` is unlikely to be the only error builder called with
more argument values than it has clauses; (b) the controller census remainder with the
D11-corrected instrument; (c) conn-level coverage for `webhook_controller` replay/test-send
and `tickets_attachments`, which ship with zero controller tests — that absence is *why*
their seams went unexamined. `share_controller` / `share_link_controller` stay FILE-only
under D9 until #12404 and #12405 merge.
