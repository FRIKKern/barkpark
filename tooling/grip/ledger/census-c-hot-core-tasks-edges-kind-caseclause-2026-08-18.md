# Census C — hot-core re-derivation: TWO reachable bare 500s in `tasks_controller`

Wave: web-glue-robustness-wave-2026-08-18 · lane `census-c-hot-core` · 2026-08-18
Pinned: `origin/main` = `6015bedabd301db9893bd300c90600ce307ae567` (the digest's pin `228090798` is
behind; the four hot-core files are byte-identical at both — see step 0).

## Verdict in one line

The direction's bet that the hot core is hardened is CONFIRMED for `query_controller`,
`tickets_controller`, `federated_search_controller` and `tasks_controller/params.ex` — and
FALSIFIED for `tasks_controller.ex`, which carries TWO request-reachable bare 500s:

* **F1** `edges/2` — the sole `case params[…]` in the whole hot core with no catch-all clause.
* **F2** `request_dataset/1` — returns `conn.params["dataset"]` unvalidated into callees that
  are `when is_binary(dataset)`-guarded with NO fallback clause. Proven reachable on
  `GET /v1/tasks/events` and `GET /v1/fleet/roster`.

Both are in `tasks_controller.ex`, a module the surveyors opened only for `Integer.parse` —
so the finding is not "the direction was wrong about hardening", it is "the direction was wrong
about WHERE it stopped looking". The `parse_int` family IS hardened; the two params that never
go through it are not.

## Step 0 — pin, and prove the two shas agree on the fence

    git rev-parse origin/main
    for f in query_controller tasks_controller tickets_controller federated_search_controller; do
      diff <(git show 228090798:api/lib/barkpark_web/controllers/$f.ex) \
           <(git show origin/main:api/lib/barkpark_web/controllers/$f.ex) >/dev/null \
        && echo "$f IDENTICAL" || echo "$f DIFFERS"
    done

## Step 1 — the defect, read off origin/main (no line numbers, grep pattern)

    git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex | grep -n 'def edges' -A 9

Expected output — note the missing `_ ->` arm:

    def edges(conn, %{"doc_id" => doc_id} = params) do
      kind_opt =
        case params["kind"] do
          nil -> :blocks
          "all" -> :all
          other when is_binary(other) -> other
        end

Route (token-gated, ordinary read token):

    git grep -n ':edges' origin/main -- api/lib/barkpark/plugins/tasks.ex
    # => {:get, "/tasks/:doc_id/edges", BarkparkWeb.TasksController, :edges, auth: :token_root}

## Step 2 — prove Phoenix hands the action a list, and the action raises

    cd api && MIX_ENV=test mix run --no-start -e '
      IO.inspect(Plug.Conn.Query.decode("kind[]=blocks"), label: "QUERY-DECODE")
      try do
        BarkparkWeb.TasksController.edges(%Plug.Conn{}, %{"doc_id" => "task-abc", "kind" => ["blocks"]})
      rescue e -> IO.puts("RAISED: " <> inspect(e.__struct__) <> " | " <> Exception.message(e)) end'

Expected:

    QUERY-DECODE: %{"kind" => ["blocks"]}
    RAISED: CaseClauseError | no case clause matching:
        ["blocks"]

The raise happens BEFORE `find_task_by_doc_id/2`, so no DB and no valid doc_id are needed to
reproduce; a nonexistent task id still 500s instead of 404ing.

## Step 3 — prove the status is 500, not the framework's clean 400

Phoenix 1.8.9 converts an ACTION-HEAD clause mismatch into `Phoenix.ActionClauseError` → 400.
That mechanism does not reach this raise: it is in the action BODY.

    cd api && MIX_ENV=test mix run --no-start -e '
      IO.puts("CaseClauseError => "     <> inspect(Plug.Exception.status(%CaseClauseError{term: ["blocks"]})))
      IO.puts("ActionClauseError => "   <> inspect(Plug.Exception.status(%Phoenix.ActionClauseError{})))
      IO.puts("Ecto.Query.CastError => "<> inspect(Plug.Exception.status(%Ecto.Query.CastError{type: :string, value: ["x"], message: "m"})))'

