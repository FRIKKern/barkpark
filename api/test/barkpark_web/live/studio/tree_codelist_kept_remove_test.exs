defmodule BarkparkWeb.Studio.TreeCodelistKeptRemoveTest do
  @moduledoc """
  task-9ae4a10efeab3bc9: a tree codelist over a stored value that is no code
  (7), top-level and in an object, offers Remove, in the desk and the old
  Studio. The value is kept as stored on an edit of another field; Remove's
  own press writes "" for that field only (a top-level "" takes the key
  off the document, as Remove over a code does).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list_id = "onixedit:tree-kept-#{n}"

    {:ok, _} =
      Codelists.register("onixedit", list_id, %{
        issue: "1",
        name: "Tree kept",
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

    type = "tk_book_#{n}"
    tree = %{"title" => "Subject", "type" => "codelist", "codelistId" => list_id}

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Tree kept",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            Map.put(tree, "name", "subject"),
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [
                Map.merge(tree, %{"name" => "code", "title" => "Code"}),
                %{"name" => "label", "title" => "Label", "type" => "string"}
              ]
            },
            %{"name" => "notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "tree-kept-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "tree-kept", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, root: root, type: type}
  end

  defp doc!(c) do
    id = "tk-#{System.unique_integer([:positive])}"
    content = %{"subject" => 7, "meta" => %{"code" => 7, "label" => "x"}, "notes" => "0"}

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => content},
        @dataset
      )

    id
  end

  defp open(c, :desk, id) do
    {:ok, view, _} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert has_element?(view, "[data-pane-editing] #editor-form")
    {view, "[data-pane-editing] #editor-form"}
  end

  defp open(c, :studio, id) do
    {:ok, view, _} = live(c.conn, "#{c.root}/#{c.type}/#{id}")
    assert has_element?(view, "#editor-form")
    {view, "#editor-form"}
  end

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  defp edit_notes(view, form, value) do
    view
    |> form(form, %{"doc" => %{"notes" => value}})
    |> render_change(%{"_target" => ["doc", "notes"]})
  end

  # The tree's own wrapper: the top-level field's, or the object's subfield's.
  defp field(form, :top), do: ~s(#{form} [data-field-name="subject"])
  defp field(form, :nested), do: ~s(#{form} [data-field-name="code"])

  defp remove(form, where), do: field(form, where) <> ~s( [data-test-id="tree-codelist-remove"])

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: Remove is offered over a stored 7, top-level and in an object", c do
      {view, form} = open(c, @surface, doc!(c))

      assert has_element?(view, remove(form, :top))
      assert has_element?(view, remove(form, :nested))

      if @surface == :desk do
        assert has_element?(
                 view,
                 ~s(#{field(form, :top)} .codelist-current[data-codelist-kept]),
                 "Not a code (kept as stored)"
               )
      end
    end

    test "#{surface}: an edit elsewhere keeps the 7; Remove writes \"\" for its own field only",
         c do
      id = doc!(c)
      {view, form} = open(c, @surface, id)

      edit_notes(view, form, "typed")
      assert stored(c, id)["subject"] === 7
      assert stored(c, id)["meta"] == %{"code" => 7, "label" => "x"}

      EditorPost.press_on(view, element(view, remove(form, :top)))
      render(view)
      # A top-level "" takes the key off, as Remove over a code does.
      refute Map.has_key?(stored(c, id), "subject")
      assert stored(c, id)["meta"] == %{"code" => 7, "label" => "x"}

      EditorPost.press_on(view, element(view, remove(form, :nested)))
      render(view)
      assert stored(c, id)["meta"] == %{"code" => "", "label" => "x"}

      edit_notes(view, form, "again")
      assert stored(c, id)["notes"] == "again"
      assert stored(c, id)["meta"]["code"] == ""
    end
  end
end
