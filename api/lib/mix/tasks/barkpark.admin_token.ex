defmodule Mix.Tasks.Barkpark.AdminToken do
  @moduledoc """
  Mint a new admin token from the server when the admin token file is lost:

      sudo /opt/barkpark/api/start.sh admin-token --label "admin (recovered)"
      MIX_ENV=prod mix barkpark.admin_token --label <label> [--file <path>] [--force]

  The token goes to `--file` (default `/etc/barkpark/admin-token`, mode 0600)
  and its id to `<file>.id`. Only the id and the path are printed. An existing
  file is kept unless `--force`. The release twin is
  `/app/bin/admin-token`, which calls `Barkpark.Release.admin_token/0`.
  See `Barkpark.Auth.AdminTokenRecovery`.
  """
  @shortdoc "Mint an admin token to a root-only file (server-side recovery)"

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # The narrowed tree: no listener, no Oban, so it runs beside the live
    # server without taking its port.
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    case Barkpark.Auth.AdminTokenRecovery.cli(argv) do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
