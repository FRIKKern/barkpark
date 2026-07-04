defmodule Barkpark.Search.CrystallizerTest do
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Search.{Crystal, Crystallizer, Event, MergePattern}
  alias Barkpark.Repo

  @surface "media"
  @scope "production"

  test "crystallize_period aggregates queries and merge patterns" do
    day = ~D[2026-05-20]
    start = DateTime.new!(day, ~T[10:00:00.000000], "Etc/UTC")

    {:ok, e1} =
      insert_event("Hero", "hero", %{}, false, "actor-1", start)

    {:ok, _e2} =
      insert_event(
        "Hero",
        "hero",
        %{"kind" => "image"},
        false,
        "actor-1",
        DateTime.add(start, 60, :second),
        parent: e1.id
      )

    _rejected =
      insert_event(
        "",
        "",
        %{},
        true,
        "actor-2",
        DateTime.add(start, 120, :second),
        quality: "rejected",
        reject_reason: "profanity"
      )

    stats = Crystallizer.crystallize_period(@surface, @scope, :day, day)

    assert stats.events >= 3
    assert stats.crystals >= 2
    assert stats.merge_patterns >= 1

    crystal =
      Repo.get_by!(Crystal,
        surface: @surface,
        scope: @scope,
        period: "day",
        period_start: day,
        query_normalized: "hero",
        filter_fingerprint: "q:hero"
      )

    assert crystal.search_count == 1

    filtered =
      Repo.get_by!(Crystal,
        surface: @surface,
        scope: @scope,
        period: "day",
        period_start: day,
        query_normalized: "hero",
        filter_fingerprint: "q:hero|kind:image"
      )

    assert filtered.search_count == 1

    quality =
      Repo.get_by!(Crystal,
        surface: @surface,
        scope: @scope,
        period: "day",
        period_start: day,
        query_normalized: "__quality__"
      )

    assert quality.rejected_count == 1

    pattern =
      Repo.one!(
        from(m in MergePattern,
          where:
            m.surface == ^@surface and m.scope == ^@scope and m.period == "day" and
              m.period_start == ^day,
          limit: 1
        )
      )

    assert pattern.transition_count >= 1
    assert pattern.pattern_type in ["facet_add", "query_and_facet_add", "filter_merge"]
  end

  test "crystallize excludes test-tagged traffic from analytics" do
    day = ~D[2026-05-24]
    start = DateTime.new!(day, ~T[11:00:00.000000], "Etc/UTC")

    insert_event("real", "real", %{}, false, "actor-1", start, tags: [])

    insert_event(
      "smoke",
      "smoke",
      %{},
      false,
      "actor-2",
      DateTime.add(start, 30, :second),
      tags: ["test"]
    )

    Crystallizer.crystallize_period(@surface, @scope, :day, day)

    assert Repo.get_by(Crystal,
             surface: @surface,
             scope: @scope,
             period: "day",
             period_start: day,
             query_normalized: "real"
           )

    refute Repo.get_by(Crystal,
             surface: @surface,
             scope: @scope,
             period: "day",
             period_start: day,
             query_normalized: "smoke"
           )
  end

  test "crystallize_due backfills a trailing day window idempotently" do
    today = ~D[2026-05-30]
    # Two days before `today`: inside the trailing backfill window but NOT
    # yesterday, so the old single-day run would have missed it entirely.
    day = Date.add(today, -2)
    at = DateTime.new!(day, ~T[09:00:00.000000], "Etc/UTC")

    insert_event("backfill", "backfill", %{}, false, "actor-1", at)

    Crystallizer.crystallize_due(today)

    crystal =
      Repo.get_by!(Crystal,
        surface: @surface,
        scope: @scope,
        period: "day",
        period_start: day,
        query_normalized: "backfill",
        filter_fingerprint: "q:backfill"
      )

    assert crystal.search_count == 1

    # Re-running the whole due-window is an idempotent upsert: still exactly one
    # row at that key, same count — no duplicate, no runaway.
    Crystallizer.crystallize_due(today)

    rows =
      Repo.all(
        from(c in Crystal,
          where:
            c.surface == ^@surface and c.scope == ^@scope and c.period == "day" and
              c.period_start == ^day and c.query_normalized == "backfill"
        )
      )

    assert length(rows) == 1
    assert hd(rows).search_count == 1
  end

  test "crystallize_due self-heals a missed WEEK boundary within the backfill window" do
    # Wednesday (day_of_week 3): inside @backfill_days but NOT Monday, so the
    # old single-shot `day_of_week == 1` gate produced no week crystal at all —
    # a permanent weekly hole whenever the Monday cron run was missed.
    today = ~D[2026-06-03]
    week_start = Date.add(Date.beginning_of_week(today), -7)
    at = DateTime.new!(Date.add(week_start, 2), ~T[09:00:00.000000], "Etc/UTC")

    insert_event("weekheal", "weekheal", %{}, false, "actor-1", at)

    Crystallizer.crystallize_due(today)

    crystal =
      Repo.get_by!(Crystal,
        surface: @surface,
        scope: @scope,
        period: "week",
        period_start: week_start,
        query_normalized: "weekheal",
        filter_fingerprint: "q:weekheal"
      )

    assert crystal.search_count == 1
  end

  test "crystallize_due self-heals a missed MONTH boundary within the backfill window" do
    # 2nd of the month (day 2): inside @backfill_days but NOT the 1st, so the
    # old single-shot `today.day == 1` gate produced no month crystal at all.
    today = ~D[2026-07-02]
    month_start = Date.add(Date.beginning_of_month(today), -1) |> Date.beginning_of_month()
    at = DateTime.new!(Date.add(month_start, 14), ~T[09:00:00.000000], "Etc/UTC")

    insert_event("monthheal", "monthheal", %{}, false, "actor-1", at)

    Crystallizer.crystallize_due(today)

    crystal =
      Repo.get_by!(Crystal,
        surface: @surface,
        scope: @scope,
        period: "month",
        period_start: month_start,
        query_normalized: "monthheal",
        filter_fingerprint: "q:monthheal"
      )

    assert crystal.search_count == 1
  end

  defp insert_event(
         query,
         normalized,
         filters,
         zero_hits,
         actor,
         at,
         opts \\ []
       ) do
    tags = Keyword.get(opts, :tags, [])
    parent = Keyword.get(opts, :parent)
    quality = Keyword.get(opts, :quality, "accepted")
    reject_reason = Keyword.get(opts, :reject_reason)

    %Event{}
    |> Ecto.Changeset.change(%{
      surface: @surface,
      scope: @scope,
      query: query,
      query_normalized: normalized,
      filters: filters,
      result_count: if(zero_hits, do: 0, else: 3),
      zero_hits: zero_hits,
      actor_key: actor,
      quality: quality,
      reject_reason: reject_reason,
      parent_event_id: parent,
      tags: tags,
      inserted_at: at
    })
    |> Repo.insert()
  end
end
