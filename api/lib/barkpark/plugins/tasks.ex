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

  The persisted `type` discriminator is still `"task"` and the API surface
  (`/v1/tasks`, `/v1/rail`) is unchanged — only the registration/scheduling
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
end
