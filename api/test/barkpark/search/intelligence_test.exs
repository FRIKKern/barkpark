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

    assert :skipped =
             Intelligence.record(@surface, @scope, %{query: "x"}, 0, 1, record: false)

    assert_receive {:telemetry, %{count: 1},
                    %{surface: "media", scope: "production", result: :skipped}}

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
