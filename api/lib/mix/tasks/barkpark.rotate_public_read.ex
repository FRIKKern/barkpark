defmodule Mix.Tasks.Barkpark.RotatePublicRead do
  @moduledoc """
  Rotate the weekly `public-read` API token.

  Generates a fresh opaque token, inserts an `api_tokens` row labelled
  `public-read-<ISO date>`, writes the plaintext to the env file consumed
  by the Next.js deploy hook (chmod 0600), POSTs the new token to
  `VERCEL_DEPLOY_HOOK` if set, and purges `public-read-*` rows older than
  8 days (a 24 h grace window beyond the weekly cadence).

  Invoked weekly by `barkpark-rotate-public-token.timer` via
  `/opt/barkpark/api/start.sh rotate-public-read`.
  """
  @shortdoc "Rotate the public-read API token"

  use Mix.Task
  require Logger

  @token_file_default "/opt/barkpark/.env.public_token"
  @grace_seconds 8 * 24 * 60 * 60

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    label = "public-read-" <> Date.to_iso8601(Date.utc_today())

    with {:ok, raw, _row} <- Barkpark.Auth.PublicRead.create_public_read_token(label),
         :ok <- write_token_file(raw),
         :ok <- maybe_notify_deploy_hook(raw),
         {:ok, purged} <-
           Barkpark.Auth.PublicRead.purge_public_read_older_than(grace_cutoff()) do
      IO.puts("rotated public-read token label=#{label} purged=#{purged}")
      :ok
    else
      {:error, reason} ->
        IO.puts(:stderr, "rotation failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp grace_cutoff do
    DateTime.utc_now() |> DateTime.add(-@grace_seconds, :second)
  end

  defp token_file_path do
    System.get_env("PUBLIC_READ_TOKEN_FILE") || @token_file_default
  end

  defp write_token_file(raw) do
    path = token_file_path()

    case File.write(path, raw <> "\n") do
      :ok ->
        _ = File.chmod(path, 0o600)
        :ok

      {:error, reason} ->
        {:error, {:token_file, path, reason}}
    end
  end

  defp maybe_notify_deploy_hook(raw) do
    case System.get_env("VERCEL_DEPLOY_HOOK") do
      nil ->
        Logger.info("VERCEL_DEPLOY_HOOK not set; skipping deploy notify")
        :ok

      hook ->
        case Req.post(hook, json: %{"public_read_token" => raw}, retry: false) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            :ok

          other ->
            Logger.warning("deploy hook POST failed: #{inspect(other)}")
            :ok
        end
    end
  end
end
