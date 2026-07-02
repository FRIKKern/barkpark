defmodule BarkparkWeb.Studio.ApiTesterLiveScopeGuardTest do
  @moduledoc """
  Pins the nil-endpoint guarding of the API Tester LiveView handlers.

  Endpoints.find/2 returns nil for any id not in all(dataset). Because the
  endpoint list is dataset-scoped, a still-rendered phx-value-id left over
  from a prior dataset/scope resolves to nil after a switch. The "select"
  handler used to seed initial_form_state(nil) — a BadMapError deref of
  endpoint.path_params — and "run" read endpoint.kind on nil, crashing the
  whole tool on an ordinary click and forcing a reconnect that drops session
  state. Both handlers now no-op on a nil endpoint; the process stays alive.

  Scope/setup mirrors StudioLiveScopeGuardTest: a uniquely-slugged
  workspace+project+dataset with an `author` schema, mounted under its own
  scoped API Tester URL.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ws_slug "api-tester-guard-ws"
  @proj_slug "api-tester-guard-proj"
  @dataset "api-tester-guard-ds"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()

    {:ok, ws} = Tenancy.create_workspace(%{slug: @ws_slug, name: "ApiTesterGuardWS"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: @proj_slug, name: "ApiTesterGuardProj"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "ApiTesterGuard"})

    raw = "api-tester-guard-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "api-tester-guard", "production", ["read", "write"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "member")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _schema} =
      Barkpark.Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Authors",
          "icon" => "user",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset,
        scope
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn}
  end

  defp mount_tester(conn) do
    live(conn, "/w/#{@ws_slug}/p/#{@proj_slug}/d/#{@dataset}/studio/api-tester")
  end

  test "select with an unknown/stale endpoint id does not crash the LiveView", %{conn: conn} do
    {:ok, view, _html} = mount_tester(conn)

    render_click(view, "select", %{"id" => "does-not-exist"})

    # No BadMapError deref of endpoint.path_params — process alive, still renders.
    assert Process.alive?(view.pid)
    assert is_binary(render(view))
  end

  test "an unknown/stale phx event does not crash the LiveView", %{conn: conn} do
    {:ok, view, _html} = mount_tester(conn)

    render_hook(view, "totally-unknown-stale-event", %{})

    assert Process.alive?(view.pid)
    assert is_binary(render(view))
  end
end
