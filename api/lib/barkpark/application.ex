defmodule Barkpark.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Barkpark.RateLimiter,
      BarkparkWeb.Telemetry,
      Barkpark.Repo,
      Barkpark.Vault,
      # WI1: plugin registry — must come up before workers/endpoint so any
      # later boot hook that calls Barkpark.Plugins.Registry has a live PID.
      Barkpark.Plugins.Registry,
      # Task barkpark-otv: in-memory run-status tracker the plugin admin LV
      # reads to surface "last bootstrap" / "last seed" timestamps. Must
      # come up before the post-boot Task that calls Bootstrap +
      # codelist seeders so the very first sweep's results land in the
      # map. Empty-state if absent — never crashes the caller.
      Barkpark.Plugins.RunStatus,
      # Phase 3 WI1: cross-field validation kernel — registry of value-
      # checkers (ETS-backed) and per-schema rule cache. Both must be up
      # before the endpoint can serve mutate/export traffic.
      Barkpark.Validation.Registry,
      Barkpark.Content.Validation.Rules,
      # Phase 7 WI3: OAuth2 token cache for Bokbasen ingestion. Lazy —
      # does not fetch a token at boot; first Auth.token/0 call triggers
      # the first fetch.
      Barkpark.Plugins.OnixEdit.Bokbasen.Auth,
      {Oban, Application.fetch_env!(:barkpark, Oban)},
      {DNSCluster, query: Application.get_env(:barkpark, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Barkpark.PubSub},
      # Start a worker by calling: Barkpark.Worker.start_link(arg)
      # {Barkpark.Worker, arg},
      BarkparkWeb.Presence,
      {Task.Supervisor, name: Barkpark.TaskSupervisor},
      # Start to serve requests, typically the last entry
      BarkparkWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Barkpark.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = ok ->
        Barkpark.Telemetry.Handlers.attach()

        # WI1: plugin registry — boot-time discovery runs in a supervised
        # one-shot Task so a slow filesystem walk never blocks startup.
        # Phase 3 WI3: after discovery completes, walk the registered
        # plugins and load their declared checkers into the validation
        # registry. Sequential inside one task — order matters (checkers
        # need plugins to be present first), but neither blocks endpoint.
        Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
          Barkpark.Plugins.Registry.discover_and_register()
          # Task 5: persist each plugin's `register_schemas/1` output via
          # `Content.upsert_schema/2`. Idempotent on `(name, dataset)`. Per-
          # plugin try/rescue inside Bootstrap keeps a bad plugin from
          # tanking the whole sweep — never crashes app start.
          Barkpark.Plugins.Bootstrap.register_all_schemas()
          # Phase 3 WI1: pull `checkers/0` slots out of every plugin
          # registered above and namespace them as
          # `plugin:<name>:<checker>` in the value-checker registry.
          Barkpark.Validation.Registry.reload_plugin_checkers()
          # Task barkpark-auo: every plugin contributes its codelist
          # seeders via the `Barkpark.Plugin.codelist_seeders/0` callback.
          # `Plugins.Registry.run_all_codelist_seeders/0` walks the
          # registered plugins and invokes each seeder in a per-seeder
          # try/rescue so one bad plugin never breaks the others. Runs
          # after `register_all_schemas/0` so the alias resolver in
          # `Codelists.get/2` already has the schemas (and their
          # `onix.codelistId: N` metadata) when the first render hits.
          Barkpark.Plugins.Registry.run_all_codelist_seeders()
        end)

        ok

      other ->
        other
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BarkparkWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
