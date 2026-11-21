defmodule BarkparkWeb.Studio.DeskCodelistPasteTest do
  @moduledoc """
  task-ae3cc32064148893 (found fixing #27955): Paste field and Paste
  document refused every codelist value ("A field of type "codelist" cannot
  be pasted into"), where the TanStack Studio pastes a copied code into a
  codelist field (`clipboard.ts` `transfer`: the same signature).

  A copied code now pastes into a codelist field, as typing it would save
  it: a code of another list (or of none) is stored, and Validation warns
  under the field, as for a typed unknown code (task-400a66c6ebd31026). A
  value that is not a code (a list, a map, a string over 64 characters) is
  refused in words, as a typed one is not saved (#27955).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @form "[data-pane-editing] #editor-form"
  @toast "desk:field-toast"
  @not_code "Not a code (kept as stored)"

  defp codelist(name, list_id),
    do: %{"name" => name, "title" => name, "type" => "codelist", "codelistId" => list_id}

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list = "onixedit:desk-paste-#{n}"
    other = "onixedit:desk-paste-other-#{n}"
    type = "dcp_#{n}"

    for {id, codes} <- [{list, ~w(FBA YFB)}, {other, ~w(X1 X2)}] do
      {:ok, _} =
        Codelists.register("onixedit", id, %{
          issue: "1",
          name: id,
          values:
            for(code <- codes, do: %{code: code, translations: [%{language: "eng", label: code}]})
        })
    end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Codelist paste #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            codelist("subject", list),
            codelist("subject2", list),
            codelist("region", other),
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [codelist("code", list), %{"name" => "note", "type" => "string"}]
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-paste-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-paste", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     root: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type}
  end

  defp doc!(c, content) do
    id = "dcp-#{System.unique_integer([:positive])}"

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
    assert has_element?(view, @form)
    view
  end

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  defp pressed(view, params),
    do: Map.merge(Map.take(EditorPost.marks(view), ["_bp_doc"]), params)

  # Copy field `name` as the field's menu does; the clipboard's JSON.
  defp copy_field(view, name) do
    render_hook(view, "desk-field-copy", %{"field" => name})
    assert_push_event(view, "desk:field-copied", %{json: json})
    json
  end

  defp paste_field(view, name, clip),
    do: render_hook(view, "desk-field-paste", pressed(view, %{"field" => name, "clip" => clip}))

  # Barkpark's own copy of a codelist field holding `value`.
  defp field_clip(value) do
    Jason.encode!(%{
      "type" => "sanityClipboardItem",
      "isDocument" => false,
      "schemaTypeName" => "codelist",
      "value" => value,
      "barkpark" => %{
        "kind" => "field",
        "field" => %{"name" => "subject", "sig" => "codelist", "value" => value}
      }
    })
  end

  test "Paste field: a copied code pastes into a codelist field of the same list", c do
    id = doc!(c, %{"subject" => "YFB", "subject2" => "FBA"})
    view = desk(c, id)

    clip = copy_field(view, "subject")
    paste_field(view, "subject2", clip)

    assert stored(c, id)["subject2"] == "YFB"
    assert stored(c, id)["subject"] == "YFB"
    assert :sys.get_state(view.pid).socket.assigns[:editor_form]["subject2"] == "YFB"
    refute_push_event(view, @toast, %{tone: "critical"})
  end

  test "Paste field: a code of another list is stored, as a typed unknown code is", c do
    id = doc!(c, %{"subject" => "YFB", "region" => "X1"})
    view = desk(c, id)

    paste_field(view, "region", copy_field(view, "subject"))

    assert stored(c, id)["region"] == "YFB"
  end

  test "Paste field: a codelist inside an object takes a copied code", c do
    id = doc!(c, %{"subject" => "YFB", "meta" => %{"code" => "FBA", "note" => "m"}})
    view = desk(c, id)

    clip =
      Jason.encode!(%{
        "type" => "sanityClipboardItem",
        "isDocument" => false,
        "schemaTypeName" => "object",
        "value" => %{"code" => "YFB"},
        "barkpark" => %{
          "kind" => "field",
          "field" => %{
            "name" => "meta",
            "sig" => "object:code=codelist,note=string",
            "value" => %{"code" => "YFB"}
          }
        }
      })

    paste_field(view, "meta", clip)

    assert stored(c, id)["meta"]["code"] == "YFB"
  end

  for {label, value} <- [
        {"a list", ["FBA", "YFB"]},
        {"a map", %{"code" => "FBA"}},
        {"a string over 64 characters", String.duplicate("F", 65)}
      ] do
    test "Paste field: #{label} is not a code, and is refused in words", c do
      id = doc!(c, %{"subject" => "FBA"})
      view = desk(c, id)

      paste_field(view, "subject", field_clip(unquote(Macro.escape(value))))

      assert_push_event(view, @toast, %{
        tone: "critical",
        title: "Invalid clipboard item",
        description: @not_code
      })

      assert stored(c, id)["subject"] == "FBA"
    end
  end

  test "Paste document: a copied document's codes paste into the codelist fields", c do
    from = doc!(c, %{"subject" => "YFB", "region" => "X2", "meta" => %{"code" => "YFB"}})
    to = doc!(c, %{"subject" => "FBA", "region" => "X1", "meta" => %{"code" => "FBA"}})

    source = desk(c, from)
    render_hook(source, "desk-doc-copy", %{})
    assert_push_event(source, "desk:doc-copied", %{json: json})

    view = desk(c, to)
    render_hook(view, "desk-doc-paste", pressed(view, %{"clip" => json}))

    assert stored(c, to)["subject"] == "YFB"
    assert stored(c, to)["region"] == "X2"
    assert stored(c, to)["meta"]["code"] == "YFB"
  end
end
