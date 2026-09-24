defmodule Barkpark.Auth.RotationRetireWorker do
  @moduledoc """
  Retires a rotated token when its grace window ends
  (`Barkpark.Auth.rotate_token/3`).

  The token has already STOPPED authenticating by then: its `expires_at` is the
  window's end, and `Auth.verify_token/1` rejects an expired row in its WHERE
  clause. This job adds what expiry alone does not: `revoked_at` for the record,
  the `token_revoked` audit row, and the socket-teardown broadcast — an open
  socket verified once at connect and would otherwise outlive the expiry.

  Idempotent: a missing or already-revoked token is a no-op. A job that runs
  before the window ends (clock skew, a manual drain) snoozes rather than
  revoking early.
  """
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [keys: [:token_id], period: 60]

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"token_id" => token_id}}) do
    case Repo.get(ApiToken, token_id) do
      nil ->
        :ok

      %ApiToken{revoked_at: %DateTime{}} ->
        :ok

      %ApiToken{expires_at: %DateTime{} = exp} = token ->
        case DateTime.diff(exp, DateTime.utc_now(), :second) do
          wait when wait > 0 -> {:snooze, wait}
          _ -> revoke(token)
        end

      %ApiToken{} = token ->
        revoke(token)
    end
  end

  defp revoke(token) do
    case Auth.revoke_token(token) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
