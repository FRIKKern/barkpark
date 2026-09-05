defmodule BarkparkWeb.Studio.PaneBuilderDeskGroupParseParityTest do
  @moduledoc """
  Gyldendal field report #35a — `/studio/<type>/<seg>` parsed DIFFERENTLY with
  and without desk groups, "so the same position means two different things
  depending on the schema, and deep links are guesswork" (S9 criterion 1a,
  task-6d80c6cc7d97b1d1).

  THE INVARIANT, stated as one fixture built TWICE. The same dataset content —
  one `publication` schema, two published documents — is desked two ways by a
  `deskStructure` declaration that is the ONLY difference between the two:

      FLAT     root ─ publication            (no desk group)
      GROUPED  root ─ Content ─ publication  (the same type, one level down)

  Two things must hold across BOTH shapes, or a deep link is guesswork:

    1. THE SHORT FORM MEANS ONE THING. `/studio/publication/<id>` opens the
       SAME document editor — same type, same id — in both. `PaneBuilder`'s
       `resolve/4` normalizes the grouped shape to `["content", "publication",
       <id>]` for the walk; the URL is untouched, so the reader's position
       ("segment 0 is the type, segment 1 is the document") holds either way.

    2. THE CANONICAL PATH IS A WORKING DEEP LINK. A row click builds
       `pane.path ++ [id]` (`Handlers.Scope.select/2`, #15987) off the `:path`
       each pane is stamped with. That path is SHAPE-DEPENDENT by design — it
       is the pane stack's own address, `["publication", id]` flat and
       `["content", "publication", id]` grouped — but it must resolve to the
       same document as the short form, and it must carry EXACTLY ONE document
       segment. Before #15987 the click sliced the RAW url by the pane's
       rendered index instead, and the grouped shape (pane stack one longer
       than the URL) produced `/studio/publication/<a>/<b>` — a path that
       parses as neither shape and opens nothing.

  This is the parse half of #35. The click half is
  `studio_live/studio_row_click_replaces_path_test.exs` (#35b) and the error
  card is `studio_live/studio_unresolved_document_triage_test.exs` (#35c).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  alias BarkparkWeb.Studio.PaneBuilder

  @suffix System.unique_integer([:positive])
  @flat "parse-parity-flat-#{@suffix}"
  @grouped "parse-parity-grouped-#{@suffix}"
  @shadowed "parse-parity-shadowed-#{@suffix}"

  # The ONE type list, declared identically in both shapes — same node id, same
  # title, same type. Only its POSITION in the declaration differs.
  @type_list %{
    "kind" => "documentTypeList",
    "id" => "publication",
    "type" => "publication",
    "title" => "Utgivelser"
  }

  @flat_items [@type_list]
  @grouped_items [
    %{"kind" => "list", "id" => "content", "title" => "Content", "items" => [@type_list]}
  ]

  setup do
    seed(@flat, @flat_items)
    seed(@grouped, @grouped_items)

    :ok
  end

  defp seed(dataset, items) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "icon" => "book",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
        },
        dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "deskStructure",
          "title" => "Desk",
          "singleton" => true,
          "visibility" => "private",
          "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
        },
        dataset
      )

    for {id, title} <- [{"pub-a", "Over My Dead Body"}, {"pub-b", "Snow Angels"}] do
      {:ok, _} =
        Content.create_document(
          "publication",
          %{"doc_id" => id, "title" => title, "status" => "published"},
          dataset
        )
    end

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", dataset)
    :ok
  end

  # The pane the `publication` rows are rendered in, in whichever shape.
  defp doc_list_pane(panes), do: Enum.find(panes, &(&1[:type_name] == "publication"))

  defp editor_identity(nil), do: nil
  defp editor_identity(editor), do: {editor.type, DraftId.published_id(editor.doc.doc_id)}

  describe "the desk shape is real — the fixture must actually differ" do
    test "flat lists the type at the root; grouped puts it one level down" do
      {flat_panes, _} = PaneBuilder.build(@flat, ["publication", "pub-a"])
      {grouped_panes, _} = PaneBuilder.build(@grouped, ["publication", "pub-a"])

      flat_depth = Enum.find_index(flat_panes, &(&1[:type_name] == "publication"))
      grouped_depth = Enum.find_index(grouped_panes, &(&1[:type_name] == "publication"))

      assert flat_depth == 1, "flat: the type list must hang off the root pane"

      assert grouped_depth == 2,
             "grouped: the type list must sit under the group pane — otherwise the two " <>
               "shapes are the same shape and every assertion below is vacuous"
    end
  end

  describe "1. the short form means one document, whatever the desk shape" do
    test "/studio/publication/<id> opens the SAME editor with and without a desk group" do
      {_, flat_editor} = PaneBuilder.build(@flat, ["publication", "pub-a"])
      {_, grouped_editor} = PaneBuilder.build(@grouped, ["publication", "pub-a"])

      assert editor_identity(flat_editor) == {"publication", "pub-a"}

      assert editor_identity(grouped_editor) == {"publication", "pub-a"},
             "the same URL must open the same document under a desk group — it opened " <>
               "#{inspect(editor_identity(grouped_editor))}"

      assert editor_identity(flat_editor) == editor_identity(grouped_editor)
    end

    test "the second document too — the position is the document, not a coincidence" do
      {_, flat_editor} = PaneBuilder.build(@flat, ["publication", "pub-b"])
      {_, grouped_editor} = PaneBuilder.build(@grouped, ["publication", "pub-b"])

      assert editor_identity(flat_editor) == {"publication", "pub-b"}
      assert editor_identity(grouped_editor) == {"publication", "pub-b"}
    end
  end

  describe "2. the canonical path a row click builds is a working deep link in both shapes" do
    test "every pane is stamped with its own address" do
      for {dataset, label} <- [{@flat, "flat"}, {@grouped, "grouped"}] do
        {panes, _} = PaneBuilder.build(dataset, ["publication", "pub-a"])
        pane = doc_list_pane(panes)

        stamped? = is_list(pane[:path])

        assert stamped?,
               "#{label}: the publication pane carries no :path stamp, so a row click has " <>
                 "no canonical prefix to build from and falls back to slicing the raw URL"
      end
    end

    test "pane.path ++ [id] opens the clicked document — one document segment, and it is the clicked one" do
      for {dataset, label} <- [{@flat, "flat"}, {@grouped, "grouped"}] do
        # From doc A open, the row for doc B: exactly what `Handlers.Scope.select/2`
        # computes from the pane the row lives in.
        {panes, _} = PaneBuilder.build(dataset, ["publication", "pub-a"])
        clicked = doc_list_pane(panes).path ++ ["pub-b"]

        assert List.last(clicked) == "pub-b",
               "#{label}: the canonical path must end in the clicked id: #{inspect(clicked)}"

        assert Enum.count(clicked, &(&1 in ["pub-a", "pub-b"])) == 1,
               "#{label}: exactly one document segment — the click must REPLACE, not " <>
                 "append: #{inspect(clicked)}"

        {_, editor} = PaneBuilder.build(dataset, clicked)

        assert editor_identity(editor) == {"publication", "pub-b"},
               "#{label}: the canonical path #{inspect(clicked)} is not a working deep " <>
                 "link — it opened #{inspect(editor_identity(editor))}"
      end
    end

    test "the canonical path is the desk's own address, and it agrees with the short form" do
      {flat_panes, _} = PaneBuilder.build(@flat, ["publication", "pub-a"])
      {grouped_panes, _} = PaneBuilder.build(@grouped, ["publication", "pub-a"])

      assert doc_list_pane(flat_panes).path == ["publication"]

      assert doc_list_pane(grouped_panes).path == ["content", "publication"],
             "grouped: the canonical prefix must be the pane stack's own address"

      # Two spellings, one document — that is what makes the short form safe to
      # keep as a deep link while the desk owns the canonical one.
      {_, short} = PaneBuilder.build(@grouped, ["publication", "pub-a"])
      {_, canonical} = PaneBuilder.build(@grouped, ["content", "publication", "pub-a"])

      assert editor_identity(short) == editor_identity(canonical)
      assert editor_identity(short) == {"publication", "pub-a"}
    end
  end

  describe "3. a desk node id that shadows a type name must not make the type unreachable" do
    # The collision the two shapes above cannot show: a declared desk whose ROOT
    # holds a group node whose `id` happens to equal a type name, while the type
    # itself is listed under a DIFFERENT group. `resolve/4` sees the head name a
    # root item (`root_has_segment?/2` matches a `:list` by id) and hands the
    # walk the RAW path, so the walk drills the group, finds no child for the
    # document tail and opens NOTHING — while the very same URL on the grouped
    # desk above opens the document. That is #35a's "the same position means two
    # different things", reached by desk-node id instead of by desk depth.
    setup do
      seed(@shadowed, [
        %{
          "kind" => "list",
          "id" => "publication",
          "title" => "Publications (a group, not the type list)",
          "items" => []
        },
        %{"kind" => "list", "id" => "content", "title" => "Content", "items" => [@type_list]}
      ])

      :ok
    end

    test "/studio/publication/<id> still opens the document when a root group shadows the name" do
      {_, editor} = PaneBuilder.build(@shadowed, ["publication", "pub-a"])

      assert editor_identity(editor) == {"publication", "pub-a"},
             "a root desk node named after the type made the type unreachable — the same " <>
               "URL opens the document on every other desk shape"
    end

    test "the shadowing group itself still wins its own address — the retry never re-routes a working URL" do
      {panes, editor} = PaneBuilder.build(@shadowed, ["publication"])

      assert editor == nil, "a group drill opens no editor"

      assert List.last(panes).title == "Publications (a group, not the type list)",
             "/studio/publication must still open the DECLARED group: precedence is unchanged, " <>
               "the retry only rescues a path that opened nothing"
    end
  end
end
