# Independent security derivation — dr-w1-s1 graph visibility bound + readmit

- **Reviewer agent:** `graph-vis-rederive` (did NOT build this slice; no authorship
  in PR #9613 and no prior context on it beyond the task row and the PR body).
- **Date:** 2026-08-22
- **origin/main SHA read:** `97cd39f3225d94e77290ae2772a86b8f61f93714`
- **Merge under review:** `dbcb128880c48c53362a3a4eed5224444f4b483e`
  ("fix(api): graph corpus honours schema visibility, is bounded, and /v1/graph
  is readmitted (#9613)")
- **Verdict: CONFIRMS-WITH-RESIDUAL.** The clamp shipped on `/v1/graph` is real,
  reachable and mutation-proved — I could not make it fail. But the SAME corpus
  derivation is served **UNCLAMPED to a fully ANONYMOUS caller** at `/finder`,
  one tier BELOW the tier this PR clamped. The leak this slice closed for
  `{public-read}` tokens is still open, wider, for callers with no token at all.
  Proved by run, below.

## Ancestry

    $ git merge-base --is-ancestor dbcb128880c48c53362a3a4eed5224444f4b483e origin/main
    $ echo $?
    0

## The named starting point, re-derived — and relocated

The PR body flags `type_gate/1`'s `:none` verdict as "an explicit 'trust the
controller' hole." **I do not agree that that is where the hole is.**

`:none` would be a hole if the clamp depended on the plug. It does not. The
filter sits at the derivation chokepoint —
`TasksController.derive_graph_corpus/2` (`tasks_controller.ex:1224`) calls
`visible_schemas/2` on the schema list *before* `all_types` is derived — so it
holds whether or not `Plugs.PublicRead` is mounted on the route. Putting the
clamp behind the plug would have been the weaker arrangement. Placement is
right.

The real weakness is the clamp's **KEY**, not its placement:

    defp visible_schemas(schemas, conn) do
      if BarkparkWeb.Plugs.PublicRead.public_read_token?(conn) do
        allowed = MapSet.new(Barkpark.Content.Schema.public_type_names(schemas))
        Enum.filter(schemas, &MapSet.member?(allowed, &1.name))
      else
        schemas
      end
    end

`public_read_token?/1` is an **allow-list of exactly one tier**. Its `else` arm
is "show everything", so the clamp fails **OPEN** for every principal that is
not a public-read token — and `public_read_token?/1` returns `false` for a conn
with no `:api_token` at all. Anonymous is not above public-read; it is below it.
On the single route that exists this is safe *only* because `:require_token`
guarantees a token is present. It stops being safe the instant this derivation
runs without one.

## Paths enumerated — every door to the corpus

| # | Door | Pipeline | Clamped? |
|---|---|---|---|
| 1 | `GET /v1/graph` → `TasksController.graph_corpus/2` (`router.ex:2069`) | `[:api, :require_token]`; `:require_token` mounts `Plugs.PublicRead` (`router.ex:599`) | **YES** — `visible_schemas/2` |
| 2 | scoped mirror `/w/:ws/p/:proj/v1/graph` | — | **does not exist**; `data_path/1`'s prefix-strip is defensive only |
| 3 | capability verbs `graph.*` (`capabilities.ex:1946,1972,1985,1997`) | — | **no `graph.corpus` verb exists**; only show/tasks/orphans/dangling |
| 4 | `live "/finder"` → `FinderLive.graph_payload/1` (`router.ex:1374`, `finder_live.ex:229`) | `[:browser, :paper_reader_csp]` — **no auth plug, no `on_mount`** | **NO — anonymous, unclamped** |

`grep -n ':graph_corpus' router.ex` returns exactly one line, so door 1 is the
only controller route. Door 4 is a **second, hand-copied derivation** of the
same payload; the PR did not touch `finder_live.ex` (`git show --stat
dbcb1288… -- api/lib/barkpark_web/live/finder_live.ex` is empty).

`FinderLive`'s own moduledoc names the relationship: *"same shape as
`TasksController.graph_corpus/2` — the flat `/v1/graph` twin; a shared
extraction is filed as backlog"*. The PR body names it too, and files it on the
**privileged** side of the ledger: *"every other principal (Studio session,
read/write/admin token, and `FinderLive` …) keeps seeing every type."* That is
the load-bearing error. `FinderLive`'s principal is not a Studio session or an
admin token — it is **the public internet**, and the module says so itself:
*"This finder mounts on the PUBLIC `/finder` route (`:browser` pipeline, no
on_mount auth)."*

## MUTATION PROOF — the shipped guard is not vacuous

### M1 — neuter the clamp's key

`visible_schemas/2`'s condition forced to `false and …` on origin/main bytes:

    $ CC=/usr/bin/cc MIX_ENV=test mix test test/barkpark_web/controllers/graph_controller_test.exs
    30 tests, 3 failures

    1) types= cannot re-open a private type for public-read
       left: 200   right: 400
    2) a schema flipped to public becomes visible on the NEXT read (read-time, not hardcoded)
       left: "FLIP-weapon-flip-23106"  right: ["FLIP-weapon-flip-23106"]
    3) MUTATION PROOF: a published private-type title is absent for public-read,
       present for admin, and gone from both after delete
       left: "SECRET-weapon-23682"
       right: ["OPEN-open-post-23714", "SECRET-weapon-23682"]

