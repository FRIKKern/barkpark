defmodule BarkparkWeb.Studio.NestedCodelistValueTest do
  @moduledoc """
  task-ab428bfe4bb189f9: a codelist inside an object field over a stored
  value that is not a code (a number, an object, a list).

  Only a top-level field's value was made a string before `CodelistField`
  drew it (`Plugins.Adapter`); an object's subfield came raw. The combobox of
  a long flat list put the raw value in its `value` attribute: an object
  raised `Protocol.UndefinedError` there, so the old Studio could not open
  the document and the desk's process died. A list was drawn as its codes
  run together ("A1B2") and posted back as that string on the next edit.

  The tests open the document in each Studio, post the form as the browser
  does with an edit to `notes`, and read the store.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy

  @dataset "production"

  @values [number: 7, object: %{"o" => 1}, list: ["A1", "B2"]]
  # An object field per variant: the select (2 codes), the combobox (a flat
  # list over 100) and the tree (a parent over 100 codes).
  @objects ~w(meta metalong metatree)

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    flat = "onixedit:nc-flat-#{n}"
    long = "onixedit:nc-long-#{n}"
    tree = "onixedit:nc-tree-#{n}"

    {:ok, _} =
      Codelists.register("onixedit", flat, %{
        issue: "1",
        name: "Flat",
        values: [
          %{code: "A1", translations: [%{language: "eng", label: "A one"}]},
          %{code: "B2", translations: [%{language: "eng", label: "B two"}]}
        ]
      })

    {:ok, _} =
      Codelists.register("onixedit", long, %{
        issue: "1",
        name: "Long",
        values:
          for(
            i <- 1..120,
            do: %{code: "L#{i}", translations: [%{language: "eng", label: "Long #{i}"}]}
          )
      })

    {:ok, _} =
      Codelists.register("onixedit", tree, %{
        issue: "1",
        name: "Tree",
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

    object = fn name, list_id ->
      %{
        "name" => name,
        "title" => name,
        "type" => "composite",
        "fields" => [
          %{"name" => "code", "title" => "Code", "type" => "codelist", "codelistId" => list_id},
          %{"name" => "label", "title" => "Label", "type" => "string"}
        ]
      }
    end

    type = "nc_book_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Nested codes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            object.("meta", flat),
            object.("metalong", long),
            object.("metatree", tree),
            %{"name" => "notes", "type" => "string"}
          ]
        },
        @dataset
      )

    docs =
      for {kind, value} <- @values, into: %{} do
        id = "nc-#{kind}-#{n}"
        content = Map.new(@objects, &{&1, %{"code" => value, "label" => "x"}})

        {:ok, _} =
          Content.create_document(
            type,
            %{"doc_id" => id, "title" => "Book", "content" => content},
            @dataset
          )

        {kind, id}
      end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "nested-code-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "nested-code", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, root: root, type: type, docs: docs}
  end

  defp address(c, :studio, kind), do: "#{c.root}/#{c.type}/#{c.docs[kind]}"
  defp address(c, :desk, kind), do: "#{c.root}/_desk/#{c.type};#{c.docs[kind]}"

  defp open(c, surface, kind) do
    {:ok, view, _} = live(c.conn, address(c, surface, kind))
    if surface == :desk, do: render_async(view, 5_000)
    assert has_element?(view, "#editor-form")
    view
  end

  defp stored(c, kind) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.docs[kind], @dataset)
    doc.content || %{}
  end

  for surface <- [:studio, :desk], {kind, value} <- @values do
    test "#{surface}, a stored #{kind} in an object's codelist: the document opens, and an edit to another field keeps it",
         c do
      view = open(c, unquote(surface), unquote(kind))

      view
      |> form("#editor-form", %{"doc" => %{"notes" => "typed"}})
      |> render_change(%{"_target" => ["doc", "notes"]})

      assert Process.alive?(view.pid)
      assert stored(c, unquote(kind))["notes"] == "typed"

      for name <- @objects do
        assert stored(c, unquote(kind))[name] == %{
                 "code" => unquote(Macro.escape(value)),
                 "label" => "x"
               },
               name
      end
    end
  end

  for surface <- [:studio, :desk] do
    test "#{surface}: a pick in an object's combobox or select over a stored object still writes",
         c do
      view = open(c, unquote(surface), :object)

      assert has_element?(
               view,
               ~s(input[name="doc[metalong].code"][data-codelist-kept="true"][value=""])
             )

      view
      |> form("#editor-form", %{"doc[metalong].code" => "L7"})
      |> render_change(%{"_target" => ["doc[metalong].code"]})

      assert stored(c, :object)["metalong"] == %{"code" => "L7", "label" => "x"}

      view
      |> form("#editor-form", %{"doc[meta].code" => "B2"})
      |> render_change(%{"_target" => ["doc[meta].code"]})

      assert stored(c, :object)["meta"] == %{"code" => "B2", "label" => "x"}
      assert stored(c, :object)["metatree"] == %{"code" => %{"o" => 1}, "label" => "x"}
    end
  end
end
