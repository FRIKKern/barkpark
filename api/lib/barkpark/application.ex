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
