defmodule BarkparkWeb.UnconfirmedLoginMemberAddTest do
  @moduledoc """
  An external Studio's editor sign-in, end to end over the real HTTP routes:
  register, log in, get seated by an admin with `POST /w/:ws/p/:p/v1/members`
  (what `bp workspace member-add` sends), log in again.

  The defect (task-0f1fd3d17e5f4edb, task-f583460d431d195c): an unconfirmed
  account could log in, then the member-add reclaimed it
  (`Privacy.reclaim_unconfirmed/1`, owner ruling #7). The reclaim replaced the
  password and deleted every session, so the token from that login 401'd on
  `/v1/auth/me` and the same password 401'd on the next login.

  The rule pinned here: password login refuses an unconfirmed account with
  `403 email_unconfirmed` and mints NO session, so nothing it hands out can be
  killed later. The refusal comes only after the password verified: a wrong
  password still gets the generic `invalid_credentials`, the same as an
  address with no account. Once an operator confirms the account
  (`mix barkpark.user.confirm`), login works, member-add answers with an
  invitation, and the password and the session both survive it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Accounts.UserSession
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  defp post_json(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp bearer(raw), do: scoped_conn() |> put_req_header("authorization", "Bearer #{raw}")

  defp register(email),
    do: post_json(scoped_conn(), "/v1/auth/register", %{email: email, password: @password})

  defp login(email, password \\ @password),
    do: post_json(scoped_conn(), "/v1/auth/login", %{email: email, password: password})

  defp sessions(email) do
    user = Accounts.get_user_by_email(email)
    Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count)
  end

  setup do
    ws = create_workspace!("login-seat-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    admin_raw = "login-seat-admin-#{System.unique_integer([:positive])}"

    {:ok, token} =
      Auth.create_token(admin_raw, "login-seat", "production", ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin", "api_token")

    member_add = fn email ->
      admin_raw
      |> bearer()
      |> post_json("/w/#{ws.slug}/p/#{project.slug}/v1/members", %{email: email, role: "member"})
    end

    %{member_add: member_add}
  end

  test "login refuses an unconfirmed account with email_unconfirmed, and mints no session" do
    email = "editor-#{System.unique_integer([:positive])}@example.com"
    assert register(email) |> json_response(201)

    body = login(email) |> json_response(403)

    assert body["error"]["code"] == "email_unconfirmed"
    assert body["error"]["hint"] =~ "mix barkpark.user.confirm"
    refute body["token"]
    assert sessions(email) == 0
  end

  test "an unconfirmed account with the WRONG password gets the generic 401, like an unknown address" do
    email = "editor-#{System.unique_integer([:positive])}@example.com"
    assert register(email) |> json_response(201)

    wrong = login(email, "not-the-password") |> json_response(401)

    unknown =
      login("nobody-#{System.unique_integer([:positive])}@example.com") |> json_response(401)

    assert wrong["error"]["code"] == "invalid_credentials"
    assert Map.delete(wrong["error"], "request_id") == Map.delete(unknown["error"], "request_id")
  end

  test "the refusal mails a fresh confirmation link, and that link confirms the account" do
    email = "editor-#{System.unique_integer([:positive])}@example.com"
    assert register(email) |> json_response(201)
    # Drain the registration mail so the next one is the refusal's.
    Swoosh.TestAssertions.assert_email_sent(to: email)

    assert login(email) |> json_response(403)

    Swoosh.TestAssertions.assert_email_sent(fn mail ->
      [{_, ^email}] = mail.to
      [_, token] = Regex.run(~r{/auth/confirm/([A-Za-z0-9_\-]+)}, mail.text_body)
      assert {:ok, _} = Accounts.confirm_user(token)
    end)

    assert login(email) |> json_response(201)
  end

  test "operator-confirmed: login, member-add, then the old token AND the password still work",
       %{member_add: member_add} do
    email = "editor-#{System.unique_integer([:positive])}@example.com"
    assert register(email) |> json_response(201)
    assert {:ok, _} = Accounts.confirm_user_by_operator(email)

    token = login(email) |> json_response(201) |> Map.fetch!("token")
    assert bearer(token) |> get("/v1/auth/me") |> json_response(200)

    # Ruling #7: a confirmed account is invited, not seated, and not reclaimed.
    assert %{"invitation" => %{"id" => invitation_id}} = member_add.(email) |> json_response(202)

    assert bearer(token) |> get("/v1/auth/me") |> json_response(200)
    assert login(email) |> json_response(201)

    assert bearer(token)
           |> post_json("/v1/auth/invitations/#{invitation_id}/accept", %{})
           |> json_response(201)

    minted =
      token
      |> bearer()
      |> post_json("/v1/auth/tokens", %{name: "studio", current_password: @password})
      |> json_response(201)

    assert is_binary(minted["token"])
    assert login(email) |> json_response(201)
  end

  test "confirm_user_by_operator: unknown address, and an already-confirmed account is left alone" do
    assert {:error, :not_found} =
             Accounts.confirm_user_by_operator(
               "nobody-#{System.unique_integer([:positive])}@example.com"
             )

    email = "editor-#{System.unique_integer([:positive])}@example.com"
    assert register(email) |> json_response(201)

    assert {:ok, %{confirmed_at: %DateTime{} = at}} =
             Accounts.confirm_user_by_operator(String.upcase(email))

    assert {:ok, %{confirmed_at: ^at}, :already_confirmed} =
             Accounts.confirm_user_by_operator(email)
  end

  test "the operator door: `mix barkpark.user.confirm <email>` lets the editor log in" do
    email = "editor-#{System.unique_integer([:positive])}@example.com"
    assert register(email) |> json_response(201)
    assert login(email) |> json_response(403)

    Mix.Tasks.Barkpark.User.Confirm.run([email])

    assert login(email) |> json_response(201)

    assert_raise Mix.Error, ~r/no account/, fn ->
      Mix.Tasks.Barkpark.User.Confirm.run([
        "nobody-#{System.unique_integer([:positive])}@example.com"
      ])
    end
  end

  test "the browser door refuses the same way: no session, back to /login with the reason" do
    email = "editor-#{System.unique_integer([:positive])}@example.com"
    assert register(email) |> json_response(201)

    conn =
      scoped_conn()
      |> put_req_header("accept", "text/html")
      |> post("/login/account", %{"email" => email, "password" => @password})

    assert redirected_to(conn) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Confirm your email"
    refute get_session(conn, "user_session")
    assert sessions(email) == 0
  end
end
