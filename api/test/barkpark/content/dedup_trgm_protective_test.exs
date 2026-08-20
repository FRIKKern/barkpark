defmodule Barkpark.Content.DedupTrgmProtectiveTest do
  @moduledoc """
  Protective proof for `DedupWall` candidate fetch (authoring-excellence D46).

  The fetch's coarse trgm pre-filter was rewritten from `similarity(?, ?) > x`
  to the `?  % ?` operator so it can ENGAGE the GIN `documents_title_trgm_idx`
  before any type holds thousands of published docs. Two guarantees are pinned:

    * PLAN — on the ISOLATED barest `title % ?` arm the planner rides
      `documents_title_trgm_idx` (a Bitmap Index Scan). The OLD `similarity() > x`
      arm on the same corpus Seq-Scans no matter what — the function form is
      index-OPAQUE. The win is scale-GATED: at the ~3000-row sandbox corpus a raw
      seq-scan is genuinely CHEAPER than the GIN scan (trgm GIN start-up cost only
      amortizes at tens of thousands of rows), so the default plan seq-scans BOTH
      arms and would prove nothing. We therefore `SET LOCAL enable_seqscan = off`
      to force the planner to reveal index ELIGIBILITY: the `%` arm then takes the
      trgm index (REACHABLE), while the old arm STILL seq-scans (the planner has
      no index option for `similarity()>x` even with seqscan penalized) — exactly
      the correctness/preparedness distinction the rewrite buys. Asserted on the
      isolated predicate, NOT the full `guard()` path (which correctly seq-scans
      at small scale — a full-path index assertion is a vacuous-green trap).

    * RECALL — `%` (a `>=` with the SET-LOCAL threshold at @candidate_trgm_floor)
      returns the SAME candidate set as the old strict `>` floor for a
      gray-zone (~0.15 similarity) near-duplicate: byte-identical MapSet.

  The win is scale-GATED — no immediate speedup on today's small corpus; the
  value is making the index REACHABLE (correctness/preparedness). The 15
  behavioral tests in `dedup_wall_test.exs` stay green under the same rewrite.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "production"
  @title "Rate limiting the mutate controller endpoint"

  # Keep in lockstep with DedupWall's single-source floor.
  @candidate_trgm_floor 0.1

  # Seed enough distinct rows that the planner has a real choice: at ~3000 rows a
  # low-selectivity trgm predicate is cheaper via the GIN index than a full scan.
  @seed_count 3000

  setup do
    now = DateTime.utc_now()

    noise =
      for i <- 1..@seed_count do
        %{
          doc_id: "trgm-noise-#{i}",
          type: "paper",
          dataset: @dataset,
          # Deliberately far from @title — near-zero trigram overlap → the `%`
          # predicate is highly selective, which is what tips the planner to the
          # index rather than a seq-scan.
          title: "Unrelated distinct heading number #{i} lorem ipsum dolor sit",
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
    # exactly what DedupWall.fetch_candidates does inside its own txn.
    Repo.query!("SET LOCAL pg_trgm.similarity_threshold = #{@candidate_trgm_floor}")

    :ok
  end

  # The barest possible arms — no type/status/order/limit noise — so the EXPLAIN
  # reflects ONLY the predicate's index-eligibility.
  defp new_arm do
    from(d in Document,
      where: fragment("? % ?", d.title, ^@title),
      select: d.doc_id
    )
  end

  defp old_arm do
    from(d in Document,
      where: fragment("similarity(?, ?) > ?", d.title, ^@title, ^@candidate_trgm_floor),
      select: d.doc_id
    )
  end

  test "the `%` arm rides documents_title_trgm_idx; the old similarity() arm seq-scans" do
    # Force the planner to reveal index ELIGIBILITY. At sandbox scale the GIN
    # trgm start-up cost makes a seq-scan cheaper, so the DEFAULT plan seq-scans
    # both arms (the win is scale-gated). With seqscan penalized the difference
    # is deterministic: `%` reaches the index, `similarity()>x` cannot.
    Repo.query!("SET LOCAL enable_seqscan = off")

    new_plan = Repo.explain(:all, new_arm())
    old_plan = Repo.explain(:all, old_arm())

    assert new_plan =~ "documents_title_trgm_idx",
           "expected the `%` predicate to engage the GIN trgm index, got:\n#{new_plan}"

    assert new_plan =~ ~r/Bitmap Index Scan|Index Scan/,
           "expected an (Bitmap) Index Scan for the `%` arm, got:\n#{new_plan}"

    refute old_plan =~ "documents_title_trgm_idx",
           "the old `similarity() > x` arm must NOT reach the trgm index, got:\n#{old_plan}"

    assert old_plan =~ "Seq Scan",
           "expected the old `similarity() > x` arm to Seq-Scan, got:\n#{old_plan}"
  end

  test "recall is byte-identical: a ~0.15 gray-zone near-duplicate survives `%` and equals the old set" do
    now = DateTime.utc_now()

    # A title that shares a MODERATE run of trigrams with @title — genuinely in
    # the 0.10–0.30 gray band the floor is designed to keep (the exact value is
    # verified below, not assumed).
    gray_title = "Throttling writes on the API endpoint"

    {1, _} =
      Repo.insert_all(Document, [
        %{
          doc_id: "gray-zone-dup",
          type: "paper",
          dataset: @dataset,
          title: gray_title,
          status: "published",
          content: %{},
          rev: "rev-gray",
          inserted_at: now,
          updated_at: now
        }
      ])

    [[sim]] = Repo.query!("SELECT similarity($1, $2)", [gray_title, @title]).rows

    assert sim > @candidate_trgm_floor and sim < 0.30,
           "fixture must be a genuine gray-zone near-duplicate, got similarity=#{sim}"

    new_ids = new_arm() |> Repo.all() |> MapSet.new()
    old_ids = old_arm() |> Repo.all() |> MapSet.new()

    assert MapSet.member?(new_ids, "gray-zone-dup"),
           "the gray-zone near-duplicate must survive the `%` candidate net"

    assert new_ids == old_ids,
           "the `%` candidate set must be byte-identical to the old similarity()>floor set"
  end
end
