defmodule BarkparkWeb.Plugs.RequireIngestToken do
  @moduledoc """
  Authenticates the paper-ingest POST.

  Authorizes a request when EITHER:

    * the bearer constant-time matches the EFFECTIVE ingest token from
      `Barkpark.Secrets.ingest_token/0` — DB-first (the rotatable cloud secret),
      env-fallback (`config :barkpark, :ingest_token`, wired from
      `BARKPARK_INGEST_TOKEN` in `config/runtime.exs`). This is the original
      **shared secret** for paper ingest, deliberately NOT the SHA256
      `api_tokens` table. Compared with `Plug.Crypto.secure_compare` so a
      timing side-channel cannot leak the secret; OR

    * the bearer resolves to a VALID ADMIN `api_tokens` row —
      `Barkpark.Auth.verify_token/1` returns a live token whose permissions
      satisfy admin per `Barkpark.Tenancy.Auth.permits?/2`. This lets an admin
      drive ingest without provisioning the shared secret.

  Rejects with 401 when the header is absent/empty, or when neither path
  authorizes.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> presented] when is_binary(presented) and presented != "" ->
        if ingest_secret_match?(presented) or admin_token?(presented) do
          conn
        else
          reject(conn)
        end

      _ ->
        reject(conn)
    end
  end

  # Constant-time compare against the effective (DB-first, env-fallback) ingest
  # shared secret. nil/empty effective secret → no match (never authorizes the
  # secret path).
  defp ingest_secret_match?(presented) do
    case Barkpark.Secrets.ingest_token() do
      expected when is_binary(expected) and expected != "" ->
        Plug.Crypto.secure_compare(presented, expected)

      _ ->
        false
    end
  end

  # A valid, non-revoked, non-expired api_token whose permissions satisfy admin.
  defp admin_token?(presented) do
    case Barkpark.Auth.verify_token(presented) do
      {:ok, token} -> Barkpark.Tenancy.Auth.permits?(token, :admin)
      _ -> false
    end
  end

  defp reject(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{error: %{code: "unauthorized", message: "invalid ingest token"}})
    |> halt()
  end
end
