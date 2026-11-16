defmodule BarkparkWeb.AuditControllerTest do
  @moduledoc """
  `GET /w/:ws/p/:proj/v1/audit` — a workspace admin reads the audit log.

  Only rows of the URL workspace, and of the URL project or no project. Never a
  row with no workspace. Only an owner or admin seat of that workspace, on a
  token with `admin`, may read. Filters and the cursor never widen that scope,
  and no answer carries a row's metadata beyond the fields the feed allows.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Audit, Auth}
  alias Barkpark.TenancyFixtures

  setup do
    ws_a = TenancyFixtures.create_workspace!()
    proj_a = TenancyFixtures.create_project!(ws_a, "default")
    sibling = TenancyFixtures.create_project!(ws_a, "sibling")
    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b, "default")

    %{
      ws_a: ws_a,
      proj_a: proj_a,
      sibling: sibling,
      ws_b: ws_b,
      proj_b: proj_b,
      admin_a: token!(["read", "write", "admin"], ws_a.id),
      admin_b: token!(["read", "write", "admin"], ws_b.id),
      member_a: token!(["read", "write"], ws_a.id)
    }
  end

  test "lists an event of the caller's workspace and none of another workspace or of no workspace",
       ctx do
    mine = event!(ctx.ws_a.id, ctx.proj_a.id, subject: "doc-mine")
    wide = event!(ctx.ws_a.id, nil, subject: "doc-wide")
    _sibling = event!(ctx.ws_a.id, ctx.sibling.id, subject: "doc-sibling")
    _theirs = event!(ctx.ws_b.id, ctx.proj_b.id, subject: "doc-theirs")
    _global = event!(nil, nil, subject: "doc-global")

    body = get_json(ctx.admin_a.raw, audit_path(ctx)) |> json_response(200)
    subjects = Enum.map(body["events"], & &1["target_id"])

    assert "doc-mine" in subjects
    assert "doc-wide" in subjects
    refute "doc-sibling" in subjects
    refute "doc-theirs" in subjects
    refute "doc-global" in subjects

    # Newest first.
    assert Enum.find_index(subjects, &(&1 == "doc-wide")) <
             Enum.find_index(subjects, &(&1 == "doc-mine"))

    row = Enum.find(body["events"], &(&1["target_id"] == "doc-mine"))
    assert row["category"] == "content_mutation"
    assert row["action"] == "document.update"
    assert row["target_type"] == "document"
    assert row["dataset"] == "production"
    assert row["doc_type"] == "post"
    assert row["at"] == DateTime.to_iso8601(mine.occurred_at)
    assert Enum.find(body["events"], &(&1["target_id"] == "doc-wide"))["project_wide"]
    refute row["project_wide"]
    assert wide
  end

  test "a member, a signed-out caller and an admin of another workspace are refused", ctx do
    event!(ctx.ws_a.id, ctx.proj_a.id, subject: "doc-secret-row")

    for raw <- [ctx.member_a.raw, nil, ctx.admin_b.raw] do
      conn = get_json(raw, audit_path(ctx))
      assert conn.status in [401, 403], "#{inspect(raw)} got #{conn.status}"
      refute conn.resp_body =~ "doc-secret-row"
    end
  end

  test "the flat path names no workspace and answers 404", ctx do
    event!(ctx.ws_a.id, ctx.proj_a.id, subject: "doc-flat")
    conn = get_json(ctx.admin_a.raw, "/v1/audit")
    assert conn.status == 404
    refute conn.resp_body =~ "doc-flat"
  end

  test "filters, a huge limit and a cursor never leave the workspace", ctx do
    actor_a = Ecto.UUID.generate()
    actor_b = Ecto.UUID.generate()
    for n <- 1..3, do: event!(ctx.ws_a.id, nil, subject: "a-#{n}", actor_id: actor_a)
    event!(ctx.ws_a.id, nil, subject: "a-token", category: "token", action: "token_minted")
    event!(ctx.ws_b.id, nil, subject: "b-1", actor_id: actor_b)

    # A forged actor id from workspace B finds nothing here.
    body = get_json(ctx.admin_a.raw, audit_path(ctx, actor: actor_b)) |> json_response(200)
    assert body["events"] == []

    body = get_json(ctx.admin_a.raw, audit_path(ctx, actor: actor_a)) |> json_response(200)
    assert Enum.map(body["events"], & &1["target_id"]) == ["a-3", "a-2", "a-1"]

    body = get_json(ctx.admin_a.raw, audit_path(ctx, category: "token")) |> json_response(200)
    assert Enum.map(body["events"], & &1["category"]) |> Enum.uniq() == ["token"]
    assert "a-token" in Enum.map(body["events"], & &1["target_id"])

    assert get_json(ctx.admin_a.raw, audit_path(ctx, category: "nope")).status == 400
    assert get_json(ctx.admin_a.raw, audit_path(ctx, since: "yesterday")).status == 400

    future = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
    body = get_json(ctx.admin_a.raw, audit_path(ctx, since: future)) |> json_response(200)
    assert body["events"] == []

    # A huge limit is capped, not refused.
    body = get_json(ctx.admin_a.raw, audit_path(ctx, limit: 1_000_000)) |> json_response(200)
    assert body["limit"] == 200

    # Page by one: the cursor walks the rows of this workspace only.
    page1 =
      get_json(ctx.admin_a.raw, audit_path(ctx, actor: actor_a, limit: 2)) |> json_response(200)

    assert Enum.map(page1["events"], & &1["target_id"]) == ["a-3", "a-2"]
    assert is_binary(page1["next_cursor"])

    page2 =
      get_json(
        ctx.admin_a.raw,
        audit_path(ctx, actor: actor_a, limit: 2, cursor: page1["next_cursor"])
      )
      |> json_response(200)

    assert Enum.map(page2["events"], & &1["target_id"]) == ["a-1"]
    assert page2["next_cursor"] == nil

    # Workspace B's admin cannot use A's cursor, and a made-up one is refused.
    b_path = "/w/#{ctx.ws_b.slug}/p/#{ctx.proj_b.slug}/v1/audit?cursor=#{page1["next_cursor"]}"
    assert get_json(ctx.admin_b.raw, b_path).status == 400
    assert get_json(ctx.admin_a.raw, audit_path(ctx, cursor: "12")).status == 400
  end

  test "a secret-bearing metadata field never appears in the answer", ctx do
    event!(ctx.ws_a.id, ctx.proj_a.id,
      subject: "doc-meta",
      metadata: %{
        "type" => "post",
        "dataset" => "production",
        "label" => "app:someone-else@example.com",
        "token_hash" => "SECRET-HASH-VALUE",
        "file" => "/srv/barkpark/admin-token.txt"
      }
    )

    event!(ctx.ws_a.id, nil, subject: "leak@example.com", category: "membership")

    conn = get_json(ctx.admin_a.raw, audit_path(ctx))
    body = json_response(conn, 200)
    assert Enum.any?(body["events"], &(&1["target_id"] == "doc-meta"))

    for needle <- ["SECRET-HASH-VALUE", "someone-else@example.com", "admin-token.txt", "leak@"],
        do: refute(conn.resp_body =~ needle, "answer carries #{needle}")
  end

  defp audit_path(ctx, query \\ []) do
    q = if query == [], do: "", else: "?" <> URI.encode_query(query)
    "/w/#{ctx.ws_a.slug}/p/#{ctx.proj_a.slug}/v1/audit" <> q
  end

  defp get_json(raw, path) do
    conn = put_req_header(scoped_conn(), "accept", "application/json")
    conn = if raw, do: put_req_header(conn, "authorization", "Bearer #{raw}"), else: conn
    get(conn, path)
  end

  defp event!(ws_id, proj_id, opts) do
    {:ok, event} =
      Audit.emit(%{
        category: Keyword.get(opts, :category, "content_mutation"),
        action: Keyword.get(opts, :action, "document.update"),
        subject: Keyword.fetch!(opts, :subject),
        actor_type: "user",
        actor_id: Keyword.get(opts, :actor_id, Ecto.UUID.generate()),
        workspace_id: ws_id,
        project_id: proj_id,
        metadata: Keyword.get(opts, :metadata, %{"type" => "post", "dataset" => "production"})
      })

    event
  end

  defp token!(permissions, workspace_id) do
    raw = "audit-feed-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "audit test", "production", permissions, workspace_id)
    %{raw: raw, token: token}
  end
end
