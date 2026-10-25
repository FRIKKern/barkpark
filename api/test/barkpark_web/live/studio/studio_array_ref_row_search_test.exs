defmodule BarkparkWeb.Studio.StudioArrayRefRowSearchTest do
  @moduledoc """
  task-03b2805eda66cef7: typing in the picker of a new, empty arrayOf
  reference row did not search. The row's `bp-reference-picker` sits in a
  `phx-update="ignore"` wrapper whose id hashes the row value, and the picker
  left the DOM within a second of typing: LiveView swapped the wrapper.

  A row keeps its wrapper, and so its picker and the editor's half-typed
  search, while the document saves around it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for {name, fields} <- [
          {"meetup",
           [
             %{"name" => "title", "title" => "Title", "type" => "string"},
             %{
               "name" => "relatedBooks",
               "title" => "Related books",
               "type" => "arrayOf",
               "of" => %{"type" => "reference", "refType" => "book"}
             }
           ]},
          {"book", [%{"name" => "title", "title" => "Title", "type" => "string"}]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
          @dataset,
          scope
        )
    end

    doc_id = "meetup-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "meetup",
        %{"_id" => doc_id, "title" => "Lesekveld"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "meetup", @dataset, scope)

    raw = "array-ref-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "array-ref", @dataset, ["read", "write"], ws.id)
    conn = scoped_conn() |> Plug.Test.init_test_session(%{"api_token" => raw})
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/meetup/#{doc_id}"))

    %{view: view}
  end

  defp row_ids(html),
    do: Regex.scan(~r/id="(bp-aref-relatedBooks-[^"]+?)(?<!-h)"/, html, capture: :all_but_first)

  defp add_row(view) do
    view
    |> element(~s([phx-value-action="add_row"][phx-value-field="relatedBooks"]))
    |> render_click()
  end

  test "an empty row keeps its wrapper id when the form saves its empty value", %{view: view} do
    html = add_row(view)
    assert [[id]] = row_ids(html)

    # The browser posts the row's hidden input, which holds "", with every
    # autosave, here one from the title.
    html =
      render_change(view, "autosave", %{
        "_target" => ["doc", "title"],
        "doc" => %{"title" => "Lesekveld i biblioteket", "relatedBooks" => %{"0" => ""}}
      })

    assert row_ids(html) == [[id]],
           "the empty row's picker was replaced while the editor could be typing in it"
  end

  test "a row's wrapper id follows its picked value", %{view: view} do
    add_row(view)

    html =
      render_change(view, "autosave", %{
        "_target" => ["doc", "relatedBooks", "0"],
        "doc" => %{"title" => "Lesekveld", "relatedBooks" => %{"0" => "book-a"}}
      })

    [[picked]] = row_ids(html)

    html =
      render_change(view, "autosave", %{
        "_target" => ["doc", "relatedBooks", "0"],
        "doc" => %{"title" => "Lesekveld", "relatedBooks" => %{"0" => "book-b"}}
      })

    [[repicked]] = row_ids(html)
    refute picked == repicked, "a new pick remounts the picker with the new value"
  end
end
