defmodule BarkparkWeb.RevokedTokenStatusTest do
  @moduledoc """
  task-2366a212d58a1700 — barkpark-studio repro: mint an app token, revoke
  it, then `POST /w/studio-parity/p/default/v1/data/mutate/e2e-sanity-builder`
  with it answers 403 `not_a_member` instead of 401.

  THE SECURITY HALF, pinned first: a revoked token must not authorize ANY
  route. Every test below asserts the operation did NOT succeed (no 200/201,
  no write landed, no privileged read, no mint) regardless of which status
  code comes back -- this is the invariant that must hold both before and
  after the status-code fix.

  THE ROOT CAUSE: flat routes gate on `RequireToken` (hard auth, halts 401
  the instant a presented bearer fails `Auth.verify_token/1`). Every scoped
  route instead resolves credentials SOFTLY (`OptionalToken` on POST,
  `OptionalSessionToken` on GET -- both documented to silently drop an
  invalid bearer and continue anonymous), so `ResolveWorkspace`'s membership
  gate runs against an already-anonymized caller and answers the SAME 403
  `not_a_member` it gives someone who sent no credential at all. Fixed by
  turning on each plug's `strict_on_presented: true` option across every
  SCOPED json-api pipeline: a PRESENTED-but-invalid bearer now halts 401
  there, before `ResolveWorkspace` ever runs -- unless a valid session (or
  session user) would have recovered the request anyway, which is
  unchanged and re-pinned below.

  Deliberately reuses the EXISTING generic `unauthorized` shape (not a new
  `token_revoked` code): `Auth.verify_token/1`'s own documented design
  folds revoked/expired/unknown into ONE indistinguishable refusal
  specifically to avoid an existence oracle, and a distinct code would
  reopen exactly that.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Sso, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "revoked_status_ds"

  setup %{conn: conn} do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "revstatus-ws-#{suffix}", name: "Revoked Status"})

    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "probe-doc", "title" => "T"}, @dataset, scope)

    {:ok, _} = Content.publish_document("probe-doc", "post", @dataset, scope)

    raw = "revstatus-app-token-#{suffix}"
    user = Sso.find_or_create_user("revstatus-#{suffix}@example.com")
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

    {:ok, token} =
      Auth.create_token(raw, "app:revstatus", @dataset, ["read", "write"], ws.id,
        class: :app,
        owner_user_id: user.id
      )

    {:ok, _revoked} = Auth.revoke_token(token)

    %{conn: conn, ws: ws, raw: raw}
  end

  defp bearer(conn, raw),
    do:
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")

  describe "the security half: a revoked token authorizes NOTHING, on any surface" do
    test "scoped write (mutate) does not write", %{conn: conn, ws: ws, raw: raw} do
      resp =
        conn
        |> bearer(raw)
        |> post(
          "/w/#{ws.slug}/p/default/v1/data/mutate/#{@dataset}",
          Jason.encode!(%{
            "mutations" => [
              %{"create" => %{"_type" => "post", "_id" => "revoked-write", "title" => "x"}}
            ]
          })
        )

      refute resp.status == 200

      assert Content.get_document("revoked-write", "post", @dataset, workspace_id: ws.id) ==
               {:error, :not_found}
    end

    test "scoped preview-token mint does not mint", %{conn: conn, ws: ws, raw: raw} do
      resp =
        conn
        |> bearer(raw)
        |> post("/w/#{ws.slug}/p/default/v1/preview-tokens", %{"dataset" => @dataset})

      refute resp.status == 201
    end

    test "flat write (mutate) does not write (already correct, unaffected by this change)", %{
      conn: conn,
      raw: raw
    } do
      resp =
        conn
        |> bearer(raw)
        |> post(
          "/v1/data/mutate/#{@dataset}",
          Jason.encode!(%{
            "mutations" => [
              %{"create" => %{"_type" => "post", "_id" => "revoked-flat-write", "title" => "x"}}
            ]
          })
        )

      refute resp.status == 200
    end
  end

  describe "the status-code fix: scoped routes now answer 401, not 403, for a revoked token" do
    test "scoped write (mutate) — the exact barkpark-studio repro", %{
      conn: conn,
      ws: ws,
      raw: raw
    } do
      resp =
        conn
        |> bearer(raw)
        |> post(
          "/w/#{ws.slug}/p/default/v1/data/mutate/#{@dataset}",
          Jason.encode!(%{"mutations" => []})
        )

      assert resp.status == 401,
             "a revoked token must answer 401, not #{resp.status}: #{resp.resp_body}"

      assert %{"error" => %{"code" => "unauthorized"}} = Jason.decode!(resp.resp_body)
    end

    test "scoped read (query)", %{conn: conn, ws: ws, raw: raw} do
      resp = conn |> bearer(raw) |> get("/w/#{ws.slug}/p/default/v1/data/query/#{@dataset}/post")

      assert resp.status == 401, "#{resp.status} #{resp.resp_body}"
      assert %{"error" => %{"code" => "unauthorized"}} = Jason.decode!(resp.resp_body)
    end

    test "scoped listen/SSE", %{conn: conn, ws: ws, raw: raw} do
      task =
        Task.async(fn ->
          conn
          |> bearer(raw)
          |> get("/w/#{ws.slug}/p/default/v1/data/listen/#{@dataset}", %{"lastEventId" => "0"})
        end)

      send(task.pid, :sse_overloaded)
      resp = Task.await(task, 20_000)

      assert resp.status == 401, "#{resp.status} #{resp.resp_body}"
    end

    test "scoped preview-token mint", %{conn: conn, ws: ws, raw: raw} do
      resp =
        conn
        |> bearer(raw)
        |> post("/w/#{ws.slug}/p/default/v1/preview-tokens", %{"dataset" => @dataset})

      assert resp.status == 401, "#{resp.status} #{resp.resp_body}"
    end
  end

  describe "a live token merely lacking workspace membership still answers 403" do
    test "a valid token with no membership in this workspace is still not_a_member, 403", %{
      conn: conn,
      ws: ws
    } do
      raw = "revstatus-stranger-#{System.unique_integer([:positive])}"
      {:ok, _token} = Auth.create_token(raw, "stranger", @dataset, ["read", "write"])

      resp = conn |> bearer(raw) |> get("/w/#{ws.slug}/p/default/v1/data/query/#{@dataset}/post")

      assert resp.status == 403
      assert %{"error" => %{"reason" => "not_a_member"}} = Jason.decode!(resp.resp_body)
    end
  end

  describe "the session-fallback precedence is unchanged" do
    test "an invalid bearer alongside a VALID session still resolves the session, not a 401", %{
      conn: conn,
      ws: ws,
      raw: revoked_raw
    } do
      session_raw = "revstatus-session-#{System.unique_integer([:positive])}"

      {:ok, session_token} =
        Auth.create_token(session_raw, "session writer", @dataset, ["read", "write"])

      {:ok, _} = TenancyAuth.create_membership(ws.id, session_token.id)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session("api_token", session_raw)
        |> put_req_header("authorization", "Bearer " <> revoked_raw)

      resp = get(conn, "/w/#{ws.slug}/p/default/v1/data/query/#{@dataset}/post")

      assert resp.status == 200,
             "a valid session must still recover the request even with a stale/revoked bearer header present: " <>
               "#{resp.status} #{resp.resp_body}"
    end
  end
end
