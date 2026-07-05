defmodule BarkparkWeb.Plugs.RequireOrgMfaEnrolment do
  @moduledoc """
  Org-wide MFA enrolment gate (era-w2-org-require-mfa) — the blunt overlay on
  top of opt-in step-up (#1140).

  When any organization governing the current user sets `require_mfa`
  (governing rule: ANY-org-requires → enforce, strictest-wins — see
  `Barkpark.Tenancy.org_requires_mfa_for_user?/1`) and the user has NO factor
  enrolled, every session-authenticated route halts with
  `403 mfa_enrolment_required` EXCEPT the paths the user needs to comply:
  reading their own state (`/me`), logging out, and the TOTP/passkey enrolment
  endpoints. Once a factor is enrolled the gate opens (enrolled users skip the
  org lookup entirely).

  Runs AFTER `RequireUserSession` (reads `:current_user`); absent that assign
  it fails closed. With no org requiring MFA the gate adds one indexed EXISTS
  query for unenrolled users and changes NOTHING observable — the opt-in,
  zero-tax contract.
  """
  import Plug.Conn
  alias Barkpark.Accounts
  alias Barkpark.Tenancy

  # Paths a gated user may still reach — exactly what's needed to see their
  # state, enrol a factor (TOTP or passkey), or leave. Everything else 403s.
  @exempt_paths [
    ["v1", "auth", "me"],
    ["v1", "auth", "logout"],
    ["v1", "auth", "mfa", "enroll"],
    ["v1", "auth", "mfa", "verify"],
    ["v1", "auth", "webauthn", "register", "challenge"],
    ["v1", "auth", "webauthn", "register"]
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns[:current_user]

    cond do
      is_nil(user) ->
        # RequireUserSession must precede us; if it didn't, fail closed.
        halt_enrolment_required(conn, nil)

      conn.path_info in @exempt_paths ->
        conn

      Accounts.mfa_enrolled?(user) ->
        conn

      not Tenancy.org_requires_mfa_for_user?(user.id) ->
        conn

      true ->
        halt_enrolment_required(conn, user)
    end
  end

  defp halt_enrolment_required(conn, user) do
    Barkpark.Audit.emit(%{
      category: "auth",
      action: "mfa_enrolment_required",
      subject: user && user.id,
      actor_type: "user",
      actor_id: user && user.id,
      metadata: %{"reason" => "org_require_mfa", "path" => conn.request_path}
    })

    conn
    |> put_status(403)
    |> Phoenix.Controller.json(%{
      error: %{
        code: "mfa_enrolment_required",
        message: "an organization you belong to requires MFA — enrol a factor to continue",
        hint:
          "enrol TOTP via POST /v1/auth/mfa/enroll + /verify, or a passkey via " <>
            "POST /v1/auth/webauthn/register/challenge + /register, then retry"
      }
    })
    |> halt()
  end
end
