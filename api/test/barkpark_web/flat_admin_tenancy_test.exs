defmodule BarkparkWeb.FlatAdminTenancyTest do
  @moduledoc """
  Fail-before protective test for the FLAT admin routes that resolved their
  tenancy to the seeded **Default Workspace** instead of the calling token's own
  workspace (task-2b396416a680ff0b — the 15-scope remainder of charter D45/D49).

  ## The mechanism

  `pipe_through([:api, :require_admin])` runs `Plugs.OptionalToken` (assigns
  `:api_token`, NOT `:current_workspace`) and then `Plugs.AssignDefaultScope`,
  which stamps `current_workspace = Tenancy.get_default_workspace()` whenever
  that assign is absent. `ScopeHelpers.scope_opts/1` builds
  `[workspace_id: …]` straight from that assign, so EVERY caller — from every
  workspace — converged on Default.

  `DeriveWorkspaceFromToken` is **no-op-if-set**, so appending it after `:api`
  is a pure no-op: Default has already won. ORDER is the entire fix, which is
  why `plug_order_is_the_fix` below pins the derivation ahead of the fallback.

  ## Why these assertions are on IDENTITY

  These routes answered 200 while talking to the wrong workspace, so a status
  assertion is vacuous. Every test here reads the `workspace_id` actually
  written to (or filtered on by) the row store.

  RED on origin/main; GREEN once the 3 flat scopes ride the deriving pipeline.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures, only: [create_workspace!: 0, ensure_default_scope!: 0]

  alias Barkpark.Auth
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Webhook

  @pipeline :flat_admin_api
  @dataset "flat-admin-tenancy"
  @token_a "flat-admin-tenancy-token-a"
  @token_default "flat-admin-tenancy-token-default"

  setup do
    # The Default Workspace must EXIST for the defect to manifest —
    # AssignDefaultScope is a no-op on a DB that has never been backfilled, and
    # that is precisely the configuration in which this bug was invisible.
    {default_ws, default_project} = ensure_default_scope!()

    ws_a = create_workspace!()

    {:ok, _} =
      Auth.create_token(@token_a, "flat-admin-a", @dataset, ["read", "write", "admin"], ws_a.id)

    {:ok, _} =
      Auth.create_token(
        @token_default,
        "flat-admin-default",
        @dataset,
        ["read", "write", "admin"],
        default_ws.id
      )

    %{default_ws: default_ws, default_project: default_project, ws_a: ws_a}
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  describe "webhooks (WebhookController) — the flat /v1/webhooks admin scope" do
    test "POST stamps the CALLER's workspace on the row, not the seeded Default",
         %{conn: conn, ws_a: ws_a, default_ws: default_ws} do
      body = %{
        "name" => "hook-owned-by-a",
        "url" => "https://a.example.test/hook",
        "events" => ["create"]
      }

      resp =
        conn
        |> authed(@token_a)
        |> post(~p"/v1/webhooks/#{@dataset}", Jason.encode!(body))

      assert resp.status == 201
      id = json_response(resp, 201)["webhook"]["id"]

      # IDENTITY, read straight off the persisted row — not the status code.
      row = Repo.get!(Webhook, id)

      refute row.workspace_id == default_ws.id,
             "POST /v1/webhooks/:dataset stamped the SEEDED DEFAULT workspace " <>
               "(#{default_ws.id}) for a token bound to workspace #{ws_a.id} — " <>
               "the flat admin scope is not deriving tenancy from the token"

      assert row.workspace_id == ws_a.id
    end

    test "GET lists the CALLER's webhooks and never the Default workspace's",
         %{conn: conn, ws_a: ws_a, default_ws: default_ws, default_project: default_project} do
      {:ok, _a} =
        Webhooks.create_webhook(
          %{"name" => "hook-a", "url" => "https://a.example.test/h", "dataset" => @dataset},
          workspace_id: ws_a.id
        )

      {:ok, _d} =
        Webhooks.create_webhook(
          %{"name" => "hook-default", "url" => "https://d.example.test/h", "dataset" => @dataset},
          # Stamped exactly as the flat route itself stamps a Default-scoped row
          # (workspace AND project), so the leak arm below is reachable rather
          # than accidentally filtered out by a nil project_id.
          workspace_id: default_ws.id,
          project_id: default_project.id
        )

      names =
        conn
        |> authed(@token_a)
        |> get(~p"/v1/webhooks/#{@dataset}")
        |> json_response(200)
        |> Map.fetch!("webhooks")
        |> Enum.map(& &1["name"])
        |> Enum.sort()

      assert names == ["hook-a"],
             "GET /v1/webhooks/:dataset answered workspace #{ws_a.id}'s admin with " <>
               "#{inspect(names)}, not its own [\"hook-a\"] — the read is resolving to the " <>
               "seeded Default Workspace (#{default_ws.id})"
    end
  end

  describe "schemas (SchemaController) — the flat /v1/schemas admin scope" do
    test "POST stamps the CALLER's workspace on the row, not the seeded Default",
         %{conn: conn, ws_a: ws_a, default_ws: default_ws} do
      body = %{
        "name" => "flat_admin_widget",
        "title" => "Flat Admin Widget",
        "fields" => [%{"name" => "title", "type" => "string"}]
      }

      resp =
        conn
        |> authed(@token_a)
        |> post(~p"/v1/schemas/#{@dataset}", Jason.encode!(body))

      assert resp.status == 201

      row = Repo.get_by!(SchemaDefinition, name: "flat_admin_widget", dataset: @dataset)

      refute row.workspace_id == default_ws.id,
             "POST /v1/schemas/:dataset stamped the SEEDED DEFAULT workspace " <>
               "(#{default_ws.id}) for a token bound to workspace #{ws_a.id}"

      assert row.workspace_id == ws_a.id
    end
  end

  describe "structure (StructureController) — the flat /v1/structure admin scope" do
    test "the desk tree is built under the CALLER's workspace",
         %{conn: conn, ws_a: ws_a, default_ws: default_ws} do
      # One type per workspace, same dataset slug — isolation must come from
      # workspace_id, never from the dataset leaf.
      seed_schema!("structure_type_a", ws_a.id)
      seed_schema!("structure_type_default", default_ws.id)

      json =
        conn
        |> authed(@token_a)
        |> get(~p"/v1/structure/#{@dataset}")
        |> json_response(200)

      blob = Jason.encode!(json)

      assert blob =~ "structure_type_a",
             "GET /v1/structure/:dataset did not surface workspace #{ws_a.id}'s own type"

      refute blob =~ "structure_type_default",
             "GET /v1/structure/:dataset surfaced the SEEDED DEFAULT workspace's type " <>
               "(#{default_ws.id}) to a token bound to workspace #{ws_a.id}"
    end
  end

  describe "single-tenant instances are unaffected" do
    test "a token bound to the Default Workspace still resolves to Default",
         %{conn: conn, default_ws: default_ws} do
      body = %{
        "name" => "hook-owned-by-default",
        "url" => "https://d.example.test/hook",
        "events" => ["create"]
      }

      resp =
        conn
        |> authed(@token_default)
        |> post(~p"/v1/webhooks/#{@dataset}", Jason.encode!(body))

      assert resp.status == 201
      id = json_response(resp, 201)["webhook"]["id"]

      assert Repo.get!(Webhook, id).workspace_id == default_ws.id,
             "the single-tenant path (Default IS the only workspace) changed behaviour"
    end
  end

  describe "the Default PROJECT never pairs with a derived workspace" do
    # Second half of the same defect, found by RUNNING the pipeline fix rather
    # than by reading it. `DeriveWorkspaceFromToken` sets only
    # `:current_workspace`; `AssignDefaultScope` used to stamp `:current_project`
    # unconditionally, producing the pair (workspace A, DEFAULT's project).
    # `Content.Scope.scope_to_workspace/3` ANDs both columns, so every scoped
    # read matched zero rows and every scoped write stamped another tenant's
    # project_id — the reorder alone left the routes broken a different way.
    test "a token-derived workspace is left project-less, not paired with Default's project",
         %{ws_a: ws_a} do
      derived =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.assign(:current_workspace, ws_a)
        |> BarkparkWeb.Plugs.AssignDefaultScope.call([])

      refute Map.get(derived.assigns, :current_project),
             "AssignDefaultScope stamped the Default Workspace's project onto a conn " <>
               "resolved to workspace #{ws_a.id} — a cross-tenant (workspace, project) pair"

      assert derived.assigns.current_workspace.id == ws_a.id
    end

    test "the Default Workspace still gets the Default Project (single-tenant path)",
         %{default_ws: default_ws, default_project: default_project} do
      conn =
        Plug.Test.conn(:get, "/")
        |> BarkparkWeb.Plugs.AssignDefaultScope.call([])

      assert conn.assigns.current_workspace.id == default_ws.id
      assert conn.assigns.current_project.id == default_project.id
    end
  end

  describe "plug ORDER is the fix — a reorder must go red" do
    # DeriveWorkspaceFromToken is no-op-if-set. Placed AFTER AssignDefaultScope
    # it can never fire, because Default has already been stamped. The
    # behavioural tests above catch that too, but this reads the ordering
    # DIRECTLY so the failure names the cause instead of a symptom.
    #
    # Block-scoped, not line-anchored: it finds `pipeline :<name> do … end` by
    # name, so inserting lines anywhere in router.ex cannot slide it.
    test "#{@pipeline} derives the workspace from the token BEFORE the Default fallback" do
      plugs = pipeline_plugs(@pipeline)

      derive = index_of!(plugs, "DeriveWorkspaceFromToken", @pipeline)
      default = index_of!(plugs, "AssignDefaultScope", @pipeline)
      token = index_of!(plugs, "RequireToken", @pipeline)

      assert token < derive,
             "RequireToken must assign :api_token before DeriveWorkspaceFromToken reads it " <>
               "(pipeline #{@pipeline}: #{inspect(plugs)})"

      assert derive < default,
             "DeriveWorkspaceFromToken is NO-OP-IF-SET: placed after AssignDefaultScope " <>
               "it can never fire and every caller collapses to the Default Workspace " <>
               "(pipeline #{@pipeline}: #{inspect(plugs)})"
    end

    test "the flat admin scopes ride #{@pipeline}, not the naive [:api, :require_admin]" do
      src = router_source()

      for scope <- ~w(/v1/structure /v1/schemas /v1/webhooks) do
        assert scope_pipeline(src, scope) == "#{@pipeline}",
               "scope \"#{scope}\" is not piped through :#{@pipeline} — its callers " <>
                 "resolve to the seeded Default Workspace"
      end
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp seed_schema!(name, workspace_id) do
    Repo.insert!(
      SchemaDefinition.changeset(%SchemaDefinition{}, %{
        "name" => name,
        "title" => name,
        "dataset" => @dataset,
        "fields" => [%{"name" => "title", "type" => "string"}],
        # `private` puts the type in the desk's Content group; a `public` ad-hoc
        # type is not rendered there, which would make the assertion vacuous.
        "visibility" => "private",
        "workspace_id" => workspace_id
      })
    )
  end

  @router_path Path.expand("../../lib/barkpark_web/router.ex", __DIR__)

  defp router_source, do: File.read!(@router_path)

  # The plug module basenames of `pipeline :name do … end`, in source order.
  defp pipeline_plugs(name) do
    src = router_source()

    [_, block] =
      Regex.run(~r/^  pipeline :#{name} do\n(.*?)^  end$/ms, src) ||
        flunk("router.ex has no `pipeline :#{name}` block")

    ~r/^\s*plug\(([^),]+)/m
    |> Regex.scan(block)
    |> Enum.map(fn [_, arg] -> arg |> String.trim() |> String.split(".") |> List.last() end)
  end

  defp index_of!(plugs, plug, pipeline) do
    case Enum.find_index(plugs, &(&1 == plug)) do
      nil -> flunk("pipeline :#{pipeline} no longer runs #{plug} — got #{inspect(plugs)}")
      i -> i
    end
  end

  # The pipe_through of `scope "<path>", BarkparkWeb do … end`.
  defp scope_pipeline(src, path) do
    case Regex.run(
           ~r/^  scope "#{Regex.escape(path)}", BarkparkWeb do\n\s*pipe_through\((.+?)\)$/m,
           src
         ) do
      [_, pipes] -> pipes |> String.trim() |> String.trim_leading(":")
      nil -> flunk(~s(router.ex has no `scope "#{path}", BarkparkWeb` with a pipe_through))
    end
  end
end
