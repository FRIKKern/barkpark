defmodule BarkparkWeb.Studio.StudioLiveWorkspaceSwitcherTest do
  @moduledoc """
  Task barkpark-k86v: the Studio LiveView workspace/project switcher.
  Task barkpark-g4a7: the switcher is now MEMBERSHIP-AWARE — it lists only the
  mounted principal's member workspaces (never the unscoped `list_workspaces/0`),
  and `switch-workspace` / `switch-project` reject a switch to a workspace the
  principal isn't a member of.

  Covers:
    * the switcher renders both selects (Workspace + Project) in the topbar,
      defaulting to the principal's first member workspace;
    * the workspace `<select>` lists ONLY member workspaces — a foreign
      workspace the principal has no membership in never appears;
    * `switch-workspace` to a MEMBER workspace re-assigns `:current_workspace`
      (and re-defaults the project); a switch to a NON-MEMBER workspace is
      rejected (scope unchanged);
    * `switch-project` re-assigns `:current_project` within the current
      workspace.

  The Studio route shape stays `/studio/:dataset` — switching is a LiveView
  event over socket scope, NOT a URL navigation. Full live-browser round-trip
  is the orchestrator's integration gate; this is LiveViewTest + compile.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    # The migration backfill seeds the Default workspace/project into the test
    # DB (outside the sandbox), so it is present here. Add a SECOND workspace +
    # project (a MEMBER workspace) so switching has somewhere to go, and a THIRD
    # (a FOREIGN workspace) the principal is NOT a member of.
    default_ws = Tenancy.get_default_workspace()
    default_project = Tenancy.get_default_project()

    {:ok, acme_ws} = Tenancy.create_workspace(%{slug: "acme", name: "Acme"})
    {:ok, acme_blog} = Tenancy.create_project(acme_ws, %{slug: "blog", name: "Blog"})
    # A SECOND Acme project so the Project level has >1 option and renders a
    # `<select>` (the single-option→static-label rule, Task barkpark-dgpf, only
    # collapses to static text when exactly one option exists). "blog" stays
    # slug-first, so the mount default project is unchanged.
    {:ok, _acme_zine} = Tenancy.create_project(acme_ws, %{slug: "zine", name: "Zine"})

    # Datasets under the Acme/Blog project — the controlled data for the
    # project-scoped Dataset select (Task barkpark-dgpf). Mirrors the real
    # Default-project shape (production/paperflow/reftest_16835): "production"
    # is the auto-select default; "staging"/"reftest" are the alternates.
    {:ok, acme_production} =
      Tenancy.create_dataset(acme_blog, %{slug: "production", name: "Production"})

    {:ok, acme_staging} = Tenancy.create_dataset(acme_blog, %{slug: "staging", name: "Staging"})
    {:ok, acme_reftest} = Tenancy.create_dataset(acme_blog, %{slug: "reftest", name: "Reftest"})

    {:ok, foreign_ws} = Tenancy.create_workspace(%{slug: "foreign", name: "Foreign Co"})
    {:ok, _foreign_proj} = Tenancy.create_project(foreign_ws, %{slug: "secret", name: "Secret"})

    # Mint a principal that is a member of Default + Acme but NOT Foreign Co.
    raw = "switcher-test-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "switcher", @dataset, ["read", "write"], default_ws.id)
    {:ok, _} = TenancyAuth.create_membership(acme_ws.id, token.id, "member")

    # A schema so the desk has something to render after a scope switch.
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     default_ws: default_ws,
     default_project: default_project,
     acme_ws: acme_ws,
     acme_blog: acme_blog,
     acme_production: acme_production,
     acme_staging: acme_staging,
     acme_reftest: acme_reftest,
     foreign_ws: foreign_ws}
  end

  describe "switcher render" do
    test "renders the Workspace + Project selects defaulting to a member workspace", %{
      conn: conn,
      default_ws: default_ws,
      acme_ws: acme_ws,
      acme_blog: acme_blog
    } do
      {:ok, view, html} = live(conn, "/studio/#{@dataset}")

      # Both selects present, wired to the switch events.
      assert html =~ ~s(phx-change="switch-workspace")
      assert html =~ ~s(phx-change="switch-project")

      # The initial scope is the principal's slug-FIRST member workspace
      # (`list_workspaces_for/1` is slug-ordered, "acme" < "default"), with
      # its first project — not the seeded Default. Both member workspaces
      # are offered in the workspace select.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == acme_ws.slug
      assert assigns.current_project.slug == acme_blog.slug

      ws_select = view |> element(~s(select[name="workspace"])) |> render()
      assert ws_select =~ acme_ws.name
      assert ws_select =~ default_ws.name
    end

    test "the workspace select lists ONLY member workspaces — no foreign tenant", %{
      conn: conn,
      foreign_ws: foreign_ws
    } do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      ws_select = view |> element(~s(select[name="workspace"])) |> render()

      # Member workspaces present.
      assert ws_select =~ "Acme"
      # The foreign workspace (no membership row) MUST NOT appear/be selectable.
      refute ws_select =~ foreign_ws.name,
             "TENANT LEAK: a non-member workspace appeared in the switcher — " <>
               "the switcher must use list_workspaces_for/1, not list_workspaces/0"
    end
  end

  describe "switching scope" do
    test "switch-workspace to a MEMBER workspace re-assigns scope + re-defaults project", %{
      conn: conn,
      acme_ws: acme_ws,
      acme_blog: acme_blog
    } do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => acme_ws.slug})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == acme_ws.slug
      # Project re-defaulted to the new workspace's first project.
      assert assigns.current_project.slug == acme_blog.slug

      # The Project select now shows the new workspace's project.
      assert view |> element(~s(select[name="project"])) |> render() =~ acme_blog.name
    end

    test "switch-workspace to a NON-MEMBER workspace is REJECTED (scope unchanged)", %{
      conn: conn,
      foreign_ws: foreign_ws
    } do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      before = :sys.get_state(view.pid).socket.assigns.current_workspace.slug

      # Forge a switch to the foreign workspace's slug (the option isn't even
      # rendered, but a crafted phx-change must still be refused server-side).
      render_change(element(view, ~s(select[name="workspace"])), %{
        "workspace" => foreign_ws.slug
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == before,
             "MEMBERSHIP GATE BREACH: switch-workspace re-scoped to a non-member workspace"
      refute assigns.current_workspace.slug == foreign_ws.slug
    end

    test "switch-project re-assigns current_project within a member workspace", %{
      conn: conn,
      default_ws: default_ws
    } do
      {:ok, second_project} =
        Tenancy.create_project(default_ws, %{slug: "secondary", name: "Secondary"})

      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      # Switch into Default (a member workspace), then change project within it.
      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => default_ws.slug})

      render_change(element(view, ~s(select[name="project"])), %{
        "project" => second_project.slug
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == default_ws.slug
      assert assigns.current_project.slug == second_project.slug
    end

    test "unknown workspace slug is a no-op (scope unchanged)", %{
      conn: conn,
      acme_ws: acme_ws
    } do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => "does-not-exist"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == acme_ws.slug
    end
  end

  # ── Task barkpark-dgpf: project-scoped Dataset select, far-right control ─────
  #
  # The switcher now renders THREE controls left→right: Workspace · Project ·
  # Dataset. The Dataset (rightmost) is populated from the CURRENT project's
  # datasets (`Tenancy.list_datasets/1`), `selected` = the active dataset slug.
  # Switching the project cascades: reload the dataset list + auto-select the
  # project's default (production-first, else first) + re-scope to it.
  describe "dataset select (barkpark-dgpf)" do
    test "renders Workspace → Project → Dataset in DOM order, dataset is the far-right control",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}")

      # All three controls are present, wired to their switch events.
      assert html =~ ~s(phx-change="switch-workspace") or html =~ "workspace-switcher-static"
      assert html =~ ~s(phx-change="switch-dataset")

      # DOM order: the Workspace label precedes the Project label precedes the
      # Dataset label. The Dataset is LAST (far right).
      ws_at = ws_label_pos(html)
      proj_at = label_pos(html, "Project")
      ds_at = label_pos(html, "Dataset")

      assert ws_at < proj_at,
             "Workspace must render before Project"

      assert proj_at < ds_at,
             "Project must render before Dataset (Dataset is the far-right control)"
    end

    test "mount comes up with workspace + project + dataset auto-selected (not empty)", %{
      conn: conn,
      acme_ws: acme_ws,
      acme_blog: acme_blog
    } do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      assigns = :sys.get_state(view.pid).socket.assigns

      # Workspace + project resolved by mount scope (slug-first member).
      assert assigns.current_workspace.slug == acme_ws.slug
      assert assigns.current_project.slug == acme_blog.slug
      # Dataset auto-set from the URL leaf — never empty.
      assert assigns.dataset == @dataset
      refute assigns.dataset in [nil, ""]
    end

    test "dataset options equal the CURRENT project's datasets, current selected", %{
      conn: conn,
      acme_production: acme_production,
      acme_staging: acme_staging,
      acme_reftest: acme_reftest
    } do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      ds_select = view |> element(~s(select[name="dataset"])) |> render()

      # Exactly the Acme/Blog project's datasets are offered.
      assert ds_select =~ acme_production.name
      assert ds_select =~ acme_staging.name
      assert ds_select =~ acme_reftest.name

      # The current dataset (production, the URL leaf) is the selected option.
      assert ds_select =~ ~r/<option value="production"[^>]*selected/
    end

    test "switch-project reloads dataset options + auto-selects the project's default", %{
      conn: conn,
      default_ws: default_ws
    } do
      # Give the Default workspace's project a controlled, DISTINCT dataset set
      # so the cascade target is unambiguous: a non-production default-eligible
      # set proves the production-first preference.
      {:ok, second_project} =
        Tenancy.create_project(default_ws, %{slug: "secondary", name: "Secondary"})

      {:ok, _} = Tenancy.create_dataset(second_project, %{slug: "production", name: "Prod2"})
      {:ok, _} = Tenancy.create_dataset(second_project, %{slug: "archive", name: "Archive2"})

      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      # Move into Default (a member workspace) — its first project may differ;
      # then switch explicitly to `secondary`, whose datasets we control.
      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => default_ws.slug})

      render_change(element(view, ~s(select[name="project"])), %{
        "project" => second_project.slug
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_project.slug == second_project.slug

      # Cascade auto-selected the project's default dataset (production-first).
      assert assigns.dataset == "production",
             "switch-project must auto-select the new project's default dataset (production-first)"

      # The Dataset select now lists the NEW project's datasets.
      ds_select = view |> element(~s(select[name="dataset"])) |> render()
      assert ds_select =~ "Prod2"
      assert ds_select =~ "Archive2"
    end

    test "switch-project to a single-dataset project auto-selects that one dataset", %{
      conn: conn,
      default_ws: default_ws
    } do
      {:ok, solo_project} = Tenancy.create_project(default_ws, %{slug: "solo", name: "Solo"})
      {:ok, _} = Tenancy.create_dataset(solo_project, %{slug: "only-ds", name: "Only"})

      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => default_ws.slug})
      render_change(element(view, ~s(select[name="project"])), %{"project" => solo_project.slug})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_project.slug == solo_project.slug
      # No production dataset here → falls back to the only/first dataset.
      assert assigns.dataset == "only-ds"
    end

    test "switch-dataset re-scopes the socket dataset to a project dataset", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      assert :sys.get_state(view.pid).socket.assigns.dataset == "production"

      render_change(element(view, ~s(select[name="dataset"])), %{"dataset" => "staging"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.dataset == "staging",
             "switch-dataset must re-scope the socket dataset (push_patch to /studio/:dataset)"
    end

    test "switch-dataset to a slug NOT in the current project is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      before = :sys.get_state(view.pid).socket.assigns.dataset

      render_change(element(view, ~s(select[name="dataset"])), %{
        "dataset" => "not-a-real-dataset"
      })

      assert :sys.get_state(view.pid).socket.assigns.dataset == before,
             "switch-dataset must refuse a slug that isn't one of the current project's datasets"
    end
  end

  # ── Task barkpark-ylrw: "+ New workspace" / "+ New project" affordances ─────
  #
  # The switcher exposes a "＋" button on the Workspace + Project controls that
  # toggles a tiny inline name form. Submitting reuses the atomic create-with-
  # bootstrap context (create_workspace_with_owner / create_project_with_dataset)
  # and auto-switches the whole scope to the new workspace/project + its
  # production dataset. A blank name flashes an error + creates nothing. An
  # anonymous session (no token, no dev fallback) never renders the affordance.
  describe "create affordances (barkpark-ylrw)" do
    test "create-workspace builds ws + owner membership + Default project + production dataset, switches to it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      # The "＋ New workspace" button is present (token-backed session).
      assert view
             |> element(~s(button[phx-click="toggle-create"][phx-value-target="workspace"]))
             |> has_element?()

      # Toggle the form open, then submit a name.
      render_click(
        element(view, ~s(button[phx-click="toggle-create"][phx-value-target="workspace"]))
      )

      assert view |> element(~s(form[phx-submit="create-workspace"])) |> has_element?()

      render_submit(element(view, ~s(form[phx-submit="create-workspace"])), %{
        "name" => "Brand New Co"
      })

      # The workspace exists with the full bootstrap (owner membership +
      # Default project + production dataset) — verified via Tenancy.
      ws = Tenancy.get_workspace_by_slug("brand-new-co")
      assert ws, "create-workspace must persist the workspace (slug derived from name)"

      # The mounted principal is the OWNER of the new workspace.
      token = :sys.get_state(view.pid).socket.assigns.api_token
      assert TenancyAuth.member?(token, ws.id)

      owner =
        Barkpark.Repo.get_by(Barkpark.Tenancy.Membership,
          workspace_id: ws.id,
          principal_id: token.id
        )

      assert owner && owner.role == "owner",
             "create-workspace must make the creator the OWNER"

      project = Tenancy.get_project(ws.slug, "default")
      assert project, "create-workspace must create a Default project (slug 'default')"
      assert Enum.any?(Tenancy.list_datasets(project), &(&1.slug == "production")),
             "create-workspace must create the production dataset"

      # The switcher now shows the new workspace as the current scope.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == "brand-new-co"
      assert assigns.current_project.id == project.id
      assert assigns.dataset == "production"
    end

    test "create-project in the current workspace creates project + dataset and switches to it",
         %{conn: conn, acme_ws: acme_ws} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      # Mount scope is the slug-first member workspace (acme). Open the Project
      # create form and submit.
      render_click(
        element(view, ~s(button[phx-click="toggle-create"][phx-value-target="project"]))
      )

      render_submit(element(view, ~s(form[phx-submit="create-project"])), %{
        "name" => "Fresh Project"
      })

      project = Tenancy.get_project(acme_ws.slug, "fresh-project")
      assert project, "create-project must persist the project under the current workspace"
      assert Enum.any?(Tenancy.list_datasets(project), &(&1.slug == "production")),
             "create-project must create the production dataset"

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == acme_ws.slug
      assert assigns.current_project.slug == "fresh-project"
      assert assigns.dataset == "production"
    end

    test "blank workspace name flashes an error and creates nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      before = Tenancy.list_workspaces_for(:sys.get_state(view.pid).socket.assigns.api_token)

      render_click(
        element(view, ~s(button[phx-click="toggle-create"][phx-value-target="workspace"]))
      )

      html =
        render_submit(element(view, ~s(form[phx-submit="create-workspace"])), %{"name" => ""})

      assert html =~ "Could not create workspace"

      after_ws = Tenancy.list_workspaces_for(:sys.get_state(view.pid).socket.assigns.api_token)
      assert length(after_ws) == length(before),
             "a blank name must create no workspace"

      # The form stays open so the user can fix + retry.
      assert :sys.get_state(view.pid).socket.assigns.create_open == "workspace"
    end

    test "an anonymous session (no token) does NOT render the create affordance" do
      # A FRESH conn with NO api_token in the session map (the setup conn carries
      # the test token, so build a clean one). In :test there is no dev
      # browser-token fallback, so api_token resolves to nil → can_create false.
      anon_conn = Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})
      {:ok, view, html} = live(anon_conn, "/studio/#{@dataset}")

      assert :sys.get_state(view.pid).socket.assigns.api_token == nil

      refute html =~ ~s(phx-click="toggle-create"),
             "anonymous (no-token) session must not expose the + New create affordance"

      refute view
             |> element(~s(button[phx-click="toggle-create"]))
             |> has_element?()
    end
  end

  # ── Task barkpark-yxz2: refuse switch INTO a project-less workspace ──────────
  #
  # The bug: `switch-workspace` assigned `current_project: nil` when the target
  # workspace had ZERO projects (List.first over an empty list), then proceeded.
  # A later scoped write (new-document / do_autosave) builds scope_opts with no
  # :project_id — ScopeHelpers drops the nil key and `resolve_write_scope` falls
  # back to the Default tenant, so the doc lands in Default's rows (a hard
  # boundary cross). The fix refuses the switch with a flash and keeps the prior
  # scope, so `current_project` is NEVER nil while a write can fire.
  describe "project-less workspace switch (barkpark-yxz2)" do
    setup %{conn: conn} do
      # A member workspace with ZERO projects — the switch target that used to
      # leave current_project nil.
      {:ok, empty_ws} = Tenancy.create_workspace(%{slug: "empty-co", name: "Empty Co"})
      {:ok, token} = Auth.verify_token(session_raw(conn))
      {:ok, _} = TenancyAuth.create_membership(empty_ws.id, token.id, "member")
      assert Tenancy.list_projects(empty_ws.id) == []
      {:ok, empty_ws: empty_ws}
    end

    test "switching to a project-less workspace is REFUSED — scope unchanged, current_project NOT nil, flash shown",
         %{conn: conn, empty_ws: empty_ws, acme_ws: acme_ws, acme_blog: acme_blog} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      before_ws = :sys.get_state(view.pid).socket.assigns.current_workspace.slug

      html =
        render_change(element(view, ~s(select[name="workspace"])), %{
          "workspace" => empty_ws.slug
        })

      assigns = :sys.get_state(view.pid).socket.assigns

      # The switch is refused: the prior (acme) scope is intact.
      assert assigns.current_workspace.slug == before_ws
      assert assigns.current_workspace.slug == acme_ws.slug

      # THE INVARIANT: current_project is never nil after a switch event. It must
      # still point at the prior workspace's project, not have been nulled.
      refute is_nil(assigns.current_project),
             "SCOPE INVARIANT BREACH: switch into a project-less workspace left current_project nil"

      assert assigns.current_project.slug == acme_blog.slug

      # A user-facing flash explains the refusal.
      assert html =~ "Workspace has no projects yet",
             "a refused project-less switch must surface a flash"
    end

    test "a write after a refused project-less switch does NOT leak into the Default tenant",
         %{conn: conn, empty_ws: empty_ws} do
      default_ws = Tenancy.get_default_workspace()
      default_project = Tenancy.get_default_project()

      before_count = doc_count(default_ws.id, default_project.id)

      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      # Attempt the bad switch (refused), then fire a real scoped write.
      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => empty_ws.slug})

      assigns = :sys.get_state(view.pid).socket.assigns
      # Scope stayed on the prior (acme) workspace — NOT the empty one, NOT Default.
      refute assigns.current_workspace.id == empty_ws.id
      refute assigns.current_workspace.id == default_ws.id
      refute is_nil(assigns.current_project)

      # New-document write under the (intact) prior scope. Dispatch the event
      # directly so the probe doesn't depend on which desk pane rendered the
      # button — `new-document` resolves the write scope via hook_opts/scope_opts.
      render_click(view, "new-document", %{"type" => "post"})

      after_count = doc_count(default_ws.id, default_project.id)
      assert after_count == before_count,
             "TENANT LEAK: a write after a refused project-less switch landed in the Default tenant"
    end

    test "switching to a workspace WITH projects selects its default project and write lands there, not Default",
         %{conn: conn, acme_ws: acme_ws, acme_blog: acme_blog} do
      default_ws = Tenancy.get_default_workspace()
      default_project = Tenancy.get_default_project()
      default_before = doc_count(default_ws.id, default_project.id)

      {:ok, view, _html} = live(conn, "/studio/#{@dataset}")

      # Move to Default first, then switch to acme so the handler runs for a
      # workspace with projects (initial_project must be non-nil + chosen).
      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => default_ws.slug})
      render_change(element(view, ~s(select[name="workspace"])), %{"workspace" => acme_ws.slug})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_workspace.slug == acme_ws.slug
      # initial_project resolved a real project for the target workspace.
      refute is_nil(assigns.current_project)
      assert assigns.current_project.slug == acme_blog.slug

      acme_before = doc_count(acme_ws.id, acme_blog.id)

      render_click(view, "new-document", %{"type" => "post"})

      # The write landed in the acme/blog project, not Default.
      assert doc_count(acme_ws.id, acme_blog.id) == acme_before + 1,
             "a write after a legit switch must land in the target project"

      assert doc_count(default_ws.id, default_project.id) == default_before,
             "a write after a legit switch must NOT touch the Default tenant"
    end
  end

  # Count documents stamped with the given workspace + project ids — the
  # authoritative "where did the doc land" probe (the bug crossed this boundary).
  defp doc_count(ws_id, project_id) do
    import Ecto.Query

    Barkpark.Repo.aggregate(
      from(d in Barkpark.Content.Document,
        where: d.workspace_id == ^ws_id and d.project_id == ^project_id
      ),
      :count
    )
  end

  # The raw token the setup conn carries (to mint additional memberships).
  defp session_raw(conn), do: Plug.Conn.get_session(conn, "api_token")

  # First index of the Workspace label — tolerates either the <select> chrome
  # or the single-option static-label rendering.
  defp ws_label_pos(html), do: label_pos(html, "Workspace")

  defp label_pos(html, label) do
    case :binary.match(html, ">#{label}<") do
      {pos, _} -> pos
      :nomatch -> raise "label #{inspect(label)} not found in switcher markup"
    end
  end
end
