defmodule BarkparkWeb.Studio.KeptCodelistValueTest do
  @moduledoc """
  task-244b9a6f67d38779: a flat codelist (the `<select>`, and the combobox of
  a long flat list) over a stored value that is not a code: a number, an
  object, a list.

  The control can only show a string, so it drew none, and posted "" for the
  field with every change of the form: an edit to any OTHER field deleted
  the stored value. That held in the old Studio and in the desk, which both
  draw a top-level codelist through `Plugins.Adapter` and `CodelistField`.

  The tests post the form as the browser does (`form/3` reads each control's
  posted value from the page), with an edit to `notes` only, and read the
  store.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy

  @dataset "production"

  @values [number: 7, object: %{"code" => "A1"}, list: ["A1", "B2"]]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    flat = "onixedit:kc-flat-#{n}"
    long = "onixedit:kc-long-#{n}"

    {:ok, _} =
      Codelists.register("onixedit", flat, %{
        issue: "1",
        name: "Flat",
        values: [
          %{code: "A1", translations: [%{language: "eng", label: "A one"}]},
          %{code: "B2", translations: [%{language: "eng", label: "B two"}]}
        ]
      })

    # A flat list over the 100-entry threshold: the editor draws a combobox.
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

    type = "kc_book_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Kept codes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "flat", "title" => "Flat", "type" => "codelist", "codelistId" => flat},
            %{"name" => "long", "title" => "Long", "type" => "codelist", "codelistId" => long},
            %{"name" => "notes", "type" => "string"}
          ]
        },
        @dataset
      )

    docs =
      for {kind, value} <- @values, into: %{} do
        id = "kc-#{kind}-#{n}"

        {:ok, _} =
          Content.create_document(
            type,
            %{
              "doc_id" => id,
              "title" => "Book",
              "content" => %{"flat" => value, "long" => value}
            },
            @dataset
          )

        {kind, id}
      end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "kept-code-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "kept-code", @dataset, ~w(read write admin), ws_id)
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

  defp change(view, doc, target) do
    view
    |> form("#editor-form", %{"doc" => doc})
    |> render_change(%{"_target" => ["doc", target]})
  end

  for surface <- [:studio, :desk], {kind, value} <- @values do
    test "#{surface}, a stored #{kind}: an edit to another field keeps it in the select and the combobox",
         c do
      view = open(c, unquote(surface), unquote(kind))
      change(view, %{"notes" => "typed"}, "notes")

      assert stored(c, unquote(kind))["notes"] == "typed"
      assert stored(c, unquote(kind))["flat"] == unquote(Macro.escape(value))
      assert stored(c, unquote(kind))["long"] == unquote(Macro.escape(value))
    end
  end

  test "studio: the Save button's post, which names no field, keeps a stored object", c do
    view = open(c, :studio, :object)

    view
    |> form("#editor-form", %{"doc" => %{"notes" => "saved"}})
    |> render_submit()

    assert stored(c, :object)["notes"] == "saved"
    assert stored(c, :object)["flat"] == %{"code" => "A1"}
    assert stored(c, :object)["long"] == %{"code" => "A1"}
  end

  for surface <- [:studio, :desk] do
    test "#{surface}: the select says what is stored is not a code, and a pick or a clear still writes",
         c do
      view = open(c, unquote(surface), :object)

      assert [option] =
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(~s(select[name="doc[flat]"] option[selected]))
               |> Enum.to_list()

      assert LazyHTML.attribute(option, "data-codelist-kept") == ["true"]
      assert LazyHTML.text(option) =~ "Not a code"

      change(view, %{"flat" => "B2"}, "flat")
      assert stored(c, :object)["flat"] == "B2"
      # The other one is still not touched.
      assert stored(c, :object)["long"] == %{"code" => "A1"}

      change(view, %{"long" => "L7"}, "long")
      assert stored(c, :object)["long"] == "L7"

      change(view, %{"flat" => ""}, "flat")
      refute Map.has_key?(stored(c, :object), "flat")
    end

    test "#{surface}: choosing — Select — over what is stored clears it", c do
      view = open(c, unquote(surface), :number)
      change(view, %{"flat" => ""}, "flat")

      refute Map.has_key?(stored(c, :number), "flat")
      assert stored(c, :number)["long"] == 7
    end
  end
end
