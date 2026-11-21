defmodule BarkparkWeb.Studio.DeskTagsFieldTest do
  @moduledoc """
  WP8 (task-40c3d1205c9870c2): in the desk an array of strings with
  `options.layout: "tags"` is the TanStack Studio's tags input
  (`ArrayInputs.tsx` `TagsInput`): chips with "Remove <tag>", one input
  carrying the field's path as its id, Enter adds, the last tag removed
  unsets the field. The rig drives the keys in Chrome
  (string-arrays.spec.ts, tags-fast.spec.ts); here the presses are sent as
  the page's script sends them, with the document's mark.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @form "[data-pane-editing] #editor-form"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "tagpost_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Tag posts #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            # The rig's `post.tags` (barkpark-studio fixtures/barkpark-schema/post.json).
            %{
              "name" => "tags",
              "title" => "Tags",
              "type" => "arrayOf",
              "ordered" => true,
              "options" => %{"layout" => "tags"},
              "validation" => %{"max" => 3, "level" => "warning"},
              "of" => %{"type" => "string"}
            },
            %{
              "name" => "highlights",
              "title" => "Highlights",
              "type" => "arrayOf",
              "ordered" => true,
              "of" => %{"type" => "string"}
            },
            # An array of objects, even with the tags layout, is not a tags field.
            %{
              "name" => "links",
              "title" => "Links",
              "type" => "arrayOf",
              "options" => %{"layout" => "tags"},
              "of" => %{
                "type" => "object",
                "fields" => [%{"name" => "label", "type" => "string"}]
              }
            },
            %{
              "name" => "seo",
              "title" => "SEO",
              "type" => "composite",
              "fields" => [
                %{"name" => "metaTitle", "type" => "string"},
                %{
                  "name" => "keywords",
                  "type" => "arrayOf",
                  "options" => %{"layout" => "tags"},
                  "of" => %{"type" => "string"}
                }
              ]
            }
          ]
        },
        @dataset
      )

    id = "tagpost-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "Tagged",
          "tags" => ["fixture", "t0"],
          "highlights" => ["One", "Two"],
          "links" => [%{"_key" => "l1", "label" => "One"}],
          "seo" => %{"metaTitle" => "Meta", "keywords" => ["k1"]}
        },
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-tags-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-tags", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     type: type,
     id: id,
     desk: "#{root}/_desk/#{type};#{id}",
     studio: "#{root}/#{type}/#{id}"}
  end

  defp desk(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  # What the store holds for the open document: its draft, else the published row.
  defp stored(c), do: stored_doc(c).content

  defp stored_doc(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc
  end

  defp chips(view) do
    html = view |> element(~s(#{@form} .field [data-field-name="tags"] .tags-box)) |> render()
    for [_, t] <- Regex.scan(~r/<span id="[^"]*" class="tag">([^<]*)<button/, html), do: t
  end

  # Enter in the input: the page's script puts the typed text on the field's
  # add button and presses it (bp-desk-tags.js).
  defp enter(view, text) do
    add = element(view, ~s(#{@form} [data-tags-add][phx-value-field="tags"]))
    render_click(add, Map.merge(EditorPost.mark(view), %{"value" => text}))
  end

  defp remove(view, tag) do
    EditorPost.press_on(view, element(view, ~s(#{@form} button[aria-label="Remove #{tag}"])))
  end

  test "the tags field is one input with the field's id, after a chip per tag", c do
    view = desk(c)
    assert has_element?(view, ~s(#{@form} .field .tags-box input.tags-input[id="tags"]))
    refute has_element?(view, ~s(#{@form} ol[id="tags"]))
    assert chips(view) == ["fixture", "t0"]
    assert has_element?(view, ~s(#{@form} .tags-box button[aria-label="Remove fixture"]))
    assert has_element?(view, ~s(#{@form} label[for="tags"]), "Tags")
    # The input posts nothing with the editor form: it belongs to no form.
    html = view |> element(~s(#{@form} input[id="tags"])) |> render()
    assert [_, form] = Regex.run(~r/\sform="([^"]+)"/, html)
    refute has_element?(view, ~s([id="#{form}"]))
    refute html =~ ~s(name=)
  end

  test "an empty tags field asks for a tag", c do
    id = c.id <> "-empty"
    {:ok, _} = Content.create_document(c.type, %{"doc_id" => id, "title" => "Bare"}, @dataset)
    view = desk(%{c | desk: String.replace(c.desk, ";" <> c.id, ";" <> id)})
    assert chips(view) == []

    assert has_element?(
             view,
             ~s(#{@form} input[id="tags"][placeholder="Enter tag and press ENTER…"])
           )
  end

  test "Enter adds the typed tag, trimmed, at the end, and stores a list of strings", c do
    view = desk(c)
    enter(view, "  alpha ")
    assert chips(view) == ["fixture", "t0", "alpha"]
    assert stored(c)["tags"] == ["fixture", "t0", "alpha"]
    # A blank Enter adds nothing and saves nothing.
    enter(view, "   ")
    assert stored(c)["tags"] == ["fixture", "t0", "alpha"]
  end

  test "tags entered one after another, before any answer, all land in order", c do
    view = desk(c)
    for tag <- ~w(one two three four), do: enter(view, tag)
    all = ~w(fixture t0 one two three four)
    assert chips(view) == all
    assert stored(c)["tags"] == all
  end

  test "× removes its tag; a × pressed on a list that has moved removes the tag it names", c do
    view = desk(c)
    remove(view, "fixture")
    assert stored(c)["tags"] == ["t0"]

    # A press built before the list was drawn again: index 1 named "t0",
    # which is now at 0. The tag it names goes, nothing else.
    enter(view, "x")

    EditorPost.press(view, "array_op", %{
      "action" => "remove_tag",
      "field" => "tags",
      "path" => "doc[tags]",
      "index" => "1",
      "value" => "t0"
    })

    assert stored(c)["tags"] == ["x"]
  end

  test "the last tag removed unsets the field: the stored document has no tags", c do
    view = desk(c)
    for tag <- ["fixture", "t0"], do: remove(view, tag)
    content = stored(c)
    refute Map.has_key?(content, "tags")
    assert content["highlights"] == ["One", "Two"]
    assert chips(view) == []
    # Then a tag is a list again.
    enter(view, "back")
    assert stored(c)["tags"] == ["back"]
  end

  test "inside an object, a tags field adds, and its last tag removed leaves an empty list", c do
    view = desk(c)
    assert has_element?(view, ~s(#{@form} .tags-box input.tags-input[id="seo.keywords"]))
    add = element(view, ~s(#{@form} [data-tags-add][phx-value-field="keywords"]))
    render_click(add, Map.merge(EditorPost.mark(view), %{"value" => "k2"}))
    assert stored(c)["seo"] == %{"metaTitle" => "Meta", "keywords" => ["k1", "k2"]}

    for tag <- ["k1", "k2"] do
      EditorPost.press_on(view, element(view, ~s(#{@form} button[aria-label="Remove #{tag}"])))
    end

    assert stored(c)["seo"] == %{"metaTitle" => "Meta", "keywords" => []}
  end

  test "a press for another document writes nothing", c do
    view = desk(c)
    other = Jason.encode!([@dataset, c.type, "someone-else"])
    add = element(view, ~s(#{@form} [data-tags-add][phx-value-field="tags"]))
    render_click(add, %{"_bp_doc" => other, "value" => "stray"})
    assert stored(c)["tags"] == ["fixture", "t0"]
  end

  test "an edit of another field leaves the stored tags as they are", c do
    view = desk(c)
    enter(view, "alpha")
    before = stored(c)["tags"]
    EditorPost.change(view, %{"_target" => ["doc", "title"], "doc" => %{"title" => "Renamed"}})
    doc = stored_doc(c)
    assert doc.title == "Renamed"
    assert doc.content["tags"] == before
  end

  test "the desk's sheet draws the box in the desk's tokens, no literal colour", c do
    view = desk(c)
    assert render(view) =~ ".dk .dk-edit .tags-box {"
    css = BarkparkWeb.Studio.Desk.TagsStyle.css()
    refute css =~ ~r/#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(/
    assert css =~ "var(--dk-tag-x)"
  end

  test "the old Studio keeps its rows for the same field", c do
    {:ok, studio, _html} = live(c.conn, c.studio)
    refute has_element?(studio, ".tags-box")
    assert has_element?(studio, ~s(button.bp-array-btn-remove[phx-value-field="tags"]))
  end

  # task-2730627f7a19999a: a tags press is a tags field's only. A hand-made
  # one naming another array would store a bare string in it.
  test "add_tag or remove_tag naming a field that is not a tags field stores nothing", c do
    view = desk(c)
    before = stored(c)

    for {field, action, value} <- [
          {"links", "add_tag", "bare"},
          {"highlights", "add_tag", "bare"},
          {"highlights", "remove_tag", "One"},
          {"title", "add_tag", "bare"}
        ] do
      EditorPost.press(view, "array_op", %{
        "action" => action,
        "field" => field,
        "path" => "doc[#{field}]",
        "index" => "0",
        "value" => value
      })
    end

    render(view)
    after_ = stored(c)
    assert after_["links"] == [%{"_key" => "l1", "label" => "One"}]
    assert after_["highlights"] == ["One", "Two"]
    assert stored_doc(c).title == "Tagged"
    assert after_ == before

    # Control: the same press on the tags field lands.
    enter(view, "x")
    assert eventually(fn -> stored(c)["tags"] == ["fixture", "t0", "x"] end)
  end
end
