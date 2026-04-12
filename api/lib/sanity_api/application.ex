defmodule SanityApi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SanityApiWeb.Telemetry,
      SanityApi.Repo,
      {DNSCluster, query: Application.get_env(:sanity_api, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SanityApi.PubSub},
      # Start a worker by calling: SanityApi.Worker.start_link(arg)
      # {SanityApi.Worker, arg},
      # Start to serve requests, typically the last entry
      SanityApiWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SanityApi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SanityApiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
