defmodule BarkparkWeb.Studio.DeskDocStatusTest do
  @moduledoc """
  LOOKS PR 2, the edit pane's top as the TanStack Studio draws it:
  Published / Draft pills at the left of the header (`DocStatus`), the old
  Studio's toolbar row hidden, and every action that row drew with no desk
  place of its own in the "…" menu (`DocMenu`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @chips ~s([data-pane-editing] > .pane-header > .dk-chips[data-desk-status])
  @menu ~s([data-pane-editing] .pane-header [role="menu"][popover][id$="-editor-actions"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "st_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Status #{type}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}],
          "actions" => [
            %{
              "name" => "st_export",
              "label" => "Export it",
              "kind" => "link",
              "opts" => %{"href" => "/export/:dataset/:id"}
            }
          ]
        },
        @dataset
      )

    id = "st-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Here"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-status-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-status",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: base, type: type, id: id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};#{c.id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp items(view) do
    html = view |> element(@menu) |> render()
    for [_, label] <- Regex.scan(~r/role="menuitem"[^>]*>\s*([^<]+?)\s*</, html), do: label
  end

  defp chip(view, label), do: view |> element(~s(#{@chips} .dk-chip), label) |> render()

  test "the header's left holds the Published and Draft pills", c do
    {:ok, _} = Content.publish_document(c.id, c.type, @dataset)
    view = open(c)

    assert has_element?(view, @chips)
    published = chip(view, "Published")
    assert published =~ ~s(data-tone="positive")
    refute published =~ "data-off"
    draft = chip(view, "Draft")
    assert draft =~ "data-selected"
    refute draft =~ "data-active"
  end

  test "an edit not yet published fills the Draft pill", c do
    {:ok, _} = Content.publish_document(c.id, c.type, @dataset)
    view = open(c)

    view |> element("#editor-form") |> render_change(%{"doc" => %{"title" => "Typed"}})
    render_async(view, 5_000)

    assert eventually(fn -> chip(view, "Draft") =~ "data-active" end), chip(view, "Draft")
    refute chip(view, "Published") =~ "data-off"
  end

  # The rig's J46 (navbar.spec.ts, a touch phone): every doc-pane button is a 44 px
  # tap. The pills became buttons in #27369 and stayed 25 px; TanStack grows
  # a pill's box with a clear 10 px border above and below on a touch screen.
  test "on a touch screen the pill buttons are 44 px taps, drawn as before", c do
    {:ok, _} = Content.publish_document(c.id, c.type, @dataset)
    view = open(c)
    html = render(view)

    assert has_element?(view, ~s(#{@chips} button.dk-chip[aria-pressed]), "Published")
    assert has_element?(view, ~s(#{@chips} button.dk-chip[aria-pressed]), "Draft")

    coarse =
      ~r/@media \(max-width: 768px\) and \(pointer: coarse\) \{\s*([^}]*\})/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.find("", &(&1 =~ "dk-chip"))

    assert coarse =~ ".dk button.dk-chip, .dk button.dk-chip:hover {"
    # 25 px (3 + 19 + 3) and 10 px above and below: 45.
    assert coarse =~ "border-style: solid; border-color: transparent; border-width: 10px 0;"
    assert coarse =~ "background-clip: padding-box;"
  end

  test "a document never published greys out the Published pill", c do
    view = open(c)

    assert chip(view, "Published") =~ "data-off"
    refute chip(view, "Published") =~ "data-tone"
  end

  test "the old toolbar's actions with no desk place are in the menu, in the Studio's order", c do
    {:ok, _} = Content.publish_document(c.id, c.type, @dataset)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => "Edited"},
        @dataset
      )

    view = open(c)

    labels = items(view)

    for label <- [
          "Publish",
          "History",
          "Diff",
          "Discard draft",
          "Duplicate",
          "Open another",
          "View blast radius",
          "Delete",
          "Export it"
        ],
        do: assert(label in labels, inspect(labels))

    assert Enum.find_index(labels, &(&1 == "View blast radius")) <
             Enum.find_index(labels, &(&1 == "Delete"))

    # A schema's link opens its address, with the document's id filled in.
    assert has_element?(
             view,
             ~s(#{@menu} a[role="menuitem"][data-desk-doc-action="st_export"][href="/export/#{@dataset}/#{c.id}"])
           )

    # An item sends the Studio's own event: Diff turns into Edit.
    view |> element(~s(#{@menu} [data-desk-doc-action="toggle-diff"])) |> render_click()
    assert eventually(fn -> "Edit" in items(view) end), inspect(items(view))
  end

  test "the sheet hides the Classic editor's toolbar row and keeps its heading for screen readers" do
    css = rendered_to_string(BarkparkWeb.Studio.Desk.Style.sheet(%{}))

    assert css =~
             ~s(.dk .dk-edit .editor-panel[role=main] > .editor-header { visibility: hidden; height: 0;)

    assert css =~
             ~s(.dk .dk-edit .editor-panel[role=main] > .editor-header h1 { visibility: visible; })

    assert css =~
             ".dk .dk-doc > .pane-header { flex: none; box-sizing: border-box; height: 51px; min-height: 51px;"
  end

  # Control: the old Studio keeps its toolbar and draws no pills.
  test "the old Studio has no pills", c do
    {:ok, _view, html} =
      live(c.conn, String.replace(c.base, "/_desk", "") <> "/#{c.type}/#{c.id}")

    assert html =~ ~s(class="pane-header editor-header")
    refute html =~ "dk-chips"
  end
end
