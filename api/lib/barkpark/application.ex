defmodule Barkpark.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Goal barkpark-G1, task s2: ask the Plugins.Registry for every plugin-
    # contributed child spec BEFORE constructing the supervision tree. The
    # call is a pure function — Registry.collect_workers/1 does NOT depend
    # on the Registry GenServer being alive, which is essential because the
    # Registry process is itself a child below. See its moduledoc for the
    # source-of-truth precedence (Application env wins; otherwise sync disk
    # walk of priv/plugins). Per the locked Q1 grill decision, topology is
    # compile-time static — hot-reload is out of scope for v1.
    plugin_children = Barkpark.Plugins.Registry.collect_workers(%{phase: :boot})

    children =
      [
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
        Barkpark.Content.Validation.Rules
        # Plugin-contributed workers fold in BELOW (was: a hardcoded plugin
        # GenServer child here). Position between host services and Oban so
        # plugin workers can rely on Repo/Vault/Registry being up, but come
        # up before the endpoint serves traffic.
      ] ++
        plugin_children ++
        [
          # Boot-order fix: SchemaBootstrap runs SYNCHRONOUSLY here, after the
          # Repo + Plugins.Registry GenServer (above) and BEFORE Oban. The
          # supervisor blocks on its init/1 (which registers every plugin's
          # schemas) before starting Oban, so Oban can never dequeue a job
          # against an unregistered schema. No paused queues, no resume loop.
          Barkpark.SchemaBootstrap,
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

        # Plugin discovery + schema/checker/seeder registration now runs
        # synchronously in Barkpark.SchemaBootstrap (a child positioned
        # before the Oban child above), so it has completed by the time the
        # supervisor returns {:ok, _pid} here. Nothing left to do post-boot.

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
