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
      # Phase 3 WI1: cross-field validation kernel — registry of value-
      # checkers (ETS-backed) and per-schema rule cache. Both must be up
      # before the endpoint can serve mutate/export traffic.
      Barkpark.Validation.Registry,
      Barkpark.Content.Validation.Rules,
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
        Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
          Barkpark.Plugins.Registry.discover_and_register()
          # Phase 3 WI1: pull `checkers/0` slots out of every plugin
          # registered above and namespace them as
          # `plugin:<name>:<checker>` in the value-checker registry.
          Barkpark.Validation.Registry.reload_plugin_checkers()
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