Expected:

    CaseClauseError => 500
    ActionClauseError => 400
    Ecto.Query.CastError => 400

The third line is why the OTHER unvalidated params in this controller (`?dataset[]=x` into
`request_dataset/1`, `?worker[]=x` into `prime/2`) are NOT findings — a list reaching an Ecto
`==` lands as a clean 400 through phoenix_ecto's Plug.Exception impl.

## Step 4 — prove it is the ONLY such site in the hot core

    for f in query_controller tasks_controller tickets_controller \
             federated_search_controller tasks_controller/params; do
      echo "=== $f"
      git show origin/main:api/lib/barkpark_web/controllers/$f.ex \
        | grep -nE 'case params\[|case Map\.get\(params' -A 8
    done

Every other site ends in `_ ->` or `other -> other`. Only `edges/2` does not.

## Step 5 — baseline green (the fix's red must be attributable)

    cd api && mix test test/barkpark_web/controllers/query_controller_test.exs \
                       test/barkpark_web/controllers/tasks_controller_test.exs 2>&1 | tail -3
    # => Finished in 7.2 seconds (0.00s async, 7.2s sync)
    #    122 tests, 0 failures

No existing test touches `edges`' `kind` param:

    git grep -n 'kind' origin/main -- api/test/barkpark_web/controllers/tasks_controller_test.exs

## Step 6 — the fix + its mutation proof (for the builder)

