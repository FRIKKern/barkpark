defmodule BarkparkWeb.Studio.ArrayCodelistValueTest do
  @moduledoc """
  task-63404d06a6b5259d: an array of codelist values whose stored rows are
  not all codes (a number, an object, a list).

  Each row is a codelist control, and a control can only show a string: a
  row that is no code drew nothing picked and posted "" with every change of
  the form, so an edit to any other field turned `[7, {o: 1}, "A1"]` into
  `["", "", "A1"]`. That held in the old Studio and in the desk.

  The tests post the form as the browser does (`form/3` reads each control's
  posted value from the page) and read the store.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy

  @dataset "production"
  @codes [7, %{"o" => 1}, ["A1", "B2"], "A1"]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    flat = "onixedit:ac-flat-#{n}"

    {:ok, _} =
      Codelists.register("onixedit", flat, %{
        issue: "1",
        name: "Flat",
        values: [
          %{code: "A1", translations: [%{language: "eng", label: "A one"}]},
          %{code: "B2", translations: [%{language: "eng", label: "B two"}]}
        ]
      })

    type = "ac_book_#{n}"
    id = "ac-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Array codes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "codes",
              "title" => "Codes",
              "type" => "arrayOf",
              "of" => %{"name" => "code", "type" => "codelist", "codelistId" => flat}
            },
            %{"name" => "notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Book", "content" => %{"codes" => @codes}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "array-code-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "array-code", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     type: type,
     id: id,
     studio: "#{root}/#{type}/#{id}",
     desk: "#{root}/_desk/#{type};#{id}"}
  end

  defp open(c, surface) do
    {:ok, view, _} = live(c.conn, Map.fetch!(c, surface))
    if surface == :desk, do: render_async(view, 5_000)
    assert has_element?(view, "#editor-form")
    view
  end

  defp codes(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    (doc.content || %{})["codes"]
  end

  defp change(view, doc, target) do
    view
    |> form("#editor-form", %{"doc" => doc})
    |> render_change(%{"_target" => ["doc" | target]})
  end

  for surface <- [:studio, :desk] do
    test "#{surface}: an edit to another field keeps every row as stored", c do
      view = open(c, unquote(surface))
      change(view, %{"notes" => "typed"}, ["notes"])
      change(view, %{"notes" => "typed again"}, ["notes"])

      assert codes(c) == @codes
    end

    test "#{surface}: a pick in a code's row writes it, and the other rows stay", c do
      view = open(c, unquote(surface))
      change(view, %{"codes" => %{"3" => "B2"}}, ["codes", "3"])

      assert codes(c) == [7, %{"o" => 1}, ["A1", "B2"], "B2"]
    end

    test "#{surface}: a pick in a row that holds no code writes it, and the other rows stay",
         c do
      view = open(c, unquote(surface))
      change(view, %{"codes" => %{"1" => "B2"}}, ["codes", "1"])

      assert codes(c) == [7, "B2", ["A1", "B2"], "A1"]
    end
  end

  test "studio: the Save button's post, which names no field, keeps every row", c do
    view = open(c, :studio)

    view
    |> form("#editor-form", %{"doc" => %{"notes" => "saved"}})
    |> render_submit()

    assert codes(c) == @codes
  end
end
