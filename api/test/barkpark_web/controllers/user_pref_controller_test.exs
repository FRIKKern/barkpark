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

    # task-9ef21c251c14488e: DELETE removes only the caller's own key.
    test "one user's DELETE leaves another user's same-named key intact", %{
      ws: ws,
      project: project
    } do
      {raw_a, _} = personal_token!(ws)
      {raw_b, _} = personal_token!(ws)

      for {raw, owner} <- [{raw_a, "a"}, {raw_b, "b"}] do
        bearer(raw)
        |> put(prefs_path(ws, project, "k"), Jason.encode!(%{value: %{"owner" => owner}}))
        |> json_response(200)
      end

      bearer(raw_a) |> delete(prefs_path(ws, project, "k")) |> json_response(200)

      assert (bearer(raw_a) |> get(prefs_path(ws, project, "k")) |> json_response(200))["value"] ==
               nil

      assert (bearer(raw_b) |> get(prefs_path(ws, project, "k")) |> json_response(200))["value"] ==
               %{"owner" => "b"},
             "user A's DELETE removed user B's pref"
    end

    test "DELETE of a key that was never set still succeeds (idempotent)", %{
      ws: ws,
      project: project
    } do
      {raw, _user} = personal_token!(ws)

      for _ <- 1..2 do
        assert bearer(raw) |> delete(prefs_path(ws, project, "never-set")) |> json_response(200) ==
                 %{"ok" => true}
      end
    end
  end

  defp list_op(raw, ws, project, body, status \\ 200) do
    bearer(raw)
    |> patch(prefs_path(ws, project, "recents"), Jason.encode!(body))
    |> json_response(status)
  end

  defp push_front(id, max \\ 3), do: %{op: "push_front", field: "ids", item: id, max: max}

  describe "PATCH list ops (task-f150278ead8dbfb3)" do
    test "push_front on an unset key creates the list", %{ws: ws, project: project} do
      {raw, _} = personal_token!(ws)

      assert list_op(raw, ws, project, push_front("a")) ==
               %{
                 "ok" => true,
                 "key" => "recents",
                 "dataset" => @dataset,
                 "value" => %{"ids" => ["a"]}
               }
    end

    test "push_front moves an id to the front, dedupes, caps, and keeps other keys", %{
      ws: ws,
      project: project
    } do
      {raw, _} = personal_token!(ws)

      bearer(raw)
      |> put(prefs_path(ws, project, "recents"), Jason.encode!(%{value: %{v: 1, ids: ~w(a b c)}}))
      |> json_response(200)

      assert list_op(raw, ws, project, push_front("c"))["value"] == %{
               "v" => 1,
               "ids" => ~w(c a b)
             }

      assert list_op(raw, ws, project, push_front("d"))["value"]["ids"] == ~w(d c a)
      assert list_op(raw, ws, project, push_front("e", 2))["value"]["ids"] == ~w(e d)
    end

    test "every op applied twice answers what it answered once", %{ws: ws, project: project} do
      {raw, _} = personal_token!(ws)
      list_op(raw, ws, project, push_front("a"))

      for body <- [
            push_front("b"),
            %{op: "add", field: "ids", item: "z"},
            %{op: "remove", field: "ids", item: "a"}
          ] do
        once = list_op(raw, ws, project, body)
        assert list_op(raw, ws, project, body) == once
      end

      assert list_op(raw, ws, project, %{op: "add", field: "ids", item: "b"})["value"]["ids"] ==
               ~w(b z)
    end

    test "a stored value that is not a list is refused and left alone", %{
      ws: ws,
      project: project
    } do
      {raw, _} = personal_token!(ws)

      bearer(raw)
      |> put(prefs_path(ws, project, "recents"), Jason.encode!(%{value: %{ids: "a"}}))
      |> json_response(200)

      resp = list_op(raw, ws, project, push_front("b"), 422)
      assert resp["error"]["code"] == "invalid_pref"
      assert resp["error"]["message"] == %{"value" => ["ids is not a list"]}

      assert (bearer(raw)
              |> get(prefs_path(ws, project, "recents"))
              |> json_response(200))[
               "value"
             ] == %{"ids" => "a"}
    end

    test "a malformed op is refused and writes nothing", %{ws: ws, project: project} do
      {raw, _} = personal_token!(ws)

      for body <- [
            %{op: "toggle", field: "ids", item: "a"},
            %{op: "add", field: "ids"},
            %{op: "add", field: "", item: "a"},
            %{op: "push_front", field: "ids", item: "a", max: 0},
            %{op: "push_front", field: "ids", item: "a", max: "3x"},
            %{op: "push_front", field: "ids", item: "a", max: -1}
          ] do
        assert list_op(raw, ws, project, body, 422)["error"]["code"] == "bad_request"
      end

      assert (bearer(raw)
              |> get(prefs_path(ws, project, "recents"))
              |> json_response(200))[
               "value"
             ] == nil
    end

    test "max may be a digit string, as bp sends it", %{ws: ws, project: project} do
      {raw, _} = personal_token!(ws)
      for id <- ~w(a b c), do: list_op(raw, ws, project, push_front(id, "2"))
      assert list_op(raw, ws, project, push_front("d", "2"))["value"]["ids"] == ~w(d c)
    end

    test "remove on an absent key writes nothing", %{ws: ws, project: project} do
      {raw, _} = personal_token!(ws)
      assert list_op(raw, ws, project, %{op: "remove", field: "ids", item: "a"})["value"] == nil

      assert (bearer(raw)
              |> get(prefs_path(ws, project, "recents"))
              |> json_response(200))[
               "value"
             ] == nil
    end

    test "an over-long key is a 422 invalid_pref, as on PUT", %{ws: ws, project: project} do
      {raw, _} = personal_token!(ws)
      path = prefs_path(ws, project, String.duplicate("k", 201))

      for {method, body} <- [{:put, %{value: %{ids: []}}}, {:patch, push_front("a")}] do
        resp =
          bearer(raw)
          |> dispatch(@endpoint, method, path, Jason.encode!(body))
          |> json_response(422)

        assert resp["error"]["code"] == "invalid_pref", "#{method}: #{inspect(resp)}"
      end
    end

    test "a shared token with no owner is refused", %{ws: ws, project: project} do
      resp = list_op(shared_token!(ws), ws, project, push_front("a"), 403)
      assert resp["error"]["code"] == "no_user_identity"
    end

    test "a session cookie needs x-requested-with", %{conn: conn, ws: ws, project: project} do
      {_user, conn} = account_session!(conn, ws, "member")
      conn = put_req_header(conn, "content-type", "application/json")
      path = prefs_path(ws, project, "recents")

      assert patch(conn, path, Jason.encode!(push_front("a"))).status == 403

      assert conn
             |> put_req_header("x-requested-with", "bp-studio")
             |> patch(path, Jason.encode!(push_front("a")))
             |> json_response(200)
             |> Map.fetch!("value") == %{"ids" => ["a"]}
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
