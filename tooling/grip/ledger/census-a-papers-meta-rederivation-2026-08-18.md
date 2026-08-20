# CENSUS A — Papers/Bulldocs + meta/ops controllers: re-derivation recipes

Wave: web-glue-robustness-wave-2026-08-18 · lane `census-a-papers-meta`
Pinned to `origin/main` = `228090798bf50a3ae2bb15699c04ddf65b2dcdd2`.

18 assigned modules opened. **1 REAL bug (executed proof), 15 SAFE with a named
guard, 2 NOT CONTROLLERS (census correction).**

---

## R1 — REAL: `BulldocsEmailController` 500s on a non-binary `dataset` query param

Failing request (route is the SCOPED one; there is no flat `/papers/:slug/email`):

    GET /w/<ws_slug>/p/<proj_slug>/papers/<any-slug>/email?dataset[]=production
    GET /w/<ws_slug>/p/<proj_slug>/papers/<any-slug>/email?dataset[a]=b

→ `Ecto.Query.CastError` → uncaught → **500**. Expected: 404 (or 400).

Locus: `api/lib/barkpark_web/controllers/bulldocs_email_controller.ex:31`

    dataset = Map.get(params, "dataset") || Content.paper_default_dataset()

`params["dataset"]` is QUERY-STRING sourced (only `:slug` is a path segment), so
Plug decodes `dataset[]=` to a LIST and `dataset[a]=` to a MAP. It is then bound
to `x.dataset == ^dataset` where `field :dataset, :string`.

Re-derive the route (proves no flat/public email route exists):

    cd api && git grep -n 'BulldocsEmailController' origin/main -- lib/barkpark_web/router.ex

Re-derive the param decode:

    cd api && MIX_ENV=test mix run -e 'IO.inspect(Plug.Conn.Query.decode("dataset[]=production"))'

Re-derive the crash on the ACTUAL call path (`paper_scope` matches
`%{"workspace_slug" => _}` → non-empty scope → `Content.get_paper/3`):

    cd api && MIX_ENV=test mix run -e '
    alias Barkpark.Content
    for ds <- ["production", ["production"], %{"a"=>"b"}] do
      try do IO.puts("OK -> " <> inspect(Content.get_paper("no-such-slug", ds, [workspace_id: "da076f64-9549-4ad3-9fa8-86eba2a6efdc"])))
      rescue e -> IO.puts("RAISED: " <> inspect(e.__struct__)) end
    end'

Re-derive that nothing downgrades the CastError off 500:

    cd api && grep -rn "Plug.Exception" deps/ecto/lib/ ; git grep -n 'defimpl Plug.Exception' origin/main -- lib/

Re-derive the binding and the column type:

    cd api && git show origin/main:api/lib/barkpark/content/query.ex | sed -n '1245,1253p'
    cd api && git grep -nE 'field\(?:dataset' origin/main -- lib/barkpark/content/document.ex

**The fix is a one-liner with in-repo prior art.** `MetaController:32` already
guards the identical param:

    case Map.get(params, "dataset") do
      ds when is_binary(ds) -> ...
      _ -> ...
    end

    cd api && git show origin/main:api/lib/barkpark_web/controllers/meta_controller.ex | sed -n '30,35p'

Test home already exists in-fence:
`api/test/barkpark_web/controllers/bulldocs_email_controller_test.exs`.
Mutation proof = a conn test asserting 404 (not a raise) on `?dataset[]=production`.

**Same-class sibling, same route, NOT in this lane's roster —
`bulldocs_source_controller.ex:17` is byte-equivalent (`Map.get(params,
"dataset") || …`) and is mounted on the same scope block. Re-derive:**

    cd api && git grep -nE 'Map\.get\(params, "dataset"\)|params\["dataset"\]' origin/main -- lib/barkpark_web/controllers/

---

## R2 — CENSUS CORRECTION: `paper_backlinks.ex` / `paper_tasks.ex` are not controllers

Both live under `controllers/` but are pure HTML render helpers — zero `conn`,
zero `params`, no router entry. They carry total catch-all clauses
(`section_html(_), do: ""`). No HTTP surface ⇒ no four-class verdict applies.

    cd api && git grep -nE 'use BarkparkWeb|conn|params' origin/main -- lib/barkpark_web/controllers/paper_backlinks.ex lib/barkpark_web/controllers/paper_tasks.ex ; echo "EXIT=$?"
    cd api && git grep -n 'PaperBacklinks\|PaperTasks' origin/main -- lib/barkpark_web/router.ex ; echo "EXIT=$?"

Both exit 1 (no match). The fence's controller denominator is 2 lower than the roster implies.

---

## R3 — SAFE, with the guard named (the ones worth re-deriving)

* **`status_controller.ex:80`** — `Status.get_incident(id)` is uuid-guarded:
  `Repo.uuid_or_nil(id)` returns nil for a malformed uuid → 404, never CastError.
  The `status_incidents` PK IS `:binary_id`, so the guard is load-bearing.

      cd api && git show origin/main:api/lib/barkpark/status.ex | sed -n '150,157p'

