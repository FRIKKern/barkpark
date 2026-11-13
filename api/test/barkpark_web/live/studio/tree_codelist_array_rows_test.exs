defmodule BarkparkWeb.Studio.TreeCodelistArrayRowsTest do
  @moduledoc """
  task-f9f7a9acd3608ca4: an array whose rows hold a tree codelist.

  `CodelistField` built its ids from the field's name alone (`f-<name>`), and
  the tree's LiveComponent id from that (`tree-f-<name>`). Every row of one
  array has the same item field, so with two rows the editor raised
  `found duplicate ID "tree-f-<name>"` and the document did not open. The ids
  now carry the row's path. These tests open such a document in the old
  Studio and in the desk, pick in row 2, and read the stored draft.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy

  @dataset "production"
  @plugin "onixedit"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list_id = "onixedit:tree-rows-#{n}"
    type = "tr_volume_#{n}"
    doc_id = "tr-volume-#{n}"

    # One parent with 101 children: over the 100-entry tree threshold.
    children =
      for i <- 1..101 do
        code = "FB" <> String.pad_leading(Integer.to_string(i), 3, "0")
        %{code: code, translations: [%{language: "eng", label: "Fiction #{i}"}]}
      end

    {:ok, _} =
      Codelists.register(@plugin, list_id, %{
        issue: "1",
        name: "Tree rows proof",
        values: [
          %{code: "FB", translations: [%{language: "eng", label: "Fiction"}], children: children}
        ]
      })

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "TR volumes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "subjects",
              "title" => "Subjects",
              "type" => "arrayOf",
              "of" => %{"name" => "subject", "type" => "codelist", "codelistId" => list_id}
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => doc_id,
          "title" => "Volume one",
          "content" => %{"subjects" => ["FB001", "FB002"]}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "tree-rows-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "tree-rows", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     studio: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type,
     doc_id: doc_id,
     list_id: list_id}
  end

  defp stored_subjects(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    (doc.content || %{})["subjects"]
  end

  # Pick `code` in the tree of row `idx` (0-based) inside `scope`.
  defp pick(view, scope, idx, code) do
    tree = scope <> " #tree-f-subjects-#{idx}"
    row = tree <> ~s( [phx-click="tree_node_select"][phx-value-code="#{code}"])

    unless has_element?(view, row) do
      view
      |> element(tree <> ~s( [phx-click="tree_node_toggle"][phx-value-code="FB"]))
      |> render_click()
    end

    view |> element(row) |> render_click()

    # The save rides a message the LiveView handles after the click.
    render(view)
  end

  test "old Studio: both rows render a tree, and a pick in row 2 saves to row 2 only", c do
    {:ok, view, _html} = live(c.conn, "#{c.studio}/#{c.type}/#{c.doc_id}")

    assert has_element?(view, "#editor-form #tree-f-subjects-0")
    assert has_element?(view, "#editor-form #tree-f-subjects-1")

    pick(view, "#editor-form", 1, "FB042")

    assert stored_subjects(c) == ["FB001", "FB042"]
  end

  test "desk: both rows render a tree, and a pick in row 2 saves to row 2 only", c do
    {:ok, view, _html} = live(c.conn, "#{c.studio}/_desk/#{c.type};#{c.doc_id}")

    assert has_element?(view, "[data-pane-editing] #tree-f-subjects-0")
    assert has_element?(view, "[data-pane-editing] #tree-f-subjects-1")

    pick(view, "[data-pane-editing]", 1, "FB007")

    assert stored_subjects(c) == ["FB001", "FB007"]
  end

  # #25887 review: a composite's children are `parent.child`, with no
  # brackets, so ids from bracket segments alone gave two tree codelists in one
  # composite the same id, and the editor raised.
  test "composites: every tree codelist gets its own id; top-level ids stay as they were",
       c do
    small = "onixedit:tree-rows-small-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Codelists.register(@plugin, small, %{
        issue: "1",
        name: "Small",
        values: [%{code: "A", translations: [%{language: "eng", label: "A"}]}]
      })

    tree = fn name ->
      %{"name" => name, "title" => name, "type" => "codelist", "codelistId" => c.list_id}
    end

    type = c.type <> "_c"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "TR composites",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "kind", "title" => "Kind", "type" => "codelist", "codelistId" => small},
            tree.("subject"),
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [tree.("a"), tree.("b")]
            },
            %{
              "name" => "rows",
              "title" => "Rows",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "title" => "Row",
                "fields" => [tree.("a"), tree.("b")]
              }
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => c.doc_id <> "-c",
          "title" => "Composite one",
          "content" => %{
            "meta" => %{"a" => "FB001", "b" => "FB002"},
            "rows" => [%{"a" => "FB003", "b" => "FB004"}, %{"a" => "FB005", "b" => "FB006"}]
          }
        },
        @dataset
      )

    {:ok, view, _html} = live(c.conn, "#{c.studio}/#{type}/#{c.doc_id}-c")

    for id <-
          ~w(f-kind tree-f-subject tree-f-meta-a tree-f-meta-b tree-f-rows-0-a tree-f-rows-0-b tree-f-rows-1-a tree-f-rows-1-b) do
      assert has_element?(view, "#editor-form ##{id}"), "no ##{id}"
    end
  end
end
