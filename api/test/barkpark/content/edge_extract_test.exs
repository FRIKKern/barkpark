defmodule Barkpark.Content.EdgeExtractTest do
  @moduledoc """
  Phase 2 — `Barkpark.Content.extract_edges/2` over reference fields.

  Five surfaces (per the brief's VERIFY gate):

    1. Scalar `reference` field WITH refType → edge resolved via the typed
       `get_document(to_id, refType, ...)` path; not dangling when the target
       exists.
    2. Scalar `reference` field WITHOUT refType → resolved via the UNTYPED path
       (type-agnostic `Repo.exists?`, mirroring `reference_title/4`); NOT
       falsely flagged dangling when a real target exists under ANY type. This
       is the gap-#2 regression lock — a nil refType must NOT call
       `get_document` with a nil type.
    3. arrayOf-of-reference (`task.attachments` shape: bare-id string array) →
       ONE edge per `List.wrap` element.
    4. A target that exists ONLY as `drafts.X` → flagged dangling for the
       `:published` lens (published twin does not exist).
    5. A draft SOURCE (`drafts.A`) is coalesced to `A` — never a from_id.

  Runs against the test DB (Postgres on :5432).
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Edge

  @dataset "edge_extract_test"

  setup do
    # `author` — a plain target type with a title (for the typed path).
    Content.upsert_schema(
      %{
        "name" => "author",
        "title" => "Author",
        "visibility" => "public",
        "fields" => []
      },
      @dataset
    )

    # `mediaAsset` — target type for the arrayOf-of-reference attachments.
    Content.upsert_schema(
      %{
        "name" => "mediaAsset",
        "title" => "Media Asset",
        "visibility" => "public",
        "fields" => []
      },
      @dataset
    )

    # `note` — a second type sharing nothing, used to prove the UNTYPED path
    # resolves a target under ANY type when refType is absent.
    Content.upsert_schema(
      %{
        "name" => "note",
        "title" => "Note",
        "visibility" => "public",
        "fields" => []
      },
      @dataset
    )

    # `article` carries three reference shapes:
    #   - typed scalar reference (refType "author")
    #   - UNTYPED scalar reference (no refType key)
    #   - arrayOf-of-reference (attachments → mediaAsset, the task shape)
    Content.upsert_schema(
      %{
        "name" => "article",
        "title" => "Article",
        "visibility" => "public",
        "fields" => [
          %{"name" => "author", "type" => "reference", "refType" => "author"},
          %{"name" => "mentions", "type" => "reference"},
          %{
            "name" => "attachments",
            "type" => "arrayOf",
            "of" => %{"type" => "reference", "refType" => "mediaAsset"}
          }
        ]
      },
      @dataset
    )

    :ok
  end

  # Create + publish a document so it exists under the :published lens.
  defp publish!(type, id, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(
        type,
        Map.merge(%{"_id" => id, "title" => id}, attrs),
        @dataset
      )

    {:ok, doc} = Content.publish_document(id, type, @dataset)
    doc
  end

  # Create a DRAFT only (no publish) — exists solely as drafts.<id>.
  defp draft_only!(type, id, attrs \\ %{}) do
    {:ok, doc} =
      Content.create_document(
        type,
        Map.merge(%{"_id" => id, "title" => id}, attrs),
        @dataset
      )

    doc
  end

  describe "(1) scalar reference WITH refType" do
    test "resolves via the typed get_document path; not dangling when target exists" do
      publish!("author", "auth-1")
      src = publish!("article", "art-1", %{"author" => "auth-1"})

      edges = Content.extract_edges(src)

      edge = Enum.find(edges, &(&1.field == "author"))
      assert edge.from_id == "art-1"
      assert edge.to_id == "auth-1"
      assert edge.kind == "references"
      assert edge.refType == "author"
      refute edge.dangling
    end

    test "flags dangling when the typed target does not exist" do
      src = publish!("article", "art-missing", %{"author" => "ghost-author"})

      edge = Content.extract_edges(src) |> Enum.find(&(&1.field == "author"))
      assert edge.to_id == "ghost-author"
      assert edge.dangling
    end
  end

  describe "(2) scalar reference WITHOUT refType (untyped path)" do
    test "resolves via the untyped Repo.exists? path when target exists under ANY type" do
      # Target exists only as a `note` — refType is absent on the `mentions`
      # field, so resolution must be type-agnostic and find it anyway.
      publish!("note", "note-1")
      src = publish!("article", "art-untyped", %{"mentions" => "note-1"})

      edge = Content.extract_edges(src) |> Enum.find(&(&1.field == "mentions"))
      assert edge.to_id == "note-1"
      assert edge.refType in [nil, ""]
      refute edge.dangling, "untyped ref to a real target must NOT be dangling"
    end

    test "flags dangling when no document anywhere matches the untyped ref" do
      src = publish!("article", "art-untyped-missing", %{"mentions" => "nowhere"})

      edge = Content.extract_edges(src) |> Enum.find(&(&1.field == "mentions"))
      assert edge.to_id == "nowhere"
      assert edge.dangling
    end
  end

  describe "(3) arrayOf-of-reference" do
    test "emits one edge per List.wrap element (bare-id string array)" do
      publish!("mediaAsset", "media-a")
      publish!("mediaAsset", "media-b")

      src =
        publish!("article", "art-arr", %{"attachments" => ["media-a", "media-b"]})

      arr_edges =
        Content.extract_edges(src)
        |> Enum.filter(&(&1.field == "attachments"))
        |> Enum.sort_by(& &1.to_id)

      assert length(arr_edges) == 2
      assert Enum.map(arr_edges, & &1.to_id) == ["media-a", "media-b"]

      for e <- arr_edges do
        assert e.from_id == "art-arr"
        assert e.refType == "mediaAsset"
        refute e.dangling
      end
    end

    test "a single bare-id (non-list) attachment still produces one edge" do
      publish!("mediaAsset", "media-solo")
      src = publish!("article", "art-solo", %{"attachments" => "media-solo"})

      arr_edges = Content.extract_edges(src) |> Enum.filter(&(&1.field == "attachments"))
      assert [%{to_id: "media-solo", dangling: false}] = arr_edges
    end
  end

  describe "(4) draft-only target under the :published lens" do
    test "a target that exists ONLY as drafts.X is dangling for :published (typed)" do
      draft_only!("author", "draft-auth")
      src = publish!("article", "art-draft-target", %{"author" => "draft-auth"})

      edge = Content.extract_edges(src) |> Enum.find(&(&1.field == "author"))
      assert edge.to_id == "draft-auth"

      assert edge.dangling,
             "a published-twin-less draft target must be dangling under the :published lens"
    end

    # The UNTYPED twin of the test above (gap #2 lens-agreement lock). Without
    # the published-only fix the untyped branch matched the `drafts.` twin and
    # reported NOT dangling — disagreeing with the typed branch on the SAME
    # draft-only target. Both branches now share the :published lens.
    test "a draft-only target via the UNTYPED `mentions` ref is ALSO dangling for :published" do
      draft_only!("note", "draft-note")
      src = publish!("article", "art-untyped-draft-target", %{"mentions" => "draft-note"})

      edge = Content.extract_edges(src) |> Enum.find(&(&1.field == "mentions"))
      assert edge.to_id == "draft-note"
      assert edge.refType in [nil, ""]

      assert edge.dangling,
             "an untyped ref to a published-twin-less draft target must be dangling — " <>
               "typed and untyped branches MUST agree under the :published lens"
    end
  end

  describe "(5) draft source coalesced to published id" do
    test "a draft source (drafts.A) yields from_id == A, never the drafts. id" do
      publish!("author", "auth-coalesce")

      # A draft-only article — its doc_id is `drafts.art-draft-src`.
      src =
        draft_only!("article", "art-draft-src", %{"author" => "auth-coalesce"})

      assert String.starts_with?(src.doc_id, "drafts.")

      edge = Content.extract_edges(src) |> Enum.find(&(&1.field == "author"))

      assert edge.from_id == "art-draft-src",
             "from_id MUST be the published-coalesced id, never drafts.art-draft-src"
    end
  end

  describe "(6) storage round-trip: extract_edges → add_edges → list_outbound_edges" do
    # The gap-#1 regression lock. extract_edges/2 emits slug `doc_id`s
    # (e.g. "art-1"), but content_edges FKs reference `documents.id` UUIDs.
    # add_edges MUST resolve the slugs to UUIDs before insert, or the FK cast
    # fails and the table can never be populated. This test exercises the FULL
    # storage path, not just the read-time projection.
    test "a resolvable edge round-trips into content_edges and reads back" do
      publish!("author", "auth-store")
      src = publish!("article", "art-store", %{"author" => "auth-store"})

      # Resolve the endpoint UUIDs we expect the writer to land on.
      {:ok, from_doc} = Content.get_document("art-store", "article", @dataset)
      {:ok, to_doc} = Content.get_document("auth-store", "author", @dataset)

      author_edge =
        src
        |> Content.extract_edges()
        |> Enum.filter(&(&1.field == "author"))

      results = Content.add_edges(author_edge, dataset: @dataset)

      assert [{:ok, %Edge{} = stored}] = results
      assert stored.from_id == from_doc.id
      assert stored.to_id == to_doc.id
      assert stored.kind == "references"

      outbound = Content.list_outbound_edges(from_doc.id)
      assert Enum.any?(outbound, &(&1.id == stored.id and &1.to_id == to_doc.id))
    end

    test "a dangling edge is unstorable → {:error, :no_target}, never inserted" do
      src = publish!("article", "art-store-missing", %{"author" => "ghost-store"})

      dangling_edge =
        src
        |> Content.extract_edges()
        |> Enum.filter(&(&1.field == "author"))

      assert [{:error, :no_target}] = Content.add_edges(dangling_edge, dataset: @dataset)

      {:ok, from_doc} = Content.get_document("art-store-missing", "article", @dataset)
      assert Content.list_outbound_edges(from_doc.id) == []
    end

    test "re-extract REPLACES weight/plugin_source on the same triple (on_conflict)" do
      publish!("author", "auth-replace")
      src = publish!("article", "art-replace", %{"author" => "auth-replace"})

      {:ok, from_doc} = Content.get_document("art-replace", "article", @dataset)

      edge = src |> Content.extract_edges() |> Enum.filter(&(&1.field == "author"))

      first = Enum.map(edge, &Map.put(&1, :weight, 1.0))
      [{:ok, e1}] = Content.add_edges(first, dataset: @dataset)
      assert e1.weight == 1.0

      second = edge |> Enum.map(&Map.put(&1, :weight, 2.0))
      [{:ok, e2}] = Content.add_edges(second, dataset: @dataset)

      assert e2.id == e1.id, "same triple → same row (idempotent on the triple)"
      assert e2.weight == 2.0, "weight REPLACED on re-extract, not kept stale"

      # Exactly one row for the triple.
      assert length(Content.list_outbound_edges(from_doc.id)) == 1
    end
  end
end