Three named reds. The clamp is reachable and load-bearing.

### M2 — the fail-closed claim for `type_gate/1`, driven directly

The `:unknown` arm is documented as *"Unreachable while `allowed_route?/1`
enumerates exactly these shapes; it exists so the next route added to the
allowlist without a clause here fails CLOSED"*. A comment claiming a guard that
never runs is the "deliberately unable to fail" trap, so I **made it run**: added
`["v1", "graph", "orphans"] -> true` to `allowed_route?/1` and added **no**
`type_gate/1` clause — literally the mistake the comment predicts.

    $ CC=/usr/bin/cc MIX_ENV=test mix test test/barkpark_web/controllers/graph_controller_test.exs:781
    1) the graph SIBLINGS and non-graph reads stay denied for public-read
       /v1/graph/orphans returned 404 for a public-read token — expected 403

**404 — not 200 (leak) and not 500 (the `FunctionClauseError` the old
two-clause `extract_ds_type/1` would have raised).** The claim is exactly true:
the arm is reachable by the predicted mistake, and it denies. This is the
cleanest part of the slice.

Both mutations were reverted; `git diff origin/main -- api/lib` was **empty**
(byte-identical) before publication.

## THE RESIDUAL — a case the builder never drove

Probe (`test/barkpark_web/live/finder_corpus_visibility_probe_test.exs`, not
committed — it is red against origin/main by design): seed a
`visibility: "private"` schema `vault` plus one **published** document, then
mount `/finder` **anonymously** and read back the `data-nodes` payload the
`FinderGraph` hook ingests.

    PROBE: anonymous /finder corpus = 1 node(s)
    PROBE: types present = ["vault"]
    PROBE: private 'vault' type present? true
    PROBE: private title present? true

    1) test the anonymous /finder corpus does NOT carry a private-type document title
       ANONYMOUS /finder inlined a PRIVATE-visibility TYPE NAME into the corpus payload

**The same LiveView contradicts itself on one HTTP response.** The contrast case
drives the search box with the same private document:

    PROBE: search hit line = ["0 hits", "0"]
    PROBE: an href to the private doc? false
    PROBE: the graph attrs on the SAME response carry the title: true

The **search** path is correctly clamped — `CallerContext.from_conn(socket)`
resolves to `anonymous/0` and `DocumentsRetriever.restrict_anonymous_to_public_types/3`
narrows to public types (search-template D62). The **graph** path on the very
same response hands the private type name and the private document title to the
same anonymous visitor. `graph_payload/1` reads

    types = dataset |> Content.list_schemas(opts) |> Enum.map(& &1.name)

with no visibility predicate — the *exact* line PR #9613 replaced in the
controller — and `Content.list_documents/3` (`content/query.ex:56`) carries no
schema-visibility gate of its own; the anonymous gate lives only in the search
retriever. So nothing downstream catches it.

Reach, from reading (not driven): the corpus is capped at
`@graph_node_budget 2000`, so an anonymous visitor receives up to 2000
`{id, type, title}` triples across **all** types; `dataset` is caller-controlled
via `?dataset=` (`sanitize_dataset/1` accepts any `[a-z0-9][a-z0-9_-]{0,62}`).

## Leads, explicitly NOT findings of this row

- **Tenancy of the anonymous corpus.** `graph_payload/1` builds
  `opts = [dataset: dataset, limit: per_type_limit]` with **no** `workspace_id`
  or `project_id`. Whether `Content.list_schemas/2` then resolves Default-only or
  spans workspaces I did **not** drive, and the known "scope_opts fails open to
  Default" hazard makes it worth a probe of its own. Unverified — do not read
  this as a second finding.
- **Phantom nodes.** Left unfiltered by design. A phantom is a
  referenced-but-absent id with `title == id` and `type: nil`, and the referring
  public document already exposes that id through the allowed `GET /v1/data/doc`
  route. I agree with the builder here: dropping them would cost the
  dangling-edge signal and close nothing.
- **`?types=` as an existence oracle.** Checked and clean: `all_types` is
  filtered *before* `parse_graph_types/2` runs, so a private type and a
  nonexistent type both return the identical `400 "unknown types: …"`. No
  oracle.
- The admission cap (503/Retry-After, ETS slot table owned by
  `Barkpark.Application.start/2`) is an availability control, not a
  confidentiality one, and I did not re-derive it.

## Disclosure about this derivation's own completion

The final combined green run (`graph_controller_test.exs` +
`public_read_test.exs` + `finder_live_test.exs` on the restored tree) was **not**
executed: this session was externally re-pinned into a peer's worktree mid-run
and every subsequent `Bash` call was refused. What *was* verified before the
block: both mutations reverted and `git diff origin/main --stat -- api/lib`
empty, i.e. the numbers above were produced against origin/main bytes plus one
mutation at a time. Stated here rather than omitted.
