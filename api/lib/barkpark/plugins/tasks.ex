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
end