Fix locus: `api/lib/barkpark_web/controllers/tasks_controller.ex`, `edges/2` only.
Prefer an honest 400 over a soft fallback: a silently-ignored `kind` filter is the same
"silent passthrough" dishonesty `query_controller`'s `invalid_filter_op` guard exists to kill
(the guard's own comment: "a typo'd op looked like it filtered but didn't"). Shape:

    kind_opt =
      case params["kind"] do
        nil -> :blocks
        "all" -> :all
        other when is_binary(other) -> other
        _ -> :invalid
      end

    if kind_opt == :invalid do
      bad_request(conn, "kind must be a string (e.g. blocks) or \"all\"")
    else
      … existing body …
    end

Mutation proof (conn test, `api/test/barkpark_web/controllers/tasks_controller_test.exs`):

    conn = get(conn, "/v1/tasks/#{doc_id}/edges?kind[]=blocks")
    assert json_response(conn, 400)["reason"] == "bad_request"

Reds WITHOUT the fix: the request raises `CaseClauseError`, so the test errors rather than
returning 400. Verify the red by stashing the fix hunk and re-running the single test file.

## F2 — `request_dataset/1`: an unguarded list param into `when is_binary` callees

### Step 1 — the seam

    git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex \
      | grep -n 'defp request_dataset' -A 3
    # =>  defp request_dataset(conn) do
    #       conn.params["dataset"] || "production"
    #     end

SEVEN call sites read it (`grep -n 'request_dataset(conn)'` → lines 214, 1032, 1039, 1119, 1507,
1888, 1933 at `6015beda`): `events/2`, `graph_orphans/2`, `graph_dangling/2`,
`derive_graph_corpus/2`, the field-visibility `seal` schema lookup, `fleet_beat/2`,
`fleet_roster/2`.

    git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex | grep -n 'request_dataset(conn)'

### Step 2 — the callees are guarded with NO fallback clause

    git show origin/main:api/lib/barkpark/tasks/events.ex | grep -n 'def replay_since' -A 3
    # => def replay_since(dataset, since, opts \\ [])
    #      when is_binary(dataset) and is_integer(since) do        <-- only clause

### Step 3 — execute both

    cd api && MIX_ENV=test mix run --no-start -e '
      try do Barkpark.Tasks.Events.replay_since(["production"], 0, limit: 10)
      rescue e -> IO.puts("EVENTS: " <> inspect(e.__struct__) <> " status=" <> inspect(Plug.Exception.status(e))) end
      try do Barkpark.Tasks.Fleet.roster(["production"])
      rescue e -> IO.puts("ROSTER: " <> Exception.message(e)) end'

Expected:

    EVENTS: FunctionClauseError status=500
    ROSTER: no function clause matching in Barkpark.Tasks.Fleet.roster/2

Both raise BEFORE any Repo call, so they reproduce with `--no-start` and need no fixture.

### Failing requests

    GET /v1/tasks/events?dataset[]=production     (auth: :token_root)  -> 500
    GET /v1/fleet/roster?dataset[]=production     (auth: :token_root)  -> 500

Route proof:

    git grep -n "'/tasks/events'\|/fleet/roster" origin/main -- api/lib/barkpark/plugins/tasks.ex

### Fix locus — ONE helper, in fence, closes all seven call sites

    defp request_dataset(conn) do
      case conn.params["dataset"] do
        ds when is_binary(ds) and ds != "" -> ds
        _ -> "production"
      end
    end

Failing soft to the default (rather than 400) is right HERE and wrong for F1: `dataset` is a
scope selector with a documented default, so a malformed value falling back is the module's own
stated convention (`|| "production"`); `kind` is a FILTER, and a silently-ignored filter is the
dishonesty class F1's 400 exists to refuse.

Mutation proof: `get(conn, "/v1/tasks/events?dataset[]=production")` asserting `json_response(conn, 200)`.
Reds without the fix with `FunctionClauseError ... Barkpark.Tasks.Events.replay_since/3`.

### Explicitly NOT settled for F2

`Graph.orphans/1`, `Graph.dangling/1` and `Content.list_schemas/2` were probed the same way and
returned `RuntimeError: could not lookup Ecto repo Barkpark.Repo because it was not started` —
the IDENTICAL error a STRING dataset produces under `--no-start`, i.e. probe noise, not a verdict.
Their behaviour under a list dataset is UNKNOWN and must be settled with a running Repo
(`mix test` conn case), not quoted from this lane.

## Deliberate NON-findings in this lane (cite, do not manufacture)

* `claim/2` `{:ok, nil} -> put_status(:ok) |> json(%{ok: false, reason: "no_ready"})` — an
  explicit `put_status(:ok)`, not an accident. "Queue empty" is not an error; the CLI reads
  `ok:false`. Changing it is a wire-shape break, not a fix.
* `tickets_controller` — every body field passes `trim/1` (`defp trim(_), do: nil`) and
  `normalize_attachments/1` (`defp normalize_attachments(_), do: []`); `find/3` is
  `when is_binary(id) and id != ""` with a `defp find(_id,…)` fallback and queries by `doc_id`
  string, never `Repo.get` by binary_id. No CastError surface.
* `federated_search_controller` — `parse_surfaces/1`, `parse_int/2` and `bin/1` each carry an
  explicit array/map catch-all with a comment naming the FunctionClauseError-500 it prevents.
* `query_controller` — `parse_int/parse_order_param/parse_expand/parse_fields/normalize_filter_map`
  all catch-all; `Content.Query.parse_has_strong/1` has `def parse_has_strong(_), do: :error`.
  The `{field, op} = bad` bind in `index/2`'s cond is guarded by the cond test that produced it.
* `tasks_controller` rescues (3) are all `ArgumentError`-narrow around `:ets`, each with a
  reasoned comment; `resolve_new_parent/2`, `Params.parse_criteria/1`, `Tasks.Claim.normalize_resources/1`
  and `Fence.add_dep/4`'s two-tuple contract all have catch-alls matching their callers' `else`.

## What this lane could NOT settle

* The three `RuntimeError` probes above (Graph.orphans / Graph.dangling / Content.list_schemas)
  — repo-not-started noise, verdict UNKNOWN. See "Explicitly NOT settled for F2".
* `Fleet.beat/3`'s own tolerance for a list `dataset` was not probed (it takes the whole params
  map and has a `{:error, other}` catch-all in the controller, so it is the least likely of the six).
* No conn-level (end-to-end router) execution was performed in this lane — both proofs are
  direct function invocations under `mix run --no-start`. The builder's mutation proof MUST be a
  conn test, which is a strictly stronger claim than anything here.
