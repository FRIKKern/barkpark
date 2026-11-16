defmodule BarkparkWeb.DatasetBoundAdminReadsTest do
  @moduledoc """
  A dataset-bound admin token on the workspace-level admin reads: the audit log,
  the member roster and its invitations, the token inventories (workspace
  tokens, app tokens, share-edit tokens), run secrets (scoped and flat: list,
  reveal, audit trail), the workspace export, and the Studio Activity page.

  `:observe` (the default) answers exactly as before and writes one audit row
  per read. `:enforce` refuses with 403 `dataset_not_bound`. An unbound admin
  token on the same seat reads everything in both modes and is never recorded.
  """
  use BarkparkWeb.ConnCase, async: false

  # Observe mode logs one line per read; keep them out of the test output.
  @moduletag :capture_log

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.{Audit, Auth, Repo, Secrets, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.TenancyFixtures
  alias BarkparkWeb.Plugs.DatasetBoundAdminReads

  @admin ["read", "write", "admin"]
  @action "bound_token.admin_read"

  setup do
    ws = TenancyFixtures.create_workspace!()
    proj = TenancyFixtures.create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, "production")

    for n <- 1..2 do
      {:ok, _} =
        Audit.emit(%{
          category: "content_mutation",
          action: "document.update",
          subject: "doc-#{n}",
          actor_type: "user",
          actor_id: Ecto.UUID.generate(),
          workspace_id: ws.id,
          project_id: proj.id,
          metadata: %{"type" => "post", "dataset" => "production"}
        })
    end

    {:ok, _} = Secrets.put("BOUND_PROBE", "scoped-value", scope: ws.id)
    {:ok, _} = Secrets.put("BOUND_PROBE_GLOBAL", "global-value", scope: :global)

    previous = Application.get_env(:barkpark, :dataset_bound_admin_reads)
    on_exit(fn -> Application.put_env(:barkpark, :dataset_bound_admin_reads, previous) end)

    {:ok,
     ws: ws,
     base: "/w/#{ws.slug}/p/default",
     bound: token!(ws.id, dataset_bound: true),
     unbound: token!(ws.id, []),
     flat_bound: token!(nil, dataset_bound: true),
     flat_unbound: token!(nil, [])}
  end

  defp token!(ws_id, opts) do
    raw = "bound-reads-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "bound reads", "production", @admin, ws_id, opts)
    %{raw: raw, id: token.id}
  end

  defp enforce!, do: Application.put_env(:barkpark, :dataset_bound_admin_reads, :enforce)

  defp get_as(raw, path) do
    scoped_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> raw)
    |> get(path)
  end

  # Every read: {group, token kind, surface recorded, path}. One test per group
  # and mode, so each surface fails or passes on its own.
  @groups [
    "audit",
    "members",
    "workspace tokens",
    "app tokens",
    "share tokens",
    "scoped secrets",
    "flat secrets",
    "workspace export"
  ]

  defp reads(ctx, cursor) do
    b = ctx.base

    [
      {"audit", :ws, "audit", b <> "/v1/audit"},
      {"audit", :ws, "audit", b <> "/v1/audit?limit=1&cursor=" <> URI.encode_www_form(cursor)},
      {"members", :ws, "members", b <> "/v1/members"},
      {"members", :ws, "members", b <> "/v1/members?limit=1&offset=1"},
      {"members", :ws, "members", b <> "/v1/invitations"},
      {"workspace tokens", :ws, "tokens", b <> "/v1/tokens"},
      {"workspace tokens", :ws, "tokens", b <> "/v1/tokens?limit=1&offset=1"},
      {"app tokens", :ws, "tokens", "/v1/auth/app-tokens"},
      {"share tokens", :ws, "tokens", "/v1/shares/tokens"},
      {"scoped secrets", :ws, "secrets", b <> "/v1/secrets"},
      {"scoped secrets", :ws, "secrets", b <> "/v1/secrets/BOUND_PROBE"},
      {"scoped secrets", :ws, "secrets", b <> "/v1/secrets/BOUND_PROBE/audit"},
      {"flat secrets", :flat, "secrets", "/v1/secrets"},
      {"flat secrets", :flat, "secrets", "/v1/secrets/BOUND_PROBE_GLOBAL"},
      {"flat secrets", :flat, "secrets", "/v1/secrets/BOUND_PROBE_GLOBAL/audit"},
      {"workspace export", :ws, "workspace_export", "/api/workspaces/#{ctx.ws.slug}/export"}
    ]
  end

  defp reads(ctx, cursor, group),
    do: for({^group, kind, surface, path} <- reads(ctx, cursor), do: {kind, surface, path})

  defp raw_for(ctx, :ws, :bound), do: ctx.bound
  defp raw_for(ctx, :flat, :bound), do: ctx.flat_bound
  defp raw_for(ctx, :ws, :unbound), do: ctx.unbound
  defp raw_for(ctx, :flat, :unbound), do: ctx.flat_unbound

  # A real page-2 cursor, read by the unbound admin of the same workspace.
  defp cursor!(ctx) do
    body = get_as(ctx.unbound.raw, ctx.base <> "/v1/audit?limit=1") |> json_response(200)
    assert is_binary(body["next_cursor"])
    body["next_cursor"]
  end

  defp with_query(path, q),
    do: if(String.contains?(path, "?"), do: path <> "&" <> q, else: path <> "?" <> q)

  defp records, do: Repo.all(from(e in Event, where: e.action == @action, order_by: e.id))

  defp comparable(conn) do
    {conn.status, conn.resp_body,
     conn.resp_headers |> Enum.reject(fn {k, _} -> k == "x-request-id" end) |> Enum.sort()}
  end

  describe "observe (the default)" do
    for group <- @groups do
      test "#{group}: a bound admin token's read writes one audit row", ctx do
        assert DatasetBoundAdminReads.mode() == :observe

        for {kind, surface, path} <- reads(ctx, cursor!(ctx), unquote(group)) do
          token = raw_for(ctx, kind, :bound)
          before = records()

          conn = get_as(token.raw, path)
          assert conn.status == 200, "#{path} answered #{conn.status}: #{conn.resp_body}"

          new_rows = records() -- before
          assert length(new_rows) == 1, "#{path} wrote #{length(new_rows)} rows"
          [row] = new_rows
          assert row.category == "access"
          assert row.actor_type == "api_token"
          assert row.actor_id == token.id
          assert row.subject == token.id
          assert row.workspace_id == if(kind == :ws, do: ctx.ws.id)
          assert row.metadata["surface"] == surface
          assert row.metadata["route"] =~ ~r/^GET BarkparkWeb\.\w+\.\w+$/

          written = inspect(Map.from_struct(row))
          refute written =~ token.raw
          refute written =~ "bound reads"
        end
      end
    end

    test "the answer is the one the same request gets again: status, body, headers", ctx do
      cursor = cursor!(ctx)

      paths =
        reads(ctx, cursor)
        |> Enum.map(fn {_group, kind, surface, path} -> {kind, surface, path} end)
        # The export is a fresh bundle each time (its own timestamps).
        |> Enum.reject(fn {_, surface, _} -> surface == "workspace_export" end)
        # Page 1 of the audit log would show the previous read's record: the
        # category filter keeps that row out of both answers.
        |> Enum.map(fn
          {k, "audit", path} -> {k, "audit", with_query(path, "category=content_mutation")}
          other -> other
        end)

      for {kind, _surface, path} <- paths do
        token = raw_for(ctx, kind, :bound)
        first = get_as(token.raw, path)
        second = get_as(token.raw, path)
        assert first.status == 200, "#{path} answered #{first.status}: #{first.resp_body}"
        assert comparable(first) == comparable(second), "#{path} changed between two reads"
      end
    end

    test "a read never contains its own record", ctx do
      conn = get_as(ctx.bound.raw, ctx.base <> "/v1/audit")
      actions = conn |> json_response(200) |> Map.fetch!("events") |> Enum.map(& &1["action"])
      refute @action in actions
      assert [_] = records()
    end

    test "a refused or failed read is not recorded", ctx do
      conn = get_as(ctx.bound.raw, ctx.base <> "/v1/audit?cursor=not-a-cursor")
      assert conn.status == 400
      assert records() == []
    end

    test "the Studio Activity page opens for a bound admin session and records the read", ctx do
      bound = Plug.Test.init_test_session(scoped_conn(), %{"api_token" => ctx.bound.raw})
      assert {:ok, _view, html} = live(bound, ctx.base <> "/d/production/studio/_activity")
      assert html =~ "doc-1"
      assert [_ | _] = rows = records()
      assert Enum.all?(rows, &(&1.metadata["surface"] == "audit" and &1.actor_id == ctx.bound.id))
    end
  end

  describe "enforce" do
    setup do
      enforce!()
      :ok
    end

    for group <- @groups do
      test "#{group}: a bound admin token gets 403 dataset_not_bound", ctx do
        assert DatasetBoundAdminReads.mode() == :enforce

        for {kind, _surface, path} <- reads(ctx, cursor!(ctx), unquote(group)) do
          conn = get_as(raw_for(ctx, kind, :bound).raw, path)
          assert conn.status == 403, "#{path} answered #{conn.status}: #{conn.resp_body}"
          error = Jason.decode!(conn.resp_body)["error"]
          assert error["code"] == "forbidden"
          assert error["reason"] == "dataset_not_bound"
          refute conn.resp_body =~ "doc-1"
          refute conn.resp_body =~ "value"
        end

        assert records() == []
      end
    end

    test "the Studio Activity page refuses a session signed in with a bound admin token", ctx do
      bound = Plug.Test.init_test_session(scoped_conn(), %{"api_token" => ctx.bound.raw})

      assert {:error, {:redirect, %{to: "/studio"}}} =
               live(bound, ctx.base <> "/d/production/studio/_activity")
    end
  end

  for mode <- [:observe, :enforce] do
    test "#{mode}: an unbound admin token on the same seat reads all of them, unrecorded", ctx do
      Application.put_env(:barkpark, :dataset_bound_admin_reads, unquote(mode))

      for {_group, kind, _surface, path} <- reads(ctx, cursor!(ctx)) do
        conn = get_as(raw_for(ctx, kind, :unbound).raw, path)
        assert conn.status == 200, "#{path} answered #{conn.status}: #{conn.resp_body}"
      end

      unbound = Plug.Test.init_test_session(scoped_conn(), %{"api_token" => ctx.unbound.raw})
      assert {:ok, _view, html} = live(unbound, ctx.base <> "/d/production/studio/_activity")
      assert html =~ "doc-1"

      assert records() == []
    end
  end

  test "the token inventory says which tokens are bound", ctx do
    body = get_as(ctx.unbound.raw, ctx.base <> "/v1/tokens") |> json_response(200)
    by_id = Map.new(body["tokens"], &{&1["id"], &1["dataset_bound"]})
    assert by_id[ctx.bound.id] == true
    assert by_id[ctx.unbound.id] == false
  end

  test "any setting other than :enforce reads as :observe" do
    for value <- [nil, :observe, "enforce", :other] do
      Application.put_env(:barkpark, :dataset_bound_admin_reads, value)
      assert DatasetBoundAdminReads.mode() == :observe
    end

    enforce!()
    assert DatasetBoundAdminReads.mode() == :enforce
  end
end
