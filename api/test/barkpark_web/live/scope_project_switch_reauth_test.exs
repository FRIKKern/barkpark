defmodule BarkparkWeb.Live.ScopeProjectSwitchReauthTest do
  @moduledoc """
  LiveView authz sweep (r4a): `switch-project` / `switch-workspace` skipped
  LiveScope's re-authorization.

  `LiveScope.reauthorize/3` decided "same scope, skip" by comparing the URL
  slugs with the socket's `current_workspace` / `current_project` / `dataset`
  ASSIGNS. But `Scope.switch_project/2` and `Scope.switch_workspace/2` write
  the NEW project/workspace into those assigns BEFORE they `push_patch`. The
  hook then compared the new URL against the new assigns, saw a match, and
  never re-ran `authorize_read/4`.

  Shares are per project (`Sharing.shared?/4`), and both events are on the
  read-only allowlist. So an anonymous visitor on a `:docs` share of
  `ws/projA/production` could send `switch-project` with an UNSHARED sibling
  project and read it — the dataset slug matches (`production`), so not even
  the dataset arm forced a re-check.

  The fix stamps the scope LiveScope actually authorized and compares the URL
  against that stamp, not against assigns the LiveView can rewrite.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Tenancy}

  @dataset "production"
  @secret_title "UNSHARED-PROJECT-SECRET"
  @shared_title "SHARED-PROJECT-DOC"

  setup %{conn: conn} do
    Barkpark.SharingFixtures.snapshot_shares!()
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    # A NON-default workspace (Default is the open public demo in test).
    ws = create_workspace!("proj-switch-#{System.unique_integer([:positive])}")
    shared = create_project!(ws, "shared-proj")
    unshared = create_project!(ws, "unshared-proj")

    for proj <- [shared, unshared] do
      {:ok, _} = Tenancy.get_or_create_dataset(proj, @dataset)
      seed_post_schema!(ws, proj)
    end

    {:ok, _} =
      Content.create_document("post", %{"title" => @shared_title}, @dataset,
        workspace_id: ws.id,
        project_id: shared.id
      )

    {:ok, _} =
      Content.create_document("post", %{"title" => @secret_title}, @dataset,
        workspace_id: ws.id,
        project_id: unshared.id
      )

    # ONLY the shared project is :docs-shared, read-only.
    Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{shared.slug}/#{@dataset}:docs:read")

    {:ok, conn: conn, ws: ws, shared: shared, unshared: unshared}
  end

  defp seed_post_schema!(ws, proj) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Posts",
          "icon" => "📝",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )
  end

  defp mount_share_read!(conn, ws, proj) do
    {:ok, view, _html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio")
    assert :sys.get_state(view.pid).socket.assigns[:share_access] == :read
    view
  end

  defp drill_post(view) do
    render_click(view, "select", %{"pane" => "0", "id" => "post"})
    render(view)
  end

  test "positive control: the share reads its own project", %{conn: conn, ws: ws, shared: p} do
    view = mount_share_read!(conn, ws, p)
    assert drill_post(view) =~ @shared_title
  end

  test "switch-project to an UNSHARED sibling project is denied before any read", %{
    conn: conn,
    ws: ws,
    shared: shared,
    unshared: unshared
  } do
    view = mount_share_read!(conn, ws, shared)

    render_click(view, "switch-project", %{"project" => unshared.slug})

    assert_redirect(view, "/login")
  end

  test "switch-workspace to the SAME workspace cannot land in an unshared project", %{
    conn: conn,
    ws: ws,
    shared: shared
  } do
    view = mount_share_read!(conn, ws, shared)

    result = render_click(view, "switch-workspace", %{"workspace" => ws.slug})

    # Either the switch stays in the shared project, or it re-authorizes and
    # is ejected — it must never render the unshared project's documents.
    case result do
      html when is_binary(html) ->
        if Process.alive?(view.pid) do
          refute drill_post(view) =~ @secret_title
        end

      _ ->
        :ok
    end
  end
end
