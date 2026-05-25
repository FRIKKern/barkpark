defmodule Barkpark.Search.SynonymsTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Search.{MergePattern, Synonyms}
  alias Barkpark.Repo

  @surface "documents"
  @scope "test"

  test "search_terms/3 expands one_way synonyms" do
    assert {:ok, _} = Synonyms.create(@surface, @scope, %{"from" => "hero", "to" => "phoenix"})

    terms = Synonyms.search_terms(@surface, @scope, "hero")

    assert "hero" in terms
    assert "phoenix" in terms
  end

  test "search_terms/3 expands alt_correction both ways" do
    assert {:ok, _} =
             Synonyms.create(@surface, @scope, %{
               "from" => "elixir",
               "to" => "erlang",
               "kind" => "alt_correction"
             })

    assert "elixir" in Synonyms.search_terms(@surface, @scope, "erlang")
    assert "erlang" in Synonyms.search_terms(@surface, @scope, "elixir")
  end

  test "candidates/3 surfaces zero_to_hit merge patterns not already promoted" do
    period_start = Date.utc_today()

    %MergePattern{}
    |> Ecto.Changeset.change(%{
      surface: @surface,
      scope: @scope,
      period: "week",
      period_start: period_start,
      from_fingerprint: "q:hero",
      to_fingerprint: "q:phoenix",
      pattern_type: "zero_to_hit",
      transition_count: 4,
      success_count: 3
    })
    |> Repo.insert!()

    [candidate | _] =
      Synonyms.candidates(@surface, @scope,
        period: "week",
        period_start: period_start
      )

    assert candidate.from == "hero"
    assert candidate.to == "phoenix"
    assert candidate.source == "auto"

    assert {:ok, _} = Synonyms.create(@surface, @scope, %{"from" => "hero", "to" => "phoenix"})
    assert [] = Synonyms.candidates(@surface, @scope, period: "week", period_start: period_start)
  end
end
