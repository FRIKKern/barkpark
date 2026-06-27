defmodule Barkpark.Search.InteractionTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Search.{Crystallizer, Event, Intelligence}
  alias Barkpark.Repo

  @surface "documents"
  @scope "production"

  test "record_interaction links click to prior search event" do
    {:ok, search} =
      %Event{}
      |> Ecto.Changeset.change(%{
        surface: @surface,
        scope: @scope,
        event_type: "search",
        query: "Hero Post",
        query_normalized: "hero post",
        filters: %{"type" => "post"},
        result_count: 3,
        zero_hits: false,
        actor_key: "client:test"
      })
      |> Repo.insert()

    assert {:ok, click_id} =
             Intelligence.record_interaction(
               @surface,
               @scope,
               %{
                 "queryEventId" => search.id,
                 "objectId" => "p1",
                 "position" => 1,
                 "type" => "select"
               },
               actor_key: "client:test",
               source: "test"
             )

    click = Repo.get!(Event, click_id)
    assert click.event_type == "select"
    assert click.query_event_id == search.id
    assert click.object_id == "p1"
    assert click.position == 1
    assert click.query_normalized == "hero post"
  end

  test "crystallize rolls click_count and ctr into query crystals" do
    day = ~D[2026-05-23]
    at = DateTime.new!(day, ~T[09:00:00.000000], "Etc/UTC")

    {:ok, search} =
      %Event{}
      |> Ecto.Changeset.change(%{
        surface: @surface,
        scope: @scope,
        event_type: "search",
        query: "alpha",
        query_normalized: "alpha",
        filters: %{},
        result_count: 2,
        zero_hits: false,
        actor_key: "actor-1",
        inserted_at: at
      })
      |> Repo.insert()

    {:ok, _click} =
      %Event{}
      |> Ecto.Changeset.change(%{
        surface: @surface,
        scope: @scope,
        event_type: "click",
        query: "alpha",
        query_normalized: "alpha",
        filters: %{},
        object_id: "p1",
        position: 0,
        query_event_id: search.id,
        result_count: 0,
        zero_hits: false,
        actor_key: "actor-1",
        inserted_at: DateTime.add(at, 30, :second)
      })
      |> Repo.insert()

    Crystallizer.crystallize_period(@surface, @scope, :day, day)

    crystal =
      Repo.get_by!(Barkpark.Search.Crystal,
        surface: @surface,
        scope: @scope,
        period: "day",
        period_start: day,
        query_normalized: "alpha",
        filter_fingerprint: "q:alpha"
      )

    assert crystal.search_count == 1
    assert crystal.click_count == 1
    assert crystal.ctr == 1.0
  end
end
