defmodule Barkpark.Content.EdgesRichtextTest do
  @moduledoc """
  task-e13285602dccceca — a richText field's STRUCTURAL references now
  contribute to the content graph (backlinks + the unpublish/delete guard),
  per team-lead's ruling written to the row: a markDef/annotation, inline
  object, or custom object block carrying a `_ref`, OR a declared
  reference-typed field inside a custom object block's own schema, PLUS a
  wikilink resolving to a doc id. NOT a plain URL link (href only).

  `extract_field_edges/2` previously had no clause for `"type" => "richText"`
  at all — found during the task-839f9bebf5628c03 grep audit (#22576): not a
  wrong-shape bug, an absence. Every test here exercises BOTH live value
  shapes a richText field holds (a bare list, and the block-editor's
  `%{"blocks", "html"}` wrapper — task-839f9bebf5628c03/#22575/#22576), since
  `BlockOps.field_blocks/1` is what the new clause reads through.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.EdgeProjector.Projector

  @dataset "edges_richtext_test"

  @callout %{
    "name" => "callout",
    "fields" => [
      %{"name" => "linkedDoc", "type" => "reference", "refType" => "person"},
      %{"name" => "tone", "type" => "string"}
    ]
  }

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "person", "title" => "Person", "visibility" => "public", "fields" => []},
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "article",
          "title" => "Article",
          "visibility" => "public",
          "fields" => [
            %{
              "name" => "body",
              "type" => "richText",
              "editor" => "blocks",
              "blocks" => %{"of" => ["image", @callout]}
            }
          ]
        },
        @dataset
      )

    :ok
  end

  defp publish!(type, id, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), @dataset)

    {:ok, doc} = Content.publish_document(id, type, @dataset)
    doc
  end

  defp para(text),
    do: %{
      "id" => "p1",
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => text}]
    }

  defp annotation_ref(target),
    do: %{
      "id" => "p2",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "text",
          "value" => "see also",
          "marks" => [%{"_type" => "internalLink", "_ref" => target}]
        }
      ]
    }

  defp wikilink(target),
    do: %{"id" => "p3", "type" => "wikilink", "target" => target}

  defp href_only(url),
    do: %{"id" => "p4", "type" => "paragraph", "content" => [%{"type" => "text", "href" => url}]}

  defp callout_ref(target),
    do: %{"id" => "p5", "type" => "callout", "linkedDoc" => target, "tone" => "info"}

  defp to_ids(edges), do: edges |> Enum.map(& &1.to_id) |> Enum.sort()

  describe "extract_edges/2 — bare list shape" do
    test "a markDef/annotation carrying _ref is extracted" do
      publish!("person", "ada")
      body = [para("hi"), annotation_ref("ada")]
      src = publish!("article", "art-bare-ref", %{"body" => body})

      assert [%{to_id: "ada", field: "body", dangling: false}] = Content.extract_edges(src)
    end

    test "a wikilink resolving to a doc id is extracted" do
      publish!("person", "ada")
      body = [para("hi"), wikilink("ada")]
      src = publish!("article", "art-bare-wiki", %{"body" => body})

      assert [%{to_id: "ada", field: "body"}] = Content.extract_edges(src)
    end

    test "a plain href-only link is NOT extracted" do
      body = [para("hi"), href_only("https://example.com")]
      src = publish!("article", "art-bare-href", %{"body" => body})

      assert Content.extract_edges(src) == []
    end

    test "a custom object block's declared reference field (bare string id) is extracted" do
      publish!("person", "ada")
      body = [para("hi"), callout_ref("ada")]
      src = publish!("article", "art-bare-callout", %{"body" => body})

      assert [%{to_id: "ada", field: "body"}] = Content.extract_edges(src)
    end

    test "a reference to a missing target is dangling" do
      body = [annotation_ref("ghost")]
      src = publish!("article", "art-bare-dangling", %{"body" => body})

      assert [%{to_id: "ghost", dangling: true}] = Content.extract_edges(src)
    end

    test "every structural source in one body is extracted, deduped targets kept distinct" do
      publish!("person", "ada")
      publish!("person", "bob")
      body = [annotation_ref("ada"), wikilink("bob"), callout_ref("ada"), href_only("https://x")]
      src = publish!("article", "art-bare-multi", %{"body" => body})

      assert to_ids(Content.extract_edges(src)) == ["ada", "ada", "bob"]
    end
  end

  describe "extract_edges/2 — the %{\"blocks\" => [...]} wrapper shape" do
    test "the SAME extraction holds when body is wrapped" do
      publish!("person", "ada")
      wrapped = %{"blocks" => [para("hi"), annotation_ref("ada")], "html" => "<p>hi</p>"}
      src = publish!("article", "art-wrap-ref", %{"body" => wrapped})

      assert [%{to_id: "ada", field: "body", dangling: false}] = Content.extract_edges(src)
    end

    test "a wikilink is extracted from the wrapped shape too" do
      publish!("person", "ada")
      wrapped = %{"blocks" => [wikilink("ada")], "html" => ""}
      src = publish!("article", "art-wrap-wiki", %{"body" => wrapped})

      assert [%{to_id: "ada", field: "body"}] = Content.extract_edges(src)
    end

    test "a custom block's reference field is extracted from the wrapped shape too" do
      publish!("person", "ada")
      wrapped = %{"blocks" => [callout_ref("ada")], "html" => ""}
      src = publish!("article", "art-wrap-callout", %{"body" => wrapped})

      assert [%{to_id: "ada", field: "body"}] = Content.extract_edges(src)
    end

    test "a plain href-only link in the wrapped shape is still NOT extracted" do
      wrapped = %{"blocks" => [href_only("https://example.com")], "html" => ""}
      src = publish!("article", "art-wrap-href", %{"body" => wrapped})

      assert Content.extract_edges(src) == []
    end
  end

  describe "the projector — edge removal when the ref is edited out" do
    test "PRUNES a richText-sourced edge once the reference is removed from the body" do
      publish!("person", "ada")
      src = publish!("article", "art-prune", %{"body" => [annotation_ref("ada")]})

      {:ok, _} = Projector.upsert_record(src, dataset: @dataset)

      assert [%{from_doc_id: "art-prune"}] =
               Content.Graph.reverse_referencers("ada", dataset: @dataset)

      # Edit the PUBLISHED row's content directly (the update/patch funnel) —
      # the reference is gone from the new body.
      {:ok, edited} =
        Content.upsert_document(
          "article",
          %{
            "doc_id" => "art-prune",
            "title" => "art-prune",
            "content" => %{"body" => [para("no more refs")]}
          },
          @dataset
        )

      {:ok, _} = Projector.upsert_record(edited, dataset: @dataset)

      assert Content.Graph.reverse_referencers("ada", dataset: @dataset) == []
    end
  end
end
