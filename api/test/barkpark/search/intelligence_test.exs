defmodule Barkpark.Search.IntelligenceTest do
  use Barkpark.DataCase, async: true

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

  test "record/6 returns skipped when disabled option is set" do
    assert :skipped =
             Intelligence.record(@surface, @scope, %{query: "skip-me"}, 1, 5, disabled: true)

    assert Repo.aggregate(Event, :count, :id) == 0
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
end
