defmodule BarkparkWeb.DatasetBoundAdminReadsTest do
  @moduledoc """
  A token minted with an explicit dataset is held to that dataset, so the
  workspace-level admin reads refuse it: the audit log, the member roster and
  its invitations, the token inventory, and run secrets (scoped and flat).
  Every read path is covered: list, page 2 or cursor, reveal and a secret's
  audit trail. The same seat on an unbound admin token still reads all of them.
  The Studio Activity page, which reads the same audit feed, refuses a session
  signed in with a bound token.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Audit, Auth, Secrets, Tenancy}
  alias Barkpark.TenancyFixtures

  @admin ["read", "write", "admin"]

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

    %{
      ws: ws,
      base: "/w/#{ws.slug}/p/default",
      bound: token!(ws.id, dataset_bound: true),
      unbound: token!(ws.id, []),
      flat_bound: token!(nil, dataset_bound: true),
      flat_unbound: token!(nil, [])
    }
  end

  defp token!(ws_id, opts) do
    raw = "bound-reads-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "bound reads", "production", @admin, ws_id, opts)
    raw
  end

  defp get_as(raw, path) do
    scoped_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> raw)
    |> get(path)
  end

  defp assert_bound_refusal(conn, path) do
    assert conn.status == 403, "#{path} answered #{conn.status}: #{conn.resp_body}"
    error = Jason.decode!(conn.resp_body)["error"]
    assert error["code"] == "forbidden"
    assert error["reason"] == "dataset_not_bound"
    refute conn.resp_body =~ "doc-1"
    refute conn.resp_body =~ "value"
  end

  defp scoped_paths(base, cursor) do
    [
      base <> "/v1/audit",
      base <> "/v1/audit?limit=1&cursor=" <> URI.encode_www_form(cursor),
      base <> "/v1/members",
      base <> "/v1/members?limit=1&offset=1",
      base <> "/v1/invitations",
      base <> "/v1/tokens",
      base <> "/v1/tokens?limit=1&offset=1",
      base <> "/v1/secrets",
      base <> "/v1/secrets/BOUND_PROBE",
      base <> "/v1/secrets/BOUND_PROBE/audit"
    ]
  end

  @flat_paths [
    "/v1/secrets",
    "/v1/secrets/BOUND_PROBE_GLOBAL",
    "/v1/secrets/BOUND_PROBE_GLOBAL/audit"
  ]

  # A real page-2 cursor, read by the unbound admin of the same workspace.
  defp cursor!(ctx) do
    body = get_as(ctx.unbound, ctx.base <> "/v1/audit?limit=1") |> json_response(200)
    assert is_binary(body["next_cursor"])
    body["next_cursor"]
  end

  test "audit: a bound admin token gets 403 on the first page and on a cursor page", ctx do
    cursor = cursor!(ctx)

    for path <- [ctx.base <> "/v1/audit", ctx.base <> "/v1/audit?cursor=" <> cursor] do
      assert_bound_refusal(get_as(ctx.bound, path), path)
    end
  end

  test "members: a bound admin token gets 403 on the roster, page 2 and invitations", ctx do
    for path <- ~w(/v1/members /v1/members?limit=1&offset=1 /v1/invitations) do
      assert_bound_refusal(get_as(ctx.bound, ctx.base <> path), path)
    end
  end

  test "tokens: a bound admin token gets 403 on the inventory and page 2", ctx do
    for path <- ~w(/v1/tokens /v1/tokens?limit=1&offset=1) do
      assert_bound_refusal(get_as(ctx.bound, ctx.base <> path), path)
    end
  end

  test "secrets: a bound admin token gets 403 on list, reveal and audit, scoped and flat", ctx do
    for path <- ~w(/v1/secrets /v1/secrets/BOUND_PROBE /v1/secrets/BOUND_PROBE/audit) do
      assert_bound_refusal(get_as(ctx.bound, ctx.base <> path), path)
    end

    for path <- @flat_paths do
      assert_bound_refusal(get_as(ctx.flat_bound, path), path)
    end
  end

  test "an unbound admin token on the same seat still reads all four", ctx do
    cursor = cursor!(ctx)

    for path <- scoped_paths(ctx.base, cursor) do
      conn = get_as(ctx.unbound, path)
      assert conn.status == 200, "#{path} answered #{conn.status}: #{conn.resp_body}"
    end

    for path <- @flat_paths do
      conn = get_as(ctx.flat_unbound, path)
      assert conn.status == 200, "#{path} answered #{conn.status}: #{conn.resp_body}"
    end
  end

  test "the Studio Activity page refuses a session signed in with a bound admin token", ctx do
    path = ctx.base <> "/d/production/studio/_activity"
    bound = Plug.Test.init_test_session(scoped_conn(), %{"api_token" => ctx.bound})

    assert {:error, {:redirect, %{to: "/studio"}}} = live(bound, path)

    unbound = Plug.Test.init_test_session(scoped_conn(), %{"api_token" => ctx.unbound})
    assert {:ok, _view, html} = live(unbound, path)
    assert html =~ "doc-1"
  end
end
