defmodule BarkparkWeb.MemberAddReclaimByDesignTest do
  @moduledoc """
  BY DESIGN, owner ruling #7: seating an UNCONFIRMED account reclaims it.

  `POST /w/:ws/p/:p/v1/members` (what `bp workspace member-add` sends) on an
  account whose email was never confirmed runs
  `Accounts.Privacy.reclaim_unconfirmed/1` before the seat: the password is
  replaced and every session deleted, because nobody proved that the person
  who set them owns the address. On guerrilla this read as two bugs
  (task-0f1fd3d17e5f4edb: a fresh token 401s on `/v1/auth/me`;
  task-f583460d431d195c: the same password 401s). Both are this rule.

  What is pinned here:

    * the reclaim itself, end to end over HTTP, and that the response SAYS it
      happened (`reclaimed: true` plus an `account_reclaimed` warning, which
      `bp` prints on stderr);
    * the control: a CONFIRMED account is invited, not reclaimed, and keeps
      its password and its session;
    * the operator door that gets a seeded editor to "confirmed" first,
      `Barkpark.Release.confirm_email/1`.

  If a test here goes red, ruling #7 changed or broke. Do not "fix" the test
  by weakening the reclaim; it closes a squatting hole.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, BootModeSandbox, Release}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  defp post_json(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp bearer(raw), do: scoped_conn() |> put_req_header("authorization", "Bearer #{raw}")

  defp register!(email) do
    assert post_json(scoped_conn(), "/v1/auth/register", %{email: email, password: @password})
           |> json_response(201)
  end

  defp login(email),
    do: post_json(scoped_conn(), "/v1/auth/login", %{email: email, password: @password})

  defp email, do: "editor-#{System.unique_integer([:positive])}@example.com"

  # Release.confirm_email/1 boots the one-shot tree in a release; the test
  # node is already up, and booting would write :boot_mode for every test.
  defp confirm!(email), do: Release.confirm_email(email, boot: fn -> :ok end)

  setup do
    ws = create_workspace!("ruling7-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    admin_raw = "ruling7-admin-#{System.unique_integer([:positive])}"

    {:ok, token} =
      Auth.create_token(admin_raw, "ruling7", "production", ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin", "api_token")

    member_add = fn email ->
      admin_raw
      |> bearer()
      |> post_json("/w/#{ws.slug}/p/#{project.slug}/v1/members", %{email: email, role: "member"})
    end

    %{member_add: member_add}
  end

  test "BY DESIGN (ruling #7): member-add reclaims an unconfirmed account, its session and password stop working, and the answer says so",
       %{member_add: member_add} do
    email = email()
    register!(email)
    session = login(email) |> json_response(201) |> Map.fetch!("token")
    assert bearer(session) |> get("/v1/auth/me") |> json_response(200)

    body = member_add.(email) |> json_response(201)

    assert body["member"]["identity"] == email
    assert body["reclaimed"] == true
    assert [%{"code" => "account_reclaimed", "message" => message}] = body["warnings"]
    assert message =~ "password was replaced"
    assert message =~ "No email was sent"

    assert bearer(session) |> get("/v1/auth/me") |> json_response(401)

    assert login(email) |> json_response(401) |> get_in(["error", "code"]) ==
             "invalid_credentials"
  end

  test "control: a CONFIRMED account is invited, not reclaimed, and keeps its password and session",
       %{member_add: member_add} do
    email = email()
    register!(email)
    assert {:ok, ^email} = confirm!(email)

    session = login(email) |> json_response(201) |> Map.fetch!("token")

    body = member_add.(email) |> json_response(202)

    assert body["invitation"]["email"] == email
    refute Map.has_key?(body, "reclaimed")
    refute Map.has_key?(body, "warnings")

    assert bearer(session) |> get("/v1/auth/me") |> json_response(200)
    assert login(email) |> json_response(201)
  end

  test "a brand-new email is seated with no reclaim warning", %{member_add: member_add} do
    body = member_add.(email()) |> json_response(201)

    assert body["member"]
    refute Map.has_key?(body, "reclaimed")
    refute Map.has_key?(body, "warnings")
  end

  test "Release.confirm_email/1: confirms, says so twice, and names an unknown address" do
    email = email()
    register!(email)
    refute Accounts.get_user_by_email(email).confirmed_at

    assert {:ok, ^email} = confirm!(String.upcase(email))
    assert Accounts.get_user_by_email(email).confirmed_at
    assert {:ok, ^email, :already_confirmed} = confirm!(email)
    assert {:error, :not_found} = confirm!(email())
  end

  test "mix barkpark.user.confirm <email> confirms, so a later member-add invites instead of reclaiming",
       %{member_add: member_add} do
    email = email()
    register!(email)

    BootModeSandbox.protecting(fn -> Mix.Tasks.Barkpark.User.Confirm.run([email]) end)

    assert member_add.(email) |> json_response(202)
    assert login(email) |> json_response(201)

    assert_raise Mix.Error, ~r/no account/, fn ->
      BootModeSandbox.protecting(fn -> Mix.Tasks.Barkpark.User.Confirm.run([email()]) end)
    end
  end
end
