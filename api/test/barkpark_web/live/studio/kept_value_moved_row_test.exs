defmodule BarkparkWeb.Studio.KeptValueMovedRowTest do
  @moduledoc """
  task-9dc943bf59b530fa: a "" posted for a codelist the page draws as kept
  (its stored value is no code, here 7) is written only when this post
  changes that input. `Fields.kept_value?/4` read the stored value at the
  POSTED index. After B moved the rows, that index held the other row, whose
  code is a string, so the "" was folded and written, by `_key`, over the
  kept 7 of the row it was posted for.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias Barkpark.Content.Codelists

  @moduletag :studio_live

  setup %{conn: conn} do
    c = setup_doc(conn)
    list = "onixedit:kv-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Codelists.register("onixedit", list, %{
        issue: "1",
        name: "Codes",
        values: [
          %{code: "A1", translations: [%{language: "eng", label: "A one"}]},
          %{code: "B2", translations: [%{language: "eng", label: "B two"}]}
        ]
      })

    type = c.type <> "-kv"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Kept rows",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "items",
              "title" => "Items",
              "type" => "arrayOf",
              "of" => [
                %{
                  "type" => "composite",
                  "name" => "item",
                  "title" => "Item",
                  "fields" => [
                    %{"name" => "name", "title" => "Name", "type" => "string"},
                    %{
                      "name" => "code",
                      "title" => "Code",
                      "type" => "codelist",
                      "codelistId" => list
                    }
                  ]
                }
              ]
            }
          ]
        },
        "production"
      )

    id = c.id <> "-kv"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T0",
          "content" => %{"items" => [item("r1", "alpha", "A1"), item("r2", "beta", "B2")]}
        },
        "production"
      )

    Map.merge(c, %{type: type, id: id})
  end

  defp item(key, name, code),
    do: %{"_type" => "item", "_key" => key, "name" => name, "code" => code}

  defp open_rows(c, surface) do
    path =
      case surface do
        :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
        :studio -> "#{c.root}/#{c.type}/#{c.id}"
      end

    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp put_items(c, items) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.put(doc.content, "items", items)
        },
        "production"
      )
  end

  # A post as the browser sends it: exactly these fields. A Save carries no `_target`.
  defp post(view, how, target, fields) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(view.pid).socket.assigns

    params =
      fields
      |> Map.merge(%{"doc[title]" => "T0"})
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.put(
        "_bp_doc",
        BarkparkWeb.Studio.StudioLive.PostIdentity.value(ds, d.type, d.doc_id)
      )

    {event, params} =
      if how == :auto,
        do: {"autosave", Map.put(params, "_target", [target])},
        else: {"save", params}

    render_hook(view, event, params)
  end

  # Two rows' inputs, named by their place on A's page.
  defp rows(r1, r2) do
    [r1, r2]
    |> Enum.with_index()
    |> Enum.flat_map(fn {{key, name, code}, i} ->
      [
        {"doc[items][#{i}]._type", "item"},
        {"doc[items][#{i}]._key", key},
        {"doc[items][#{i}].name", name},
        {"doc[items][#{i}].code", code}
      ]
    end)
    |> Map.new()
  end

  defp by_key(c), do: Map.new(stored(c)["items"], &{&1["_key"], {&1["name"], &1["code"]}})

  for surface <- [:desk, :studio], how <- [:auto, :save] do
    @tag timeout: 120_000
    test "#{surface} #{how}: B moves the rows; a touched \"\" for r2's kept code never blanks it",
         c do
      a = open_rows(c, unquote(surface))

      # A picks r2's code: the path is in A's touched set from here on.
      post(a, :auto, "doc[items][1].code", rows({"r1", "alpha", "A1"}, {"r2", "beta", "A1"}))
      assert by_key(c)["r2"] == {"beta", "A1"}

      # B gives r2 a number (an import): A's page draws it kept and posts "".
      put_items(c, [item("r1", "alpha", "A1"), item("r2", "beta", 7)])
      assert eventually(fn -> Enum.at(form(a)["items"], 1)["code"] == 7 end)

      # B moves r2 to the top; A's post below was sent before A's page took it.
      put_items(c, [item("r2", "beta", 7), item("r1", "alpha", "A1")])
      assert eventually(fn -> Enum.map(form(a)["items"], & &1["_key"]) == ["r2", "r1"] end)

      post(
        a,
        unquote(how),
        "doc[items][0].name",
        rows({"r1", "alpha A", "A1"}, {"r2", "beta", ""})
      )

      # On main: r2's code became "", read as unkept at index 1 (now r1).
      assert by_key(c) == %{"r1" => {"alpha A", "A1"}, "r2" => {"beta", 7}}
      assert Enum.map(stored(c)["items"], & &1["_key"]) == ["r2", "r1"]
    end
  end
end
