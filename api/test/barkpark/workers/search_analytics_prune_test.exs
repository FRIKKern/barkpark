defmodule Barkpark.Workers.SearchAnalyticsPruneTest do
  use Barkpark.DataCase, async: true
  use Oban.Testing, repo: Barkpark.Repo

  import Ecto.Query

  alias Barkpark.Search.Event
  alias Barkpark.Repo
  alias Barkpark.Search.Workers.Prune

  test "perform/1 prunes stale search events" do
    {:ok, event} =
      %Event{}
      |> Ecto.Changeset.change(%{
        surface: "media",
        scope: "production",
        query: "old",
        filters: %{},
        actor_key: "test",
        result_count: 0,
        zero_hits: true
      })
      |> Repo.insert()

    stale_at = DateTime.add(DateTime.utc_now(), -120, :day)

    from(e in Event, where: e.id == ^event.id)
    |> Repo.update_all(set: [inserted_at: stale_at])

    assert {:ok, %{deleted: 1}} = perform_job(Prune, %{})
    assert Repo.aggregate(Event, :count, :id) == 0
  end
end
