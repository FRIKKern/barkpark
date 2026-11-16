defmodule BarkparkWeb.Studio.AuditLiveTest do
  @moduledoc """
  The Studio Activity page: an admin sees this workspace's audit rows and
  nothing of another workspace, another project or the instance; filters and
  "Load more" stay in that scope; metadata never reaches the page; a member is
  refused and a demoted admin loses the page on the next click.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Audit, Repo, Tenancy}
  alias Barkpark.Accounts.User

  @dataset "production"

  setup do
    {ws, proj} = workspace!("activity-a")
    {other, other_proj} = workspace!("activity-b")
    {:ok, ws: ws, proj: proj, other: other, other_proj: other_proj}
  end

  test "an admin sees this workspace's rows and never another's or the instance's", ctx do
    conn = sign_in(ctx.conn, ctx.ws, "admin")
    me = conn.assigns.user
    Repo.update_all(from(u in User, where: u.id == ^me.id), set: [display_name: "Ada Admin"])

    event!(ctx.ws.id, ctx.proj.id, "doc-mine", actor_id: me.id)
    event!(ctx.ws.id, nil, "doc-wide")
    event!(ctx.ws.id, create_project!(ctx.ws, "sibling").id, "doc-sibling")
    event!(ctx.other.id, ctx.other_proj.id, "doc-theirs")
    event!(nil, nil, "doc-global")

    event!(ctx.ws.id, ctx.proj.id, "doc-meta",
      metadata: %{"type" => "post", "label" => "app:other@example.com", "token_hash" => "HASHVAL"}
    )

    {:ok, _view, html} = live(conn, path(ctx.ws))

    assert html =~ "doc-mine"
    assert html =~ "doc-wide"
    assert html =~ "doc-meta"
    assert html =~ "Ada Admin"
    refute html =~ "doc-sibling"
    refute html =~ "doc-theirs"
    refute html =~ "doc-global"
    refute html =~ "other@example.com"
    refute html =~ "HASHVAL"
  end

  test "a member who is not an admin is refused", ctx do
    assert {:error, {:redirect, %{to: "/studio", flash: flash}}} =
             live(sign_in(ctx.conn, ctx.ws, "member"), path(ctx.ws))

    assert flash["error"] == "Admin access required"
  end

  test "filters and Load more stay in this workspace", ctx do
    actor = Ecto.UUID.generate()
    for n <- 1..51, do: event!(ctx.ws.id, nil, "row-#{n}", actor_id: actor)
    event!(ctx.ws.id, nil, "tok-1", category: "token", action: "token_minted")
    event!(ctx.other.id, nil, "theirs-1", actor_id: actor)

    {:ok, view, _html} = live(sign_in(ctx.conn, ctx.ws, "admin"), path(ctx.ws))

    view |> form("#audit-filter", filter: %{category: "token"}) |> render_submit()
    assert_patch(view, path(ctx.ws) <> "?category=token")
    html = render(view)
    assert html =~ "tok-1"
    refute html =~ "row-51"

    # Clicking an actor filters by it; the other workspace's row by the same
    # actor id never shows.
    view |> element("button", "Clear filters") |> render_click()
    render_click(view, "actor", %{"id" => actor})
    assert_patch(view, path(ctx.ws) <> "?actor=#{actor}")
    assert view |> element("[data-test-id=audit-row]", "row-51") |> has_element?()
    refute render(view) =~ "row-1<"
    refute render(view) =~ "theirs-1"

    html = view |> element("button", "Load more") |> render_click()
    assert html =~ "row-1<"
    refute html =~ "theirs-1"
    refute html =~ "Load more"
    assert length(Regex.scan(~r/data-test-id="audit-row"/, html)) == 51
  end

  test "a bad date in the URL shows a message, not rows", ctx do
    event!(ctx.ws.id, nil, "row-x")
    {:ok, _view, html} = live(sign_in(ctx.conn, ctx.ws, "admin"), path(ctx.ws) <> "?since=nope")
    assert html =~ "Enter dates as year-month-day"
    refute html =~ "row-x"
  end

  test "an admin demoted after opening the page is sent away on the next click", ctx do
    event!(ctx.ws.id, nil, "row-demoted")
    conn = sign_in(ctx.conn, ctx.ws, "admin")
    {:ok, view, _html} = live(conn, path(ctx.ws))

    {:ok, _} =
      Tenancy.Members.update_role(ctx.ws.id, %{type: :user, id: conn.assigns.user.id}, "member")

    assert {:error, {:redirect, %{to: "/studio"}}} =
             view |> form("#audit-filter", filter: %{category: "token"}) |> render_submit()
  end

  defp path(ws), do: "/w/#{ws.slug}/p/default/d/#{@dataset}/studio/_activity"

  defp workspace!(name) do
    ws = create_workspace!("#{name}-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, @dataset)
    {ws, proj}
  end

  defp event!(ws_id, proj_id, subject, opts \\ []) do
    {:ok, _} =
      Audit.emit(%{
        category: Keyword.get(opts, :category, "content_mutation"),
        action: Keyword.get(opts, :action, "document.update"),
        subject: subject,
        actor_type: "user",
        actor_id: Keyword.get(opts, :actor_id, Ecto.UUID.generate()),
        workspace_id: ws_id,
        project_id: proj_id,
        metadata: Keyword.get(opts, :metadata, %{"type" => "post", "dataset" => @dataset})
      })
  end

  defp sign_in(conn, ws, role) do
    email = "activity-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)

    conn |> Plug.Test.init_test_session(%{"user_session" => raw}) |> Plug.Conn.assign(:user, user)
  end
end
