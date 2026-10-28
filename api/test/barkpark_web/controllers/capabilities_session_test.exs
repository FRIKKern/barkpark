defmodule BarkparkWeb.CapabilitiesSessionTest do
  @moduledoc """
  `tier_of/1` ranks API tokens and answers "none" for a login session, and bp
  reads "none" with a token present as a refused credential. So
  `GET /v1/capabilities` echoes a session bearer as "read", which also lists
  the session-gated `auth` verbs. Without that, `bp auth mfa-enroll` with the
  token `bp auth login` printed failed (break-glass setup, docs/setup/ENTRA.md).
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.AccountsFixtures

  alias Barkpark.Accounts

  @session_verbs ~w(auth.mfa-enroll auth.mfa-verify auth.invitation-ls auth.invitation-accept auth.logout)

  defp caps(conn), do: conn |> get("/v1/capabilities") |> json_response(200)
  defp command_ids(conn), do: conn |> caps() |> Map.fetch!("commands") |> Enum.map(& &1["id"])

  test "a login session is echoed as read and sees the session-gated auth verbs", %{conn: conn} do
    user = register_user("caps-session@example.com")
    {:ok, token} = Accounts.create_user_session_token(user)
    session_conn = put_req_header(scoped_conn(), "authorization", "Bearer " <> token)

    assert caps(session_conn)["auth_tier"] == "read"
    anon = command_ids(conn)
    session = command_ids(put_req_header(scoped_conn(), "authorization", "Bearer " <> token))

    for id <- @session_verbs do
      refute id in anon
      assert id in session
    end
  end

  test "an unknown bearer stays none", %{conn: conn} do
    other = put_req_header(scoped_conn(), "authorization", "Bearer not-a-session")
    assert caps(other)["auth_tier"] == "none"
    assert command_ids(other) == command_ids(conn)
  end
end
