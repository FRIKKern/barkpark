defmodule BarkparkWeb.Live.ScopedReaderMemberRecheckTest do
  @moduledoc """
  LiveView authz sweep (r4a): the scoped paper reader re-checked share links on
  every socket mount but never re-checked MEMBERSHIP.

  `/w/:ws/p/:proj/papers/:slug` admits a reader at dead render through the
  router pipeline (`ResolveWorkspace`: member, anonymous Default, or access
  grant). The LiveView socket mounts again on `live_redirect`, reconnect, or a
  join replaying the signed session (accepted for about 14 days), and none of
  those run the pipeline. So a member REMOVED from a workspace kept opening its
  papers over the socket.

  The fix re-runs the same admission (member | anonymous Default | grant) on
  every scoped reader mount; share-granted sessions keep their own re-check.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Content, Repo}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup %{conn: conn} do
    Barkpark.SharingFixtures.snapshot_shares!()
    Barkpark.SharingFixtures.clear_shares!()

    ws = create_workspace!("rdr-recheck-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    seed_paper!(ws, proj, "first", "FIRST PAPER")
    seed_paper!(ws, proj, "second", "SECOND-PAPER-BODY")

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp seed_paper!(ws, proj, slug, body) do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => slug,
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => body}]
            }
          ],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )
  end

  defp user_conn(conn) do
    email = "rdr-recheck-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp reader_path(ws, slug), do: "/w/#{ws.slug}/p/default/papers/#{slug}"

  test "a member removed from the workspace cannot keep reading over the socket", ctx do
    {user, conn} = user_conn(ctx.conn)
    {:ok, membership} = TenancyAuth.create_membership(ctx.ws.id, user.id, "member", "user")

    {:ok, view, html} = live(conn, reader_path(ctx.ws, "first"))
    assert html =~ "FIRST PAPER"

    Repo.delete!(membership)

    case live_redirect(view, to: reader_path(ctx.ws, "second")) do
      {:ok, _view, html} ->
        refute html =~ "SECOND-PAPER-BODY", "a removed member kept reading over the socket"

      {:error, {:redirect, %{to: to}}} ->
        assert to =~ "/login"
    end
  end

  test "a current member still navigates between papers (control)", ctx do
    {user, conn} = user_conn(ctx.conn)
    {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, user.id, "member", "user")

    {:ok, view, _} = live(conn, reader_path(ctx.ws, "first"))
    assert {:ok, _view, html} = live_redirect(view, to: reader_path(ctx.ws, "second"))
    assert html =~ "SECOND-PAPER-BODY"
  end

  test "a non-member with an active read grant still navigates (control)", ctx do
    {user, conn} = user_conn(ctx.conn)
    bind_grant!(ctx.ws, user, %{capabilities: ["read"]})

    {:ok, view, _} = live(conn, reader_path(ctx.ws, "first"))
    assert {:ok, _view, html} = live_redirect(view, to: reader_path(ctx.ws, "second"))
    assert html =~ "SECOND-PAPER-BODY"
  end
end
