defmodule Mix.Tasks.Barkpark.RotatePublicRead do
  @moduledoc """
  Rotate the weekly `public-read` API token by hand, now.

  The scheduled rotation is the core job `Barkpark.Auth.PublicReadRotationWorker`
  (Mondays 03:00 UTC, off unless `BARKPARK_PUBLIC_READ_ROTATION=on`). This task
  runs the same `Barkpark.Auth.PublicRead.rotate/1` once, whatever the switch
  says: mint `public-read-<ISO date>`, write the token file (0600), POST
  `VERCEL_DEPLOY_HOOK` if set, purge `public-read-*` rows older than 8 days.

  `/opt/barkpark/api/start.sh rotate-public-read` runs it on a box.
  """
  @shortdoc "Rotate the public-read API token"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Barkpark.Auth.PublicRead.rotate() do
      {:ok, %{label: label, purged: purged}} ->
        IO.puts("rotated public-read token label=#{label} purged=#{purged}")
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "rotation failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
