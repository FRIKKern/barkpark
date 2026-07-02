defmodule BarkparkWeb.StudioLiveScopeGuardTest do
  @moduledoc """
  Pins the input-guarding of the pane-navigation handlers (Scope.select/2 and
  Scope.expand_pane/2). Both take a client-controlled index off phx-value; a
  non-numeric value used to crash the LiveView (String.to_integer raises) and a
  negative value silently built a wrong nav path (Enum.take/2 counts from the
  end). Guarded Integer.parse now no-ops on both — the process must stay alive
  and the URL must not change.

  Scope/setup mirrors StudioLiveEmptyPaneTest: a uniquely-slugged
  workspace+project+dataset with an `author` schema, mounted under its own
  scoped Studio URL.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ws_slug "scope-guard-ws"
  @proj_slug "scope-guard-proj"
  @dataset "scope-guard-ds"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()

    {:ok, ws} = Tenancy.create_workspace(%{slug: @ws_slug, name: "ScopeGuardWS"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: @proj_slug, name: "ScopeGuardProj"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "ScopeGuard"})

    raw = "scope-guard-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "scope-guard", "production", ["read", "write"], default_ws.id)

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

  defp mount_studio(conn) do
    live(conn, "/w/#{@ws_slug}/p/#{@proj_slug}/d/#{@dataset}/studio/author")
  end

  test "select with a non-numeric pane index does not crash the LiveView", %{conn: conn} do
    {:ok, view, _html} = mount_studio(conn)

    render_click(view, "select", %{"pane" => "bogus", "id" => "some-doc"})

    # Still alive and rendering — the raise-on-String.to_integer is gone.
    assert is_binary(render(view))
    refute patched?(view)
  end

  test "select with a negative pane index no-ops rather than building a wrong path", %{conn: conn} do
    {:ok, view, _html} = mount_studio(conn)

    render_click(view, "select", %{"pane" => "-1", "id" => "some-doc"})

    # Negative index is rejected: no navigation, process alive. (Old code
    # parsed fine and Enum.take(path, -1) took from the end → wrong path.)
    assert is_binary(render(view))
    refute patched?(view)
  end

  test "expand-pane with a bogus index does not crash the LiveView", %{conn: conn} do
    {:ok, view, _html} = mount_studio(conn)

    render_click(view, "expand-pane", %{"idx" => "not-an-int"})

    assert is_binary(render(view))
    refute patched?(view)
  end

  # A rejected event must NOT push_patch. assert_patch raises on timeout when no
  # patch arrives, so a raise here means "no navigation" — which is what we want.
  defp patched?(view) do
    assert_patch(view, 50)
    true
  rescue
    _ -> false
  end
end
