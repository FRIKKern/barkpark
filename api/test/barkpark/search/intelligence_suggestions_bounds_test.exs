defmodule Barkpark.Search.IntelligenceSuggestionsBoundsTest do
  # async: false — this module attaches a PROCESS-GLOBAL :telemetry handler on
  # Ecto's default [:barkpark, :repo, :query] event to capture the VERBATIM SQL
  # each query emits (Barkpark.Repo sets no custom telemetry_prefix). The handler
  # table is node-wide, so this module must never run concurrently with other DB
  # tests. Under the SQL sandbox, suggestion queries run in THIS process, so the
  # handler fires synchronously and the SQL lands in this mailbox.
  #
  # This is the fail-before harness for
  # task-felix-w14-search-suggestions-unbounded: it asserts the FOUR popular/nohits
  # GROUP BY aggregates over search_intel_crystals/search_intel_events carry a
  # SQL-side LIMIT, and the correction-session count emits COUNT(DISTINCT …) rather
  # than fetching every distinct session_key. It is a SQL-shape harness, NOT an
  # output-parity test (parity is asserted separately, below the cap).
  use Barkpark.DataCase, async: false

  alias Barkpark.QueryCounter
  alias Barkpark.Search.{Crystal, Event, Intelligence}
  alias Barkpark.Repo

  @surface "media"
  @scope "production"

  # LINEAGE-SCOPED SQL capture, via the shared `Barkpark.QueryCounter`. The
  # local copy this replaced was node-global: it captured every statement the
  # VM issued inside the window, and both assertions below are shape claims
  # over that capture — `length(crystal_grouped) == 2` reds on a foreign
  # GROUP BY, and the `refute` reds on a foreign `SELECT DISTINCT`. Ownership
  # is now decided by process lineage. See `Barkpark.QueryCounterTest`.

  defp insert_event(attrs) do
    %Event{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          surface: @surface,
          scope: @scope,
          event_type: "search",
          quality: "accepted",
          filters: %{},
          actor_key: "anon",
          result_count: 1,
          zero_hits: false,
          inserted_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp seed_popular_events do
    # gamma x5, beta x3, alpha x2 — distinct counts so ORDER BY is unambiguous.
    for {q, n} <- [{"gamma", 5}, {"beta", 3}, {"alpha", 2}], _ <- 1..n do
      insert_event(%{query: q, query_normalized: q, zero_hits: false})
    end
  end

  describe "SQL bounds (fail-before harness)" do
    test "every popular/nohits GROUP BY aggregate carries a SQL LIMIT" do

      # Seed one crystal with BOTH success_count>0 and zero_hit_count>0 so the two
      # crystal helpers fire, plus events with zero_hits false/true so the two
      # event helpers fire — all four aggregates exercised in one suggestions/5 call.
      day = Date.add(Date.utc_today(), -3)

      Repo.insert!(%Crystal{
        surface: @surface,
        scope: @scope,
        period: "day",
        period_start: day,
        query_normalized: "kryptonite",
        success_count: 7,
        zero_hit_count: 4,
        avg_result_count: 3.0
      })

      insert_event(%{query: "helios", query_normalized: "helios", zero_hits: false})
      insert_event(%{query: "voidquery", query_normalized: "voidquery", zero_hits: true})

      {_, sqls} =
        QueryCounter.sql(fn ->
          Intelligence.suggestions(@surface, @scope, "actor-1", nil, min_search_count: 1)
        end)

      grouped_intel =
        Enum.filter(sqls, fn s ->
          String.contains?(s, "GROUP BY") and
            (String.contains?(s, "search_intel_crystals") or
               String.contains?(s, "search_intel_events"))
        end)

      crystal_grouped = Enum.filter(grouped_intel, &String.contains?(&1, "search_intel_crystals"))
      event_grouped = Enum.filter(grouped_intel, &String.contains?(&1, "search_intel_events"))

      # All four sources fired: 2 over crystals (popular=sum success_count,
      # nohits=sum zero_hit_count) + 2 over events. recent_queries emits a
      # non-grouped (already-LIMITed) SELECT and is excluded by the GROUP BY filter.
      assert length(crystal_grouped) == 2,
             "expected 2 grouped crystal aggregates, got:\n#{Enum.join(crystal_grouped, "\n")}"

      assert length(event_grouped) == 2,
             "expected 2 grouped event aggregates, got:\n#{Enum.join(event_grouped, "\n")}"

      assert Enum.any?(crystal_grouped, &String.contains?(&1, "success_count")),
             "popular_from_crystals aggregate missing"

      assert Enum.any?(crystal_grouped, &String.contains?(&1, "zero_hit_count")),
             "nohits_from_crystals aggregate missing"

      # The load-bearing assertion — RED before the fix (none of the four carried
      # a LIMIT; truncation happened only in Elixir via Enum.take AFTER the fetch).
      for sql <- grouped_intel do
        assert String.contains?(sql, "LIMIT"),
               "grouped intel aggregate ran WITHOUT a SQL LIMIT:\n#{sql}"
      end
    end

    test "distinct correction-session count emits COUNT(DISTINCT …), not a full fetch" do

      {{:ok, _}, sqls} =
        QueryCounter.sql(fn ->
          Intelligence.record_correction(
            @surface,
            @scope,
            %{"from" => "colour", "to" => "color"},
            session_key: "sess-1"
          )
        end)

      # Fixed: a single COUNT(DISTINCT session_key) aggregate.
      assert Enum.any?(sqls, fn s ->
               String.contains?(s, "count(DISTINCT") and String.contains?(s, "session_key")
             end),
             "expected a COUNT(DISTINCT session_key) query, captured:\n#{Enum.join(sqls, "\n")}"

      # RED before the fix: the old code emitted `SELECT DISTINCT e0."session_key"
      # FROM "search_intel_events"` and counted the rows in Elixir via length/1.
      refute Enum.any?(sqls, fn s ->
               Regex.match?(~r/SELECT DISTINCT\s+\w+\."session_key"/, s) and
                 String.contains?(s, "search_intel_events")
             end),
             "correction count still fetches every distinct session_key row:\n#{Enum.join(sqls, "\n")}"
    end
  end

  describe "output parity below the per-source cap" do
    test "suggestions results are unchanged at normal cardinality" do
      seed_popular_events()

      popular =
        Intelligence.suggestions(@surface, @scope, "actor-2", nil, min_search_count: 1).popular

      # Default cap (500) sits far above 3 distinct rows, so the generous SQL
      # LIMIT drops nothing: identical to the pre-fix Enum.sort_by |> Enum.take(8).
      assert Enum.map(popular, & &1.query) == ["gamma", "beta", "alpha"]
      assert Enum.map(popular, & &1.count) == [5, 3, 2]
    end

    test "the per-source cap is the lever that governs output (and 500 is generous)" do
      seed_popular_events()

      full =
        Intelligence.suggestions(@surface, @scope, "actor-3", nil, min_search_count: 1).popular

      assert length(full) == 3, "default cap must keep all 3 rows (parity)"

      # Tighten the cap to 1: the SQL-side ORDER BY count DESC + LIMIT now truncates
      # each source to its single top row, proving the bound lives in SQL and that
      # the default 500 is what makes it non-altering at normal cardinality.
      Application.put_env(:barkpark, :search_suggestions_source_cap, 1)
      on_exit(fn -> Application.delete_env(:barkpark, :search_suggestions_source_cap) end)

      capped =
        Intelligence.suggestions(@surface, @scope, "actor-4", nil, min_search_count: 1).popular

      assert Enum.map(capped, & &1.query) == ["gamma"],
             "cap=1 must keep only the top-count row via SQL ORDER BY/LIMIT"
    end

    test "the cap governs the CRYSTAL aggregates too — ORDER BY direction + LIMIT are SQL-side" do
      # The events-only cap-lever above leaves the two crystal aggregates' ORDER BY
      # DESC direction behaviorally unproven: a reversed direction (keep the LEAST
      # popular / least zero-hit) or a dropped crystal LIMIT still passes the
      # SQL-text harness (LIMIT present) and the events-only lever (no crystals).
      # Seed two crystals with OPPOSITE success/zero-hit rankings and cap to 1 so
      # exactly the TOP crystal survives EACH aggregate — reds if either crystal
      # ORDER BY is reversed, or either crystal LIMIT is dropped.
      day = Date.add(Date.utc_today(), -3)

      for {q, success, zero_hits} <- [{"quartz", 9, 2}, {"flint", 2, 9}] do
        Repo.insert!(%Crystal{
          surface: @surface,
          scope: @scope,
          period: "day",
          period_start: day,
          query_normalized: q,
          success_count: success,
          zero_hit_count: zero_hits,
          avg_result_count: 1.0
        })
      end

      Application.put_env(:barkpark, :search_suggestions_source_cap, 1)
      on_exit(fn -> Application.delete_env(:barkpark, :search_suggestions_source_cap) end)

      result =
        Intelligence.suggestions(@surface, @scope, "actor-crystal", nil, min_search_count: 1)

      # popular_from_crystals: ORDER BY sum(success_count) DESC LIMIT 1 -> quartz.
      assert Enum.map(result.popular, & &1.query) == ["quartz"],
             "cap=1 must keep the highest-SUCCESS crystal via SQL ORDER BY DESC/LIMIT"

      # nohits_from_crystals: ORDER BY sum(zero_hit_count) DESC LIMIT 1 -> flint.
      assert Enum.map(result.nohits, & &1.query) == ["flint"],
             "cap=1 must keep the highest-ZERO-HIT crystal via SQL ORDER BY DESC/LIMIT"
    end
  end
end
