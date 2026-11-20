defmodule BarkparkWeb.Studio.DeskCodelistListPasteTest do
  @moduledoc """
  task-98885f8aa1aa21f1 (found doing #27970): a list of codelist values
  (`arrayOf` a codelist) did not paste. `FieldPaste`'s row types had no
  codelist, so Paste field and Paste document answered "cannot be pasted
  into", where the TanStack Studio pastes `array:codelist` into
  `array:codelist` (the same signature).

  Each row is now read as a typed codelist value is (`CodelistShape.code?/1`):
  a code of another list is stored, and Validation warns; a row that is not
  a code (a list, a map, a string over 64 characters, nothing) refuses the
  paste in words, and the store keeps its value. A copied item is appended
  as one row.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @toast "desk:field-toast"

  defp codes(name, list_id),
    do: %{
      "name" => name,
      "title" => name,
      "type" => "arrayOf",
      "of" => %{"type" => "codelist", "codelistId" => list_id}
    }

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list = "onixedit:desk-list-paste-#{n}"
    other = "onixedit:desk-list-paste-other-#{n}"
    type = "dclp_#{n}"

    for {id, values} <- [{list, ~w(FBA YFB YFC)}, {other, ~w(X1 X2)}] do
      {:ok, _} =
        Codelists.register("onixedit", id, %{
          issue: "1",
          name: id,
          values:
            for(
              code <- values,
              do: %{code: code, translations: [%{language: "eng", label: code}]}
            )
        })
    end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Codelist list paste #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            codes("subjects", list),
            codes("subjects2", list),
            codes("regions", other),
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-list-paste-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-list-paste", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     root: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type}
  end

  defp doc!(c, content) do
    id = "dclp-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => Map.put(content, "notes", "n0")},
        @dataset
      )

    id
  end

  defp desk(c, id) do
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert has_element?(view, "[data-pane-editing] #editor-form")
    view
  end

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  defp pressed(view, params),
    do: Map.merge(Map.take(EditorPost.marks(view), ["_bp_doc"]), params)

  defp copy_field(view, name) do
    render_hook(view, "desk-field-copy", %{"field" => name})
    assert_push_event(view, "desk:field-copied", %{json: json})
    json
  end

  defp paste_field(view, name, clip),
    do: render_hook(view, "desk-field-paste", pressed(view, %{"field" => name, "clip" => clip}))

  # Barkpark's own copy of a list of codelist values holding `rows`.
  defp list_clip(rows) do
    Jason.encode!(%{
      "type" => "sanityClipboardItem",
      "isDocument" => false,
      "schemaTypeName" => "array",
      "value" => rows,
      "barkpark" => %{
        "kind" => "field",
        "field" => %{"name" => "subjects", "sig" => "array:codelist", "value" => rows}
      }
    })
  end

  test "Paste field: a copied list of codes pastes into a list of the same codelist", c do
    id = doc!(c, %{"subjects" => ["FBA", "YFB"], "subjects2" => ["YFC"]})
    view = desk(c, id)

    paste_field(view, "subjects2", copy_field(view, "subjects"))

    assert stored(c, id)["subjects2"] == ["FBA", "YFB"]
    assert stored(c, id)["subjects"] == ["FBA", "YFB"]
    assert stored(c, id)["notes"] == "n0"
    refute_push_event(view, @toast, %{tone: "critical"})
  end

  test "Paste field: codes of another list are stored, as typed unknown codes are", c do
    id = doc!(c, %{"subjects" => ["FBA", "YFB"], "regions" => ["X1"]})
    view = desk(c, id)

    paste_field(view, "regions", copy_field(view, "subjects"))

    assert stored(c, id)["regions"] == ["FBA", "YFB"]
  end

  test "Paste field: a copied item is appended as one row", c do
    id = doc!(c, %{"subjects" => ["FBA", "YFB"], "subjects2" => ["YFC"]})
    view = desk(c, id)

    render_hook(view, "desk-item-copy", %{
      "field" => "subjects",
      "path" => "subjects",
      "index" => "1"
    })

    assert_push_event(view, "desk:field-copied", %{json: json})
    paste_field(view, "subjects2", json)

    assert stored(c, id)["subjects2"] == ["YFC", "YFB"]
  end

  for {label, row} <- [
        {"a list", ["FBA"]},
        {"a map", %{"code" => "FBA"}},
        {"a string over 64 characters", String.duplicate("F", 65)},
        {"nothing", nil}
      ] do
    test "Paste field: a row that is #{label} is not a code; the paste is refused in words", c do
      id = doc!(c, %{"subjects" => ["FBA"]})
      view = desk(c, id)

      paste_field(view, "subjects", list_clip(["YFB", unquote(Macro.escape(row))]))

      assert_push_event(view, @toast, %{
        tone: "critical",
        title: "Invalid clipboard item",
        description: "Not a code (kept as stored)"
      })

      assert stored(c, id)["subjects"] == ["FBA"]
    end
  end

  test "Paste document: a copied document's lists of codes paste into the lists", c do
    from = doc!(c, %{"subjects" => ["YFB", "YFC"], "regions" => ["X2"]})
    to = doc!(c, %{"subjects" => ["FBA"], "regions" => ["X1"]})

    source = desk(c, from)
    render_hook(source, "desk-doc-copy", %{})
    assert_push_event(source, "desk:doc-copied", %{json: json})

    view = desk(c, to)
    render_hook(view, "desk-doc-paste", pressed(view, %{"clip" => json}))

    assert stored(c, to)["subjects"] == ["YFB", "YFC"]
    assert stored(c, to)["regions"] == ["X2"]
  end
end
