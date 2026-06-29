defmodule BarkparkCloud.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # The control plane's only stateful dependency: its own Postgres,
        # which stores METADATA about many independent Barkpark instances
        # (never customer content). Identity/registry schemas land in
        # cloud-8/9; this skeleton just brings the Repo up.
        BarkparkCloud.Repo,
        # oban-substrate: the job + cron engine. Positioned right after Repo (its
        # only dependency) and before Events/web so recurring jobs can fire and
        # request handlers can enqueue the moment the plane is up. Config (queues
        # + Pruner + Cron) lives in config.exs; test.exs sets testing: :manual so
        # the Sandbox stays deterministic. `fetch_env!` so a missing/typo'd config
        # block fails loudly at boot rather than silently running a zero-queue
        # Oban. Oban supervises its own queues + plugins internally, so a queue
        # crash never takes down Repo or web under :one_for_one.
        {Oban, Application.fetch_env!(:barkpark_cloud, Oban)},
        # The :pg scope behind the live dashboard's SSE stream
        # (BarkparkCloud.Events). Started here (not in web_children) so it is up
        # in EVERY env — including test, where broadcasts are harmless no-ops —
        # and is ready before the web listener accepts the first /v1/events
        # connection.
        BarkparkCloud.Events
      ] ++ web_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BarkparkCloud.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The cloud-12a JSON API runs on Bandit serving BarkparkCloud.Web.Router. The
  # port comes from config; `server: false` (the test default) leaves the HTTP
  # listener out of the tree entirely, since the router is exercised directly via
  # Plug.Test — no live socket needed.
  defp web_children do
    config = Application.get_env(:barkpark_cloud, BarkparkCloud.Web.Endpoint, [])

    if Keyword.get(config, :server, true) do
      [{Bandit, plug: BarkparkCloud.Web.Router, port: Keyword.get(config, :port, 4100)}]
    else
      []
    end
  end
end
