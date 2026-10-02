defmodule Barkpark.Search.GoldenSurfaceCoverageTest do
  @moduledoc """
  The gate that makes every shipped golden surface a surface that can FAIL.

  Three things were true on main at the time this file was written
  (task-e3072e262161be3e):

    1. `test/search_golden/media/` shipped a fixture nothing ran. Every
       `GoldenEval.run/3` call site in the suite passed `"documents"`; the only
       other caller, `mix search.eval`, is invoked by no workflow. A whole
       surface directory could rot, or be added, unnoticed.
    2. Both media entries declared `expect_ids: []` with no `must_exclude`.
       `score/3`'s `failure? = missing != [] or excluded_present != []` is then
       `false` for EVERY possible result set — structurally unfailable — and
       `mrr` / `ndcg_at_10` are 0.0 by construction, so even the metric arm
       carried no information.
    3. Consequently the media surface's numbers said nothing about retrieval.

  Each test below is the arm for one of those, and each derives what it checks
  from DISK rather than from a list retyped here: a surface directory added to
  `test/search_golden/` is picked up with no edit to this file, and a fixture
  entry added to any `test.jsonl` is checked with no edit either.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.GoldenMediaFixtures
  alias Barkpark.Search.{GoldenEval, SurfaceConfigs}

  # The scope every golden surface is scored in. The documents corpus below and
  # the media corpus in GoldenMediaFixtures are both seeded into it, so ONE
  # scope serves every surface directory on disk.
  @scope "pipeline"

  # A scope nothing is seeded into: the empty-index control for the media arm.
  @empty_scope "golden_media_empty_index"

  setup do
    SurfaceConfigs.seed_defaults!()
    seed_documents!()
    GoldenMediaFixtures.seed!(@scope)
    :ok
  end

  defp seed_documents! do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @scope
    )

    Content.upsert_schema(
      %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
      @scope
    )

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.p1", "title" => "Elixir Phoenix Guide"},
      @scope
    )

    Content.create_document(
      "author",
      %{"doc_id" => "drafts.p2", "title" => "Phoenix Wright"},
      @scope
    )

    Content.publish_document("p1", "post", @scope)
    Content.publish_document("p2", "author", @scope)
  end

  defp golden_root, do: Path.join([File.cwd!(), "test", "search_golden"])

  # Surface DIRECTORIES, not fixture files. A directory planted with no
  # test.jsonl in it is exactly the shape this must refuse — enumerating
  # `*/test.jsonl` would look straight past it.
  defp surface_dirs do
    golden_root()
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(golden_root(), &1)))
    |> Enum.sort()
  end

  defp fixture_entries do
    [golden_root(), "*", "test.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.with_index(1)
      |> Enum.map(fn {line, lineno} ->
        {Path.relative_to(path, golden_root()), lineno, Jason.decode!(line)}
      end)
    end)
  end

  # ------------------------------------------------------------ criterion 0

  test "every golden surface directory shipped on disk is scored by this gate" do
    surfaces = surface_dirs()

    # POSITIVE CONTROL. An empty enumeration would make the loop below run zero
    # times and pass while scoring nothing at all — the precise failure this
    # whole file exists to end.
    assert surfaces != [],
           "no surface directories found under #{golden_root()}; the enumeration " <>
             "that is supposed to drive this gate read NOTHING, so the gate is vacuous."

    for surface <- surfaces do
      metrics =
        try do
          GoldenEval.run(surface, @scope)
        rescue
          e in [FunctionClauseError, File.Error] ->
            flunk(
              "test/search_golden/#{surface}/ ships as a golden surface but is NOT scored: " <>
                "GoldenEval.run(#{inspect(surface)}, #{inspect(@scope)}) raised " <>
                "#{Exception.message(e)}. Either give the surface a run arm (a " <>
                "GoldenEval.run/3 clause, a test.jsonl and a seeded corpus) or delete " <>
                "the directory — a shipped surface nothing scores is a fixture that " <>
                "cannot fail."
            )
        end

      assert metrics.queries > 0,
             "surface #{surface} scored 0 queries; its test.jsonl is empty."

      assert metrics.failures == [],
             "surface #{surface} failed golden eval: #{inspect(metrics.failures)}"
    end
  end

  # ------------------------------------------------------------ criterion 1

  test "every fixture entry declares a non-empty expect_ids or must_exclude" do
    entries = fixture_entries()

    assert entries != [],
           "no fixture entries read from #{golden_root()}/*/test.jsonl; this arm is vacuous."

    toothless =
      Enum.filter(entries, fn {_path, _lineno, entry} ->
        (entry["expect_ids"] || []) == [] and (entry["must_exclude"] || []) == []
      end)

    assert toothless == [],
           "fixture entries with BOTH expect_ids and must_exclude empty can never fail: " <>
             "GoldenEval.score/3 computes failure? from `missing != [] or " <>
             "excluded_present != []`, and both are [] for every possible result set. " <>
             Enum.map_join(toothless, "; ", fn {path, lineno, entry} ->
               "#{path}:#{lineno} q=#{inspect(entry["q"])}"
             end)
  end

  # ------------------------------------------------------------ criterion 2

  test "the media surface's metrics come from real retrieval against a seeded corpus" do
    metrics = GoldenEval.run("media", @scope)

    assert metrics.queries == length(GoldenMediaFixtures.entries())
    assert metrics.failures == [], "media golden failed: #{inspect(metrics.failures)}"

    # The number that was 0.0 BY CONSTRUCTION before this task: with every
    # expect_ids empty, reciprocal_rank had nothing to rank and MRR could not
    # move off zero no matter what the retriever returned.
    assert metrics.mrr > 0,
           "media MRR is #{metrics.mrr}; the surface's metrics reflect no retrieval."

    assert metrics.ndcg_at_10 > 0
    assert metrics.zero_hit_rate == 0.0
  end

  test "the media surface reds against an empty index" do
    # THE CONTROL FOR THE ARM ABOVE. If media golden passed here too, the green
    # up there would be telling us about the harness, not about retrieval.
    metrics = GoldenEval.run("media", @empty_scope)

    assert metrics.queries == length(GoldenMediaFixtures.entries())
    assert metrics.mrr == 0.0
    assert metrics.zero_hit_rate == 1.0

    assert metrics.failures != [],
           "the media golden corpus passed against an EMPTY index — it cannot fail."
  end
end
