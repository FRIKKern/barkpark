defmodule BarkparkWeb.Studio.MediaLibraryNarrowLayoutTest do
  @moduledoc """
  task-c196ca78349ea153: at phone width the media library kept its desktop
  row (200px library rail | grid | 300px inspector) and crushed the grid to a
  sliver; the library's collection buttons had no CSS at all (the browser's
  grey outset button), and so did "Publish this scope's media".

  The explorer reflows by a container query on its HOST — `<bp-asset-explorer>`
  is itself `.bp-ae-root`, and a container query cannot restyle its own
  container — so the host must carry `.bp-ae-host`, and the stylesheet must
  hold the query and the collection rule. The layout check reads the shipped
  stylesheet; the rendered layout is checked in the browser.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Tenancy}

  @root Path.expand("../../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  setup %{conn: conn} do
    ws = create_workspace!("media-narrow-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, "production")

    email = "media-narrow-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "admin", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_session" => raw}), ws: ws}
  end

  test "the explorer's host is the container and the publish button is a styled button", ctx do
    {:ok, _view, html} = live(ctx.conn, "/w/#{ctx.ws.slug}/p/default/d/production/studio/media")
    doc = LazyHTML.from_fragment(html)

    host = LazyHTML.query(doc, "#media-explorer-host")
    assert LazyHTML.attribute(host, "class") == ["bp-ae-host"]
    assert Enum.count(LazyHTML.query(host, "bp-asset-explorer")) == 1

    publish = LazyHTML.query(doc, ~s(button[phx-click="publish_scope_media"]))
    assert Enum.count(publish) == 1
    assert [class] = LazyHTML.attribute(publish, "class")
    assert "btn" in String.split(class)
  end

  test "the stylesheet styles collection buttons and stacks the explorer below 640px" do
    css = File.read!(@root)

    assert css =~ ".bp-ae-host { container: bp-ae / inline-size; }"
    assert css =~ ~r/\.bp-ae-filter,\s*\.bp-ae-collection \{/
    assert css =~ ~r/\.bp-ae-filter\.is-active,\s*\.bp-ae-collection\.is-active \{/

    [_, query] = Regex.run(~r/@container bp-ae \(width <= 640px\) \{(.*?)\n    \}/s, css)
    assert query =~ ".bp-ae-root { flex-direction: column;"
    assert query =~ ~r/\.bp-ae-sidebar \{[^}]*width: auto/
    assert query =~ ~r/\.bp-ae-inspector \{[^}]*width: auto/
  end
end
