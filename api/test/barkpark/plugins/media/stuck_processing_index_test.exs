defmodule Barkpark.Plugins.Media.StuckProcessingIndexTest do
  @moduledoc """
  Protective proof for the `StuckProcessingSweeper` candidate SELECT's index
  (task `asm-bl-processing-status-jsonb-index`).

  The fix has TWO halves and neither works alone, so both are pinned here:

    1. THE INDEX EXISTS, with the right shape. `documents_media_processing_idx`
       (migration 20260908094217) is a PARTIAL index keyed on `updated_at` with
       predicate `type = 'mediaAsset' AND content->>'bp_processing_status' =
       'processing'`. Asserted against `pg_indexes.indexdef`, so this locks the
       DEFINITION — reverting the migration, renaming the index, dropping the
       partial predicate, or moving the key column all red it.

    2. THE QUERY CAN REACH IT. A partial index is only usable when the planner
       can PROVE the query's WHERE implies the index predicate, and a BIND
       PARAMETER defeats that proof under a generic plan. So the emitted SQL is
       asserted to carry the type and the status key/value as SQL LITERALS, not
       `$n` placeholders. This is the half a reader would not think to check and
       the half a well-meaning "use the module attribute properly" refactor
       silently breaks.

  ## What this does NOT claim

  It does not assert PLAN CHOICE. The sandbox corpus is a handful of rows, where
  Postgres correctly prefers a seq-scan no matter what indexes exist; forcing
  the issue (`enable_seqscan = off`, or seeding tens of thousands of rows) buys a
  flakier test, not a truer one. Existence-and-definition plus literal-reachability
  is the honest guarantee, and it is exactly what regresses if the fix is undone.
  The plan evidence lives in the migration's moduledoc, measured under
  `plan_cache_mode = force_generic_plan` on a 200k-row table.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Repo

  @index "documents_media_processing_idx"

  test "#{@index} exists as a partial index on updated_at over processing mediaAssets" do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE tablename = 'documents' AND indexname = $1",
        [@index]
      )

    # NOT `assert [[indexdef]] = rows, "..."` — a pattern match inside assert/2
    # raises MatchError BEFORE assert/2 can render its message, so the guard's
    # explanation would be dead code in the exact run that needs it.
    indexdef =
      case rows do
        [[def_]] ->
          def_

        [] ->
          flunk("""
           Missing index #{@index} on `documents`.

           `StuckProcessingSweeper.stuck_candidates/1` filters
           `type='mediaAsset' AND content->>'bp_processing_status'='processing'`
           and orders by `updated_at`; without this index that is a seq-scan
           plus a sort on every cron tick. Migration:
           priv/repo/migrations/20260908094217_add_documents_media_processing_index.exs
          """)
      end

    # Key column — the ONLY one, which is what lets the LIMIT be a forward index
    # seek instead of a sort.
    assert indexdef =~ ~r/USING btree \(updated_at\)/,
           "expected #{@index} keyed on (updated_at) alone, got:\n#{indexdef}"

    # The PARTIAL predicate. Both conjuncts must be present or the index stops
    # being the tiny transient-state structure it is meant to be, and stops
    # matching the sweeper's WHERE.
    assert indexdef =~ "WHERE", "expected #{@index} to be PARTIAL, got:\n#{indexdef}"

    assert indexdef =~ "= 'mediaAsset'::text",
           "expected the partial predicate to pin type='mediaAsset', got:\n#{indexdef}"

    assert indexdef =~ "'bp_processing_status'::text) = 'processing'",
           "expected the partial predicate to pin the processing status, got:\n#{indexdef}"
  end

  test "the sweeper's candidate SELECT spells type and status as LITERALS, not bind params" do
    {sql, params} = candidate_sql()

    # The cutoff and the batch limit are legitimately parameterised — they vary
    # per tick. Nothing in the INDEX PREDICATE may be.
    assert length(params) == 2,
           "expected exactly the cutoff + limit as bind params, got #{inspect(params)}\n#{sql}"

    assert sql =~ "'mediaAsset'",
           """
           The candidate SELECT must spell the document type as a SQL LITERAL.
           A bind parameter defeats the planner's partial-index proof under a
           generic plan and silently restores the seq-scan. Got:
           #{sql}
           """

    assert sql =~ "'bp_processing_status'",
           """
           The candidate SELECT must spell the JSONB status KEY as a SQL
           LITERAL — `content->>$n` can never match the partial index's
           `content->>'bp_processing_status'` predicate. Got:
           #{sql}
           """

    assert sql =~ "'processing'",
           "the candidate SELECT must spell the status VALUE as a literal, got:\n#{sql}"

    # The inverse, stated directly: no `->>$n` may survive in this query.
    refute sql =~ ~r/->>\s*\$\d/,
           "the JSONB key must not be a bind parameter, got:\n#{sql}"
  end

  # Reach the private candidate query through the public sweep path by capturing
  # the SQL Ecto emits for it. `stuck_candidates/1` is private on purpose (it is
  # an implementation detail of `sweep/1`), so instead of making it public — which
  # would change the module's surface just to test it — we rebuild the identical
  # query shape ONLY if the module does not expose it. It does not, so we assert
  # against the real emitted statement captured from a live sweep.
  defp candidate_sql do
    parent = self()

    handler = fn _event, _measure, %{query: query, params: params}, _cfg ->
      # Keyed on the SHAPE of the candidate SELECT (a `documents` read carrying a
      # JSONB `->>` extraction), NOT on the literals under test — otherwise the
      # mutation this test exists to catch would make the capture silently miss
      # and the red would name a missing statement instead of the missing
      # literal. With an empty corpus `sweep/1` issues exactly this one query.
      if is_binary(query) and String.contains?(query, "FROM \"documents\"") and
           String.contains?(query, "->>") do
        send(parent, {:candidate_sql, query, params})
      end

      :ok
    end

    id = "stuck-processing-index-test-#{System.unique_integer([:positive])}"
    :telemetry.attach(id, [:barkpark, :repo, :query], handler, nil)

    try do
      # Drives the real candidate SELECT. An empty corpus is fine — we are
      # capturing the STATEMENT, not rows.
      Barkpark.Plugins.Media.StuckProcessingSweeper.sweep(900)
    after
      :telemetry.detach(id)
    end

    receive do
      {:candidate_sql, sql, params} -> {sql, params}
    after
      0 ->
        flunk("""
        Never observed the sweeper's candidate SELECT on `documents`.

        The capture keys on a `documents` read carrying a JSONB `->>`
        extraction, which is the candidate SELECT's shape regardless of how its
        constants are spelled. Reaching here means `stuck_candidates/1` no
        longer issues that query at all (renamed, restructured, or the JSONB
        status filter dropped) — re-point the capture at its replacement.
        """)
    end
  end
end
