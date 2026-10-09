defmodule BarkparkWeb.Integration.ScopedPreviewTokenTest do
  @moduledoc """
  task-88e9094df76d31c6 — `POST /v1/preview-tokens` (#22299) is FLAT only, so
  `ScopeHelpers.scope_opts/1` resolves whatever the MINTING ADMIN's own token
  carries (usually Default). Measured live on guerrilla: a studio-parity
  admin's mint carried `workspace_id` = Default, and its `/v1/preview` reads
  found nothing in studio-parity.

  This file covers the `/w/:workspace_slug/p/:project_slug` twins this task
  adds:

    * `POST .../v1/preview-tokens` — same `PreviewTokenController.mint/2`,
      mounted on `[:scoped_api, :scoped_admin]` so the signed scope comes
      from the URL's resolved (role-gated) workspace/project, never from the
      minting admin's own token.
    * `.../v1/preview/{query,doc,listen}` accepting that token when its
      signed scope matches the URL — refusing it, in BOTH directions, when
      it does not.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "spt-a-#{suffix}", name: "WS A"})
    {:ok, proj_a} = Tenancy.create_project(ws_a, %{slug: "default", name: "Default"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "spt-b-#{suffix}", name: "WS B"})
    {:ok, proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    for {ws, proj} <- [{ws_a, proj_a}, {ws_b, proj_b}] do
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )

      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => "#{ws.slug}-doc", "title" => "TITLE_#{ws.slug}"},
          @dataset,
          scope
        )
    end

    # ADMIN of A only (legit minter for A, a stranger to B).
    admin_a_raw = "spt-admin-a-#{suffix}"

    {:ok, admin_a} =
      Auth.create_token(admin_a_raw, "admin-a", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws_a.id, admin_a.id, "admin")

    # ADMIN of B too, symmetric fixture for the reverse direction.
    admin_b_raw = "spt-admin-b-#{suffix}"

    {:ok, admin_b} =
      Auth.create_token(admin_b_raw, "admin-b", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws_b.id, admin_b.id, "admin")

    # MEMBER (not admin) of A, global admin perms — must NOT be able to mint.
    member_a_raw = "spt-member-a-#{suffix}"

    {:ok, member_a} =
      Auth.create_token(member_a_raw, "member-a", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws_a.id, member_a.id)

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      admin_a_raw: admin_a_raw,
      admin_b_raw: admin_b_raw,
      member_a_raw: member_a_raw
    }
  end

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)
  defp preview(conn, jwt), do: put_req_header(conn, "authorization", "Preview " <> jwt)

  defp mint!(conn, ws_slug, raw, body) do
    resp =
      conn
      |> bearer(raw)
      |> put_req_header("content-type", "application/json")
      |> post("/w/#{ws_slug}/p/default/v1/preview-tokens", body)

    assert resp.status == 201,
           "mint on /w/#{ws_slug}/... failed: #{resp.status} #{resp.resp_body}"

    Jason.decode!(resp.resp_body)
  end

  # ── scoped mint ──────────────────────────────────────────────────────────

  test "an admin of A mints a token scoped to A, never to Default", %{
    ws_a: ws_a,
    admin_a_raw: raw,
    conn: conn
  } do
    body = mint!(conn, ws_a.slug, raw, %{"dataset" => @dataset})

    assert body["workspace_id"] == ws_a.id
    refute body["workspace_id"] == Tenancy.get_default_workspace().id
  end

  test "a member of A (global admin perms, not an admin ROLE in A) cannot mint", %{
    ws_a: ws_a,
    member_a_raw: raw,
    conn: conn
  } do
    resp =
      conn
      |> bearer(raw)
      |> put_req_header("content-type", "application/json")
      |> post("/w/#{ws_a.slug}/p/default/v1/preview-tokens", %{"dataset" => @dataset})

    assert resp.status == 403
  end

  test "an admin of A cannot mint on /w/B/...", %{
    ws_a: ws_a,
    ws_b: ws_b,
    admin_a_raw: raw,
    conn: conn
  } do
    _ = ws_a

    resp =
      conn
      |> bearer(raw)
      |> put_req_header("content-type", "application/json")
      |> post("/w/#{ws_b.slug}/p/default/v1/preview-tokens", %{"dataset" => @dataset})

    assert resp.status == 403
  end

  # ── scoped reads: the matching case ─────────────────────────────────────

  test "a token minted for A reads A's drafts on /w/A/.../v1/preview/*", %{
    ws_a: ws_a,
    admin_a_raw: raw,
    conn: conn
  } do
    body = mint!(conn, ws_a.slug, raw, %{"dataset" => @dataset})
    token = body["token"]

    resp =
      conn
      |> preview(token)
      |> get("/w/#{ws_a.slug}/p/default/v1/preview/doc/#{@dataset}/post/#{ws_a.slug}-doc")

    assert resp.status == 200
    assert Jason.decode!(resp.resp_body)["result"]["title"] == "TITLE_#{ws_a.slug}"
  end

  test "a token minted for A reads A's list query on /w/A/.../v1/preview/*", %{
    ws_a: ws_a,
    admin_a_raw: raw,
    conn: conn
  } do
    body = mint!(conn, ws_a.slug, raw, %{"dataset" => @dataset, "multi_use" => true})
    token = body["token"]

    resp =
      conn
      |> preview(token)
      |> get("/w/#{ws_a.slug}/p/default/v1/preview/query/#{@dataset}/post")
      |> json_response(200)

    ids = resp |> get_in(["result", "documents"]) |> Enum.map(& &1["_id"])
    assert "drafts.#{ws_a.slug}-doc" in ids
  end

  test "a token minted for A also serves the scoped listen stream", %{
    ws_a: ws_a,
    admin_a_raw: raw,
    conn: conn
  } do
    body = mint!(conn, ws_a.slug, raw, %{"dataset" => @dataset})
    token = body["token"]

    task =
      Task.async(fn ->
        conn
        |> preview(token)
        |> get("/w/#{ws_a.slug}/p/default/v1/preview/listen/#{@dataset}", %{"lastEventId" => "0"})
      end)

    send(task.pid, :sse_overloaded)
    listen = Task.await(task, 20_000)

    assert listen.status == 200,
           "the scoped listen route refused a correctly-scoped token: #{listen.status} #{listen.resp_body}"
  end

  # ── scoped reads: BOTH mismatch directions are refused ──────────────────

  test "a token minted for A is refused reading on /w/B/... (not silently re-scoped)", %{
    ws_a: ws_a,
    ws_b: ws_b,
    admin_a_raw: raw,
    conn: conn
  } do
    body = mint!(conn, ws_a.slug, raw, %{"dataset" => @dataset})
    token = body["token"]

    resp =
      conn
      |> preview(token)
      |> get("/w/#{ws_b.slug}/p/default/v1/preview/doc/#{@dataset}/post/#{ws_b.slug}-doc")

    assert resp.status == 403

    refute resp.resp_body |> Jason.decode!() |> get_in(["error", "reason"]) == "not_a_member",
           "a scope MISMATCH was reported as the membership gate's own reason -- wrong refusal"
  end

  test "a token minted for B is refused reading on /w/A/... — the reverse direction", %{
    ws_a: ws_a,
    ws_b: ws_b,
    admin_b_raw: raw,
    conn: conn
  } do
    body = mint!(conn, ws_b.slug, raw, %{"dataset" => @dataset})
    token = body["token"]

    resp =
      conn
      |> preview(token)
      |> get("/w/#{ws_a.slug}/p/default/v1/preview/doc/#{@dataset}/post/#{ws_a.slug}-doc")

    assert resp.status == 403
  end

  test "a token minted for A is refused on B's listen stream too", %{
    ws_a: ws_a,
    ws_b: ws_b,
    admin_a_raw: raw,
    conn: conn
  } do
    body = mint!(conn, ws_a.slug, raw, %{"dataset" => @dataset})
    token = body["token"]

    task =
      Task.async(fn ->
        conn
        |> preview(token)
        |> get("/w/#{ws_b.slug}/p/default/v1/preview/listen/#{@dataset}", %{"lastEventId" => "0"})
      end)

    send(task.pid, :sse_overloaded)
    listen = Task.await(task, 20_000)

    assert listen.status == 403
  end

  # ── the existing session/Bearer path is untouched ───────────────────────

  test "with no Preview header at all, the ordinary member/Bearer path still works unchanged", %{
    ws_a: ws_a,
    admin_a_raw: raw,
    conn: conn
  } do
    # A plain Bearer caller on this route has no forced perspective -- same
    # as the pre-existing scoped preview-doc convention
    # (drafts_id_doc_clamp_test.exs), the DRAFT must be addressed by its
    # `drafts.`-prefixed id explicitly.
    resp =
      conn
      |> bearer(raw)
      |> get("/w/#{ws_a.slug}/p/default/v1/preview/doc/#{@dataset}/post/drafts.#{ws_a.slug}-doc")

    assert resp.status == 200
  end

  test "an anonymous caller with no Preview header is still refused not_a_member", %{
    ws_a: ws_a,
    conn: conn
  } do
    resp = conn |> get("/w/#{ws_a.slug}/p/default/v1/preview/doc/#{@dataset}/post/anything")

    assert resp.status == 403
  end
end
