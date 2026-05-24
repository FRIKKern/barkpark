defmodule Barkpark.Search.SurfaceIsolationTest do
  use Barkpark.DataCase, async: true

  import Ecto.Query
  alias Barkpark.Search.{Crystal, Crystallizer, Event, MergePattern}
  alias Barkpark.Repo

  @scope "production"
  @day ~D[2026-05-22]

  test "media and documents crystals coexist on the same scope" do
    start = DateTime.new!(@day, ~T[12:00:00.000000], "Etc/UTC")

    insert_event("media", "alpha", "alpha", %{}, false, "actor-1", start)
    insert_event("documents", "beta", "beta", %{}, false, "actor-1", start)

    Crystallizer.crystallize_period("media", @scope, :day, @day)
    Crystallizer.crystallize_period("documents", @scope, :day, @day)

    media =
      Repo.get_by!(Crystal,
        surface: "media",
        scope: @scope,
        period: "day",
        period_start: @day,
        query_normalized: "alpha"
      )

    documents =
      Repo.get_by!(Crystal,
        surface: "documents",
        scope: @scope,
        period: "day",
        period_start: @day,
        query_normalized: "beta"
      )

    assert media.search_count == 1
    assert documents.search_count == 1
  end

  test "merge patterns are isolated by surface" do
    start = DateTime.new!(@day, ~T[12:00:00.000000], "Etc/UTC")

    {:ok, m1} = insert_event("media", "Hero", "hero", %{}, false, "actor-1", start)

    insert_event(
      "media",
      "Hero",
      "hero",
      %{"kind" => "image"},
      false,
      "actor-1",
      DateTime.add(start, 60, :second),
      m1.id
    )

    {:ok, d1} = insert_event("documents", "Page", "page", %{}, false, "actor-2", start)

    insert_event(
      "documents",
      "Page",
      "page",
      %{"type" => "post"},
      false,
      "actor-2",
      DateTime.add(start, 60, :second),
      d1.id
    )

    Crystallizer.crystallize_period("media", @scope, :day, @day)
    Crystallizer.crystallize_period("documents", @scope, :day, @day)

    media_patterns = Repo.all(from(m in MergePattern, where: m.surface == "media"))
    document_patterns = Repo.all(from(m in MergePattern, where: m.surface == "documents"))

    assert length(media_patterns) >= 1
    assert length(document_patterns) >= 1
    assert Enum.all?(media_patterns, &(&1.scope == @scope))
    assert Enum.all?(document_patterns, &(&1.scope == @scope))
  end

  defp insert_event(surface, query, normalized, filters, zero_hits, actor, at, parent \\ nil) do
    %Event{}
    |> Ecto.Changeset.change(%{
      surface: surface,
      scope: @scope,
      query: query,
      query_normalized: normalized,
      filters: filters,
      result_count: if(zero_hits, do: 0, else: 2),
      zero_hits: zero_hits,
      actor_key: actor,
      quality: "accepted",
      parent_event_id: parent,
      inserted_at: at
    })
    |> Repo.insert()
  end
end