* **`bulldocs_intents_controller.ex:46`** — `Events.mark_processed(id)` same guard
  (`Repo.uuid_or_nil`), with the reason written into its own docstring.

      cd api && git show origin/main:api/lib/barkpark/plugins/bulldocs/events.ex | sed -n '100,120p'

* **`bulldocs_email_controller.ex:51`** — the inner `case source do {:blocks,_} /
  {:html,_} end` has no catch-all but IS exhaustive: `reader_source/3`'s total
  return set is `{:blocks,_} | {:html,_} | {:error,_}`, and the OUTER case peels
  `{:error,_}` first.

      cd api && git show origin/main:api/lib/barkpark/content/papers.ex | sed -n '88,155p'

* **`schema_controller.ex`** — every `dataset` is a PATH segment; `Content.get_schema/3`
  returns ONLY `{:ok,_} | {:error, :not_found}`; and `action_fallback
  BarkparkWeb.FallbackController` is a single total `def call(conn, error)`.

      cd api && git show origin/main:api/lib/barkpark/content/schema.ex | sed -n '106,124p'
      cd api && git grep -nE 'def call' origin/main -- lib/barkpark_web/controllers/fallback_controller.ex

* **`bulldocs_form_controller.ex`** — the model citizen: with-chain has an
  `{:error, _}` catch-all, `sanitize_answers/2` has a non-map clause (a list or
  scalar `answers` → 422, never a MatchError), `sanitize_value/1` has a total
  clause, honeypot + rate limit both return tagged tuples.

* **`meta_controller.ex:32`** — `is_binary(ds)` guard (the R1 prior art).
* **`capabilities_controller.ex`** — `params["x"] in ["1","true"]` is total for any
  param type; `Integer.parse` on a header sits inside a `with … else _ -> nil`.
* **`metrics` / `request_stats` / `openapi` / `plugins`** — `_params`, no user input.
* **`plugin_settings_controller.ex`** — `update/2` has a total
  `update(_conn, _params), do: {:error, :malformed}` fallback clause.
* **`structure_controller.ex`** — `dataset` is a PATH segment (`/v1/structure/:dataset`).
* **`scoped_paper_controller.ex`** — `slug` is a path segment; `get_paper/3` returns
  `%Document{} | nil` and both are handled (nil → 404 via ErrorHTML).
* **`export_controller.ex`** — `chunk/2`'s `{:error, reason}` is explicitly caught
  and halts inside the transaction; the 200 is already committed by design and
  the truncation is logged.

---

## R4 — LATENT in-body hard matches (NOT bugs; feed the V5 census-gap contradiction)

The digest's `] = params` grep was structurally blind to `} = <call>` binds.
Two live in this roster. Both are currently UNREACHABLE, so neither is a REAL bug:

* `status_controller.ex:87` — `{:ok, resolved} = Status.resolve_incident(incident)`.
  Spec says `{:ok,_} | {:error, Ecto.Changeset.t()}`. Unreachable because the
  changeset only sets `status: "resolved"` (∈ `@statuses`) + `resolved_at` on a row
  that already passed `validate_required` and `validate_inclusion(:impact, …)`.

      cd api && git show origin/main:api/lib/barkpark/status/incident.ex | sed -n '12,13p;32,38p'

* `export_controller.ex:35` — `{:ok, {conn, delivered, outcome}} = Repo.transaction(…)`.
  Unreachable: the fn contains no `Repo.rollback`, so the transaction cannot
  return `{:error, _}`.

Recipe to enumerate the whole class fence-wide (the grep the survey lane needed):

    cd api && git grep -nE '^\s+\{:ok, [^}]*\} = [A-Z]' origin/main -- lib/barkpark_web/controllers/

## R5 — Nothing found, per class, in this roster

* Bare `json(conn, %{error…})` defaulting to 200: **ZERO**. The MUST-RUN grep
  returns empty, and the pathspec is proven live by a control grep for `json(conn`
  (9 hits / 6 files). Every error branch in the roster pairs with `put_status`,
  `send_resp(conn, <code>, …)`, or a `{:error, _}` tuple to the FallbackController.

      cd api && git grep -nE 'json\(conn, %\{(error|errors)' origin/main -- 'lib/barkpark_web/controllers/bulldocs_*' 'lib/barkpark_web/controllers/paper_*' 'lib/barkpark_web/controllers/scoped_paper*' 'lib/barkpark_web/controllers/structure_controller.ex' 'lib/barkpark_web/controllers/export_controller.ex' 'lib/barkpark_web/controllers/meta_controller.ex' 'lib/barkpark_web/controllers/plugins_controller.ex' 'lib/barkpark_web/controllers/schema_controller.ex'
      # control (must be NON-empty, else the pathspec is the thing that is broken):
      cd api && git grep -c 'json(conn' origin/main -- <same pathspec>

* Unguarded `params[id]` → binary_id `Repo.get`: **ZERO** (R3 names both guards).
* Non-halting error plug / plug assign gap: **N/A** — no module in this roster is a plug.
* Unhandled `with`/`case` arm reachable by a request: **ZERO** (R3, R4).
