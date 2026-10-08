defmodule BarkparkWeb.UserPrefControllerTest do
  @moduledoc """
  task-7d2a48dbf7e4bf34 — `GET/PUT/DELETE /w/:ws/p/:proj/v1/prefs/:dataset/:key`,
  the per-account JSON key-value store. Covers both identity sources
  (bearer token with an owner_user_id, and an account-session cookie), the
  no-owner-token refusal, and the size/shape validations.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    ws = create_workspace!("prefs-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    %{ws: ws, project: project}
  end

  defp personal_token!(ws) do
    raw = "prefs-personal-#{System.unique_integer([:positive])}"

    {:ok, user} =
      Accounts.register_user(%{
        email: "prefs-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, token} =
      Auth.create_token(raw, "personal", @dataset, ["read", "write"], nil, owner_user_id: user.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id)
    # Owner ruling 2026-10-03 #2 (the D22 seat rule): a user-owned token
    # (`owner_user_id` set) is ALSO gated on the owner's OWN seat — a token
    # never outlives its holder's demotion or removal. The token's own seat
    # above is not enough by itself.
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    {raw, user}
  end

  defp shared_token!(ws) do
    raw = "prefs-shared-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "shared", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id)
    raw
  end

  defp account_session!(conn, ws, role) do
    email = "prefs-acct-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp bearer(raw),
    do:
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")

  defp prefs_path(ws, project, key),
    do: "/w/#{ws.slug}/p/#{project.slug}/v1/prefs/#{@dataset}/#{key}"

  describe "a personal access token (owner_user_id set)" do
    test "GET on an unset key returns value: nil", %{ws: ws, project: project} do
      {raw, _user} = personal_token!(ws)
      resp = bearer(raw) |> get(prefs_path(ws, project, "recent_searches")) |> json_response(200)
      assert resp == %{"key" => "recent_searches", "dataset" => @dataset, "value" => nil}
    end

    test "PUT then GET round-trips the value", %{ws: ws, project: project} do
      {raw, _user} = personal_token!(ws)
      value = %{"items" => ["foo", "bar"]}

      put_resp =
        bearer(raw)
        |> put(prefs_path(ws, project, "recent_searches"), Jason.encode!(%{value: value}))
        |> json_response(200)

      assert put_resp["ok"] == true
      assert put_resp["value"] == value

      get_resp =
        bearer(raw) |> get(prefs_path(ws, project, "recent_searches")) |> json_response(200)

      assert get_resp["value"] == value
    end

    test "a second PUT replaces the value (upsert, not append)", %{ws: ws, project: project} do
      {raw, _user} = personal_token!(ws)

      bearer(raw)
      |> put(prefs_path(ws, project, "k"), Jason.encode!(%{value: %{"v" => 1}}))
      |> json_response(200)

      resp =
        bearer(raw)
        |> put(prefs_path(ws, project, "k"), Jason.encode!(%{value: %{"v" => 2}}))
        |> json_response(200)

      assert resp["value"] == %{"v" => 2}
    end

    test "DELETE clears it back to nil", %{ws: ws, project: project} do
      {raw, _user} = personal_token!(ws)

      bearer(raw)
      |> put(prefs_path(ws, project, "k"), Jason.encode!(%{value: %{"v" => 1}}))
      |> json_response(200)

      bearer(raw) |> delete(prefs_path(ws, project, "k")) |> json_response(200)
      resp = bearer(raw) |> get(prefs_path(ws, project, "k")) |> json_response(200)
      assert resp["value"] == nil
    end

    test "a non-map value is refused with 422", %{ws: ws, project: project} do
      resp =
        bearer(elem(personal_token!(ws), 0))
        |> put(prefs_path(ws, project, "k"), Jason.encode!(%{value: "not a map"}))
        |> json_response(422)

      assert resp["error"]["code"] == "bad_request"
    end

    test "an oversized value is refused with 422", %{ws: ws, project: project} do
      {raw, _user} = personal_token!(ws)
      big = %{"blob" => String.duplicate("x", 20_000)}

      resp =
        bearer(raw)
        |> put(prefs_path(ws, project, "k"), Jason.encode!(%{value: big}))
        |> json_response(422)

      assert resp["error"]["code"] == "invalid_pref"
    end

    test "two different users' prefs under the same key never collide", %{
      ws: ws,
      project: project
    } do
      {raw_a, _} = personal_token!(ws)
      {raw_b, _} = personal_token!(ws)

      bearer(raw_a)
      |> put(prefs_path(ws, project, "k"), Jason.encode!(%{value: %{"owner" => "a"}}))
      |> json_response(200)

      resp_b = bearer(raw_b) |> get(prefs_path(ws, project, "k")) |> json_response(200)
      assert resp_b["value"] == nil

      resp_a = bearer(raw_a) |> get(prefs_path(ws, project, "k")) |> json_response(200)
      assert resp_a["value"] == %{"owner" => "a"}
    end
  end

  describe "an account session (no bearer)" do
    test "reads and writes its own prefs via the cookie", %{conn: conn, ws: ws, project: project} do
      {_user, conn} = account_session!(conn, ws, "member")

      put_resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-requested-with", "bp-studio")
        |> put(prefs_path(ws, project, "k"), Jason.encode!(%{value: %{"v" => "cookie"}}))
        |> json_response(200)

      assert put_resp["ok"] == true

      get_resp = conn |> get(prefs_path(ws, project, "k")) |> json_response(200)
      assert get_resp["value"] == %{"v" => "cookie"}
    end

    test "a PUT with no x-requested-with is refused — the cookie is never admitted on a non-GET without it",
         %{conn: conn, ws: ws, project: project} do
      {_user, conn} = account_session!(conn, ws, "member")

      # `scoped_api_optional_credential`'s `cookie_credential_admissible?/1`
      # only admits the cookie on GET/HEAD, or on another method WITH the
      # header — without it here the request resolves ANONYMOUS, same
      # fail-closed path as no session at all (not a distinct "csrf_required"
      # code — that belongs to RequireBearerOrSessionToken on the
      # :scoped_mutate/:scoped_media_mutate pipelines, not plain :scoped_api).
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> put(prefs_path(ws, project, "k"), Jason.encode!(%{value: %{"v" => 1}}))

      assert resp.status == 403
    end
  end

  describe "a shared token with no owner_user_id" do
    test "is refused with no_user_identity, never a 500", %{ws: ws, project: project} do
      raw = shared_token!(ws)
      resp = bearer(raw) |> get(prefs_path(ws, project, "k")) |> json_response(403)
      assert resp["error"]["code"] == "no_user_identity"
    end
  end

  describe "anonymous" do
    test "is refused, never a 500", %{ws: ws, project: project} do
      resp = scoped_conn() |> get(prefs_path(ws, project, "k"))
      refute resp.status == 500
    end
  end
end
