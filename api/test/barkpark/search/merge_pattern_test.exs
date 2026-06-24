defmodule Barkpark.Search.MergePatternTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Search.MergePattern
  alias Barkpark.Repo

  @surface "documents"
  @scope "production"

  defp build_pattern(attrs \\ %{}) do
    Map.merge(
      %{
        surface: @surface,
        scope: @scope,
        period: "day",
        period_start: ~D[2026-06-01],
        from_fingerprint: "q:alpha",
        to_fingerprint: "q:alpha|kind:image",
        pattern_type: "facet_add",
        transition_count: 3,
        success_count: 2
      },
      attrs
    )
  end

  test "struct has correct integer defaults before insertion" do
    m = %MergePattern{}
    assert m.transition_count == 0
    assert m.success_count == 0
  end

  test "struct fields match schema definition" do
    m = %MergePattern{}
    assert Map.has_key?(m, :surface)
    assert Map.has_key?(m, :scope)
    assert Map.has_key?(m, :period)
    assert Map.has_key?(m, :period_start)
    assert Map.has_key?(m, :from_fingerprint)
    assert Map.has_key?(m, :to_fingerprint)
    assert Map.has_key?(m, :pattern_type)
    assert Map.has_key?(m, :transition_count)
    assert Map.has_key?(m, :success_count)
  end

  test "inserts and reads back all fields correctly" do
    attrs = build_pattern()

    {:ok, inserted} =
      %MergePattern{}
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert()

    assert inserted.id != nil
    assert inserted.surface == @surface
    assert inserted.scope == @scope
    assert inserted.period == "day"
    assert inserted.period_start == ~D[2026-06-01]
    assert inserted.from_fingerprint == "q:alpha"
    assert inserted.to_fingerprint == "q:alpha|kind:image"
    assert inserted.pattern_type == "facet_add"
    assert inserted.transition_count == 3
    assert inserted.success_count == 2

    fetched = Repo.get!(MergePattern, inserted.id)
    assert fetched.from_fingerprint == "q:alpha"
    assert fetched.transition_count == 3
  end

  test "inserts multiple patterns with different fingerprints independently" do
    day = ~D[2026-06-02]

    {:ok, p1} =
      %MergePattern{}
      |> Ecto.Changeset.change(build_pattern(%{period_start: day, from_fingerprint: "q:cat", to_fingerprint: "q:cat|kind:image", transition_count: 1}))
      |> Repo.insert()

    {:ok, p2} =
      %MergePattern{}
      |> Ecto.Changeset.change(build_pattern(%{period_start: day, from_fingerprint: "q:dog", to_fingerprint: "q:dog|breed:lab", transition_count: 5}))
      |> Repo.insert()

    assert p1.id != p2.id
    assert p1.from_fingerprint == "q:cat"
    assert p2.from_fingerprint == "q:dog"
    assert p2.transition_count == 5
  end

  test "inserted_at is set automatically, updated_at is absent" do
    {:ok, inserted} =
      %MergePattern{}
      |> Ecto.Changeset.change(build_pattern())
      |> Repo.insert()

    assert %DateTime{} = inserted.inserted_at
    refute Map.has_key?(inserted, :updated_at)
  end
end
