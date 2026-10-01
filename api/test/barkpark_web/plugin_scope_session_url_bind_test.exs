defmodule BarkparkWeb.PluginScopeSessionUrlBindTest do
  @moduledoc """
  LiveView authz sweep (r4a): `PluginScopeSession :scope` took the tenant
  scope from the SIGNED SESSION and never compared it with the URL.

  The session map is written once, at dead render, by `build/1` from the
  conn's resolved workspace/project. A LiveView socket can then mount (on
  `live_redirect`, or a join replaying an old `data-phx-session`) ANY URL in
  the same live_session, and the session scope comes along unchanged. The
  gates that look at the URL (`LiveAuth :scoped_admin`, the router pipeline on
  a fresh dead render) and the data the LiveView reads (session scope) could
  therefore name two different workspaces.

  Proof below on the scoped paper reader: a reader of workspace A loses that
  membership, then navigates the open socket to a paper URL in workspace B
  (where they are still a member) whose slug also exists in A. The reader
  served A's paper under B's URL. The fix makes a mount whose URL slugs differ
  from the session's re-run the HTTP pipeline (a full navigation to the same
  URL) instead of serving the stale session scope.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Content, Repo}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @slug "shared-slug"

  setup %{conn: conn} do
    suffix = System.unique_integer([:positive])
    ws_a = create_workspace!("psurl-a-#{suffix}")
    proj_a = create_project!(ws_a, "default")
    ws_b = create_workspace!("psurl-b-#{suffix}")
    proj_b = create_project!(ws_b, "default")

    seed_paper!(ws_a, proj_a, "a-start", "A START PAPER")
    seed_paper!(ws_a, proj_a, @slug, "A-SECRET-PAPER")
    seed_paper!(ws_b, proj_b, @slug, "B-OWN-PAPER")

    email = "psurl-#{suffix}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, mem_a} = TenancyAuth.create_membership(ws_a.id, user.id, "member", "user")
    {:ok, _} = TenancyAuth.create_membership(ws_b.id, user.id, "member", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"user_session" => raw}),
     ws_a: ws_a,
     ws_b: ws_b,
     mem_a: mem_a}
  end

  defp seed_paper!(ws, proj, slug, title) do
    attrs = %{
      "slug" => slug,
      "title" => title,
      "workspace_id" => ws.id,
      "project_id" => proj.id,
      "blocks" => [
        %{"id" => "heading", "type" => "heading", "level" => 1, "text" => title},
        %{
          "id" => "body",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => title}]
        }
      ]
    }

    {:ok, _} = Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(attrs))
  end

  test "a socket whose session names workspace A cannot serve A under a workspace-B URL", ctx do
    {:ok, view, html} = live(ctx.conn, "/w/#{ctx.ws_a.slug}/p/default/papers/a-start")
    assert html =~ "A START PAPER"

    # Membership in A is revoked while the socket (and its signed session) lives on.
    Repo.delete!(ctx.mem_a)

    result = live_redirect(view, to: "/w/#{ctx.ws_b.slug}/p/default/papers/#{@slug}")

    html =
      case result do
        {:ok, _view, html} -> html
        {:error, {kind, _}} when kind in [:redirect, :live_redirect] -> ""
      end

    refute html =~ "A-SECRET-PAPER",
           "the reader served workspace A's paper under a workspace-B URL after A access was revoked"

    # Not a coincidental miss: the socket hands the URL back to HTTP, where the
    # router pipeline builds a session for workspace B.
    target = "/w/#{ctx.ws_b.slug}/p/default/papers/#{@slug}"
    assert {:error, {:redirect, %{to: ^target}}} = result
  end

  test "navigating within the session's own workspace still works (control)", ctx do
    {:ok, view, _} = live(ctx.conn, "/w/#{ctx.ws_a.slug}/p/default/papers/a-start")
    {:ok, _view, html} = live_redirect(view, to: "/w/#{ctx.ws_a.slug}/p/default/papers/#{@slug}")
    assert html =~ "A-SECRET-PAPER"
  end
end
