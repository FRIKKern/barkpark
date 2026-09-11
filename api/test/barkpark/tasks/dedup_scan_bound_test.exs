defmodule Barkpark.Tasks.DedupScanBoundTest do
  @moduledoc """
  The task dedup candidate scan reads a BOUNDED number of rows, and still detects.

  Task `guerrilla-task-mutate-pool-saturation`. The 2026-07-30 incident:
  `POST /v1/data/mutate/production` for `type:task` 500ing under pool
  saturation, with `Tasks.Dedup fail-open: candidate fetch failed` then
  `Sent 500 in 16389ms` — the fail-open does not save the request, because the
  15 s DBConnection checkout is already dead by the time it fires. Fix
  candidate (1) on the row: bound/index the candidate fetch so it cannot eat
  the checkout.

  The old shape was a `DISTINCT ON` subquery under
  `ORDER BY similarity(title, $1) DESC, doc_id LIMIT 501`, fed by a
  `WHERE title % $1` net under `SET LOCAL pg_trgm.similarity_threshold`. GIN
  has no order and neither does a subquery, so every row surviving the net was
  fetched, scored and top-N heapsorted: the LIMIT capped the RESULT while the
  SORT INPUT grew with the corpus. `@query_timeout_ms` (5 s) was a countdown,
  not a ceiling — and what it overran was the request's ONE 15 s checkout.

  The scan now orders by the KNN distance `title <-> $1` over
  `documents_title_trgm_gist_idx` (migration 20260910100000), which RETURNS
  rows in that order, so the LIMIT stops the SCAN. The `@candidate_trgm_floor`
  and the draft/published twin collapse both moved into Elixir, applied to the
  bounded rows, because either as SQL costs the ordered path.

  ## This test EXPLAINs the query `Tasks.Dedup` actually ran

  It does not mirror the query — a mirror only proves the mirror. The real SQL
  and its params are captured off the `[:barkpark, :repo, :query]` telemetry
  event emitted during a live `check_new_task/5`, and EXPLAIN ANALYZE runs on
  exactly those bytes.

  ## What reds it

    * restoring `ORDER BY similarity(...)` (or adding any second sort key) —
      the ordered index path is gone and a `Sort` node appears (asserted
      absent), and the capture itself flunks when no `<->` query is issued;
    * dropping the `limit` — the scan's actual row count exceeds the cap
      (asserted <=);
    * dropping the GiST index — the plan no longer names it (asserted present).

  The other two tests are the detection controls: bounding the scan must not
  cost a refusal, and must not manufacture one.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Dedup
  alias Barkpark.TenancyFixtures

  @dataset "production"

  # Must track Dedup's @candidate_limit. A drift here reads as a cap
  # regression, which is the correct alarm.
  @candidate_limit 500

  # Comfortably above the cap so "<= cap" is a real constraint and not a
  # vacuous green: with @seed_count < @candidate_limit the assertion would pass
  # for ANY plan. Every seeded title shares the probe's common words, so under
  # the OLD shape all of these rows cleared the 0.2 net and were sorted.
  @seed_count 1200

  @probe "task doc mutates 500 under DB pool saturation during the dedup candidate fetch"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    now = DateTime.utc_now()

    rows =
      for i <- 1..@seed_count do
        %{
          doc_id: "scanbound-#{i}",
          type: "task",
          dataset: @dataset,
          workspace_id: ws.id,
          project_id: project.id,
          # Same common words as the probe, different tail — trigram-near
          # (clears @candidate_trgm_floor) but token-Jaccard well under the
          # refuse bar, so these are candidates, never verdicts.
          title: "task doc mutates under DB pool saturation note number #{i}",
          status: "published",
          content: %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "description" => "seeded near-corpus row #{i}"
          },
          rev: "rev-scanbound-#{i}",
          inserted_at: now,
          updated_at: now
        }
      end

    {count, _} = Repo.insert_all(Document, rows)
    assert count == @seed_count

    Repo.query!("ANALYZE documents")
    %{scope: [workspace_id: ws.id, project_id: project.id]}
  end

  defp check(title, description, scope) do
    Dedup.check_new_task(
      "task",
      %{
        "doc_id" => "drafts.scanbound-probe",
        "title" => title,
        "content" => %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "description" => description
        }
      },
      @dataset,
      nil,
      scope
    )
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

  test "the candidate scan reads at most the cap, off the KNN index, with no Sort", %{
    scope: scope
  } do
    {sql, params} =
      capture_candidate_sql(fn -> check(@probe, "the incident probe", scope) end)

    # Small-corpus honesty (same device as the DedupWall sibling). At ~1200
    # sandbox rows a seq-scan, or a cheap index scan plus a top-N heapsort,
    # genuinely beats a GiST start-up, so the DEFAULT plan here proves nothing
    # about ELIGIBILITY — and eligibility is the property that goes away
    # silently under a refactor. Penalizing seqscan AND sort forces the planner
    # to reveal which ORDERED path exists. This does NOT make the test vacuous:
    # `enable_sort = off` is a cost penalty, not a prohibition, and an
    # `ORDER BY similarity(...)` has no ordered index path at any cost — it
    # still materializes a Sort node and still reds the refute below.
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

    assert Enum.max(scanned) <= @candidate_limit + 1,
           "the scan read #{Enum.max(scanned)} rows against a #{@candidate_limit} cap " <>
             "over a #{@seed_count}-row near-corpus — the LIMIT is not bounding the " <>
             "scan:\n#{plan}"
  end

  test "detection survives the bound: a near-duplicate is still REFUSED", %{scope: scope} do
    assert {:error, {:duplicate_task, payload}} =
             check(
               "task doc mutates under DB pool saturation note number 7",
               "seeded near-corpus row 7",
               scope
             )

    assert Enum.any?(payload.similar, &(&1.id == "scanbound-7"))
  end

  test "detection survives the bound: an unrelated title still PASSES", %{scope: scope} do
    assert :ok =
             check(
               "Postfix DKIM mail relay sidecar container image",
               "ship a mail relay image",
               scope
             )
  end
end
