defmodule BarkparkWeb.Studio.ListPreviewObjectPathsTest do
  @moduledoc """
  task-86b6aa7ee423ecaf: every `list_preview` key reads a field inside an
  object. `subtitle` and `description` already walked dotted paths through
  `PreviewText`; `title`, `badge` and `meta` read a top-level key only. They
  now walk into objects too, such as `slug.current` or `info.format`. A field
  whose own name holds a dot still reads as written. Synthetic fixtures only.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{PreviewText, SchemaDefinition, TitleDerivation}
  alias BarkparkWeb.Studio.PaneBuilder

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

  describe "PreviewText.field_value/2" do
    test "walks into objects and list items, and follows no reference" do
      content = %{
        "slug" => %{"current" => "spring-fair"},
        "info" => %{"formats" => [%{"code" => "BB"}]},
        "owner" => %{"_ref" => "person-1"}
      }

      assert PreviewText.field_value(content, "slug.current") == "spring-fair"
      assert PreviewText.field_value(content, "info.formats.0.code") == "BB"
      assert PreviewText.field_value(content, "owner.name") == nil
      assert PreviewText.field_value(content, "slug.missing") == nil
      assert PreviewText.field_value(nil, "slug.current") == nil
    end

    test "a key that matches the path as written wins" do
      assert PreviewText.field_value(%{"a.b" => "flat", "a" => %{"b" => "deep"}}, "a.b") ==
               "flat"
    end
  end

  test "a page's subtitle shows /slug.current" do
    dataset = "lp_paths_page"

    insert_schema!(%{
      name: "landing",
      title: "Landing",
      icon: "file",
      visibility: "public",
      dataset: dataset,
      fields: [
        %{"name" => "title", "type" => "string"},
        %{"name" => "slug", "type" => "slug"}
      ],
      list_preview: %{"subtitle" => %{"parts" => ["/{slug.current}"], "empty" => "No slug"}}
    })

    create!(dataset, "landing", "l1", "Spring fair", %{"slug" => %{"current" => "spring-fair"}})
    create!(dataset, "landing", "l2", "Draft page", %{})

    rows = rows(dataset, "landing")
    assert rows["l1"].meta == "/spring-fair"
    assert rows["l2"].meta == "No slug"
  end

  test "badge and meta read a field inside an object" do
    dataset = "lp_paths_badge"

    insert_schema!(%{
      name: "gadget",
      title: "Gadget",
      icon: "box",
      visibility: "public",
      dataset: dataset,
      fields: [
        %{"name" => "title", "type" => "string"},
        %{"name" => "info", "type" => "object"}
      ],
      list_preview: %{
        "badge" => "info.state",
        "meta" => %{"field" => "info.code", "prefix" => "#"}
      }
    })

    create!(dataset, "gadget", "g1", "Widget", %{"info" => %{"state" => "ready", "code" => 42}})
    create!(dataset, "gadget", "g2", "Gizmo", %{"info" => %{}})

    rows = rows(dataset, "gadget")
    assert rows["g1"].badge == "ready"
    assert rows["g1"].meta == "#42"
    assert rows["g2"].badge == nil
    assert rows["g2"].meta == nil
  end

  test "list_preview.title reads a field inside an object" do
    schema = %{
      "name" => "person",
      "fields" => [%{"name" => "name", "type" => "object"}],
      "list_preview" => %{"title" => "name.full"}
    }

    attrs = %{"content" => %{"name" => %{"full" => "Ada Example"}}}
    assert TitleDerivation.derive(attrs, schema)["title"] == "Ada Example"

    doc = %{title: nil, content: %{"name" => %{"full" => "Ada Example"}}}
    assert TitleDerivation.preview_title(doc, schema) == "Ada Example"
  end
end
