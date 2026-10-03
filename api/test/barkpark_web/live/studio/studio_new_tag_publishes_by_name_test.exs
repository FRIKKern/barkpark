defmodule BarkparkWeb.Studio.StudioNewTagPublishesByNameTest do
  @moduledoc """
  task-655768f4fa3c9fed — a tag made with Studio's "+" must be usable.

  The publish wall registers a tag by its DOCUMENT ID (`TagRegistry`), while
  Studio births every document with a generated id (`tag-<16 hex>`). Found
  dogfooding: New tag, title it "editorial", Publish — then every document
  weighted with `editorial` was refused `unknown_tag`. The first publish of a
  generated-id tag now publishes it under the name its title gives.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.TagRegistry

  @dataset "production"

  setup do
    TagRegistry.register!(@dataset)
    :ok
  end

  defp new_tag(conn, title) do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))
    render_click(view, "new-document", %{"type" => "tag"})

    draft =
      "tag"
      |> Content.list_documents(@dataset, perspective: :raw)
      |> Enum.find(&(Content.draft?(&1.doc_id) and &1.doc_id =~ ~r/^drafts\.tag-[0-9a-f]{16}$/))

    assert draft, "Studio's new-document should birth a drafts.tag-<hex> row"
    pub_id = Content.published_id(draft.doc_id)

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/tag/#{pub_id}"))
    render_change(view, "autosave", %{"doc" => %{"title" => title}})
    {view, pub_id}
  end

  defp tag_rows(id) do
    for doc_id <- [id, Content.draft_id(id)],
        match?({:ok, _}, Content.get_document(doc_id, "tag", @dataset)),
        do: doc_id
  end

  test "publishing a new tag titled 'Editorial Process' registers editorial-process", %{
    conn: conn
  } do
    {view, generated} = new_tag(conn, "Editorial Process")

    html = render_click(view, "publish")
    assert html =~ "Published tag “editorial-process”"

    assert {:ok, tag} = Content.get_document("editorial-process", "tag", @dataset)
    assert tag.title == "Editorial Process"
    assert tag_rows(generated) == []

    weighted = %Barkpark.Content.Document{
      doc_id: "drafts.n1",
      type: "note",
      content: %{
        "tags" => [%{"tag" => "editorial-process", "strength" => 80, "rationale" => "x"}]
      }
    }

    assert :ok = TagRegistry.validate_publish(weighted, @dataset, [])
  end

  test "an Untitled tag is refused with a sentence naming the fix, and nothing is published",
       %{conn: conn} do
    {view, generated} = new_tag(conn, "Untitled")

    html = render_click(view, "publish")
    assert html =~ "Name the tag before publishing"
    assert tag_rows(generated) == [Content.draft_id(generated)]
    assert {:error, _} = Content.get_document(generated, "tag", @dataset)
  end

  test "a name another tag already holds is refused and names that tag", %{conn: conn} do
    {:ok, _} =
      Content.create_document("tag", %{"doc_id" => "editorial", "title" => "editorial"}, @dataset)

    {:ok, _} = Content.publish_document("editorial", "tag", @dataset)

    {view, generated} = new_tag(conn, "Editorial")

    html = render_click(view, "publish")
    assert html =~ "A tag named “editorial” already exists"
    assert tag_rows(generated) == [Content.draft_id(generated)]
  end
end
