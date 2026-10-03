defmodule BarkparkWeb.Studio.ClassicDocSwitchIgnoredFieldsTest do
  @moduledoc """
  task-eda246dcab63dc3f — switching documents in one Classic pane must not
  carry the previous document's rich text, reference or image value along.

  Those three inputs live in `phx-update="ignore"` wrappers (the web
  component owns the DOM). With a wrapper id built from the field name only,
  a doc→doc patch kept the old wrapper, so its hidden input still held the
  previous document's value and the next autosave wrote it into the document
  now open. `Phoenix.LiveViewTest` applies `phx-update="ignore"` the way the
  browser does (it keeps the old children of a same-id container), so the
  hidden inputs read here are what the browser would serialize.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "note",
          "title" => "Note",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"},
            %{
              "name" => "author",
              "title" => "Author",
              "type" => "reference",
              "refType" => "person"
            },
            %{"name" => "cover", "title" => "Cover", "type" => "image"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "person",
          "title" => "Person",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset
      )

    for {id, body, author, cover} <- [
          {"n1", "<p>first body</p>", "ada", "/media/one.png"},
          {"n2", "<p>second body</p>", "grace", "/media/two.png"}
        ] do
      {:ok, _} =
        Content.create_document(
          "note",
          %{
            "doc_id" => id,
            "title" => "Note #{id}",
            "content" => %{"body" => body, "author" => author, "cover" => cover}
          },
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "note", @dataset)
    end

    :ok
  end

  defp hidden_value(html, input_id) do
    [_, value] = Regex.run(~r{<input[^>]*id="#{input_id}"[^>]*value="([^"]*)"}, html)
    value
  end

  test "patching from one note to another shows the second note's body, author and cover",
       %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/note/n1"))

    assert hidden_value(html, "bp-rt-hidden-body") =~ "first body"
    assert hidden_value(html, "bp-ref-hidden-author") == "ada"
    assert hidden_value(html, "bp-mp-hidden-cover") =~ "one.png"

    html = render_patch(view, scoped_studio("/d/#{@dataset}/studio/note/n2"))

    assert hidden_value(html, "bp-rt-hidden-body") =~ "second body"
    assert hidden_value(html, "bp-ref-hidden-author") == "grace"
    assert hidden_value(html, "bp-mp-hidden-cover") =~ "two.png"
  end

  test "the first edit of a published note keeps the same wrappers (no remount mid-typing)",
       %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/note/n1"))

    wrapper_ids = fn html ->
      Regex.scan(~r{id="(bp-(?:rt|ref|mp)-wrap-[^"]+)"}, html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()
    end

    before = wrapper_ids.(html)
    assert length(before) == 3

    # The first keystroke births drafts.n1; the editor now holds the draft.
    render_change(view, "autosave", %{"doc" => %{"title" => "Note n1 edited"}})
    {:ok, draft} = Content.get_document("drafts.n1", "note", @dataset)
    assert draft.title == "Note n1 edited"

    assert wrapper_ids.(render(view)) == before
  end

  # task-c7b0565a482b9d21 — the same document open in two tabs. Tab B saves a
  # new body and author; tab A has no unsaved edits, so its form is refreshed
  # in place. Before the fix its ignored widgets kept the OLD values, and tab
  # A's next keystroke autosaved them over tab B's edit.
  test "an idle tab shows the body and author another tab just saved", %{conn: conn} do
    path = scoped_studio("/d/#{@dataset}/studio/note/n1")
    {:ok, tab_a, _} = live(conn, path)
    {:ok, tab_b, html_b} = live(conn, path)

    wrapper_ids = fn html ->
      Regex.scan(~r{id="(bp-(?:rt|ref|mp)-wrap-[^"]+)"}, html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()
    end

    render_change(tab_b, "autosave", %{
      "doc" => %{"title" => "Note n1", "body" => "<p>tab B body</p>", "author" => "grace"}
    })

    # The saving tab never remounts its own widgets.
    assert wrapper_ids.(render(tab_b)) == wrapper_ids.(html_b)

    html_a = render(tab_a)
    assert hidden_value(html_a, "bp-rt-hidden-body") =~ "tab B body"
    assert hidden_value(html_a, "bp-ref-hidden-author") == "grace"
    # The image was not touched; it stays as it was.
    assert hidden_value(html_a, "bp-mp-hidden-cover") =~ "one.png"
  end
end
