defmodule BarkparkCloud.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # The control plane's only stateful dependency: its own Postgres,
      # which stores METADATA about many independent Barkpark instances
      # (never customer content). Identity/registry schemas land in
      # cloud-8/9; this skeleton just brings the Repo up.
      BarkparkCloud.Repo
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BarkparkCloud.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
