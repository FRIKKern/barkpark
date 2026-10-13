defmodule BarkparkWeb.CloudUserDeprovisionTest do
  @moduledoc """
  Owner ruling #26 (2026-10-03, "Match role, revoke"): removing a person from
  the Cloud team that owns this instance takes them OFF the instance —
  `POST /v1/auth/cloud-users/deprovision {email}` with the stored admin token.

    * the hole: before this, a removed member's Studio session, workspace seat
      and the admin-grade token they minted for themselves all kept working;
    * after: sessions revoked, seats dropped, owned tokens + app:<email> tokens
      revoked — and NOTHING belonging to anyone else is touched;
    * gate: admin bearer only (a read token gets 401); unknown email is a
      200 no-op so a retry converges; a missing email is 422.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Accounts, Auth, Repo, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @admin_token "deprov-admin-token-abcdef"
  @reader_token "deprov-reader-token-123456"
  @email "gone@cloud.example"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "cloud admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@reader_token, "reader", "production", ["read"])
    :ok
  end

  defp deprovision(conn, token, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/cloud-users/deprovision", Jason.encode!(body))
  end

  defp seated_user(email, role) do
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    %{id: ws_id} = Tenancy.get_default_workspace()
    {:ok, _} = TenancyAuth.create_membership(ws_id, user.id, role, "user")
    {:ok, session} = Accounts.create_user_session_token(user)
    {user, ws_id, session}
  end

  defp owned_token(user, raw, perms) do
    {:ok, token} = Auth.create_token(raw, "minted in studio", "production", perms)
    token |> Ecto.Changeset.change(owner_user_id: user.id) |> Repo.update!()
  end

  test "a removed member is signed out, unseated, and every token they own dies", %{conn: conn} do
    {user, ws_id, session} = seated_user(@email, "owner")
    owned = owned_token(user, "gone-own-admin-pat-1234567", ["read", "write", "admin"])

    {:ok, app} =
      Auth.create_token("gone-app-token-1234567", "app:" <> @email, "production", [
        "read",
        "write",
        "chat"
      ])

    # A bystander on the same instance keeps everything.
    {bystander, _ws, bystander_session} = seated_user("stays@cloud.example", "member")
    theirs = owned_token(bystander, "stays-own-pat-123456789", ["read"])

    assert {:ok, _} = Auth.verify_token("gone-own-admin-pat-1234567")

    resp = deprovision(conn, @admin_token, %{email: @email})

    assert json_response(resp, 200) == %{
             "found" => true,
             "sessions_revoked" => 1,
             "memberships_dropped" => 1,
             "tokens_revoked" => 2
           }

    assert Accounts.verify_user_session_token(session) == nil
    assert TenancyAuth.membership(user, ws_id) == nil
    assert {:error, :unauthorized} = Auth.verify_token("gone-own-admin-pat-1234567")
    assert {:error, :unauthorized} = Auth.verify_token("gone-app-token-1234567")
    assert Repo.get!(ApiToken, owned.id).revoked_at
    assert Repo.get!(ApiToken, app.id).revoked_at

    # Untouched: the bystander's seat, session and token, and the admin bearer.
    assert %{role: "member"} = TenancyAuth.membership(bystander, ws_id)
    refute Accounts.verify_user_session_token(bystander_session) == nil
    refute Repo.get!(ApiToken, theirs.id).revoked_at
    assert {:ok, _} = Auth.verify_token(@admin_token)

    # The account row itself stays (soft): a re-invite re-seats it.
    assert Accounts.get_user_by_email(@email)
  end

  test "an unknown email is a 200 no-op, so a retried removal converges", %{conn: conn} do
    resp = deprovision(conn, @admin_token, %{email: "never@cloud.example"})

    assert json_response(resp, 200) == %{
             "found" => false,
             "sessions_revoked" => 0,
             "memberships_dropped" => 0,
             "tokens_revoked" => 0
           }
  end

  test "a non-admin bearer is refused and nothing changes", %{conn: conn} do
    {user, ws_id, _session} = seated_user(@email, "member")

    # A read token never reaches the controller: the pipeline's mutation gate
    # (RequireWriteForMutation) refuses it first. This route is NOT on that
    # gate's exempt list, so the hole the list documents does not grow.
    assert deprovision(conn, @reader_token, %{email: @email}).status == 403

    # A write token does reach it, and gets the generic 401 the admin check
    # answers (the same no-tier-oracle reply the app-token door gives).
    {:ok, _} =
      Auth.create_token("deprov-writer-token-1234", "writer", "production", ["read", "write"])

    assert deprovision(conn, "deprov-writer-token-1234", %{email: @email}).status == 401

    assert %{role: "member"} = TenancyAuth.membership(user, ws_id)
  end

  test "a missing or non-address email is 422", %{conn: conn} do
    assert deprovision(conn, @admin_token, %{}).status == 422
    assert deprovision(conn, @admin_token, %{email: "not-an-address"}).status == 422
  end
end
