defmodule BarkparkWeb.Live.ScopeDatasetSwitchReauthTest do
  @moduledoc """
  arpss-lv-dataset-switch-reauth — the share_read cross-dataset reauth seam.

  OPEN QUESTION this suite RESOLVES: `LiveScope.same_scope?` (the inline
  predicate in `reauthorize/3`, live_scope.ex) compared ONLY `workspace_slug`
  + `project_slug`, NOT the dataset. `switch-dataset` sits in `@readonly_events`,
  so the read-only gate PASSES it, and `switch_dataset/2` push_patches the socket
  to `/w/<ws>/p/<proj>/d/<sibling>/studio`. The `handle_params` reauth hook then
  no-ops (same ws+proj) while `finish_handle_params` assigns `dataset: <sibling>`
  and `rebuild_panes/1` lists documents scoped to the NEW dataset. Shares are
  dataset-SPECIFIC (`Sharing.shared?/4` matches `s.dataset == dataset` exactly),
  so a `:share_read` socket granted ONE dataset could flip to an unshared sibling
  in the same project with no re-authorization.

  VERDICT — LEAKS (Branch A). Empirically established while building this slice:
  against the unpatched `same_scope?` an anonymous `:share_read` socket mounted
  on the shared `production` dataset pushed `switch-dataset` to the unshared
  sibling `staging` (the socket's `dataset` assign flipped, no redirect), drilled
  into the `post` type, and the staging-only document `#{"STAGING-SECRET"}`
  RENDERED — a cross-dataset read the share never authorized. The positive
  control below (drilling the SHARED dataset surfaces its own doc) proved that
  read path is live, so the leak was a real read and not a rendering artifact.
  With the fix, that same `switch-dataset` now redirects to /login before any
  read — which is what the committed guard here asserts.

  THE FIX (live_scope.ex): `same_scope?` now also compares the dataset, so a
  dataset flip on an established socket re-runs `resolve_and_authorize/2`, which
  re-derives the grade against the NEW dataset. The unshared sibling is not
  `:docs`-shared, so `authorize_read/4` falls through to `deny/1` → full-page
  redirect to `/login`, fail-closed. Mutation proof: reverting the `same_scope?`
  change REDs the "does not leak after the fix" test (the staging doc renders
  again). Perf: the extra comparison is a map lookup, not a query — the hot path
  (member pane navigation within one dataset) still short-circuits with zero
  extra DB work; re-authorization fires ONLY when the dataset slug actually
  changes.

  Cross-ws/proj fail-closed is unchanged and re-asserted here as a regression
  guard.

  `async: false` — the `:shares` registry is process-global application env.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Sharing, Tenancy}

  @shared_dataset "production"
  @unshared_dataset "staging"
  @secret_title "STAGING-SECRET"
  @shared_title "PROD-DOC"

  setup %{conn: conn} do
    # arpss-w8: snapshots :shares AND :shares_env (refresh/0 reads both).
    Barkpark.SharingFixtures.snapshot_shares!()
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    # A NON-default workspace: the Default workspace is an open public-demo in
    # test, and that arm answers BEFORE the share arm — a share on Default would
    # never grade `:share_read`.
    ws = create_workspace!("ds-switch-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "ds-proj")

    # BOTH datasets must exist as rows: `switch_dataset/2` only push_patches when
    # `project_has_dataset?/2` is true (reads `Tenancy.list_datasets/1`).
    {:ok, _} = Tenancy.get_or_create_dataset(proj, @shared_dataset)
    {:ok, _} = Tenancy.get_or_create_dataset(proj, @unshared_dataset)

    # Schemas are TENANT + DATASET scoped, so the `post` type needs a row in each
    # dataset or the desk has no type to drill into and the read would be vacuous.
    seed_post_schema!(ws, proj, @shared_dataset)
    seed_post_schema!(ws, proj, @unshared_dataset)

    # The secret lives ONLY in the unshared sibling; a decoy lives in the shared
    # one (proves the share is real and the positive control has something to
    # surface).
    {:ok, _} =
      Content.create_document("post", %{"title" => @secret_title}, @unshared_dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, _} =
      Content.create_document("post", %{"title" => @shared_title}, @shared_dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    # ONLY `production` is `:docs`-shared read-only. `staging` is not shared.
    Barkpark.SharingFixtures.plant_shares!(
      "#{ws.slug}/#{proj.slug}/#{@shared_dataset}:docs:read"
    )

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp seed_post_schema!(ws, proj, dataset) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Posts",
          "icon" => "📝",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket

  # Mount an ANONYMOUS socket (no user session) on the shared dataset's studio
  # root — the share arm grades it `:share_read`.
  defp mount_share_read!(conn, ws, proj) do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@shared_dataset}/studio")

    view
  end

  # Drill the desk into the `post` type from the root pane and return the
  # rendered HTML. `select` with pane 0 builds nav_path `["post"]` and
  # push_patches to the type list for the socket's CURRENT dataset.
  defp drill_post_and_render(view) do
    render_click(view, "select", %{"pane" => "0", "id" => "post"})
    render(view)
  end

  describe "the share_read grade on the shared dataset" do
    test "mounts as :share_read read-only, and drilling the shared dataset surfaces its own doc",
         %{conn: conn, ws: ws, proj: proj} do
      view = mount_share_read!(conn, ws, proj)
      assigns = socket_of(view).assigns

      assert assigns[:share_access] == :read
      assert assigns[:readonly_gate?] == true
      assert assigns[:current_user] == nil
      assert assigns[:dataset] == @shared_dataset

      # POSITIVE CONTROL — the read path DOES surface docs of the current
      # (shared) dataset, so an "absent" assertion elsewhere is meaningful.
      assert drill_post_and_render(view) =~ @shared_title
    end
  end

  describe "switch-dataset to an UNSHARED sibling" do
    # THE FIX PROOF + MUTATION GUARD. `switch-dataset` is in @readonly_events so
    # the read-only gate PASSES it and `switch_dataset/2` push_patches to the
    # sibling URL. With the dataset now part of `same_scope?`, that push_patch
    # re-authorizes against `staging` — which is NOT `:docs`-shared → `deny/1` →
    # full-page redirect to /login. The socket is EJECTED before it can read the
    # unshared dataset, so the staging-only secret is unreachable through it.
    #
    # PRE-FIX (empirically established while building this slice — see moduledoc):
    # the flip succeeded, `dataset` became `staging`, and drilling the `post`
    # type RENDERED `#{@secret_title}` — a cross-dataset read the share never
    # authorized. Reverting the `same_scope?` dataset comparison RESTORES that:
    # the switch no longer redirects and this `assert_redirect` REDs.
    test "is denied fail-closed — the socket redirects to /login before any read",
         %{conn: conn, ws: ws, proj: proj} do
      view = mount_share_read!(conn, ws, proj)

      render_click(view, "switch-dataset", %{"dataset" => @unshared_dataset})

      assert_redirect(view, "/login")
    end
  end

  describe "cross-workspace scope change still fails closed (no hot-path regression)" do
    test "patching an established socket toward a foreign workspace re-authorizes → /login",
         %{conn: conn, ws: ws, proj: proj} do
      # A DIFFERENT, unshared, non-member workspace. The ws/proj arm of
      # `same_scope?` (unchanged by the dataset fix) still forces
      # re-authorization on the patch, and the foreign scope has no share, no
      # membership for an anonymous socket → deny → redirect to /login.
      other_ws = create_workspace!("ds-foreign-#{System.unique_integer([:positive])}")
      other_proj = create_project!(other_ws, "ds-foreign-proj")
      {:ok, _} = Tenancy.get_or_create_dataset(other_proj, @shared_dataset)

      view = mount_share_read!(conn, ws, proj)

      assert {:error, {:redirect, %{to: to}}} =
               render_patch(
                 view,
                 "/w/#{other_ws.slug}/p/#{other_proj.slug}/d/#{@shared_dataset}/studio"
               )

      assert to =~ "/login"
    end
  end
end
