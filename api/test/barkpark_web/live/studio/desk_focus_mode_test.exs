defmodule BarkparkWeb.Studio.DeskFocusModeTest do
  @moduledoc """
  J26, Sanity's focus mode (focus-mode.spec.ts): the document pane's header
  button hides every other pane and the URL stays; the title line becomes a
  breadcrumb of the panes it hides; the same button brings them back; a
  crumb opens its pane. The page keeps it, as the TanStack Studio's pane
  area does (not the URL, not a pref): any navigation ends it. The panes it
  hides stay in the page; `bp-desk.js` lays out the focused one alone.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @enter ~s|[data-pane-editing] > .pane-header button[aria-label="Enter focus mode (hide navigation)"]|
  @exit ~s|[data-pane-editing] > .pane-header button[aria-label="Exit focus mode (show navigation)"]|
  # In the title's own element: a header row that changes shape moves the
  # button, and the browser takes the focus off a moved button.
  @crumbs ~s([data-pane-editing] > .pane-header > .pane-header-title > nav[aria-label="Breadcrumb"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "focus_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Focus note",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "focus-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Focused"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-focus-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-focus", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: base, type: type, id: id}
  end

  defp open(c, path) do
    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  test "the button hides the other panes and the title line is a breadcrumb", c do
    view = open(c, "#{c.base}/#{c.type};#{c.id}")
    refute has_element?(view, "#desk-panes[data-focus-mode]")
    refute has_element?(view, @crumbs)
    [button] = view |> render() |> ids_of("Enter focus mode (hide navigation)")

    view |> element(@enter) |> render_click()

    # The panes stay in the page; the page marks the one shown alone.
    assert has_element?(view, ~s(#desk-panes[data-focus-mode]))
    assert has_element?(view, ~s(#desk-panes > [data-pane-index="2"][data-desk-focused]))
    assert has_element?(view, ~s|#desk-panes > [data-pane-index="1"]:not([data-desk-focused])|)

    # The same button, by its id, so the browser keeps the focus on it.
    assert view |> render() |> ids_of("Exit focus mode (show navigation)") == [button]
    assert has_element?(view, @exit <> ~s([aria-pressed="true"]))

    assert has_element?(view, @crumbs <> " button.dk-crumb", "Focus note")
    assert has_element?(view, @crumbs <> ~s( [aria-current="page"]), "Focused")
    # The root is a crumb too: the way back to it.
    assert view |> element(@crumbs) |> render() |> then(&Regex.scan(~r/<button/, &1)) |> length() ==
             2
  end

  test "the button again brings the panes back, and nothing navigated", c do
    path = "#{c.base}/#{c.type};#{c.id}"
    view = open(c, path)
    view |> element(@enter) |> render_click()
    view |> element(@exit) |> render_click()

    refute has_element?(view, "#desk-panes[data-focus-mode]")
    refute has_element?(view, "[data-desk-focused]")
    refute has_element?(view, @crumbs)
    assert has_element?(view, @enter <> ~s([aria-pressed="false"]))
    # No patch went out.
    assert_raise ArgumentError, ~r/to patch, but got none/, fn -> assert_patch(view, 100) end
  end

  # Measured in Chrome: a title element that changed tag between the modes
  # (h2, then a div for the nav) made the patch re-insert the button after
  # it, and Enter on the button left the focus on <body> every time.
  test "the title is one element, the same tag, in both modes", c do
    view = open(c, "#{c.base}/#{c.type};#{c.id}")

    title =
      ~s([data-pane-editing] > .pane-header > div.pane-header-title[role="heading"][aria-level="2"])

    assert has_element?(view, title, "Focused")
    view |> element(@enter) |> render_click()
    assert has_element?(view, title <> ~s( > nav[aria-label="Breadcrumb"]))
    view |> element(@exit) |> render_click()
    assert has_element?(view, title, "Focused")
    refute has_element?(view, "[data-pane-editing] > .pane-header > h2")
  end

  test "a crumb opens its pane and ends focus mode", c do
    view = open(c, "#{c.base}/#{c.type};#{c.id}")
    view |> element(@enter) |> render_click()

    view |> element(@crumbs <> " button.dk-crumb", "Focus note") |> render_click()
    assert_patched(view, "#{c.base}/#{c.type}")
    refute has_element?(view, "#desk-panes[data-focus-mode]")
  end

  test "any navigation ends it: back to the same document, the panes show", c do
    path = "#{c.base}/#{c.type};#{c.id}"
    view = open(c, path)
    view |> element(@enter) |> render_click()

    render_patch(view, "#{c.base}/#{c.type}")
    render_patch(view, path)
    assert eventually(fn -> has_element?(view, @enter) end)
    refute has_element?(view, "#desk-panes[data-focus-mode]")
  end

  test "only a document pane is focused: another pane's index is refused", c do
    view = open(c, "#{c.base}/#{c.type};#{c.id}")
    render_click(view, "desk-focus", %{"index" => "1"})
    refute has_element?(view, "#desk-panes[data-focus-mode]")
  end

  defp ids_of(html, label) do
    ~r/<button[^>]*>/
    |> Regex.scan(html)
    |> Enum.map(&hd/1)
    |> Enum.filter(&(&1 =~ ~s(aria-label="#{label}")))
    |> Enum.map(&(Regex.run(~r/\sid="([^"]+)"/, &1) |> List.last()))
  end
end
