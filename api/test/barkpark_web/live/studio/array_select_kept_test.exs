defmodule BarkparkWeb.Studio.ArraySelectKeptTest do
  @moduledoc """
  task-1f922079ee439e18 (found in the review of #27657, r2): an `arrayOf`
  select holding `[true, "b"]` was rewritten as `["b", "true"]` by an edit
  of another field, in both Studios. The checkbox list draws the stored
  values as text, in its own order, and the save read that post as an edit
  of the list.

  A post that holds the same values the form drew for the stored list is
  untouched, and the store keeps its bytes. A change of the list is still
  saved.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "arrsel_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Array select #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "arr",
              "title" => "Arr",
              "type" => "arrayOf",
              "of" => %{"name" => "s", "type" => "select", "options" => ["a", "b"]}
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "arrsel-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "arrsel", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     root: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type}
  end

  defp doc!(c, arr) do
    id = "arrsel-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => %{"arr" => arr, "notes" => "n0"}},
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

  # The draft row's `arr` as the store holds it, jsonb text.
  defp row_arr(c, id) do
    %{rows: [[text]]} =
      Barkpark.Repo.query!(
        "select (content->'arr')::text from documents where type = $1 and doc_id = $2 and dataset = $3",
        [c.type, "drafts." <> id, @dataset]
      )

    text
  end

  # The page's own post: every value the form holds, with `notes` typed.
  defp edit_notes(view, form, value) do
    view
    |> form(form, %{"doc" => %{"notes" => value}})
    |> render_change(%{"_target" => ["doc", "notes"]})
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: an edit elsewhere keeps a stored [true, \"b\"] byte-identical", c do
      id = doc!(c, [true, "b"])
      {view, form} = open(c, @surface, id)

      edit_notes(view, form, "typed")

      assert stored(c, id)["notes"] == "typed"
      assert stored(c, id)["arr"] === [true, "b"]
      assert row_arr(c, id) == ~s([true, "b"])
    end

    test "#{surface}: a list the form draws as it is stored is kept in its order", c do
      id = doc!(c, ["b", "a"])
      {view, form} = open(c, @surface, id)

      edit_notes(view, form, "typed")

      assert stored(c, id)["notes"] == "typed"
      assert stored(c, id)["arr"] === ["b", "a"]
    end

    test "#{surface}: ticking another option still saves the list", c do
      id = doc!(c, [true, "b"])
      {view, form} = open(c, @surface, id)

      view
      |> form(form, %{"doc" => %{"arr" => ["", "a", "b", "true"]}})
      |> render_change(%{"_target" => ["doc", "arr"]})

      assert stored(c, id)["arr"] == ["a", "b", "true"]
    end
  end
end
