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
        BarkparkCloud.Repo
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
