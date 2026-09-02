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

  ## The admin arm assigns `:api_token` (task-ef3eb91bf7f87d4c)

  The two arms carry DIFFERENT tenant information, and until this plug said so
  the `:ingest` pipeline threw both away: it resolved no workspace at all, so
  every `auth: :ingest` controller read and wrote with a nil scope. The sheets
  export door then served ANY tenant's sheet by slug (and raised
  `Ecto.MultipleResultsError` → 500 on a same-slug collision), while the sheets
  import door wrote through `Content.WriteScope`'s seeded-Default fallback.

  So the admin arm now assigns the full `%Barkpark.Auth.ApiToken{}` the way
  `RequireBearerOrSessionToken` / `OptionalToken` do. That assign is the ONLY
  thing this auth plug does about tenancy — the derivation itself stays where
  it belongs, in the pipeline: `DeriveWorkspaceFromToken` turns the assign into
  `:current_workspace`, and `AssignDefaultScope` catches the shared-secret arm
  (which carries NO workspace binding — `Barkpark.Secrets.ingest_token/0` is
  the `:global` tier, an instance-wide secret) on the seeded Default Workspace.
  Default is deliberately the shared secret's tenant: it is what `WriteScope`
  already stamps on an unscoped write, so existing sheets stay reachable.
  """
  import Plug.Conn

  alias Barkpark.Auth.ApiToken

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> presented] when is_binary(presented) and presented != "" ->
        # Shared secret first, so the constant-time compare keeps its
        # precedence; only then the (DB-hitting) admin-token arm.
        if ingest_secret_match?(presented) do
          conn
        else
          case admin_token(presented) do
            %ApiToken{} = token -> assign(conn, :api_token, token)
            nil -> reject(conn)
          end
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
  # Returns the TOKEN (not a boolean) so the caller can assign it — the
  # workspace binding lives on the row and is what the pipeline derives from.
  defp admin_token(presented) do
    with {:ok, %ApiToken{} = token} <- Barkpark.Auth.verify_token(presented),
         true <- Barkpark.Tenancy.Auth.permits?(token, :admin) do
      token
    else
      _ -> nil
    end
  end

  # Route through the ONE shared emitter so the 401 carries request_id (+ the
  # code-keyed hint) for log correlation — it was hand-built without it before.
  defp reject(conn) do
    BarkparkWeb.ErrorResponse.emit_custom(
      conn,
      :unauthorized,
      "unauthorized",
      "invalid ingest token"
    )
  end
end
