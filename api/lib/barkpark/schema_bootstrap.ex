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
    # Registration is intentionally synchronous so Oban cannot start before
    # every schema is available. A large production corpus can legitimately
    # take longer than GenServer's default five-second init deadline; without
    # an explicit infinite deadline the caller brutally kills this process and
    # the root application exits with the otherwise opaque reason `:killed`.
    GenServer.start_link(__MODULE__, :ok, timeout: :infinity)
  end

  @impl true
  def init(:ok) do
    # Authoring-excellence D12: the CORE `tag` schema registers BEFORE (outside)
    # the defensive try/rescue below — deliberately. That rescue exists to keep
    # one broken PLUGIN from taking down boot; a core type that cannot register
    # is a hard bug, and letting the rescue log-and-swallow it would boot a
    # system whose publish wall can never resolve a tag. Registration failure
    # RAISES here, so boot fails CLOSED. Direct `Content.upsert_schema` (via
    # `TagRegistry.register!/1`, idempotent on `(name, dataset)`) — never
    # `Plugins.Bootstrap.register_all_schemas/0`, whose `Registry.all()` walk
    # is EMPTY under `config :barkpark, :plugins, []`.
    #
    # Config-gated OFF in the test env only (same sandbox constraint as the
    # codelist seeders below: this GenServer boots before any test owns a
    # connection). Tests prove the registration path by calling
    # `TagRegistry.register!/1` directly — see tag_registry_test.exs.
    if Application.get_env(:barkpark, :run_boot_core_schema_registration, true) do
      Barkpark.Content.TagRegistry.register!("production")
    end

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
      #
      # Skippable in the test env (config :barkpark, :run_boot_codelist_seeders):
      # under the Ecto SQL Sandbox this GenServer runs at app boot before any
      # test owns a connection, so its DB writes raise "cannot find ownership
      # process" — caught here, but the failed writes intermittently cascade into
      # unrelated async test setups. Codelist DATA isn't boot-seeded in test
      # anyway (these writes fail), so tests that need it seed explicitly; skipping
      # the boot pass removes the flake source without changing what's available.
      if Application.get_env(:barkpark, :run_boot_codelist_seeders, true) do
        Barkpark.Plugins.Registry.run_all_codelist_seeders()
      end
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
