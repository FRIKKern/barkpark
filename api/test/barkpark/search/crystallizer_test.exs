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
