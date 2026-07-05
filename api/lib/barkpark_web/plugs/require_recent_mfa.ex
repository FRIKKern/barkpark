defmodule BarkparkWeb.Plugs.RequireRecentMfa do
  @moduledoc """
  Step-up MFA gate for sensitive USER actions.

  When the authenticated user has an MFA factor armed (i.e. they opted into
  security), this plug requires that their current session presented a fresh
  factor within the step-up window (`UserSession.mfa_fresh?/1`). A stale or
  absent step-up halts with `401 mfa_required`: the client calls
  `POST /v1/auth/mfa/step-up` with a current code, then retries the action.
  Every challenge is recorded on the audit chain.

  A user WITHOUT MFA enrolled is NOT gated — step-up is opt-in, so the common
  case carries zero added friction. Must run AFTER `RequireUserSession`, whose
  assigns (`:current_user`, `:current_user_session`) it reads; if those are
  absent it fails closed.
  """
  import Plug.Conn
  alias Barkpark.Accounts
  alias Barkpark.Accounts.UserSession

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns[:current_user]
    session = conn.assigns[:current_user_session]

    cond do
      is_nil(user) or is_nil(session) ->
        # RequireUserSession must precede us; if it didn't, fail closed.
        challenge(conn, nil)

      not Accounts.mfa_enrolled?(user) ->
        conn

      UserSession.mfa_fresh?(session) ->
        conn

      true ->
        challenge(conn, user)
    end
  end

  defp challenge(conn, user) do
    Barkpark.Audit.emit(%{
      category: "auth",
      action: "mfa_challenged",
      subject: user && user.id,
      actor_type: "user",
      actor_id: user && user.id,
      metadata: %{"reason" => "step_up_required", "path" => conn.request_path}
    })

    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{
      error: %{
        code: "mfa_required",
        message: "a recent MFA verification is required for this action",
        hint: "call POST /v1/auth/mfa/step-up with a current code, then retry"
      }
    })
    |> halt()
  end
end
