defmodule BarkparkWeb.Studio.DeskRowContentKeysTest do
  @moduledoc """
  A Studio desk list page reads only the content keys its rows can show.

  A row shows the title column, the update time and what the schema's
  `list_preview` names. The page used to read and decode each document's
  whole `content` to show that. It now reads the top-level keys the spec's
  text names (`Content.Query`'s `{:named_in, text}`), and the rows come out
  as before. Synthetic fixtures only.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias BarkparkWeb.Studio.PaneBuilder

  @big String.duplicate("long body text ", 400)

  defp insert_schema!(attrs) do
    %SchemaDefinition{} |> SchemaDefinition.changeset(attrs) |> Repo.insert!()
  end

  defp create!(dataset, type, id, title, content) do
    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => title, "content" => content},
        dataset
      )

    {:ok, _} = Content.publish_document(id, type, dataset)
  end

  defp rows(dataset, type) do
    {panes, _editor} = PaneBuilder.build(dataset, [type])
    for %{type: :doc} = item <- List.last(panes).items, into: %{}, do: {item.id, item}
  end

  # Every SQL statement the block runs, in order.
  defp statements(fun) do
    me = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:barkpark, :repo, :query],
      fn _, _, meta, _ -> if self() == me, do: send(me, {:sql, meta.query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect([])
  end

  defp collect(acc) do
    receive do
      {:sql, q} -> collect([q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "row_content_keys/1" do
    test "names every string of every list_preview spec, and the manifest key" do
      schema = %{
        list_preview: %{
          "title" => %{"field" => "headline"},
          "subtitle" => %{"parts" => ["{kind|upper} · {info.code}"], "empty" => "none"},
          "description" => %{"each" => "tags", "show" => "label", "max" => 2},
          "badge" => %{"when" => %{"field" => "flagged", "equals" => true}, "show" => "Flag"},
          "media" => [%{"icon" => %{"path" => "shape", "map" => %{"round" => "circle"}}}]
        }
      }

      {:named_in, text} = PaneBuilder.row_content_keys(schema)

      for key <- ~w(preview headline kind info tags label flagged shape) do
        assert String.contains?(text, key), "#{key} is not named"
      end
    end

    test "a schema without a list_preview names the manifest key only" do
      assert PaneBuilder.row_content_keys(nil) == {:named_in, "preview"}
      assert PaneBuilder.row_content_keys(%{list_preview: nil}) == {:named_in, "preview"}
    end
  end

  test "rows show the same values while the page reads only the named keys" do
    dataset = "desk_row_keys_#{System.unique_integer([:positive])}"

    insert_schema!(%{
      name: "gizmo",
      title: "Gizmo",
      icon: "box",
      visibility: "public",
      dataset: dataset,
      fields: [
        %{"name" => "title", "type" => "string"},
        %{"name" => "kind", "type" => "string"},
        %{"name" => "info", "type" => "object"},
        %{"name" => "body", "type" => "text"}
      ],
      list_preview: %{
        "subtitle" => "{kind} · {info.code}",
        "badge" => %{"field" => "info.grade", "prefix" => "Grade "}
      }
    })

    create!(dataset, "gizmo", "g1", "First gizmo", %{
      "kind" => "lever",
      "info" => %{"code" => "L-1", "grade" => "A"},
      "body" => @big
    })

    create!(dataset, "gizmo", "g2", "Second gizmo", %{"body" => @big})

    rows = rows(dataset, "gizmo")
    assert rows["g1"].title == "First gizmo"
    assert rows["g1"].meta == "lever · L-1"
    assert rows["g1"].badge == "Grade A"
    assert rows["g2"].meta == nil
    assert rows["g2"].updated =~ "Updated"

    {:ok, schema} = Content.resolve_schema("gizmo", dataset, [])
    keys = PaneBuilder.row_content_keys(schema)

    {docs, false} =
      Content.list_documents_page("gizmo", dataset, perspective: :drafts, content_keys: keys)

    by_id = Map.new(docs, &{Content.published_id(&1.doc_id), &1})

    assert by_id["g1"].content == %{
             "kind" => "lever",
             "info" => %{"code" => "L-1", "grade" => "A"}
           }

    assert by_id["g2"].content == %{}
    assert by_id["g1"].title == "First gizmo"
  end

  test "a keyed page selects the content column only inside its projection" do
    dataset = "desk_row_sql_#{System.unique_integer([:positive])}"

    insert_schema!(%{
      name: "gizmo",
      title: "Gizmo",
      icon: "box",
      visibility: "public",
      dataset: dataset,
      fields: [%{"name" => "title", "type" => "string"}]
    })

    create!(dataset, "gizmo", "g1", "First gizmo", %{"kind" => "lever", "body" => @big})

    for keys <- [{:named_in, "kind"}, ["kind"]], perspective <- [:drafts, :raw] do
      sql =
        statements(fn ->
          Content.list_documents_page("gizmo", dataset,
            perspective: perspective,
            content_keys: keys
          )
        end)
        |> Enum.find(&String.contains?(&1, "jsonb_object_agg"))

      # Once, as the projection's input. A second `"content"` in the select
      # list would send and decode each whole value beside the projection.
      assert length(String.split(sql, ~s(0."content"))) - 1 == 1, sql
    end
  end
end
