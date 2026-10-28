defmodule Mix.Tasks.Barkpark.TokenSeat do
  @moduledoc """
  Seat an existing API token in more workspaces, from the server:

      MIX_ENV=prod mix barkpark.token_seat --token <id> --workspace <slug> [--apply]

  `--workspace` repeats. Without `--apply` it is a dry run. On a box with
  blue/green slots, run it with the active slot's env, as `docs/ops/PROD_OPS.md`
  shows for operator one-shots. See `Barkpark.Auth.TokenSeatRepair`.
  """
  @shortdoc "Seat an existing API token in more workspaces (server-side repair)"

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # The narrowed tree: no listener, no Oban, so it runs beside the live
    # server without taking its port.
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    case Barkpark.Auth.TokenSeatRepair.cli(argv) do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
