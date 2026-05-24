defmodule Barkpark.Search.IntelligenceTest do
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Search.{Event, Intelligence}
  alias Barkpark.Repo

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
end
