defmodule Barkpark.Media.SearchAnalyticsTest do
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Media.SearchAnalytics
  alias Barkpark.Media.SearchEvent
  alias Barkpark.Repo

  test "prune/1 deletes events older than retention window" do
    {:ok, old} =
      %SearchEvent{}
      |> Ecto.Changeset.change(%{
        dataset: "production",
        query: "stale",
        filters: %{},
        actor_key: "test",
        result_count: 1,
        zero_hits: false
      })
      |> Repo.insert()

    stale_at = DateTime.add(DateTime.utc_now(), -100, :day)

    from(e in SearchEvent, where: e.id == ^old.id)
    |> Repo.update_all(set: [inserted_at: stale_at])

    {:ok, _fresh} =
      %SearchEvent{}
      |> Ecto.Changeset.change(%{
        dataset: "production",
        query: "fresh",
        filters: %{},
        actor_key: "test",
        result_count: 2,
        zero_hits: false
      })
      |> Repo.insert()

    assert SearchAnalytics.prune(retention_days: 90) == 1
    assert Repo.aggregate(SearchEvent, :count, :id) == 1
    assert Repo.get_by(SearchEvent, query: "fresh")
  end
end
