defmodule Barkpark.SchemaBootstrap do
  @moduledoc """
  One-shot supervised child that registers every plugin's schemas,
  validation checkers, and codelist seeders SYNCHRONOUSLY at boot.

  Boot-order contract: a `Supervisor` starts children sequentially and
  blocks on each child's `start_link/1` (and the `init/1` it runs) before
  starting the next one. By positioning this child AFTER the Repo + the
  `Plugins.Registry` GenServer and BEFORE the `{Oban, ...}` child, every
  plugin schema is registered before Oban can dequeue a single job — so a
  worker never runs against a schema that does not exist yet. No paused
  queues, no resume loop, no stall window.

  `init/1` returns `:ignore`: the work is a pure boot-time side-effect, so
  there is nothing to supervise afterwards. `:ignore` tells the supervisor
  "this child is done — move on to the next" without leaving a process in
  the tree.

  Per-plugin fault isolation lives INSIDE each call below
  (`discover_and_register/0` skips a bad dir with a warning,
  `register_all_schemas/0` accumulates per-plugin errors without raising,
  the seeders catch per-seeder) — one broken plugin logs and the boot
  continues. We wrap the whole sequence in a defensive `try/rescue` so an
  unexpected error in registration is logged and still lets boot proceed
  (Oban then dequeues against whatever schemas DID register), rather than
  taking down the application supervisor.
  """

  use GenServer

  require Logger

  @spec start_link(term()) :: :ignore
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    try do
      # WI1: discover plugins from disk (or the configured whitelist) and
      # register them into the live Plugins.Registry GenServer, which is
      # already up at this point in the tree.
      Barkpark.Plugins.Registry.discover_and_register()

      # Task 5: persist each plugin's `register_schemas/1` output via
      # `Content.upsert_schema/2`. Idempotent on `(name, dataset)`. Per-
      # plugin error accumulation inside Bootstrap keeps a bad plugin from
      # tanking the whole sweep.
      Barkpark.Plugins.Bootstrap.register_all_schemas()

      # Phase 3 WI1: pull `checkers/0` slots out of every registered plugin
      # and namespace them as `plugin:<name>:<checker>` in the value-checker
      # registry.
      Barkpark.Validation.Registry.reload_plugin_checkers()

      # Task barkpark-auo: run every plugin's codelist seeders. Per-seeder
      # try/rescue inside the call keeps one bad plugin from breaking the
      # others. Runs after `register_all_schemas/0` so the alias resolver in
      # `Codelists.get/2` already has the schemas (and their
      # `onix.codelistId: N` metadata) when the first render hits.
      Barkpark.Plugins.Registry.run_all_codelist_seeders()
    rescue
      e ->
        Logger.error(
          "Barkpark.SchemaBootstrap: registration raised — " <>
            "#{Exception.format(:error, e, __STACKTRACE__)}"
        )
    end

    :ignore
  end
end
