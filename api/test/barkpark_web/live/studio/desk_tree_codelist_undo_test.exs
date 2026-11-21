defmodule BarkparkWeb.Studio.DeskTreeCodelistUndoTest do
  @moduledoc """
  task-a895a60bcc1302d9 (review of #27740, N1): in the desk a pick or a
  Remove in a tree codelist was no undo step. Mod+Z skipped it and took back
  the change before. A Remove that unset an object (its last code) also
  left that object's earlier step reverting a value no longer stored, so
  Mod+Z did nothing and said nothing.

  Each tree pick and Remove is now one step of the document's undo, as the
  TanStack Studio records every write: Undo takes it back, Redo puts it back,
  and the earlier steps still work after it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @form "[data-pane-editing] #editor-form"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list_id = "onixedit:tree-undo-#{n}"

    # Over 100 codes: the field is drawn as a tree.
    {:ok, _} =
      Codelists.register("onixedit", list_id, %{
        issue: "1",
        name: "Tree undo",
        values: [
          %{
            code: "FB",
            translations: [%{language: "eng", label: "Fiction"}],
            children:
              for(
                i <- 1..101,
                do: %{code: "FB#{i}", translations: [%{language: "eng", label: "F#{i}"}]}
              )
          }
        ]
      })

    type = "tu_book_#{n}"
    tree = %{"type" => "codelist", "codelistId" => list_id}

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Tree undo",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            Map.merge(tree, %{"name" => "subject", "title" => "Subject"}),
            %{
              "name" => "pair",
              "title" => "Pair",
              "type" => "composite",
              "fields" => [
                Map.merge(tree, %{"name" => "a", "title" => "A"}),
                Map.merge(tree, %{"name" => "b", "title" => "B"})
              ]
            },
            %{"name" => "notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "tree-undo-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "tree-undo", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     root: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type}
  end

  defp doc!(c, content) do
    id = "tu-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => Map.put(content, "notes", "n0")},
        @dataset
      )

    id
  end

  defp desk(c, id) do
    {:ok, view, _} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert has_element?(view, @form)
    view
  end

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  defp mark(c, id), do: %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, id)}

  # A pick in the tree reaches the page as the tree component's message.
  defp pick(view, c, id, name, code) do
    send(view.pid, {:tree_codelist_pick, %{name: name, value: code, press: mark(c, id)}})
    render(view)
    # Past the undo's grouping of quick edits to one field.
    Process.sleep(650)
  end

  defp remove(view, name) do
    EditorPost.press_on(
      view,
      element(
        view,
        ~s(#{@form} [data-field-name="#{name}"] [data-test-id="tree-codelist-remove"])
      )
    )

    render(view)
    Process.sleep(650)
  end

  defp undo(view, c, id, redo \\ false) do
    render_hook(view, "desk-undo", Map.put(mark(c, id), "redo", redo))
    render(view)
  end

  test "a top-level pick and Remove are each one undo step", c do
    id = doc!(c, %{"subject" => "FB1"})
    view = desk(c, id)

    pick(view, c, id, "doc[subject]", "FB2")
    assert stored(c, id)["subject"] == "FB2"
    remove(view, "subject")
    refute Map.has_key?(stored(c, id), "subject")

    undo(view, c, id)
    assert stored(c, id)["subject"] == "FB2"
    undo(view, c, id)
    assert stored(c, id)["subject"] == "FB1"

    undo(view, c, id, true)
    assert stored(c, id)["subject"] == "FB2"
    undo(view, c, id, true)
    refute Map.has_key?(stored(c, id), "subject")
    assert stored(c, id)["notes"] == "n0"
  end

  test "pick two codes in an object, Remove both: two undos bring both back", c do
    id = doc!(c, %{})
    view = desk(c, id)

    pick(view, c, id, "doc[pair].a", "FB3")
    pick(view, c, id, "doc[pair].b", "FB4")
    assert stored(c, id)["pair"] == %{"a" => "FB3", "b" => "FB4"}

    remove(view, "a")
    remove(view, "b")
    # The last Remove leaves the object empty, and it goes.
    refute Map.has_key?(stored(c, id), "pair")

    undo(view, c, id)
    assert stored(c, id)["pair"] == %{"b" => "FB4"}
    undo(view, c, id)
    assert stored(c, id)["pair"] == %{"a" => "FB3", "b" => "FB4"}

    # The picks before them still undo.
    undo(view, c, id)
    assert stored(c, id)["pair"] == %{"a" => "FB3"}

    undo(view, c, id, true)
    assert stored(c, id)["pair"] == %{"a" => "FB3", "b" => "FB4"}
  end

  test "a typed edit before a Remove that unsets its object still undoes", c do
    id = doc!(c, %{"pair" => %{"a" => "FB5"}})
    view = desk(c, id)

    view
    |> form(@form, %{"doc" => %{"notes" => "n1"}})
    |> render_change(%{"_target" => ["doc", "notes"]})

    Process.sleep(650)
    remove(view, "a")
    refute Map.has_key?(stored(c, id), "pair")

    undo(view, c, id)
    assert stored(c, id)["pair"] == %{"a" => "FB5"}
    undo(view, c, id)
    assert stored(c, id)["notes"] == "n0"
  end
end
