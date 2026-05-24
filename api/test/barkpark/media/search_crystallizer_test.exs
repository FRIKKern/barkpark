defmodule Barkpark.Media.SearchCrystallizerTest do
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Media.{SearchCrystal, SearchEvent, SearchMergePattern}
  alias Barkpark.Media.SearchCrystallizer
  alias Barkpark.Repo

  test "crystallize_period aggregates queries and merge patterns" do
    day = ~D[2026-05-20]
    start = DateTime.new!(day, ~T[10:00:00.000000], "Etc/UTC")

    {:ok, e1} =
      insert_event("production", "Hero", "hero", %{}, false, "actor-1", start)

    {:ok, _e2} =
      insert_event(
        "production",
        "Hero",
        "hero",
        %{"kind" => "image"},
        false,
        "actor-1",
        DateTime.add(start, 60, :second),
        e1.id
      )

    _rejected =
      insert_event(
        "production",
        "",
        "",
        %{},
        true,
        "actor-2",
        DateTime.add(start, 120, :second),
        nil,
        "rejected",
        "profanity"
      )

    stats = SearchCrystallizer.crystallize_period("production", :day, day)

    assert stats.events >= 3
    assert stats.crystals >= 2
    assert stats.merge_patterns >= 1

    crystal =
      Repo.get_by!(SearchCrystal,
        dataset: "production",
        period: "day",
        period_start: day,
        query_normalized: "hero",
        filter_fingerprint: "q:hero"
      )

    assert crystal.search_count == 1

    filtered =
      Repo.get_by!(SearchCrystal,
        dataset: "production",
        period: "day",
        period_start: day,
        query_normalized: "hero",
        filter_fingerprint: "q:hero|kind:image"
      )

    assert filtered.search_count == 1

    quality =
      Repo.get_by!(SearchCrystal,
        dataset: "production",
        period: "day",
        period_start: day,
        query_normalized: "__quality__"
      )

    assert quality.rejected_count == 1

    pattern =
      Repo.one!(
        from(m in SearchMergePattern,
          where: m.dataset == "production" and m.period == "day" and m.period_start == ^day,
          limit: 1
        )
      )

    assert pattern.transition_count >= 1
    assert pattern.pattern_type in ["facet_add", "query_and_facet_add", "filter_merge"]
  end

  defp insert_event(
         dataset,
         query,
         normalized,
         filters,
         zero_hits,
         actor,
         at,
         parent \\ nil,
         quality \\ "accepted",
         reject_reason \\ nil
       ) do
    %SearchEvent{}
    |> Ecto.Changeset.change(%{
      dataset: dataset,
      query: query,
      query_normalized: normalized,
      filters: filters,
      result_count: if(zero_hits, do: 0, else: 3),
      zero_hits: zero_hits,
      actor_key: actor,
      quality: quality,
      reject_reason: reject_reason,
      parent_event_id: parent,
      inserted_at: at
    })
    |> Repo.insert()
  end
end
