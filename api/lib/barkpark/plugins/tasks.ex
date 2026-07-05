defmodule Barkpark.Plugins.Tasks do
  @moduledoc """
  Tasks — the W7 task-document substrate, as a first-party plugin.

  Tasks live as rows in the `documents` table (everything is a task: a goal/epic
  is a root task, a phase is a task with children, a rail is the chronological
  child tasks of a task). This was core machinery wired straight into
  `seeds.exs` and `config.exs`; the C4 plugin lift moves the *declarative* parts
  onto the plugin highway, while the heavy lifting stays in core.

  The split (mirroring the Bulldocs lift): *core* keeps the reusable machinery —
  `Barkpark.Tasks` (the schema builder + lifecycle validator + claim/close
  primitives), `Barkpark.Tasks.{TtlSweeper, Compactor, Edge}`, and the
  `/v1/tasks` + `/v1/rail` controllers — and this plugin is the thin wiring
  layer that declares the schema and schedules the cron.

  ## What this module contributes

    * `register_schemas/1` — the `task` document type, built by
      `Barkpark.Tasks.schema_definitions/1`. Auto-registers on every boot via
      `Barkpark.Plugins.Bootstrap.register_all_schemas/0`, idempotent on
      `(name, dataset)`. Replaces the inline registration loop that used to live
      in `seeds.exs`.
    * `oban_crontab/0` — the two task cron entries (TTL sweep every minute,
      compaction every six hours), collected at boot by
      `Barkpark.Plugins.Registry.collect_oban_crontab/0` and merged into the
      host's `Oban.Plugins.Cron` `:crontab` before Oban starts. Replaces the two
      tuples that used to live in `config/config.exs`. The `tasks_ttl` /
      `tasks_compact` queue declarations stay in config — only the worker
      *scheduling* moves here.

    * `register_routes/1` — the twelve `/v1/tasks` endpoints the `bp task` CLI
      consumes, declared with `auth: :token_root` so the dormant
      host-level `scope "/v1", BarkparkWeb do … plugin_routes(scope: :token_root)`
      wrapper mounts them at `/v1/tasks/*` behind the `[:api, :require_token]`
      pipeline. Replaces the explicit `scope "/v1/tasks"` block that used to live
      in `router.ex` (C4-3b). The `TasksController` itself stays in core; this
      plugin only owns the route declarations.

    * `cli_commands/0` — the eight `task.*` CLI verbs (`ls`, `ready`, `prime`, `get`,
      `claim`, `close`, `next`, `move`) the `/v1/capabilities` manifest exposes. Five
      moved verbatim from `Barkpark.Plugins.Capabilities`'s core verb registry;
      `next` (the queue-based atomic claim) was added later. `task` is no
      longer a core noun: the capabilities controller now derives
      `source: "plugin:tasks"` provenance for these commands. The content-graph
      read verbs (`graph` / `graph-orphans` / `graph-dangling`) are NOT here —
      they live in the CORE verb registry (Goal ges/graph-edge-seam) so they
      survive the `:plugins, []` kill switch (the graph roots on ANY doc).

  The persisted `type` discriminator is still `"task"` and the API surface
  (`/v1/tasks`, `/v1/rail`) is unchanged — only the registration/scheduling/routing
  wiring became a plugin.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/tasks/plugin.json"

  @doc """
  Declares the `task` document type by delegating to
  `Barkpark.Tasks.schema_definitions/1`.

  `dataset` comes from `opts[:dataset]` when supplied (Bootstrap calls this with
  `[]`), defaulting to `"production"` — matching every other seed schema and the
  legacy `seeds.exs` loop this replaces.
  """
  @impl Barkpark.Plugin
  def register_schemas(opts) do
    dataset = Keyword.get(opts, :dataset, "production")
    Barkpark.Tasks.schema_definitions(dataset)
  end

  @doc """
  Contributes the Tasks desk group to the Studio Structure pane via the
  plugin desk-item highway (`Barkpark.Plugin.desk_items/1`, collected by
  `Barkpark.Plugins.Registry.collect_desk_items/1` after the host's
  built-in groups — see `Barkpark.Structure.build_desk_items/3`).

  One `:document_list` entry for the `task` type, gated on the `task`
  schema actually existing in the requested dataset — mirroring how the
  host groups gate on `Map.has_key?(schemas, name)`, so a dataset that
  never registered the task schema (e.g. a clean `bp setup` profile on a
  non-production dataset) gets no dead "Tasks" row. The list pane opens
  each task in the regular Studio form editor
  (`PaneBuilder`'s `:plugin_document_list` branch).
  """
  @impl Barkpark.Plugin
  def desk_items(dataset) do
    if task_schema_present?(dataset) do
      [%{type: :document_list, label: "Tasks", doc_type: "task", icon: "✅"}]
    else
      []
    end
  end

  # Failure-safe schema probe. The rescue/catch matters beyond defensive
  # style: the Registry's `resolver_is_default_lift?/4` fingerprint RUNS
  # `desk_items("production")` once at registration time — a context with
  # no DB sandbox ownership (tests) and possibly no Repo yet (boot). A
  # raise there would mis-fingerprint the default resolver as an author
  # override and log a spurious "defines both" warning on every
  # registration. No schema reachable → no desk entry, never a crash.
  defp task_schema_present?(dataset) do
    match?({:ok, _}, Barkpark.Content.get_schema("task", dataset))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  Contributes the two task Oban cron entries, moved verbatim from
  `config/config.exs`:

    * `{"* * * * *", Barkpark.Tasks.TtlSweeper}` — W7-05 TTL sweep, runs every
      minute (the finest Oban.Cron granularity; sub-minute cadence is
      intentionally not supported).
    * `{"0 */6 * * *", Barkpark.Tasks.Compactor}` — W7-06 task-document
      compaction, every six hours (coarser than the TTL sweep because
      compaction is batch storage maintenance, not real-time crash recovery; a
      per-task advisory lock serializes it with claim/close/sweep).

  Collected at boot by `Barkpark.Plugins.Registry.collect_oban_crontab/0` and
  appended to the host's `Oban.Plugins.Cron` `:crontab` (C4-1 boot merge).
  """
  @impl Barkpark.Plugin
  def oban_crontab do
    [
      {"* * * * *", Barkpark.Tasks.TtlSweeper},
      {"0 */6 * * *", Barkpark.Tasks.Compactor}
    ]
  end

  @doc """
  The eleven `/v1/tasks` endpoints the `bp task` CLI consumes, mirroring —
  byte-identical, order-preserving — the `scope "/v1/tasks"` block this replaces
  in `router.ex`
  (C4-3b). Every spec carries `auth: :token_root`, so the dormant host-level
  `scope "/v1", BarkparkWeb do … plugin_routes(scope: :token_root)` wrapper
  mounts them at `/v1/tasks/*` behind the `[:api, :require_token]` pipeline
  (authenticated bearer, NOT admin — claim/close are workflow ops, not document
  mutations; their atomicity lives in `Tasks.claim/2` + `Tasks.close/3`).

  Static routes are declared BEFORE the `/:doc_id` catchall so an empty path
  doesn't match as `:doc_id = ""` — the documented Phoenix static/dynamic
  disambiguation idiom. The `TasksController` stays in core; this plugin owns
  only the route declarations.
  """
  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      {:get, "/tasks", BarkparkWeb.TasksController, :index, auth: :token_root},
      {:get, "/tasks/ready", BarkparkWeb.TasksController, :ready, auth: :token_root},
      # prime must mount BEFORE /tasks/:doc_id or it resolves as a doc id.
      {:get, "/tasks/prime", BarkparkWeb.TasksController, :prime, auth: :token_root},
      {:post, "/tasks/claim", BarkparkWeb.TasksController, :claim, auth: :token_root},
      {:post, "/tasks/edges", BarkparkWeb.TasksController, :add_edge, auth: :token_root},
      {:get, "/tasks/:doc_id", BarkparkWeb.TasksController, :show, auth: :token_root},
      {:get, "/tasks/:doc_id/edges", BarkparkWeb.TasksController, :edges, auth: :token_root},
      {:post, "/tasks/:doc_id/claim", BarkparkWeb.TasksController, :claim_by_id,
       auth: :token_root},
      {:post, "/tasks/:doc_id/close", BarkparkWeb.TasksController, :close, auth: :token_root},
      {:post, "/tasks/:doc_id/labels", BarkparkWeb.TasksController, :relabel, auth: :token_root},
      {:post, "/tasks/:doc_id/papers", BarkparkWeb.TasksController, :papers, auth: :token_root},
      {:post, "/tasks/:doc_id/move", BarkparkWeb.TasksController, :move, auth: :token_root}
      # NOTE: the content-graph reads (/graph/orphans, /graph/dangling,
      # /graph/:id) are NO LONGER declared here. They moved to CORE
      # (router.ex `scope "/v1" … get("/graph/…")`) because the graph roots on
      # ANY content doc, not just tasks — so they must survive the
      # `config :barkpark, :plugins, []` kill switch (fresh-install invariant).
    ]
  end

  @doc """
  The CLI verbs Tasks contributes to the `/v1/capabilities` manifest (M3),
  moved verbatim from `Barkpark.Plugins.Capabilities`'s core verb registry (the
  C4 plugin lift — task is no longer a core noun). Each command is grounded in a
  `/v1/tasks` route that `register_routes/1` ABOVE actually mounts; the
  verb/method/path/auth_tier/args/flags are byte-identical to the former core
  definitions — only the provenance changes (the capabilities controller now
  stamps `source: "plugin:tasks"` instead of `"core"`).

  Eight verbs over eight routes, all `auth_tier: "read"` (the `/v1/tasks` scope is
  `:api + :require_token`, NOT admin — claim/close are bearer-gated workflow ops,
  not document mutations):

    * `ls` — `GET /v1/tasks` (paginated). READ, table.
    * `ready` — `GET /v1/tasks/ready` (paginated). READ, table.
    * `get` — `GET /v1/tasks/:doc_id`. READ, table.
    * `claim` — `POST /v1/tasks/:doc_id/claim`. WRITES, minimal receipt.
    * `close` — `POST /v1/tasks/:doc_id/close`. WRITES, minimal receipt.
    * `next` — `POST /v1/tasks/claim` (queue-based: atomically hand me the next
      ready task in priority order). WRITES, minimal receipt. Returns
      `{"ok":false,"reason":"no_ready"}` with HTTP 200 when the queue is empty —
      a valid outcome, not an error.
    * `move` — `POST /v1/tasks/:doc_id/move` (rail-l3 re-parent). WRITES, minimal
      receipt.
  """
  @impl Barkpark.Plugin
  def cli_commands do
    [
      %{
        id: "task.ls",
        noun: "task",
        verb: "ls",
        summary: "List tasks in the queue.",
        http: %{method: "GET", path_template: "/v1/tasks"},
        auth_tier: "read",
        args: [],
        flags: [
          %{name: "limit", type: "int", summary: "Max tasks to return.", default: 50}
        ],
        writes: false,
        batch: false,
        paginated: true,
        dry_run: false,
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "task.ready",
        noun: "task",
        verb: "ready",
        summary: "List ready (unblocked) tasks.",
        http: %{method: "GET", path_template: "/v1/tasks/ready"},
        auth_tier: "read",
        args: [],
        flags: [
          %{name: "limit", type: "int", summary: "Max tasks to return.", default: 50}
        ],
        writes: false,
        batch: false,
        paginated: true,
        dry_run: false,
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "task.prime",
        noun: "task",
        verb: "prime",
        summary:
          "One-call agent rehydration: my in-progress claims, the ready head, recent events, lifecycle counts.",
        http: %{method: "GET", path_template: "/v1/tasks/prime"},
        auth_tier: "read",
        args: [],
        flags: [
          %{
            name: "worker",
            type: "string",
            summary: "Narrow in_progress to this worker's claims."
          },
          %{name: "limit", type: "int", summary: "Ready-head and event-window size.", default: 10}
        ],
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "json",
        scoped_prefix: nil
      },
      %{
        id: "task.get",
        noun: "task",
        verb: "get",
        summary: "Fetch one task by id.",
        http: %{method: "GET", path_template: "/v1/tasks/:doc_id"},
        auth_tier: "read",
        args: [
          %{name: "doc_id", required: true, type: "string", summary: "Task document id."}
        ],
        flags: [],
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "task.claim",
        noun: "task",
        verb: "claim",
        summary: "Claim a ready task by id.",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/claim"},
        auth_tier: "read",
        args: [
          %{
            name: "doc_id",
            required: true,
            type: "string",
            summary: "Task document id to claim."
          },
          %{
            name: "worker_id",
            required: true,
            type: "string",
            summary: "Worker identity claiming the task."
          }
        ],
        flags: [
          %{
            name: "resources",
            type: "string",
            summary:
              "Comma-separated resource strings (e.g. file paths) to fence while this claim is live; 409 resource_conflict if another live claim holds any."
          },
          %{
            name: "observed_rail_rev",
            type: "string",
            summary:
              "The rail_rev (rail ETag) you last observed for this task's parent rail. When it differs from the current rail_rev the response carries a rail_changed notice — advisory, never a gate."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "task.close",
        noun: "task",
        verb: "close",
        summary:
          "Close a claimed task by id; --set 'criteria:=[…]' marks acceptance criteria met with evidence in the same atomic write. By default fences on a claim-time work digest: if the task's brief (title/description/acceptance_criteria) changed under your claim, the close 409s doc_changed_since_claim — re-read, then close again (or --set observed_rev=<rev> for strict full-rev CAS instead).",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/close"},
        auth_tier: "read",
        args: [
          %{
            name: "doc_id",
            required: true,
            type: "string",
            summary: "Task document id to close."
          },
          %{
            name: "worker_id",
            required: true,
            type: "string",
            summary: "Worker identity that holds the claim."
          },
          %{
            name: "observed_epoch",
            required: true,
            type: "int",
            summary: "Claim epoch returned at claim time (optimistic concurrency guard)."
          },
          %{
            name: "lifecycle_status",
            required: false,
            type: "string",
            summary: "done | cancelled | blocked (defaults to done when omitted)."
          },
          %{
            name: "reason",
            required: false,
            type: "string",
            summary: "One-line close rationale, persisted as content.close_reason."
          }
        ],
        flags: [
          %{
            name: "set",
            type: "string",
            repeatable: true,
            summary:
              "Extra close-body fields as key=value (key:=json for typed). The expectation " <>
                "close-out (task-proves-paper): --set 'criteria:=[{\"index\":0,\"met\":true," <>
                "\"evidence\":\"PR #123\"}]' flips acceptance_criteria met/evidence atomically " <>
                "with the close (same rev CAS — no separate racing mutation). Optional " <>
                "\"criterion\" per entry text-guards against a reordered/edited list (409 " <>
                "criteria_mismatch). Unmet criteria never block a close (soft warning only). " <>
                "--set observed_rev=<rev> pins the strict full-rev CAS and BYPASSES the default " <>
                "work-digest fence (use when you intend to close against the exact rev you read)."
          },
          %{
            name: "observed_rail_rev",
            type: "string",
            summary:
              "The rail_rev (rail ETag) you last observed for this task's parent rail. When it differs from the current rail_rev the response carries a rail_changed notice — advisory, never a gate."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "task.next",
        noun: "task",
        verb: "next",
        summary: "Atomically claim the next ready task (priority order).",
        http: %{method: "POST", path_template: "/v1/tasks/claim"},
        auth_tier: "read",
        args: [
          %{
            name: "worker_id",
            required: true,
            type: "string",
            summary: "Worker identity claiming the task."
          },
          %{
            name: "phase_id",
            required: false,
            type: "string",
            summary: "Restrict the claim to tasks under this phase id."
          }
        ],
        flags: [
          %{
            name: "observed_rail_rev",
            type: "string",
            summary:
              "The rail_rev (rail ETag) you last observed for the claimed task's parent rail. When it differs from the claimed task's current rail_rev the response carries a rail_changed notice — advisory, never a gate."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "task.move",
        noun: "task",
        verb: "move",
        summary:
          "Re-parent a task (rail-l3): move it under another task's rail, or omit new_parent_id to move it to the root. Emits a task.reparented event; the response carries the destination rail_rev + the source from_rail_rev.",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/move"},
        auth_tier: "read",
        args: [
          %{
            name: "doc_id",
            required: true,
            type: "string",
            summary: "Task document id to move."
          },
          %{
            name: "new_parent_id",
            required: false,
            type: "string",
            summary: "Destination parent task id; omit (or null) to move to the root."
          }
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      }
      # NOTE: the content-graph read verbs (graph / graph-orphans /
      # graph-dangling over /v1/graph/*) are NO LONGER declared here. They
      # moved to the CORE verb registry (Barkpark.Plugins.Capabilities, the
      # `graph` noun) because the content graph roots on ANY content doc — so
      # the verbs must survive the `config :barkpark, :plugins, []` kill switch
      # alongside their CORE-mounted /v1/graph/* routes (fresh-install
      # invariant).
    ]
  end

  @doc """
  Projects a task document's dependency + hierarchy edges into the content
  graph (Goal ges/graph-edge-seam Phase 3).

  Implemented as the RESOLVER form directly (not the bare additive
  `extract_edges/2`) — the `@resolver_callbacks` entry for
  `resolve_extract_edges` is `{nil, nil, nil, :none}`, so the registry collects
  ONLY the resolver form. This mirrors how plugins implement
  `resolve_doc_actions/2`. The default lift is supplied here explicitly:
  `prev ++ extract_edges(ctx.doc)`.

  PURE — no `get_document`, no `task_edges` query, no DB. It reads ONLY the doc
  payload:

    * `doc.task_edges` — the doc's HYDRATED `task_edges` rows. The authoritative
      dependency store is the `task_edges` table, NOT `content.dependencies`
      (which `Barkpark.Tasks.schema_definitions/1` documents as a DEAD KEY the
      engine never writes/reads). Because this callback must be pure, it cannot
      query `task_edges` itself — the EdgeProjector worker hydrates the rows onto
      the payload via `Tasks.hydrate_edges/1` BEFORE projection (see
      `Barkpark.EdgeProjector.ProjectorWorker`). Each hydrated row carries its
      real `:kind` (`"blocks"` | `"discovered-from"`) which is mapped STRAIGHT
      THROUGH — never hardcoded `"blocks"`. Both kinds are whitelisted in
      `Barkpark.Content.Edge`, so they pass changeset validation.
    * `content.parent_id` — the hierarchy parent → one `parent` edge
      (`from_id` = child, `to_id` = parent).

  When `doc.task_edges` is absent (an un-hydrated payload — e.g. a task saved
  outside the projector worker, or a non-task doc), NO dependency edge is
  emitted: the dead `content.dependencies` key is NEVER read, so an un-hydrated
  task simply contributes only its `parent` edge until the worker re-hydrates it
  on the next rebuild. The core Projector pass resolves dangling targets; this
  callback never does. Guards a `nil` `ctx.doc` (the `{nil, nil, nil, :none}`
  entry skips the registration-time fingerprint, so a nil-doc crash would only
  surface at collection time) → returns `prev` unchanged.
  """
  @impl Barkpark.Plugin
  def resolve_extract_edges(prev, ctx) do
    case Map.get(ctx, :doc) do
      nil -> prev
      doc -> prev ++ extract_edges(doc, ctx)
    end
  end

  @impl Barkpark.Plugin
  def extract_edges(nil, _ctx), do: []

  def extract_edges(doc, _ctx) do
    doc_id = Map.get(doc, :doc_id) || Map.get(doc, "doc_id")
    content = Map.get(doc, :content) || Map.get(doc, "content") || %{}

    if is_binary(doc_id) do
      from_id = Barkpark.Content.published_id(doc_id)

      dep_edges = dep_edges_from_task_edges(doc, from_id)
      parent_edges = parent_edge(content, from_id)

      dep_edges ++ parent_edges
    else
      []
    end
  end

  # Read the HYDRATED `task_edges` rows off the payload. The worker attaches
  # them as `doc.task_edges` — a list of `%{to_id: <doc_id>, kind: <kind>}` maps
  # (PKs already resolved back to doc_ids by `hydrate_edges/1`). Each row's real
  # `kind` is carried straight through (NEVER hardcoded "blocks"), so both
  # `blocks` AND `discovered-from` edges surface. An un-hydrated payload (no
  # `:task_edges` key) yields []. NEVER reads `content.dependencies` (DEAD KEY).
  defp dep_edges_from_task_edges(doc, from_id) do
    doc
    |> hydrated_task_edges()
    |> Enum.flat_map(fn row ->
      to = Map.get(row, :to_id) || Map.get(row, "to_id")
      kind = Map.get(row, :kind) || Map.get(row, "kind")

      if is_binary(to) and to != "" and is_binary(kind) and kind != "" do
        [
          %{
            from_id: from_id,
            to_id: Barkpark.Content.published_id(to),
            kind: kind,
            plugin_source: "tasks"
          }
        ]
      else
        []
      end
    end)
  end

  defp hydrated_task_edges(doc) do
    case Map.get(doc, :task_edges) || Map.get(doc, "task_edges") do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end

  defp parent_edge(content, from_id) do
    case Map.get(content, "parent_id") do
      parent when is_binary(parent) and parent != "" ->
        [
          %{
            from_id: from_id,
            to_id: Barkpark.Content.published_id(parent),
            kind: "parent",
            plugin_source: "tasks"
          }
        ]

      _ ->
        []
    end
  end

  @doc """
  Hydrate a task document's payload with its authoritative `task_edges` rows so
  the PURE `extract_edges/2` callback can project them WITHOUT a DB call.

  This is the seam that resolves the purity-vs-correctness contradiction: the
  real dependency data lives in the `task_edges` table (keyed on
  `documents.id`), but `extract_edges/2` must be pure. The EdgeProjector worker
  — which already touches the DB to list the corpus — calls this on each task
  doc BEFORE handing it to the projector. It:

    1. resolves the doc's PK (`documents.id`) — a `%Document{}` already carries
       it as `:id`;
    2. fetches the doc's OUTBOUND `task_edges` rows (`Tasks.edges(pk, direction:
       :outbound, kind: :all)` — every kind, not just `:blocks`);
    3. maps each row's `to_id` (a PK) back to its `doc_id` string, carrying the
       row's `kind`;
    4. attaches the result as `doc.task_edges` (`[%{to_id: doc_id, kind: kind}]`).

  Only `type == "task"` docs are hydrated; any other doc (or a doc whose PK
  cannot be resolved) is returned UNCHANGED. Returns the (possibly hydrated)
  doc.
  """
  @spec hydrate_edges(map()) :: map()
  def hydrate_edges(doc) when is_map(doc) do
    if task_doc?(doc) do
      case doc_pk(doc) do
        pk when is_binary(pk) ->
          rows =
            pk
            |> Barkpark.Tasks.edges(direction: :outbound, kind: :all)
            |> Enum.flat_map(&edge_row_to_payload/1)

          put_task_edges(doc, rows)

        _ ->
          doc
      end
    else
      doc
    end
  end

  def hydrate_edges(doc), do: doc

  # Map a `task_edges` row (PK-keyed) to the payload shape the pure callback
  # reads: `%{to_id: <doc_id>, kind: <kind>}`. Resolves the `to_id` PK back to
  # its `doc_id` string; drops the row if the target row no longer exists.
  defp edge_row_to_payload(%Barkpark.Tasks.Edge{to_id: to_pk, kind: kind}) do
    case Barkpark.Repo.get(Barkpark.Content.Document, to_pk) do
      %Barkpark.Content.Document{doc_id: to_doc_id} when is_binary(to_doc_id) ->
        [%{to_id: to_doc_id, kind: kind}]

      _ ->
        []
    end
  end

  defp edge_row_to_payload(_), do: []

  defp task_doc?(doc) do
    (Map.get(doc, :type) || Map.get(doc, "type") || Map.get(doc, "_type")) == "task"
  end

  defp doc_pk(%Barkpark.Content.Document{id: id}) when is_binary(id), do: id
  defp doc_pk(doc), do: Map.get(doc, :id) || Map.get(doc, "id")

  defp put_task_edges(%Barkpark.Content.Document{} = doc, rows),
    do: Map.put(doc, :task_edges, rows)

  defp put_task_edges(doc, rows) when is_map(doc), do: Map.put(doc, :task_edges, rows)
end
