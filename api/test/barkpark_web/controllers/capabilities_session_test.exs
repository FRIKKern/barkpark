defmodule BarkparkWeb.CapabilitiesSessionTest do
  @moduledoc """
  A login session's tier is "none", because `tier_of/1` ranks API tokens. The
  session-gated `auth` verbs accept only a session, so `GET /v1/capabilities`
  keeps them for a session bearer. Without that, `bp auth mfa-enroll` with the
  token `bp auth login` printed answered "no verb" (break-glass setup,
  docs/setup/ENTRA.md).
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.AccountsFixtures

  alias Barkpark.Accounts

  @session_verbs ~w(auth.mfa-enroll auth.mfa-verify auth.invitation-ls auth.invitation-accept auth.logout)

  defp command_ids(conn) do
    conn
    |> get("/v1/capabilities")
    |> json_response(200)
    |> Map.fetch!("commands")
    |> Enum.map(& &1["id"])
  end

  test "a login session sees the session-gated auth verbs and nothing else above none", %{
    conn: conn
  } do
    user = register_user("caps-session@example.com")
    {:ok, token} = Accounts.create_user_session_token(user)

    anon = command_ids(conn)
    session = command_ids(put_req_header(scoped_conn(), "authorization", "Bearer " <> token))

    for id <- @session_verbs do
      refute id in anon
      assert id in session
    end

    assert Enum.all?(session -- anon, &String.starts_with?(&1, "auth."))
  end

  test "an unknown bearer gets the anonymous manifest", %{conn: conn} do
    anon = command_ids(conn)
    other = command_ids(put_req_header(scoped_conn(), "authorization", "Bearer not-a-session"))
    assert other == anon
  end
end
