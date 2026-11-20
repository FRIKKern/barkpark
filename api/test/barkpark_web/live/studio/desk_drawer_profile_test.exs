defmodule BarkparkWeb.Studio.DeskDrawerProfileTest do
  @moduledoc """
  task-ec46e037f7a4c0c8 (filed in #27884): under 600 px the desk navbar's
  own presence pill gives way, as TanStack's phone bar draws no avatar of
  yours. The pill was the only way into the presence profile, the display
  name and colour other people see, so a phone had none.

  The drawer (`Desk.NavDrawer`), where TanStack keeps who you are on a
  phone, now offers "Your profile": it closes the drawer and opens the
  profile dialog the pill opens, and the dialog saves the name.

  The dialog was the hosted editor's, so neither the pill nor the drawer
  opened anything with no document open. The desk now draws it itself,
  once, with a document open or not.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @item ~s(#studio-bar dialog#dk-drawer button.drawer-item[phx-click="show-profile"][data-desk-drawer-pick])
  @dialog "#profile-modal-dialog"

  setup %{conn: conn} do
    type = "ddp_post_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Profile posts",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-drawer-profile-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "ddp-me", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     type: type}
  end

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> String.replace(~r/<[^>]+>/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

  test "the drawer offers Your profile, after the appearance and before Sign out", c do
    {:ok, view, _html} = live(c.conn, c.base)

    assert has_element?(view, @item)
    assert text(view, @item) == "Your profile"

    foot = view |> element("#studio-bar dialog#dk-drawer .drawer-foot") |> render()
    [_, after_light] = String.split(foot, ~s(data-desk-appearance="light"), parts: 2)
    assert after_light =~ ~s(phx-click="show-profile")

    case String.split(foot, "Sign out", parts: 2) do
      [before_signout, _] -> assert before_signout =~ ~s(phx-click="show-profile")
      [_] -> :ok
    end
  end

  test "Your profile opens the profile dialog, and its name saves", c do
    {:ok, view, _html} = live(c.conn, c.base)
    refute has_element?(view, @dialog)

    view |> element(@item) |> render_click()

    assert has_element?(view, ~s(#{@dialog}[role="dialog"][aria-modal="true"]))
    assert text(view, "#profile-modal-title") == "Your profile"

    view |> form("#{@dialog} form", %{"name" => "Phone Person"}) |> render_submit()

    refute has_element?(view, @dialog)
    assert :sys.get_state(view.pid).socket.assigns.user_name == "Phone Person"
  end

  test "with no document open the pill opens the profile; under 600 px the pill gives way", c do
    {:ok, view, html} = live(c.conn, c.base)

    assert has_element?(view, ~s(#studio-bar button.presence-me-group[phx-click="show-profile"]))
    assert html =~ ".navbar .presence-me-group { display: none; }"

    view |> element("#studio-bar button.presence-me-group") |> render_click()
    assert has_element?(view, @dialog)
  end

  test "with a document open, the drawer and the pill open one profile dialog", c do
    id = "ddp-#{System.unique_integer([:positive])}"
    {:ok, _} = Content.create_document(c.type, %{"doc_id" => id, "title" => "Post"}, @dataset)

    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};#{id}")
    render_async(view, 5_000)
    assert has_element?(view, "[data-pane-editing] #editor-form")

    view |> element(@item) |> render_click()
    html = render(view)
    assert length(Regex.scan(~r/id="profile-modal-dialog"/, html)) == 1

    view
    |> element(~s(#{@dialog} button[phx-click="close-profile"][aria-label="Close"]))
    |> render_click()

    refute has_element?(view, @dialog)

    view |> element("#studio-bar button.presence-me-group") |> render_click()
    assert length(Regex.scan(~r/id="profile-modal-dialog"/, render(view))) == 1
  end

  @history ",changesInspectorTab=history,inspect=sanity%2Fstructure%2Fhistory"

  test "over a shown revision the dialog is outside the revision's fieldset, and saves", c do
    id = "ddp-#{System.unique_integer([:positive])}"
    {:ok, _} = Content.create_document(c.type, %{"doc_id" => id, "title" => "Post"}, @dataset)
    {:ok, _} = Content.publish_document(id, c.type, @dataset)

    rev =
      id
      |> Content.list_revisions(c.type, @dataset, limit: 10)
      |> Enum.find(&(&1.action == "publish"))

    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};#{id}#{@history},rev=#{rev.id}")
    render_async(view, 5_000)
    assert has_element?(view, "[data-pane-editing] [data-desk-revision-form]")

    view |> element("#studio-bar button.presence-me-group") |> render_click()

    assert has_element?(view, @dialog)
    refute has_element?(view, "fieldset #{@dialog}")
    assert length(Regex.scan(~r/id="profile-modal-dialog"/, render(view))) == 1

    view |> form("#{@dialog} form", %{"name" => "Revision Reader"}) |> render_submit()
    assert :sys.get_state(view.pid).socket.assigns.user_name == "Revision Reader"
  end

  test "the old Studio's pill still opens its profile dialog", c do
    id = "ddp-#{System.unique_integer([:positive])}"
    {:ok, _} = Content.create_document(c.type, %{"doc_id" => id, "title" => "Post"}, @dataset)
    studio = String.replace_suffix(c.base, "/_desk", "")

    {:ok, view, _html} = live(c.conn, "#{studio}/#{c.type}/#{id}")
    refute has_element?(view, @dialog)

    view |> element("button.presence-me-group") |> render_click()
    assert length(Regex.scan(~r/id="profile-modal-dialog"/, render(view))) == 1

    view |> form("#{@dialog} form", %{"name" => "Old Studio"}) |> render_submit()
    assert :sys.get_state(view.pid).socket.assigns.user_name == "Old Studio"
  end
end
