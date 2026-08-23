defmodule Barkpark.Search.IntelligenceTest do
  # async: false — this module swaps node-global env
  # (`:barkpark, :search_intel_record_async`) to exercise the off-request INSERT
  # path. Application env is ONE value for the whole node — the SQL sandbox
  # isolates the DB connection, never the VM-global env (see
  # api/test/barkpark/application_env_isolation_test.exs, which proves the leak
  # channel). Ratchet: scripts/async_env_seam_scan.exs.
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Search.{Crystallizer, Event, Intelligence}
  alias Barkpark.Repo

  @surface "media"
  @scope "production"

  test "prune/1 deletes events older than retention window" do
    {:ok, old} =
      %Event{}
      |> Ecto.Changeset.change(%{
        surface: "media",
        scope: "production",
        query: "stale",
        filters: %{},
        actor_key: "test",
        result_count: 1,
        zero_hits: false
      })
      |> Repo.insert()

    stale_at = DateTime.add(DateTime.utc_now(), -100, :day)

    from(e in Event, where: e.id == ^old.id)
    |> Repo.update_all(set: [inserted_at: stale_at])

    {:ok, _fresh} =
      %Event{}
      |> Ecto.Changeset.change(%{
        surface: "media",
        scope: "production",
        query: "fresh",
        filters: %{},
        actor_key: "test",
        result_count: 2,
        zero_hits: false
      })
      |> Repo.insert()

    assert Intelligence.prune(retention_days: 90) == 1
    assert Repo.aggregate(Event, :count, :id) == 1
    assert Repo.get_by(Event, query: "fresh")
  end

  test "popular suggestions read day crystals after raw events are pruned" do
    day = Date.add(Date.utc_today(), -5)
    at = DateTime.new!(day, ~T[10:00:00.000000], "Etc/UTC")

    for _ <- 1..3 do
      insert_event("popular-prune", "popular-prune", false, at)
    end

    Crystallizer.crystallize_period(@surface, @scope, :day, day)
    Repo.delete_all(Event)

    result = Intelligence.suggestions(@surface, @scope, "actor-1", nil, min_search_count: 3)

    assert Enum.any?(result.popular, fn row ->
             row.query == "popular-prune" and row.count >= 3
           end)
  end

  test "record/6 names each no-write cause instead of a bare :skipped (pds-bl-w36-record6-conflation)" do
    # disabled — recording is off for this request.
    assert {:skipped, :recording_disabled} =
             Intelligence.record(@surface, @scope, %{query: "skip-me"}, 1, 5, disabled: true)

    # record: false — the caller opted this one call out.
    assert {:skipped, :record_false} =
             Intelligence.record(@surface, @scope, %{query: "skip-me"}, 1, 5, record: false)

    # offset > 0 — a follow-up page is not a new search event.
    assert {:skipped, :offset_page} =
             Intelligence.record(@surface, @scope, %{query: "skip-me", offset: 20}, 1, 5)

    # unqualifiable query — blank after normalization, nothing to record.
    assert {:skipped, :unqualified_query} =
             Intelligence.record(@surface, @scope, %{query: "   "}, 1, 5)

    assert Repo.aggregate(Event, :count, :id) == 0
  end

  test "record/6 emits telemetry for outcomes" do
    handler_id = "intel-record-test-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:barkpark, :search, :intel, :record],
        fn _event, measurements, metadata, _config ->
          send(self(), {:telemetry, measurements, metadata})
        end,
        nil
      )

    assert {:ok, _id} =
             Intelligence.record(@surface, @scope, %{query: "analytics", filters: %{}}, 2, 4)

    assert_receive {:telemetry, %{count: 1},
                    %{surface: "media", scope: "production", result: :ok}}

    assert {:skipped, :record_false} =
             Intelligence.record(@surface, @scope, %{query: "x"}, 0, 1, record: false)

    # Telemetry now carries the named cause alongside the coarse status.
    assert_receive {:telemetry, %{count: 1},
                    %{
                      surface: "media",
                      scope: "production",
                      result: :skipped,
                      reason: :record_false
                    }}

    :telemetry.detach(handler_id)
  end

  test "suggestions ignore prefixes shorter than four letters" do
    at = DateTime.utc_now()

    for _ <- 1..3, do: insert_event("alphabet", "alphabet", false, at)
    for _ <- 1..3, do: insert_event("beta", "beta", false, at)

    filtered =
      Intelligence.suggestions(@surface, @scope, "actor-1", "alph", min_search_count: 3)

    assert filtered.popular != []
    assert Enum.all?(filtered.popular, &String.starts_with?(&1.query, "alph"))

    broad =
      Intelligence.suggestions(@surface, @scope, "actor-1", "be", min_search_count: 3)

    assert length(broad.popular) >= 2
  end

  test "normalize_suggest_prefix returns nil for non-binary params (no 500 on ?q[]=x)" do
    # A list param (?q[]=x) or a map param must not crash the shared suggestions handlers.
    assert Intelligence.normalize_suggest_prefix_for_test(["x"]) == nil
    assert Intelligence.normalize_suggest_prefix_for_test(%{"a" => 1}) == nil
  end

  test "normalize_suggest_prefix still normalizes a binary prefix" do
    assert Intelligence.normalize_suggest_prefix_for_test("Hello") == "hello"
  end

  test "insights/3 tolerates a map/list :period param instead of 500ing on to_string" do
    # `?period[k]=v` reaches insights as a map; `to_string/1` on it used to raise
    # (Protocol.UndefinedError → 500). It must fall back to the default window.
    assert %{} = Intelligence.insights(@surface, @scope, period: %{"k" => "v"})
    assert %{} = Intelligence.insights(@surface, @scope, period: ["week"])
    # A well-formed binary period still works unchanged.
    assert %{} = Intelligence.insights(@surface, @scope, period: "day")
  end

  test "insights default week window lands on the crystallizer's Monday key on any weekday" do
    today = Date.utc_today()
    # The crystallizer runs on Monday and keys the completed week to
    # `that_monday - 7`. From any later day the same key is
    # `beginning_of_week(today) - 7`. The default MUST land there on all days —
    # the old `today - 7` default only matched on Mondays.
    week_key = today |> Date.beginning_of_week(:monday) |> Date.add(-7)

    at = DateTime.new!(Date.add(week_key, 1), ~T[10:00:00.000000], "Etc/UTC")
    for _ <- 1..3, do: insert_event("weekly-default", "weekly-default", false, at)

    Crystallizer.crystallize_period(@surface, @scope, :week, week_key)

    result = Intelligence.insights(@surface, @scope, period: "week")

    assert result.periodStart == week_key
    assert Enum.any?(result.topQueries, &(&1.query == "weekly-default"))
  end

  test "insights default month window lands on the crystallizer's previous-month key" do
    today = Date.utc_today()
    # The crystallizer runs on the 1st and keys the row to the first of the
    # PREVIOUS month. The old default pointed at the CURRENT month → always empty.
    month_key =
      today |> Date.beginning_of_month() |> Date.add(-1) |> Date.beginning_of_month()

    at = DateTime.new!(Date.add(month_key, 5), ~T[10:00:00.000000], "Etc/UTC")
    for _ <- 1..3, do: insert_event("monthly-default", "monthly-default", false, at)

    Crystallizer.crystallize_period(@surface, @scope, :month, month_key)

    result = Intelligence.insights(@surface, @scope, period: "month")

    assert result.periodStart == month_key
    assert Enum.any?(result.topQueries, &(&1.query == "monthly-default"))
  end

  test "insights month delta compares against the true previous-month crystal" do
    month_key = ~D[2026-06-01]
    prev_key = ~D[2026-05-01]

    prev_at = DateTime.new!(Date.add(prev_key, 10), ~T[10:00:00.000000], "Etc/UTC")
    for _ <- 1..5, do: insert_event("delta-q", "delta-q", false, prev_at)
    Crystallizer.crystallize_period(@surface, @scope, :month, prev_key)
    Repo.delete_all(Event)

    cur_at = DateTime.new!(Date.add(month_key, 10), ~T[10:00:00.000000], "Etc/UTC")
    for _ <- 1..8, do: insert_event("delta-q", "delta-q", false, cur_at)
    Crystallizer.crystallize_period(@surface, @scope, :month, month_key)

    result = Intelligence.insights(@surface, @scope, period: "month", period_start: month_key)
    row = Enum.find(result.topQueries, &(&1.query == "delta-q"))

    assert row.searchCount == 8
    # delta = current(8) − previous-month(5) = 3, NOT the full 8 (old `-30 days`
    # landed on May 2, matched no crystal, so delta was the whole count).
    assert row.searchCountDelta == 3
  end

  test "insights rates are period-exact — events after period_end are excluded" do
    day_key = ~D[2026-06-15]
    in_window = DateTime.new!(day_key, ~T[10:00:00.000000], "Etc/UTC")
    # After the day's half-open end (period_end = day_key + 1 @ 00:00).
    after_window = DateTime.new!(Date.add(day_key, 1), ~T[10:00:00.000000], "Etc/UTC")

    # In-window: 1 zero-hit + 1 hit → zeroHitRate should be 0.5 for the period.
    insert_event("rate-zero", "rate-zero", true, in_window)
    insert_event("rate-hit", "rate-hit", false, in_window)

    # Outside the window: 2 more zero-hit rows. If the upper bound did NOT bite,
    # the rate would drift to 3/4 = 0.75; period-exact it stays 1/2 = 0.5.
    insert_event("rate-late-a", "rate-late-a", true, after_window)
    insert_event("rate-late-b", "rate-late-b", true, after_window)

    result = Intelligence.insights(@surface, @scope, period: "day", period_start: day_key)

    assert result.zeroHitRate == 0.5
  end

  defp insert_event(query, normalized, zero_hits, at) do
    %Event{}
    |> Ecto.Changeset.change(%{
      surface: @surface,
      scope: @scope,
      query: query,
      query_normalized: normalized,
      filters: %{},
      result_count: if(zero_hits, do: 0, else: 4),
      zero_hits: zero_hits,
      actor_key: "actor-1",
      quality: "accepted",
      inserted_at: at
    })
    |> Repo.insert!()
  end

  describe "async record (prod path — pre-generated id, background insert)" do
    # Prod runs the record INSERT off-request (search_intel_record_async: true);
    # tests default it OFF for determinism. This is the async path's own proof:
    # the returned searchEventId must be the row's id once the background task
    # lands (Task.* propagates $callers, so the sandbox owns the connection).
    test "returns the pre-generated id immediately and the row lands with that id" do
      prev = Application.get_env(:barkpark, :search_intel_record_async)
      Application.put_env(:barkpark, :search_intel_record_async, true)

      on_exit(fn -> Application.put_env(:barkpark, :search_intel_record_async, prev) end)

      assert {:ok, id} =
               Intelligence.record("documents", "async-ds", %{query: "asyncprobe"}, 3, 12)

      # The insert rides a supervised task — poll briefly for the row.
      event =
        Enum.reduce_while(1..50, nil, fn _, _ ->
          case Repo.get(Event, id) do
            nil ->
              Process.sleep(20)
              {:cont, nil}

            row ->
              {:halt, row}
          end
        end)

      assert %Event{} = event, "background insert never landed"
      assert event.id == id
      assert event.query == "asyncprobe"
      assert event.quality == "accepted"
    end
  end
end
