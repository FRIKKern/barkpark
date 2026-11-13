defmodule BarkparkWeb.Studio.DeskInspectTest do
  @moduledoc """
  J28: Ctrl+Alt+I in the edit pane opens "Inspecting <title>", the open
  document as a tree ("Parsed") and as JSON ("Raw JSON"); Escape closes it.
  The key, the modal and the tabs are `bp-desk.js`'s; here: the page's side
  of it. `desk-inspect` opens and closes the dialog, it renders the document
  the editor holds, and any navigation puts it away.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @dialog ~s([data-pane-editing] dialog[data-desk-inspect][phx-update="ignore"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "inspect_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Inspect #{type}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "object",
              "fields" => [%{"name" => "tag", "type" => "string"}]
            }
          ]
        },
        @dataset
      )

    id = "inspect-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Looked at", "meta" => %{"tag" => "deep"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-inspect-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-inspect", @dataset, ~w(read write admin), ws_id)
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

  defp inspect_open(view), do: render_hook(view, "desk-inspect", %{"open" => true})

  test "the dialog is not in the page until it is asked for", c do
    view = open(c)
    refute has_element?(view, @dialog)
  end

  test "desk-inspect opens Inspecting <title>, Parsed first, with the document's JSON", c do
    view = open(c)
    inspect_open(view)

    assert has_element?(view, @dialog)
    assert has_element?(view, "#{@dialog} h2", "Inspecting Looked at")
    assert has_element?(view, ~s(#{@dialog} [role="tab"][aria-selected="true"]), "Parsed")
    assert has_element?(view, ~s(#{@dialog} [role="tab"][aria-selected="false"]), "Raw JSON")

    # focus:165: both views sit in the one scroller, `.inspect-body`.
    assert has_element?(
             view,
             ~s{#{@dialog} .inspect-body > [role="tabpanel"]:not([hidden])},
             "_id"
           )

    assert has_element?(view, ~s(#{@dialog} .inspect-body > [role="tabpanel"][hidden] pre))

    # Parsed: the system keys first, the id among them; a nested object a branch.
    parsed = view |> element(~s{#{@dialog} [role="tabpanel"]:not([hidden])}) |> render()
    assert parsed =~ c.id
    assert parsed =~ ~r/<summary><span class="dk-inspect-key">meta:<\/span>/

    # Raw JSON: the API's envelope, pretty. The editor holds the draft.
    raw = view |> element(~s(#{@dialog} [role="tabpanel"][hidden])) |> render()
    assert raw =~ ~r/<code>\{\n  &quot;_id&quot;: &quot;drafts\.#{c.id}&quot;,\n/
    assert raw =~ "&quot;_publishedId&quot;: &quot;#{c.id}&quot;"
    assert raw =~ "&quot;tag&quot;: &quot;deep&quot;"
  end

  # LOOKS C3 (audit screen 10): TanStack's Inspect. The title in italics;
  # Parsed opens with what the document holds ("{…} N properties"), every
  # object open, each key "key:" and each value typed for its syntax colour,
  # a string unquoted.
  test "Parsed is TanStack's JSON tree: italic title, counts, typed values, all open", c do
    view = open(c)
    inspect_open(view)

    assert view |> element("#{@dialog} h2") |> render() =~ "Inspecting <em>Looked at</em>"
    parsed = view |> element(~s{#{@dialog} [role="tabpanel"]:not([hidden])}) |> render()

    assert parsed =~
             ~r/<details open="">\s*<summary><span class="dk-inspect-count"[^>]*>\{…\} \d+ properties<\/span><\/summary>/

    assert parsed =~
             ~r/<details open="">\s*<summary><span class="dk-inspect-key">meta:<\/span>\s*<span class="dk-inspect-count"[^>]*>\{…\} 1 property<\/span>/

    assert parsed =~
             ~r/<span class="dk-inspect-key">tag:<\/span><span class="dk-inspect-value" data-type="string">deep<\/span>/

    assert parsed =~ ~r/<span class="dk-inspect-value" data-type="boolean">true<\/span>/
    refute parsed =~ "&quot;deep&quot;"
    refute parsed =~ ~r/<details>/
  end

  test "desk-inspect with open false closes it", c do
    view = open(c)
    inspect_open(view)
    assert has_element?(view, @dialog)

    render_hook(view, "desk-inspect", %{"open" => false})
    refute has_element?(view, @dialog)
  end

  test "a navigation puts it away", c do
    view = open(c)
    inspect_open(view)
    assert has_element?(view, @dialog)

    render_patch(view, "#{c.base}/#{c.type}")
    refute has_element?(view, @dialog)
  end

  # keyboard:158: in the URL, as Sanity's (`inspect=on`), so Back after
  # closing opens it again and a copied link opens it.
  test "opening puts inspect=on in the URL; closing takes it out; Back opens it again", c do
    view = open(c)
    inspect_open(view)
    assert_patch(view, "#{c.base}/#{c.type};#{c.id},inspect=on")
    assert has_element?(view, @dialog)
    refute render(view) =~ "Other views and inspectors are not shown here."

    render_hook(view, "desk-inspect", %{"open" => false})
    assert_patch(view, "#{c.base}/#{c.type};#{c.id}")
    refute has_element?(view, @dialog)

    # The browser's Back: the URL with it again.
    render_patch(view, "#{c.base}/#{c.type};#{c.id},inspect=on")
    assert has_element?(view, @dialog)
  end

  test "a link with inspect=on opens the document with it open", c do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};#{c.id},inspect=on")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)

    assert has_element?(view, "#{@dialog} h2", "Inspecting Looked at")
    refute render(view) =~ "Other views and inspectors are not shown here."
  end

  test "control: another inspector in the URL is still one the desk does not draw", c do
    {:ok, view, _html} =
      live(c.conn, "#{c.base}/#{c.type};#{c.id},inspect=sanity%2Fstructure%2Fhistory")

    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)

    refute has_element?(view, @dialog)
    assert render(view) =~ "Other views and inspectors are not shown here."
  end

  # TanStack's InspectDialog: a search box over Parsed (`bp-desk.js` filters).
  test "Parsed has TanStack's search box, and each count carries its words for one and many", c do
    view = open(c)
    inspect_open(view)
    parsed = ~s{#{@dialog} [role="tabpanel"]:not([hidden])}

    assert has_element?(
             view,
             ~s(#{parsed} > label.dk-inspect-search > input[data-desk-inspect-search][aria-label="Search"][placeholder="Search"])
           )

    assert has_element?(view, ~s(#{parsed} > label.dk-inspect-search > svg[data-desk-glyph]))

    html = view |> element(parsed) |> render()

    assert html =~
             ~r/class="dk-inspect-count" data-brace="\{…\}" data-one="1 property" data-other="\{n\} properties"/

    # The raw view has no search: TanStack's box is over the tree only.
    refute has_element?(view, ~s{#{@dialog} [role="tabpanel"][hidden] [data-desk-inspect-search]})
  end
end
