defmodule Barkpark.Content.DedupWallScanBoundTest do
  @moduledoc """
  The candidate scan reads a BOUNDED number of rows, and still detects.

  Task `pds-bl-dedup-wall-scan-budget-blows-at-corpus-scale`. The old shape was
  `WHERE title % $1 ... ORDER BY similarity(title, $1) DESC LIMIT 500`: GIN has
  no order, so every row surviving the 0.1 trgm net was fetched, scored and
  top-N heapsorted. The LIMIT capped the RESULT; the SORT INPUT grew linearly
  with the corpus (3,410 rows / 203 ms at 20k → 13,566 / 729-972 ms at 80k on a
  seeded corpus of real Barkpark task titles). At that slope `@query_timeout_ms`
  is a countdown, not a ceiling.

  The scan now orders by the KNN distance `title <-> $1` over
  `documents_title_trgm_gist_idx`, which RETURNS rows in that order, so the
  LIMIT stops the scan: 500 rows read at every corpus size.

  ## This test EXPLAINs the query DedupWall actually ran

  It does not mirror the query — a mirror only proves the mirror. The real SQL
  and its params are captured off the `[:barkpark, :repo, :query]` telemetry
  event emitted during a live `DedupWall.check/4`, and EXPLAIN ANALYZE runs on
  exactly those bytes.

  ## What reds it

    * restoring `ORDER BY similarity(...)` — the ordered index path is gone, a
      `Sort` node appears (asserted absent);
    * dropping the `limit: @candidate_limit` — the scan's actual row count
      exceeds the cap (asserted <=);
    * dropping the GiST index — the plan no longer names it (asserted present).

  Verified by mutation: each of those three edits reds this file. See the PR for
  the run output.
  """
  # sync: captures queries off node-global telemetry with no lineage filter on the handler
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.{DedupWall, Document}
  alias Barkpark.Repo

  @dataset "production"

  # Must track DedupWall's @candidate_limit. A drift here reads as a cap
  # regression, which is the correct alarm.
  @candidate_limit 500

  # Every seeded title is trigram-NEAR the probe (they share the common words
  # the row names as the load driver), so under the OLD shape all of these rows
  # would have been fetched and sorted. Comfortably above the cap so "<= cap" is
  # a real constraint and not a vacuous green: with @seed_count < @candidate_limit
  # the assertion would pass for ANY plan.
  @seed_count 1200

  @probe "Publish wall dedup scan budget blows at corpus scale under fleet load"

  setup do
    now = DateTime.utc_now()

    rows =
      for i <- 1..@seed_count do
        %{
          doc_id: "scanbound-#{i}",
          type: "paper",
          dataset: @dataset,
          # Same common words as the probe, different tail — trigram-near
          # (clears the 0.1 floor) but token-Jaccard well under the 0.55 refuse
          # bar, so these are candidates, never verdicts.
          title: "Publish wall dedup scan budget note number #{i} under fleet load",
          status: "published",
          content: %{"tags" => [%{"tag" => "publish-wall"}]},
          rev: "rev-scanbound-#{i}",
          inserted_at: now,
          updated_at: now
        }
      end

    {count, _} = Repo.insert_all(Document, rows)
    assert count == @seed_count

    Repo.query!("ANALYZE documents")
    :ok
  end

  defp capture_candidate_sql(fun) do
    ref = make_ref()
    parent = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _e, _m, meta, _cfg ->
        if is_binary(meta[:query]) and String.contains?(meta[:query], "<->") do
          send(parent, {ref, meta[:query], meta[:params]})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    receive do
      {^ref, sql, params} -> {sql, params}
    after
      0 ->
        flunk(
          "no candidate query containing `<->` reached the repo — either the " <>
            "scan did not run, or the KNN ordering was removed"
        )
    end
  end

  test "the candidate scan reads at most @candidate_limit rows, off the KNN index, with no Sort" do
    {sql, params} =
      capture_candidate_sql(fn ->
        DedupWall.check(
          %{doc_id: "drafts.scanbound-probe", title: @probe, content: %{"tags" => []}},
          "paper",
          @dataset
        )
      end)

    # Small-corpus honesty (same device as dedup_trgm_protective_test). At ~1200
    # sandbox rows a seq-scan, or a cheap `documents_status_index` scan plus a
    # top-N heapsort, genuinely beats a GiST start-up, so the DEFAULT plan here
    # proves nothing about ELIGIBILITY — and eligibility is the property that
    # goes away silently under a refactor. At the corpus sizes that matter the
    # planner picks the KNN path unaided: measured on a seeded 20k/40k/80k
    # corpus it chose `documents_title_trgm_gist_idx` every time (see the PR).
    #
    # Penalizing seqscan AND sort forces the planner to reveal which ORDERED
    # path exists. This does NOT make the test vacuous: `enable_sort = off` is a
    # cost penalty, not a prohibition. An `ORDER BY similarity(...)` has no
    # ordered index path at any cost, so it still materializes a Sort node and
    # still reds the `refute plan =~ "Sort Method"` below — which is exactly the
    # mutation this file exists to catch.
    Repo.query!("SET LOCAL enable_seqscan = off")
    Repo.query!("SET LOCAL enable_sort = off")

    %{rows: plan_rows} = Repo.query!("EXPLAIN (ANALYZE, BUFFERS) " <> sql, params)
    plan = plan_rows |> List.flatten() |> Enum.join("\n")

    assert plan =~ "documents_title_trgm_gist_idx",
           "expected the KNN GiST trgm index to serve the candidate scan, got:\n#{plan}"

    assert plan =~ ~r/Order By:.*<->/s,
           "expected the index scan to be ORDERED BY the `<->` distance, got:\n#{plan}"

    refute plan =~ "Sort Method",
           "a Sort node means the scan is materializing and sorting its whole " <>
             "input — the exact unbounded shape this change removed:\n#{plan}"

    scanned =
      Regex.scan(~r/Index Scan[^\n]*\(actual time=[^)]*rows=(\d+)/, plan)
      |> Enum.map(fn [_, n] -> String.to_integer(n) end)

    assert scanned != [], "no Index Scan actual row count in the plan:\n#{plan}"

    assert Enum.max(scanned) <= @candidate_limit,
           "the scan read #{Enum.max(scanned)} rows against a #{@candidate_limit} cap " <>
             "over a #{@seed_count}-row near-corpus — the LIMIT is not bounding the " <>
             "scan:\n#{plan}"
  end

  test "detection survives the bound: a near-duplicate still REFUSES" do
    # An exact-title twin of a seeded row: token-Jaccard 1.0, shared >> 3.
    dup = %{
      doc_id: "drafts.scanbound-dup",
      title: "Publish wall dedup scan budget note number 7 under fleet load",
      content: %{"tags" => [%{"tag" => "publish-wall"}]}
    }

    assert {:error, {:duplicate_of, payload}} = DedupWall.check(dup, "paper", @dataset)
    assert payload.duplicate_of == "scanbound-7"
  end

  test "detection survives the bound: an unrelated title still PASSES" do
    fresh = %{
      doc_id: "drafts.scanbound-fresh",
      title: "Postfix DKIM mail relay sidecar container image",
      content: %{"tags" => [%{"tag" => "mail"}]}
    }

    assert :ok = DedupWall.check(fresh, "paper", @dataset)
  end
end
