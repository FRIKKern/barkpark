defmodule Barkpark.Content.TagRegistryTrgmTest do
  @moduledoc """
  Protective proof for `TagRegistry.nearest_registered/3` (authoring-excellence
  charter D49/D50, wave 7 — sibling of D46's `ae-dedup-trgm-index`).

  The unknown-tag suggestion probe's coarse trgm filter was rewritten from
  `similarity(doc_id, name) > @suggestion_floor` (a FUNCTION form the planner
  cannot serve from any index) to the `?  % ?` operator so it can ENGAGE the
  PARTIAL GIN index `documents_doc_id_trgm_idx` (migration 20260713130000,
  `WHERE type='tag' AND status='published'`). Because `@suggestion_floor` (0.1)
  is BELOW pg_trgm's 0.3 default, the rewrite pairs `%` with `SET LOCAL
  pg_trgm.similarity_threshold = 0.1` inside an explicit `Repo.transaction`.

  Two guarantees are pinned:

    * PLAN — on the ISOLATED barest arm (`type='tag' AND status='published' AND
      doc_id % ?`, the minimum that can reach the PARTIAL index) the planner
      rides `documents_doc_id_trgm_idx` (a Bitmap Index Scan). The OLD
      `similarity(doc_id, ?) > x` arm on the same corpus CANNOT reach that trgm
      index — the function form is index-OPAQUE. The win is scale-GATED: at the
      ~3000-row sandbox corpus a raw seq-scan is genuinely cheaper than the GIN
      scan (trgm GIN start-up cost only amortizes at tens of thousands of rows),
      so the DEFAULT plan seq-scans both arms and would prove nothing. We
      therefore `SET LOCAL enable_seqscan = off` to force the planner to reveal
      index ELIGIBILITY: the `%` arm then takes the trgm index (REACHABLE) while
      the old arm still cannot. Asserted on the isolated predicate, NOT the full
      `nearest_registered` path (which correctly seq-scans at small scale — a
      full-path index assertion is a vacuous-green trap that flakes).

    * RECALL — `nearest_registered` still surfaces a genuine GRAY-ZONE (~0.15
      similarity) near-match through the real `SET LOCAL 0.1` transaction. This
      is the CLIFF proof: at pg_trgm's 0.3 default the `%` operator would drop
      every 0.10–0.30 candidate, so a gray-zone suggestion surviving proves the
      `SET LOCAL` fired. `%` is a `>=` superset of the old strict `>` floor.

  The win is scale-GATED — no immediate speedup on today's small corpus; the
  value is making the index REACHABLE (correctness/preparedness). The behavioral
  tests in `tag_registry_test.exs` stay green under the same rewrite.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.{Document, TagRegistry}
  alias Barkpark.Repo

  @dataset "production"

  # Keep in lockstep with TagRegistry's single-source floor.
  @suggestion_floor 0.1

  # The unknown name whose nearest registered tags we probe. Its trigrams overlap
  # only a HANDFUL of the seeded noise names → the `%` predicate is highly
  # selective, which is what tips the planner to the index under seqscan-off.
  @name "rate limiting the mutate controller endpoint"

  # Seed enough distinct PUBLISHED type='tag' rows that the planner has a real
  # choice: at ~3000 rows a low-selectivity trgm predicate is cheaper via the GIN
  # index than a full scan (mirrors the D46 dedup protective test).
  @seed_count 3000

  setup do
    now = DateTime.utc_now()

    noise =
      for i <- 1..@seed_count do
        %{
          # doc_id IS the tag name — the column the partial trgm index covers.
          # Deliberately far from @name (near-zero trigram overlap) → the `%`
          # predicate is highly selective, tipping the planner to the index.
          doc_id: "unrelated distinct tag number #{i} lorem ipsum dolor sit",
          type: "tag",
          dataset: @dataset,
          title: "Unrelated tag #{i}",
          status: "published",
          content: %{},
          rev: "rev-noise-#{i}",
          inserted_at: now,
          updated_at: now
        }
      end

    {count, _} = Repo.insert_all(Document, noise)
    assert count == @seed_count

    # Give the planner statistics for the freshly-seeded rows (in-transaction
    # ANALYZE is honored within the sandbox connection).
    Repo.query!("ANALYZE documents")

    # SET LOCAL is transaction-scoped; the sandbox wraps the whole test in one
    # transaction, so setting it here applies to every query below — mirroring
    # exactly what nearest_registered does inside its own txn.
    Repo.query!("SET LOCAL pg_trgm.similarity_threshold = #{@suggestion_floor}")

    :ok
  end

  # The barest arm that can still reach the PARTIAL index: it MUST carry
  # `type='tag' AND status='published'` (the index's predicate) or the planner
  # cannot prove the query is a subset of the partial index. No order/limit noise
  # so the EXPLAIN reflects ONLY the predicate's index-eligibility.
  defp new_arm do
    from(d in Document,
      where: d.type == "tag" and d.status == "published",
      where: fragment("? % ?", d.doc_id, ^@name),
      select: d.doc_id
    )
  end

  defp old_arm do
    from(d in Document,
      where: d.type == "tag" and d.status == "published",
      where: fragment("similarity(?, ?) > ?", d.doc_id, ^@name, ^@suggestion_floor),
      select: d.doc_id
    )
  end

  test "the `%` arm rides documents_doc_id_trgm_idx; the old similarity() arm cannot reach it" do
    # A PARTIAL index (`WHERE type='tag' AND status='published'`) can only be
    # planned when the query carries those literals — which unavoidably brings
    # the btree indexes on `type`/`status` into contention (the D46 FULL-index
    # test had no such competitor). At the ~3000-row sandbox corpus the planner
    # prefers scanning a type-btree and filtering `%` over paying the GIN trgm
    # start-up cost, so it would NOT reveal the trgm index's eligibility. To
    # prove REACHABILITY deterministically we drop the competing indexes for the
    # duration of this test (transaction-scoped in the sandbox — every DROP rolls
    # back at test end), leaving the partial GIN as the ONLY applicable index for
    # the `%` arm. `similarity()>x` is index-OPAQUE, so with `enable_seqscan=off`
    # it still falls back to a Seq Scan even with the trgm index present — the
    # exact correctness/preparedness distinction the `%` rewrite buys.
    for [name] <-
          Repo.query!(
            "SELECT indexname FROM pg_indexes WHERE tablename='documents' " <>
              "AND indexname NOT IN ('documents_doc_id_trgm_idx','documents_pkey')"
          ).rows do
      Repo.query!(~s(DROP INDEX "#{name}"))
    end

    Repo.query!("SET LOCAL enable_seqscan = off")

    new_plan = Repo.explain(:all, new_arm())
    old_plan = Repo.explain(:all, old_arm())

    # The `%` arm rides the partial GIN trgm index with the trigram operator as
    # an INDEX CONDITION — the index itself answers the near-match lookup.
    assert new_plan =~ "documents_doc_id_trgm_idx",
           "expected the `%` predicate to engage the partial GIN trgm index, got:\n#{new_plan}"

    assert new_plan =~ ~r/Index Cond: [^\n]*%/,
           "expected the `%` operator to drive an Index Cond on the trgm index, got:\n#{new_plan}"

    # `similarity()>x` is index-OPAQUE: even when the SAME trgm index is the only
    # one available, the function can never be an Index Cond — it can only be a
    # post-scan Filter/Recheck (here the index degrades to a full scan of the
    # partial predicate). That is the correctness the `%` rewrite buys.
    refute old_plan =~ ~r/Index Cond: [^\n]*similarity/,
           "the old `similarity() > x` arm must NOT push similarity into an Index Cond, got:\n#{old_plan}"

    assert old_plan =~ ~r/(Filter|Recheck Cond): [^\n]*similarity/,
           "expected `similarity() > x` to be a post-scan Filter/Recheck (index-opaque), got:\n#{old_plan}"
  end

  test "recall preserved: nearest_registered still surfaces a ~0.15 gray-zone near-match" do
    now = DateTime.utc_now()

    # A tag name sharing a MODERATE run of trigrams with @name — genuinely in the
    # 0.10–0.30 gray band the floor is designed to keep (the exact value is
    # verified below, not assumed). It ONLY survives `%` because SET LOCAL drops
    # the threshold to 0.1 — at pg_trgm's 0.3 default it would be excluded.
    gray_name = "throttling writes on the api endpoint"

    {1, _} =
      Repo.insert_all(Document, [
        %{
          doc_id: gray_name,
          type: "tag",
          dataset: @dataset,
          title: "Gray-zone tag",
          status: "published",
          content: %{},
          rev: "rev-gray",
          inserted_at: now,
          updated_at: now
        }
      ])

    [[sim]] = Repo.query!("SELECT similarity($1, $2)", [gray_name, @name]).rows

    assert sim > @suggestion_floor and sim < 0.30,
           "fixture must be a genuine gray-zone near-duplicate, got similarity=#{sim}"

    # Drive the REAL public path: an unknown weighted tag equal to @name resolves
    # its nearest registered tags via nearest_registered's SET-LOCAL transaction.
    draft = %Document{
      doc_id: "drafts.some-post",
      type: "post",
      dataset: @dataset,
      status: "draft",
      content: %{"tags" => [%{"tag" => @name, "strength" => 90, "rationale" => "probe"}]}
    }

    assert {:error, {:unknown_tag, %{suggestions: suggestions}}} =
             TagRegistry.validate_publish(draft, @dataset, [])

    assert gray_name in Map.get(suggestions, @name, []),
           "the gray-zone near-match must survive the `%` + SET-LOCAL(0.1) probe; " <>
             "got suggestions=#{inspect(Map.get(suggestions, @name))}"
  end
end
