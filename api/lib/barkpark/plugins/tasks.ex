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

    * `register_routes/1` — the ten `/v1/tasks` endpoints the `bin/bd-shim`
      translator hits, declared with `auth: :token_root` so the dormant
      host-level `scope "/v1", BarkparkWeb do … plugin_routes(scope: :token_root)`
      wrapper mounts them at `/v1/tasks/*` behind the `[:api, :require_token]`
      pipeline. Replaces the explicit `scope "/v1/tasks"` block that used to live
      in `router.ex` (C4-3b). The `TasksController` itself stays in core; this
      plugin only owns the route declarations.

    * `cli_commands/0` — the seven `task.*` CLI verbs (`ls`, `ready`, `prime`, `get`,
      `claim`, `close`, `next`) the `/v1/capabilities` manifest exposes. Five
      moved verbatim from `Barkpark.Plugins.Capabilities`'s core verb registry;
      `next` (the queue-based atomic claim) was added later. `task` is no
      longer a core noun: the capabilities controller now derives
      `source: "plugin:tasks"` provenance for these commands.

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
  The ten `/v1/tasks` endpoints `bin/bd-shim` hits, mirroring — byte-identical,
  order-preserving — the `scope "/v1/tasks"` block this replaces in `router.ex`
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
      {:post, "/tasks/:doc_id/papers", BarkparkWeb.TasksController, :papers, auth: :token_root}
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

  Seven verbs over seven routes, all `auth_tier: "read"` (the `/v1/tasks` scope is
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
          %{name: "worker", type: "string", summary: "Narrow in_progress to this worker's claims."},
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
          %{name: "doc_id", required: true, type: "string", summary: "Task document id to claim."},
          %{name: "worker_id", required: true, type: "string", summary: "Worker identity claiming the task."}
        ],
        flags: [],
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
        summary: "Close a claimed task by id.",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/close"},
        auth_tier: "read",
        args: [
          %{name: "doc_id", required: true, type: "string", summary: "Task document id to close."},
          %{name: "worker_id", required: true, type: "string", summary: "Worker identity that holds the claim."},
          %{name: "observed_epoch", required: true, type: "int", summary: "Claim epoch returned at claim time (optimistic concurrency guard)."},
          %{name: "lifecycle_status", required: false, type: "string", summary: "done | cancelled | blocked (defaults to done when omitted)."}
        ],
        flags: [],
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
          %{name: "worker_id", required: true, type: "string", summary: "Worker identity claiming the task."},
          %{name: "phase_id", required: false, type: "string", summary: "Restrict the claim to tasks under this phase id."}
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      }
    ]
  end
end
