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

  test "expand_terms/4 answers in one read what search_terms/4 and correction_for/4 answer per word" do
    assert {:ok, _} = Synonyms.create(@surface, @scope, %{"from" => "hero", "to" => "phoenix"})

    assert {:ok, _} =
             Synonyms.create(@surface, @scope, %{
               "from" => "elixir",
               "to" => "erlang",
               "kind" => "alt_correction"
             })

    assert {:ok, _} =
             Synonyms.create(@surface, @scope, %{
               "from" => "colour",
               "to" => "color",
               "kind" => "alt_correction"
             })

    words = ["Hero", "erlang", "plain", "color", " "]
    {terms, corrected} = Synonyms.expand_terms(@surface, @scope, words)

    for w <- words do
      assert Enum.sort(terms[w]) == Enum.sort(Synonyms.search_terms(@surface, @scope, w)),
             "terms of #{inspect(w)}"
    end

    assert corrected == Enum.find_value(words, &Synonyms.correction_for(@surface, @scope, &1))
    assert corrected == "phoenix"
    assert {_, "elixir"} = Synonyms.expand_terms(@surface, @scope, ["plain", "erlang"])
    assert {%{"plain" => ["plain"]}, nil} = Synonyms.expand_terms(@surface, @scope, ["plain"])
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
