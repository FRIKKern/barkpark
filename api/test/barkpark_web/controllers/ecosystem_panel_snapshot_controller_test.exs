defmodule BarkparkWeb.EcosystemPanelSnapshotControllerTest do
  @moduledoc """
  task-270112c682dc71de — the ecosystem panel upload,
  `POST /w/:ws/p/:proj/v1/plugins/ecosystem-panel/snapshot`.

  Only an owner or admin of the URL workspace, holding a token with `admin`
  permission, may write. Every refusal asserts the row store is unchanged, not
  only the status. The row is keyed by the workspace the URL slug resolved to;
  a body or query `workspace_id` is ignored. No answer carries the HTML.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.EcosystemPanel
  alias Barkpark.EcosystemPanel.Snapshot
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.TenancyFixtures

  @html "<!doctype html><title>eco</title><p>SNAPSHOT-MARKER</p>"

  setup do
    ws_a = TenancyFixtures.create_workspace!()
    proj_a = TenancyFixtures.create_project!(ws_a)
    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b)

    admin_a = token!(["read", "write", "admin"], ws_a.id)
    admin_b = token!(["read", "write", "admin"], ws_b.id)
    member_a = token!(["read", "write"], ws_a.id)

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      proj_a: proj_a,
      proj_b: proj_b,
      admin_a: admin_a,
      admin_b: admin_b,
      member_a: member_a,
      path_a: upload_path(ws_a, proj_a)
    }
  end

  test "a member token of the workspace gets 403 and no row is written", ctx do
    conn = post_json(ctx.member_a.raw, ctx.path_a, body())

    assert conn.status == 403
    refute conn.resp_body =~ "SNAPSHOT-MARKER"
    assert rows() == []
  end

  test "an admin of the URL workspace writes one row; a second push overwrites it", ctx do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, EcosystemPanel.topic(ctx.ws_a.id))

    first = post_json(ctx.admin_a.raw, ctx.path_a, body()) |> json_response(200)
    refute Jason.encode!(first) =~ "SNAPSHOT-MARKER"
    assert first["bytes"] == byte_size(@html)
    assert first["sha256"] == sha(@html)
    assert_receive {:ecosystem_panel_snapshot, msg}
    assert msg == %{sha256: sha(@html)}

    second_html = "<p>SECOND</p>"
    second = post_json(ctx.admin_a.raw, ctx.path_a, body(html: second_html)) |> json_response(200)
    assert second["sha256"] == sha(second_html)

    assert [%Snapshot{workspace_id: ws_id, html: ^second_html}] = rows()
    assert ws_id == ctx.ws_a.id
  end

  test "refused callers leave the row unchanged", ctx do
    post_json(ctx.admin_a.raw, ctx.path_a, body()) |> json_response(200)
    before = rows()

    # A read-only token sitting on an admin seat: the membership role alone
    # passes RequireWorkspaceRole, the controller's authorize/3 refuses it.
    read_only = token!(["read"], nil)
    {:ok, _} = TenancyAuth.create_membership(ctx.ws_a.id, read_only.token.id, "admin")

    # A token with global admin permission seated only as a member of A.
    global_admin = token!(["read", "write", "admin"], ctx.ws_b.id)
    {:ok, _} = TenancyAuth.create_membership(ctx.ws_a.id, global_admin.token.id, "member")

    refusals = [
      {"signed out", nil, ctx.path_a, 403},
      {"read-only token on an admin seat", read_only.raw, ctx.path_a, 403},
      {"global admin with a member seat", global_admin.raw, ctx.path_a, 403},
      {"admin of another workspace", ctx.admin_b.raw, ctx.path_a, 403},
      {"another workspace's slug with A's project", ctx.admin_a.raw,
       "/w/#{ctx.ws_b.slug}/p/#{ctx.proj_a.slug}/v1/plugins/ecosystem-panel/snapshot", 403}
    ]

    for {label, raw, path, status} <- refusals do
      conn = post_json(raw, path, body(html: "<p>OVERWRITE</p>"))
      assert conn.status == status, "#{label}: expected #{status}, got #{conn.status}"
      refute conn.resp_body =~ "SNAPSHOT-MARKER", "#{label}: the answer carried the HTML"
      assert rows() == before, "#{label}: the row changed"
    end
  end

  test "the flat path answers 404 and writes nothing", ctx do
    conn = post_json(ctx.admin_a.raw, "/v1/plugins/ecosystem-panel/snapshot", body())

    assert conn.status == 404
    assert rows() == []
  end

  test "a forged workspace_id in the body or query cannot pick the row", ctx do
    path = ctx.path_a <> "?workspace_id=#{ctx.ws_b.id}"
    post_json(ctx.admin_a.raw, path, body(workspace_id: ctx.ws_b.id)) |> json_response(200)

    assert [%Snapshot{workspace_id: ws_id}] = rows()
    assert ws_id == ctx.ws_a.id
  end

  test "over 2 MB is 413 and a future built_at is 422; neither writes", ctx do
    big = String.duplicate("a", EcosystemPanel.max_bytes() + 1)
    conn = post_json(ctx.admin_a.raw, ctx.path_a, body(html: big))
    assert %{"error" => %{"code" => "payload_too_large"}} = json_response(conn, 413)

    future = DateTime.utc_now() |> DateTime.add(11 * 60, :second) |> DateTime.to_iso8601()
    conn = post_json(ctx.admin_a.raw, ctx.path_a, body(built_at: future))
    assert %{"error" => %{"code" => "built_at_in_future"}} = json_response(conn, 422)

    conn = post_json(ctx.admin_a.raw, ctx.path_a, %{"html" => @html, "built_at" => "soon"})
    assert %{"error" => %{"code" => "invalid_snapshot"}} = json_response(conn, 422)

    assert rows() == []
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp upload_path(ws, proj),
    do: "/w/#{ws.slug}/p/#{proj.slug}/v1/plugins/ecosystem-panel/snapshot"

  defp body(overrides \\ []) do
    %{"html" => @html, "built_at" => DateTime.utc_now() |> DateTime.to_iso8601()}
    |> Map.merge(Map.new(overrides, fn {k, v} -> {to_string(k), v} end))
  end

  defp post_json(raw, path, body) do
    conn = put_req_header(scoped_conn(), "content-type", "application/json")
    conn = if raw, do: put_req_header(conn, "authorization", "Bearer #{raw}"), else: conn
    post(conn, path, Jason.encode!(body))
  end

  defp token!(permissions, workspace_id) do
    raw = "eco-panel-#{System.unique_integer([:positive])}"

    {:ok, token} =
      Auth.create_token(raw, "eco panel test", "production", permissions, workspace_id)

    %{raw: raw, token: token}
  end

  defp rows, do: Repo.all(from s in Snapshot, order_by: s.workspace_id)

  defp sha(html), do: :crypto.hash(:sha256, html) |> Base.encode16(case: :lower)
end
