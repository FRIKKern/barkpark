defmodule Barkpark.Content.ReferencedByTermsTest do
  @moduledoc """
  `referencedBy` / `notReferencedBy` on the referencing side
  (task-d99d878b061b435a, task-948233bb3443c675).

  * A referencing type whose schema has an `arrayOf` field with a LIST of
    member types (`of: [...]`, gyldendal.no's product.tilleggsressurser) used
    to raise ArgumentError from `get_in(f, ["of", "type"])`.
  * A reference nested inside an array of objects (product.series[].series)
    counts, like Sanity's `references()`.
  * The value takes several types (`article,event`), any type (`*`), or one
    field of one type (`tag.parentTags`).
  * The clause answers from the GIN indexes: 18,020 products and 1,000 series
    answer in well under a second.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"

  defp member_ctx,
    do: %CallerContext{
      principal_type: :api_token,
      token_id: Ecto.UUID.generate(),
      roles: ["read", "write", "admin"],
      is_admin: true
    }

  defp workspace(slug) do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "#{slug}-#{suffix}", name: slug})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    [workspace_id: ws.id, project_id: proj.id, caller_context: member_ctx()]
  end

  defp schema!(name, fields, scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => name,
          "title" => name,
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"} | fields]
        },
        @dataset,
        scope
      )
  end

  defp doc!(type, id, content, scope) do
    {:ok, d} =
      Content.upsert_document(
        type,
        %{"doc_id" => id, "status" => "published", "title" => id, "content" => content},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    d
  end

  defp ids(type, filter, scope) do
    type
    |> Content.list_documents(@dataset, [filter_map: filter, limit: 1000] ++ scope)
    |> Enum.map(& &1.title)
    |> Enum.sort()
  end

  defp by(value), do: %{"_id" => %{"referencedBy" => value}}
  defp not_by(value), do: %{"_id" => %{"notReferencedBy" => value}}

  # gyldendal.no's product, cut down: a multi-type array, a reference nested in
  # an array of objects, and a scalar reference stored as a bare id.
  @product_fields [
    %{
      "name" => "tilleggsressurser",
      "type" => "arrayOf",
      "of" => [
        %{
          "name" => "lenke",
          "type" => "composite",
          "fields" => [%{"name" => "url", "type" => "url"}]
        },
        %{
          "name" => "fil",
          "type" => "composite",
          "fields" => [%{"name" => "file", "type" => "file"}]
        }
      ]
    },
    %{
      "name" => "series",
      "type" => "arrayOf",
      "of" => %{
        "type" => "composite",
        "fields" => [
          %{"name" => "series", "type" => "reference", "to" => [%{"type" => "series"}]}
        ]
      }
    },
    %{"name" => "department", "type" => "reference", "to" => [%{"type" => "department"}]},
    %{
      "name" => "related",
      "type" => "arrayOf",
      "of" => [
        %{"type" => "reference", "to" => [%{"type" => "series"}]},
        %{
          "name" => "note",
          "type" => "composite",
          "fields" => [%{"name" => "text", "type" => "string"}]
        }
      ]
    }
  ]

  describe "the referencing type has a multi-type arrayOf field" do
    setup do
      scope = workspace("refby-multi")
      schema!("series", [], scope)
      schema!("department", [], scope)
      schema!("product", @product_fields, scope)

      doc!("series", "series.a", %{}, scope)
      doc!("series", "series.b", %{}, scope)
      doc!("series", "series.c", %{}, scope)
      doc!("department", "dep.used", %{}, scope)
      doc!("department", "dep.idle", %{}, scope)

      doc!(
        "product",
        "p1",
        %{
          "tilleggsressurser" => [%{"_type" => "lenke", "url" => "https://example.org"}],
          "series" => [
            %{"_key" => "k1", "series" => %{"_ref" => "series.a", "_type" => "reference"}}
          ],
          "department" => "dep.used"
        },
        scope
      )

      # A bare id in a multi-type array that may hold a series reference.
      doc!("product", "p2", %{"related" => ["series.b"]}, scope)

      {:ok, scope: scope}
    end

    test "referencedBy does not crash and finds a reference nested in an array of objects",
         %{scope: scope} do
      assert ids("series", by("product"), scope) == ["series.a", "series.b"]
      assert ids("series", not_by("product"), scope) == ["series.c"]
    end

    test "a bare id in a scalar reference field still counts", %{scope: scope} do
      assert ids("department", by("product"), scope) == ["dep.used"]
      assert ids("department", not_by("product"), scope) == ["dep.idle"]
    end

    test "filter[_references] on the same type no longer crashes", %{scope: scope} do
      assert ids("product", %{"_references" => "series.a"}, scope) == ["p1"]
    end

    test "a draft series is matched on its published id", %{scope: scope} do
      doc!("product", "p3", %{"series" => [%{"series" => %{"_ref" => "series.c"}}]}, scope)

      drafts =
        Content.list_documents("series", @dataset, [filter_map: by("product")] ++ scope)
        |> Enum.map(& &1.doc_id)

      assert "drafts.series.c" in drafts
    end
  end

  describe "several types, any type, one field" do
    setup do
      scope = workspace("refby-terms")

      schema!(
        "tag",
        [
          %{
            "name" => "parentTags",
            "type" => "arrayOf",
            "of" => %{"type" => "reference", "to" => ["tag"]}
          },
          %{"name" => "mainTag", "type" => "reference", "to" => ["tag"]}
        ],
        scope
      )

      schema!(
        "article",
        [
          %{
            "name" => "tags",
            "type" => "arrayOf",
            "of" => %{"type" => "reference", "to" => ["tag"]}
          }
        ],
        scope
      )

      schema!(
        "event",
        [
          %{
            "name" => "tags",
            "type" => "arrayOf",
            "of" => %{"type" => "reference", "to" => ["tag"]}
          }
        ],
        scope
      )

      schema!("page", [%{"name" => "body", "type" => "array"}], scope)

      for id <- ~w(t.art t.evt t.page t.group t.main t.none), do: doc!("tag", id, %{}, scope)

      doc!("article", "a1", %{"tags" => [%{"_ref" => "t.art"}]}, scope)
      doc!("event", "e1", %{"tags" => ["t.evt"]}, scope)
      # A page links a tag deep inside portable text, with no declared field.
      doc!(
        "page",
        "pg1",
        %{"body" => [%{"children" => [%{"tag" => %{"_ref" => "t.page"}}]}]},
        scope
      )

      doc!(
        "tag",
        "t.child",
        %{"parentTags" => [%{"_ref" => "t.group"}], "mainTag" => "t.main"},
        scope
      )

      {:ok, scope: scope}
    end

    test "a comma list counts references from any of the types", %{scope: scope} do
      assert ids("tag", by("article"), scope) == ["t.art"]
      assert ids("tag", by("article,event"), scope) == ["t.art", "t.evt"]
      assert ids("tag", by(["article", "event"]), scope) == ["t.art", "t.evt"]
      assert ids("tag", by(" article , event "), scope) == ["t.art", "t.evt"]
    end

    test "* counts a reference from any type, at any depth", %{scope: scope} do
      assert ids("tag", by("*"), scope) == ["t.art", "t.evt", "t.group", "t.main", "t.page"]
      assert ids("tag", not_by("*"), scope) == ["t.child", "t.none"]
    end

    test "type.field counts only that field", %{scope: scope} do
      # tag as a whole points at both t.group (parentTags) and t.main (mainTag).
      assert ids("tag", by("tag"), scope) == ["t.group", "t.main"]
      assert ids("tag", by("tag.parentTags"), scope) == ["t.group"]
      assert ids("tag", by("tag.mainTag"), scope) == ["t.main"]
      assert "t.group" not in ids("tag", not_by("tag.parentTags"), scope)
      assert "t.main" in ids("tag", not_by("tag.parentTags"), scope)
    end

    test "fields and types mix in one list", %{scope: scope} do
      assert ids("tag", by("tag.parentTags,event"), scope) == ["t.evt", "t.group"]
    end

    test "an unknown type or field is a refusal that names it", %{scope: scope} do
      for {value, message} <- [
            {"artcle", "names no document type"},
            {"article,nope", "names no document type"},
            {"tag.parentTag", "names no field \"parentTag\""},
            {"*.tags", "names no document type"}
          ] do
        e =
          assert_raise Barkpark.Content.InvalidFilterError, fn ->
            Content.list_documents("tag", @dataset, [filter_map: by(value)] ++ scope)
          end

        assert e.message =~ message
      end
    end

    test "a blank term is a refusal", %{scope: scope} do
      for bad <- ["article,", ",", [], ["article", ""], ["article", 7]] do
        assert_raise Barkpark.Content.InvalidFilterError, fn ->
          Content.list_documents("tag", @dataset, [filter_map: by(bad)] ++ scope)
        end
      end
    end

    test "check_filter reports the same refusals without reading documents", %{scope: scope} do
      assert :ok = Content.Query.check_filter("tag", @dataset, by("article,event"), scope)

      assert {:error, reason} = Content.Query.check_filter("tag", @dataset, by("nope"), scope)
      assert reason =~ "\"_id\""
      assert reason =~ "names no document type"
    end
  end

  describe "a large dataset" do
    @products 18_020
    @series 1_000

    setup do
      scope = workspace("refby-large")
      schema!("series", [], scope)
      schema!("department", [], scope)
      schema!("product", @product_fields, scope)

      # One row through the write path to learn the scope columns a row gets.
      seed = doc!("series", "series.0", %{}, scope)
      now = DateTime.utc_now()

      row = fn type, id, content ->
        %{
          doc_id: id,
          type: type,
          dataset: seed.dataset,
          dataset_id: seed.dataset_id,
          workspace_id: seed.workspace_id,
          project_id: seed.project_id,
          title: id,
          status: "published",
          content: content,
          rev: "rev-" <> id,
          inserted_at: now,
          updated_at: now
        }
      end

      series = for i <- 1..(@series - 1), do: row.("series", "series.#{i}", %{})

      # Every product points at one of the EVEN series, so half the series are
      # referenced; series.0 is referenced only by a bare id below.
      products =
        for i <- 1..@products do
          s = rem(i * 2, @series)

          row.("product", "product.#{i}", %{
            "tilleggsressurser" => [%{"_type" => "lenke", "url" => "https://example.org/#{i}"}],
            "series" => [%{"_key" => "k", "series" => %{"_ref" => "series.#{max(s, 2)}"}}],
            "department" => %{"_ref" => "dep.#{rem(i, 5)}"}
          })
        end

      for chunk <- Enum.chunk_every(series ++ products, 2_000),
          do: Repo.insert_all(Document, chunk)

      doc!("product", "product.bare", %{"related" => ["series.0"]}, scope)
      Repo.query!("ANALYZE documents")

      # A bulk insert lands in the GIN indexes' pending lists, which every
      # probe scans in full until (auto)vacuum merges them. Merge them now, as
      # autovacuum would on a live server, so the test times the index itself.
      for index <- ~w(documents_content_refs_idx documents_content_path_idx) do
        Repo.query!("SELECT gin_clean_pending_list($1::text::regclass)", [index])
      end

      {:ok, scope: scope}
    end

    @tag timeout: 300_000
    test "referencedBy and its negation answer in well under a second", %{scope: scope} do
      count = fn filter ->
        Content.count_documents("series", @dataset, [filter_map: filter] ++ scope)
      end

      # Warm the schema memo and the plan once.
      _ = count.(by("product"))

      {us_used, used} = :timer.tc(fn -> count.(by("product")) end)
      {us_unused, unused} = :timer.tc(fn -> count.(not_by("product")) end)

      # Even series 2..998 (499) plus series.0 through the bare id.
      assert used == 500
      assert unused == @series - 500
      assert used + unused == @series

      assert us_used < 1_000_000, "referencedBy took #{div(us_used, 1000)} ms"
      assert us_unused < 1_000_000, "notReferencedBy took #{div(us_unused, 1000)} ms"

      {us_page, page} =
        :timer.tc(fn ->
          Content.list_documents_page(
            "series",
            @dataset,
            [filter_map: not_by("product"), perspective: :drafts, limit: 50] ++ scope
          )
        end)

      assert {[_ | _], true} = page
      assert us_page < 1_000_000, "a desk page took #{div(us_page, 1000)} ms"

      IO.puts(
        "referencedBy over #{@products} products and #{@series} series: " <>
          "#{div(us_used, 1000)} ms, notReferencedBy #{div(us_unused, 1000)} ms, " <>
          "desk page #{div(us_page, 1000)} ms"
      )
    end
  end
end
