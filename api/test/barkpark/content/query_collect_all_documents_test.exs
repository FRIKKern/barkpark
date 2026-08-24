defmodule Barkpark.Content.QueryCollectAllDocumentsTest do
  @moduledoc """
  The corpus-walk law: `Content.Query.collect_all_documents/3`.

  WHY THIS FILE EXISTS. `list_documents/3` clamps `:limit` to 1000
  (`content/query.ex`, `min(1000)`) and returns a BARE LIST, so a caller
  holding 1000 rows cannot tell "that is the whole corpus" from "there are
  3,000 more". Five corpus-walkers in this repo read that capped page and
  called it the corpus. `collect_all_documents/3` is the Elixir mirror of
  `web/lib/paginate.ts`'s `collectAllPages` — same law, deliberately:

    * pages of `:page_size` rows, `:offset` advanced by the RAW page length;
    * a SHORT page terminates the walk — the honest end of the corpus;
    * the walk is BOUNDED by `:max_pages`, and when the bound stops it the
      result is labelled `:cap` instead of passing as complete.

  THE MUTATION PROOF is `"the 1000-row clamp is REAL"` + `"walks PAST the
  1000-row clamp"` below: one corpus of 1001 published documents, read both
  ways. The old call shape returns 1000 rows and says nothing; the walk
  returns 1001 and reports an exhausted corpus. Revert
  `collect_all_documents/3` to a single `list_documents/3` and the second test
  fails on `1000 != 1001`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Query
  alias Barkpark.Repo

  @dataset "collect_all_unit_test"
  @type_name "cpost"

  setup do
    Content.upsert_schema(
      %{"name" => @type_name, "title" => "CPost", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  # Bulk-seed published rows straight through `insert_all`. The walk under test
  # reads rows, not revisions, and 1001 create+publish round-trips would make
  # the real-cap proof too slow to keep.
  defp seed!(n, prefix \\ "c") do
    now = DateTime.utc_now()

    rows =
      for i <- 1..n do
        %{
          id: Ecto.UUID.generate(),
          doc_id: "#{prefix}-#{String.pad_leading(Integer.to_string(i), 5, "0")}",
          type: @type_name,
          dataset: @dataset,
          title: "doc #{i}",
          status: "published",
          content: %{},
          rev: Ecto.UUID.generate(),
          inserted_at: now,
          updated_at: now
        }
      end

    {^n, _} = Repo.insert_all(Document, rows)
    :ok
  end

  defp ids({docs, _truncated}), do: Enum.map(docs, & &1.doc_id)

  describe "the defect: a capped page is indistinguishable from a whole corpus" do
    test "the 1000-row clamp is REAL — asking for 10_000 silently yields 1000" do
      seed!(1001)

      # This is verbatim what four of the five walkers did, and exactly what
      # legacy_controller.ex asked for. The request is honoured with a PREFIX
      # and there is no error, no flag, and no way for the caller to tell.
      docs = Query.list_documents(@type_name, @dataset, perspective: :published, limit: 10_000)

      assert length(docs) == 1000
      assert Query.count_documents(@type_name, @dataset, perspective: :published) == 1001
    end

    test "collect_all_documents/3 walks PAST the 1000-row clamp and reports an exhausted corpus" do
      seed!(1001)

      {docs, truncated} =
        Query.collect_all_documents(@type_name, @dataset, perspective: :published)

      assert length(docs) == 1001, "the walk must see the WHOLE corpus, not the 1000-row page cap"
      assert truncated == nil, "a corpus that ran out must NOT be labelled truncated"
      assert length(Enum.uniq_by(docs, & &1.doc_id)) == 1001, "the walk must not duplicate rows"
    end
  end

  describe "the law" do
    test "a SHORT page terminates the walk and reports nil truncation" do
      seed!(5)

      result =
        Query.collect_all_documents(@type_name, @dataset, perspective: :published, page_size: 2)

      assert {docs, nil} = result
      assert length(docs) == 5
      # Raw-advance + the total sort order means every row appears exactly once.
      assert length(Enum.uniq(ids(result))) == 5
    end

    test "an EXACTLY-full final page still terminates cleanly (the empty next page is short)" do
      seed!(4)

      assert {docs, nil} =
               Query.collect_all_documents(@type_name, @dataset,
                 perspective: :published,
                 page_size: 2
               )

      assert length(docs) == 4
    end

    test "the :max_pages bound stops the walk and says :cap — never a silent prefix" do
      seed!(5)

      assert {docs, :cap} =
               Query.collect_all_documents(@type_name, @dataset,
                 perspective: :published,
                 page_size: 2,
                 max_pages: 2
               )

      assert length(docs) == 4, "the bounded walk returns the prefix it actually read"
    end

    test "a caller-supplied :limit / :offset cannot break the walk" do
      seed!(5)

      # The walk owns paging; a stray :limit from a copied opts list must not
      # re-impose the very cap this function exists to defeat.
      assert {docs, nil} =
               Query.collect_all_documents(@type_name, @dataset,
                 perspective: :published,
                 limit: 2,
                 offset: 3,
                 page_size: 2
               )

      assert length(docs) == 5
    end

    test "an empty corpus is an exhausted corpus, not a truncated one" do
      assert {[], nil} =
               Query.collect_all_documents(@type_name, @dataset, perspective: :published)
    end

    test "the walk respects the :published perspective (drafts stay out)" do
      seed!(3, "pub")
      seed!(2, "drafts.d")

      {docs, nil} = Query.collect_all_documents(@type_name, @dataset, perspective: :published)

      assert length(docs) == 3
      refute Enum.any?(docs, &String.starts_with?(&1.doc_id, "drafts."))
    end

    test "Content.collect_all_documents/3 delegates to the same walk" do
      seed!(3)

      assert {docs, nil} =
               Content.collect_all_documents(@type_name, @dataset, perspective: :published)

      assert length(docs) == 3
    end
  end
end
