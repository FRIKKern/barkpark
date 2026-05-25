defmodule BarkparkWeb.Integration.PreviewScopeLeakTest do
  @moduledoc """
  Tenancy-leak guard for the flat preview routes (B9 / barkpark-6xd9).

  Before the fix, the `:api_preview` pipeline lacked
  `BarkparkWeb.Plugs.AssignDefaultScope` (the `:api` pipeline already had it),
  so flat `/v1/preview/*` draft reads ran UNSCOPED — a preview-JWT request
  could read another workspace's draft across the tenant boundary.

  The fix adds `AssignDefaultScope` to `:api_preview`, mirroring `:api`. The
  flat preview routes now infer the seeded Default workspace/project, and the
  `QueryController` already threads `ScopeHelpers.scope_opts(conn)` into its
  reads — so a flat preview read sees ONLY Default-scoped drafts.

  This test seeds a draft stamped to a NON-Default workspace B and asserts a
  flat preview read (Default-scoped after the fix) never returns it. A Default-
  scoped draft is also seeded as the positive control — the route still
  surfaces what it should.

  `async: false` — `Application.put_env(:barkpark, :preview, …)` is global.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, PreviewToken, Tenancy}

  @secret "test-preview-secret-leak-1234567890"
  @dataset "production"

  setup do
    prior = Application.get_env(:barkpark, :preview)

    Application.put_env(:barkpark, :preview,
      secret: @secret,
      ttl_seconds: 600,
      issuer: "barkpark"
    )

    on_exit(fn -> Application.put_env(:barkpark, :preview, prior || []) end)

    drain_task_supervisor(30_000)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset
      )

    # Default scope (what the flat preview route will scope to after the fix).
    {default_ws, default_project} = ensure_default!()

    # A SEPARATE workspace B with a draft. This draft must NEVER surface
    # through a Default-scoped flat preview read.
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "wsb-preview", name: "WS B"})
    {:ok, proj_b} = Tenancy.create_project(ws_b, %{slug: "pb-preview", name: "Proj B"})

    {:ok, _b_draft} =
      Content.create_document(
        "post",
        %{"_id" => "secret-b", "title" => "B SECRET DRAFT"},
        @dataset,
        workspace_id: ws_b.id,
        project_id: proj_b.id
      )

    # Positive control: a Default-scoped draft the route SHOULD return.
    {:ok, _ok_draft} =
      Content.create_document(
        "post",
        %{"_id" => "ok-default", "title" => "DEFAULT DRAFT"},
        @dataset,
        workspace_id: default_ws.id,
        project_id: default_project.id
      )

    :ok
  end

  defp ensure_default! do
    ws =
      case Tenancy.get_default_workspace() do
        nil ->
          {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default"})
          ws

        ws ->
          ws
      end

    project =
      case Tenancy.get_default_project() do
        nil ->
          {:ok, p} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
          p

        p ->
          p
      end

    {ws, project}
  end

  defp drain_task_supervisor(deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    case Task.Supervisor.children(Barkpark.TaskSupervisor) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(50)
          do_drain(deadline)
        end
    end
  end

  defp mint_jwt do
    {jwt, _} = PreviewToken.sign(%{dataset: @dataset, doc_ids: []}, @secret)
    jwt
  end

  defp with_preview(conn, jwt), do: put_req_header(conn, "authorization", "Preview " <> jwt)

  test "flat preview list (Default-scoped) does NOT leak workspace B's draft", %{conn: conn} do
    resp =
      conn
      |> with_preview(mint_jwt())
      |> get(~p"/v1/preview/query/#{@dataset}/post")

    assert resp.status == 200
    body = json_response(resp, 200)
    ids = Enum.map(body["result"]["documents"], & &1["_id"])

    assert "drafts.ok-default" in ids,
           "expected the Default-scoped draft in the preview list, got #{inspect(ids)}"

    refute "drafts.secret-b" in ids,
           "PREVIEW TENANCY LEAK: workspace B's draft surfaced through a Default-scoped " <>
             "flat preview read — :api_preview is missing AssignDefaultScope (got #{inspect(ids)})"
  end

  test "flat preview doc fetch (Default-scoped) cannot read workspace B's draft", %{conn: conn} do
    resp =
      conn
      |> with_preview(mint_jwt())
      |> get(~p"/v1/preview/doc/#{@dataset}/post/drafts.secret-b")

    refute resp.status == 200,
           "PREVIEW TENANCY LEAK: a Default-scoped flat preview read returned workspace B's " <>
             "draft doc (status #{resp.status})"
  end
end
