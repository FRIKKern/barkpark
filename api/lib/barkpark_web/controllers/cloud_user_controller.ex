defmodule BarkparkWeb.CloudUserController do
  @moduledoc """
  `POST /v1/auth/cloud-users/deprovision` — owner ruling #26 (2026-10-03,
  "Match role, revoke"): when a person is removed from the Barkpark Cloud team
  that owns this instance, the control plane calls this with the stored
  instance admin token to sign them out, drop their workspace seats and revoke
  the tokens they own here (`Barkpark.Auth.deprovision_cloud_user/1`).

  Same gate as the EMAIL form of `POST /v1/auth/login-tickets`, its sibling: it
  acts on any account by email, so it is an instance-level power. The bearer
  must hold `admin` (a lesser token gets the generic 401), and when the
  platform-operator allowlist is armed the bearer must be on it (403
  `required: platform_operator`).

  Body: `{"email": "person@example.com"}` → 200 `{found, sessions_revoked,
  memberships_dropped, tokens_revoked}`. An unknown email is 200 `found:
  false` — removal is idempotent, so a retry after a lost response converges.
  """
  use BarkparkWeb, :controller

  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.Plugs.RequirePlatformOperator

  def deprovision(conn, params) do
    token = conn.assigns[:api_token]

    cond do
      not Barkpark.Auth.has_permission?(token, "admin") ->
        ErrorResponse.emit(conn, {:error, :unauthorized})

      not RequirePlatformOperator.permits?(token) ->
        env = Barkpark.Content.Errors.to_envelope({:error, :forbidden}, conn)
        body = env |> Map.delete(:status) |> Map.put(:required, "platform_operator")

        conn
        |> put_status(env.status)
        |> json(%{error: body})

      true ->
        case params["email"] do
          email when is_binary(email) ->
            if String.contains?(email, "@") do
              {:ok, result} = Barkpark.Auth.deprovision_cloud_user(email)
              json(conn, result)
            else
              unprocessable(conn)
            end

          _ ->
            unprocessable(conn)
        end
    end
  end

  defp unprocessable(conn) do
    ErrorResponse.emit_fields(conn, :unprocessable_entity, %{
      code: "unprocessable",
      message: "email is required and must be an address"
    })
  end
end
