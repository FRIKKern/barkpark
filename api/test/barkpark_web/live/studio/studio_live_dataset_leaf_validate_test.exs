defmodule BarkparkWeb.Studio.StudioLiveDatasetLeafValidateTest do
  @moduledoc """
  Task barkpark-o7fu: defense-in-depth validation of the `/studio/:dataset` URL
  leaf in `handle_params`.

  Before the fix, `handle_params` took `params["dataset"]` VERBATIM into
  rebuild_panes/subscribe — unlike `switch-dataset`, which gates a slug via
  `project_has_dataset?/2`. A direct navigation to `/studio/<arbitrary-dataset>`
  applied NO membership/ownership check on the leaf. This is NOT a cross-tenant
  leak — content reads are already bounded by `scope_opts` (Content.Scope filters
  workspace_id/project_id), so a foreign slug yields the member's own (empty)
  data — but it let the URL claim a dataset the project doesn't own, leaving
  inconsistent state on the lone scope WHERE-clause.

  The fix: in `handle_params`, after `ensure_tenancy_scope`, when the dataset leaf
  is NOT one of the resolved project's datasets AND the project has a default to
  fall back to, push_patch to `default_dataset_for_project/1` instead of trusting
  the leaf. Mirrors how switch-dataset already validates.

  Covers:
    * navigating to a dataset NOT owned by the current project → redirected
      (push_patch) to the project's default dataset, NOT left on the bogus leaf;
    * navigating to a dataset the project DOES own stays there + renders;
    * the seeded Default project owns "production" — a valid nav there is NOT
      redirected (the project_has_dataset? semantics hold for the seeded slug).

  P3 (Scoped-by-URL cutover): the only Studio mount is the scoped live_session,
  and the URL names the resolved project — these tests mount
  `/w/acme/p/blog/studio/:leaf` directly (the token holds an acme membership),
  and the push_patch target carries the same scoped prefix.

  LiveViewTest + compile. Full live-browser verification is the orchestrator's gate.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  # The scoped-canonical form for the acme/blog project under test. NOT
  # ConnCase.scoped_studio/1 (that prefixes the Default workspace) — the whole
  # point here is which project the URL resolves, and it must be acme/blog.
  defp scoped(path) when is_binary(path), do: "/w/acme/p/blog" <> path

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()

    # A MEMBER workspace + project whose datasets we control. Since P3 the
    # scoped URL names the resolved scope — `/w/acme/p/blog/...` makes
    # acme/blog the `current_project` LiveScope hands to handle_params; the
    # token's acme membership authorizes the mount.
    {:ok, acme_ws} = Tenancy.create_workspace(%{slug: "acme", name: "Acme"})
    {:ok, acme_blog} = Tenancy.create_project(acme_ws, %{slug: "blog", name: "Blog"})

    # blog owns production (the default) + staging — but NOT "secret-ds".
    {:ok, _prod} = Tenancy.create_dataset(acme_blog, %{slug: "production", name: "Production"})
    {:ok, _staging} = Tenancy.create_dataset(acme_blog, %{slug: "staging", name: "Staging"})

    raw = "leaf-validate-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "leaf", @dataset, ["read", "write"], default_ws.id)
    {:ok, _} = TenancyAuth.create_membership(acme_ws.id, token.id, "member")

    # A schema so the desk renders after the (possibly redirected) nav.
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

    {:ok, conn: conn, acme_ws: acme_ws, acme_blog: acme_blog}
  end

  describe "handle_params dataset-leaf validation (barkpark-o7fu)" do
    test "a dataset NOT owned by the resolved project is redirected to the default", %{
      conn: conn,
      acme_blog: acme_blog
    } do
      # The URL-resolved scope is acme/blog. "secret-ds" is not one of blog's
      # datasets → handle_params must push_patch to blog's default
      # ("production"), NOT leave the socket on the bogus leaf. A push_patch
      # raised from the initial (disconnected) handle_params surfaces as a
      # {:live_redirect, …} that live/2 returns as {:error, …}; the redirect
      # TARGET is the assertion — it must point at the project's default
      # dataset (scoped form since P3), never the bogus leaf.
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, scoped("/studio/secret-ds"))

      assert to == scoped("/studio/production"),
             "handle_params must redirect an unowned dataset leaf to the project's default, " <>
               "got #{inspect(to)}"

      refute to =~ "/studio/secret-ds",
             "the bogus leaf must never become the navigation target"

      # Following the redirect lands on the validated dataset, scoped to blog.
      {:ok, view, _html} = live(conn, to)
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_project.slug == acme_blog.slug
      assert assigns.dataset == "production"
    end

    test "a dataset the project DOES own stays on that leaf and renders", %{conn: conn} do
      # "staging" is one of blog's datasets → no redirect, leaf is authoritative.
      {:ok, view, html} = live(conn, scoped("/studio/staging"))

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.dataset == "staging",
             "a valid project-owned dataset leaf must be honoured (no redirect), " <>
               "got #{inspect(assigns.dataset)}"

      # The view rendered against the valid scope — the chrome's scope title
      # trail shows "project / dataset" for the honoured leaf.
      assert html =~ ~r{scope-title-trail">\s*Blog / staging\s*<}
    end

    test "the project's default ('production') is NOT redirected (no loop, seeded slug owned)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, scoped("/studio/production"))

      assert :sys.get_state(view.pid).socket.assigns.dataset == "production",
             "navigating to the project's own default dataset must stay put"
    end
  end
end
