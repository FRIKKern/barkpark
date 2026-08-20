defmodule Barkpark.Content.ExpandTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content
  alias Barkpark.Content.{Envelope, Expand}

  # Default Ecto telemetry event for a repo with `otp_app: :barkpark`.
  @repo_query_event [:barkpark, :repo, :query]
  # The two tables the `?expand=` N+1 was measured against.
  @ref_sources ~w(documents schema_definitions)

  # Count, within `fun`, the Repo queries `Expand.expand/4` issues against the
  # documents + schema_definitions tables, split by source. One process owns the
  # counter via an Agent; the handler only tallies queries fired from THIS test
  # pid (Ecto emits query telemetry in the caller process), so it stays correct
  # even under `async: true` while sibling tests query concurrently.
  defp count_ref_queries(fun) do
    {:ok, counter} = Agent.start_link(fn -> %{"documents" => 0, "schema_definitions" => 0} end)
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      @repo_query_event,
      fn _event, _measurements, %{source: source}, _config ->
        if self() == test_pid and source in @ref_sources do
          Agent.update(counter, &Map.update!(&1, source, fn n -> n + 1 end))
        end
      end,
      nil
    )

    try do
      result = fun.()
      by_source = Agent.get(counter, & &1)

      {result,
       %{
         documents: by_source["documents"],
         schema: by_source["schema_definitions"],
         total: by_source["documents"] + by_source["schema_definitions"]
       }}
    after
      :telemetry.detach(handler_id)
      Agent.stop(counter)
    end
  end

  # Seed `n` distinct published authors, each referenced by one published post,
  # namespaced per `n` so successive counts expand EXACTLY n references.
  defp seed_ref_posts(n) do
    for i <- 1..n do
      aid = "qa#{n}_#{i}"
      pid = "qp#{n}_#{i}"
      {:ok, _} = Content.create_document("author", %{"_id" => aid, "title" => "A#{i}"}, "exp")
      {:ok, _} = Content.publish_document(aid, "author", "exp")

      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => pid, "title" => "P#{i}", "author" => aid},
          "exp"
        )

      {:ok, _} = Content.publish_document(pid, "post", "exp")
    end

    Content.list_documents("post", "exp", perspective: :published)
    |> Enum.map(&Envelope.render/1)
    |> Enum.filter(&String.starts_with?(&1["_id"], "qp#{n}_"))
  end

  setup do
    Content.upsert_schema(
      %{
        "name" => "author",
        "title" => "Author",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      },
      "exp"
    )

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "author", "type" => "reference", "refType" => "author"}
        ]
      },
      "exp"
    )

    {:ok, _} = Content.create_document("author", %{"_id" => "a1", "title" => "Jane"}, "exp")

    {:ok, _} = Content.publish_document("a1", "author", "exp")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p1", "title" => "Hello", "author" => "a1"},
        "exp"
      )

    {:ok, _} = Content.publish_document("p1", "post", "exp")

    :ok
  end

  test "expand/3 with :all resolves every reference field in the docs" do
    [post] =
      Content.list_documents("post", "exp", perspective: :published)
      |> Enum.map(&Envelope.render/1)
      |> Expand.expand(:all, "exp")

    assert post["title"] == "Hello"
    assert is_map(post["author"])
    assert post["author"]["_id"] == "a1"
    assert post["author"]["_type"] == "author"
    assert post["author"]["title"] == "Jane"
  end

  test "expand/3 with a field list only resolves those fields" do
    docs =
      Content.list_documents("post", "exp", perspective: :published)
      |> Enum.map(&Envelope.render/1)

    [post_none] = Expand.expand(docs, [], "exp")
    assert post_none["author"] == "a1"

    [post_author] = Expand.expand(docs, ["author"], "exp")
    assert is_map(post_author["author"])
    assert post_author["author"]["title"] == "Jane"
  end

  test "expand/3 leaves unresolved refs as raw strings" do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p2", "title" => "Orphan", "author" => "does-not-exist"},
        "exp"
      )

    {:ok, _} = Content.publish_document("p2", "post", "exp")

    docs =
      Content.list_documents("post", "exp",
        perspective: :published,
        filter_map: %{"title" => "Orphan"}
      )
      |> Enum.map(&Envelope.render/1)

    [expanded] = Expand.expand(docs, :all, "exp")
    assert expanded["author"] == "does-not-exist"
  end

  test "expand/3 is shallow — referenced docs don't themselves get expanded" do
    Content.upsert_schema(
      %{
        "name" => "category",
        "title" => "Category",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      },
      "exp"
    )

    Content.upsert_schema(
      %{
        "name" => "author",
        "title" => "Author",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "category", "type" => "reference", "refType" => "category"}
        ]
      },
      "exp"
    )

    {:ok, _} = Content.create_document("category", %{"_id" => "c1", "title" => "Cat"}, "exp")
    {:ok, _} = Content.publish_document("c1", "category", "exp")

    {:ok, _} =
      Content.create_document(
        "author",
        %{"_id" => "a2", "title" => "Nested", "category" => "c1"},
        "exp"
      )

    {:ok, _} = Content.publish_document("a2", "author", "exp")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p3", "title" => "Deep", "author" => "a2"},
        "exp"
      )

    {:ok, _} = Content.publish_document("p3", "post", "exp")

    docs =
      Content.list_documents("post", "exp",
        perspective: :published,
        filter_map: %{"title" => "Deep"}
      )
      |> Enum.map(&Envelope.render/1)

    [post] = Expand.expand(docs, :all, "exp")
    assert is_map(post["author"])
    assert post["author"]["title"] == "Nested"
    assert post["author"]["category"] == "c1"
  end

  test "expand/4 with published_only: true does NOT leak a draft ref via fallback" do
    # Create an author that exists ONLY as a draft (never published)
    {:ok, _} =
      Content.create_document(
        "author",
        %{"_id" => "adraft", "title" => "Draft Only"},
        "exp"
      )

    # Create a post referencing the draft-only author, and publish the post
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p4", "title" => "DraftRef", "author" => "adraft"},
        "exp"
      )

    {:ok, _} = Content.publish_document("p4", "post", "exp")

    docs =
      Content.list_documents("post", "exp",
        perspective: :published,
        filter_map: %{"title" => "DraftRef"}
      )
      |> Enum.map(&Envelope.render/1)

    # Without published_only the draft fallback resolves the author
    [expanded_default] = Expand.expand(docs, :all, "exp")
    assert is_map(expanded_default["author"])
    assert expanded_default["author"]["title"] == "Draft Only"

    # With published_only the draft twin must NOT be revealed — ref stays raw
    [expanded_restricted] = Expand.expand(docs, :all, "exp", published_only: true)
    assert expanded_restricted["author"] == "adraft"
  end

  # Wiring proof: a `private` field on an EXPANDED reference is redacted through
  # the caller_context threaded into resolve_ref → Envelope.render. Without this
  # the private field of a referenced doc would leak into the parent's expansion.
  test "expand/4 redacts a private field on an expanded reference for an anonymous caller" do
    alias Barkpark.Content.CallerContext

    # Re-declare `author` with a private `secret` field, and reference it.
    Content.upsert_schema(
      %{
        "name" => "author",
        "title" => "Author",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "secret", "type" => "string", "private" => true}
        ]
      },
      "exp"
    )

    {:ok, _} =
      Content.create_document(
        "author",
        %{"_id" => "asec", "title" => "Secret Jane", "secret" => "SSN-123"},
        "exp"
      )

    {:ok, _} = Content.publish_document("asec", "author", "exp")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "psec", "title" => "PrivRef", "author" => "asec"},
        "exp"
      )

    {:ok, _} = Content.publish_document("psec", "post", "exp")

    docs =
      Content.list_documents("post", "exp",
        perspective: :published,
        filter_map: %{"title" => "PrivRef"}
      )
      |> Enum.map(&Envelope.render/1)

    # Anonymous caller: the expanded author keeps `title` but DROPS `secret`.
    [anon] = Expand.expand(docs, :all, "exp", caller_context: CallerContext.anonymous())
    assert anon["author"]["title"] == "Secret Jane"
    refute Map.has_key?(anon["author"], "secret")

    # Positive control: the :internal sentinel bypasses redaction — proves the
    # field is present in the source and it is the redaction that removes it.
    [internal] = Expand.expand(docs, :all, "exp", caller_context: :internal)
    assert internal["author"]["secret"] == "SSN-123"
  end

  test "expand/4 with empty docs returns []" do
    assert Expand.expand([], :all, "exp") == []
  end

  test "expand resolves a {_ref}-object reference value (Sanity convention)" do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "pobj", "title" => "ObjRef", "author" => %{"_ref" => "a1"}},
        "exp"
      )

    {:ok, _} = Content.publish_document("pobj", "post", "exp")

    post =
      Content.list_documents("post", "exp", perspective: :published)
      |> Enum.map(&Envelope.render/1)
      |> Expand.expand(:all, "exp")
      |> Enum.find(&(&1["_id"] == "pobj"))

    assert is_map(post["author"])
    assert post["author"]["_id"] == "a1"
    assert post["author"]["title"] == "Jane"
  end

  test "expand resolves an arrayOf-of-reference field, with mixed element forms" do
    Content.upsert_schema(
      %{
        "name" => "tag",
        "title" => "Tag",
        "visibility" => "public",
        "fields" => [%{"name" => "title", "type" => "string"}]
      },
      "exp"
    )

    Content.upsert_schema(
      %{
        "name" => "article",
        "title" => "Article",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{
            "name" => "tags",
            "type" => "arrayOf",
            "of" => %{"type" => "reference", "refType" => "tag"}
          }
        ]
      },
      "exp"
    )

    for {id, title} <- [{"t1", "Elixir"}, {"t2", "CMS"}] do
      {:ok, _} = Content.create_document("tag", %{"_id" => id, "title" => title}, "exp")
      {:ok, _} = Content.publish_document(id, "tag", "exp")
    end

    # Mixed element forms: a plain id string AND a {_ref} object — both resolve.
    {:ok, _} =
      Content.create_document(
        "article",
        %{"_id" => "ar1", "title" => "A", "tags" => ["t1", %{"_ref" => "t2"}]},
        "exp"
      )

    {:ok, _} = Content.publish_document("ar1", "article", "exp")

    [article] =
      Content.list_documents("article", "exp", perspective: :published)
      |> Enum.map(&Envelope.render/1)
      |> Expand.expand(:all, "exp")

    assert [tag1, tag2] = article["tags"]
    assert is_map(tag1) and tag1["_id"] == "t1" and tag1["title"] == "Elixir"
    assert is_map(tag2) and tag2["_id"] == "t2" and tag2["title"] == "CMS"
  end

  # FAIL-BEFORE query-count probe. The old per-ref `resolve_ref/6` issued one
  # `Content.get_document` (Repo.one) + two `Content.get_schema` per resolved
  # reference — MEASURED linear: documents == N, schema == 2N+1 (N=1 -> 4,
  # N=6 -> 19, N=16 -> 49). The batch rewrite makes the count CONSTANT in N.
  # MUTATION PROOF (recorded on the task): reintroduce the per-ref loop and this
  # test goes RED (documents climbs 1 -> 6 -> 16, total climbs 4 -> 19 -> 49).
  test "?expand= query count is CONSTANT in the resolved-reference count N (kills the N+1)" do
    counts =
      for n <- [1, 6, 16] do
        docs = seed_ref_posts(n)
        assert length(docs) == n

        {expanded, c} = count_ref_queries(fn -> Expand.expand(docs, :all, "exp") end)

        # Correctness under load: every post's `author` reference is expanded.
        assert length(expanded) == n
        assert Enum.all?(expanded, &is_map(&1["author"]))
        assert Enum.all?(expanded, &(&1["author"]["_type"] == "author"))

        {n, c}
      end

    by_n = Map.new(counts)

    # The document reads DO NOT scale with N — one batched query per ref_type,
    # not one Repo.one per ref. Before the fix documents == N (1 / 6 / 16).
    assert by_n[1].documents == by_n[6].documents
    assert by_n[6].documents == by_n[16].documents
    # Strong anti-N+1: 16 references cost far fewer than 16 document queries.
    assert by_n[16].documents < 16

    # Schema reads are memoized per ref_type — constant, not 2N+1.
    assert by_n[1].schema == by_n[6].schema
    assert by_n[6].schema == by_n[16].schema

    # Total documents+schema query count is flat across N (was 4 / 19 / 49).
    assert by_n[1].total == by_n[6].total
    assert by_n[6].total == by_n[16].total
  end
end
