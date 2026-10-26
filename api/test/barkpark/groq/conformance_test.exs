defmodule Barkpark.Groq.ConformanceTest do
  @moduledoc """
  Runs Sanity's GROQ test suite (MIT, vendored in
  test/fixtures/groq_test_suite/) against `Barkpark.Groq.Parser` and
  `Barkpark.Groq.Evaluator` over in-memory datasets.

  The suite holds tests that the engine does not pass yet, so this test pins a
  floor rather than demanding every case: the pass count may rise but must not
  fall below `@floor`. Raise the floor when a change passes more cases. Set
  GROQ_CONFORMANCE_REPORT=<path> to write every failing case to a file.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Groq.{Evaluator, MemorySource, Parser}

  @fixture Path.expand("../../fixtures/groq_test_suite/suite.ndjson.gz", __DIR__)
  @external_resource @fixture

  # Pass count measured when the floor was last raised; see the moduledoc.
  @floor 7_156
  @now ~U[2026-01-01 00:00:00.000Z]

  test "the evaluator passes the GROQ conformance suite at or above the pinned floor" do
    {datasets, tests} = load_suite()

    results =
      for t <- tests do
        {t, run_case(t, Map.fetch!(datasets, t["dataset"]))}
      end

    failures = for {t, {:fail, why}} <- results, do: {t, why}
    passed = length(results) - length(failures)
    total = length(results)

    if path = System.get_env("GROQ_CONFORMANCE_REPORT") do
      File.write!(path, Enum.map_join(failures, "\n", &format_failure/1))
    end

    IO.puts(
      "\nGROQ conformance: #{passed}/#{total} passed (#{Float.round(passed * 100 / total, 1)}%)"
    )

    assert passed >= @floor,
           "GROQ conformance fell to #{passed}/#{total} (floor #{@floor}). First failures:\n" <>
             (failures |> Enum.take(10) |> Enum.map_join("\n", &format_failure/1))
  end

  defp load_suite do
    entries =
      @fixture
      |> File.read!()
      |> :zlib.gunzip()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    datasets =
      for %{"_type" => "dataset"} = d <- entries, into: %{} do
        {d["_id"], MemorySource.new(d["documents"] || [])}
      end

    {datasets, for(%{"_type" => "test"} = t <- entries, do: t)}
  end

  defp run_case(t, source) do
    params = t["params"] || %{}
    valid? = t["valid"] != false

    task =
      Task.async(fn ->
        try do
          run_parsed(t, source, params, valid?)
        rescue
          e ->
            {:fail, {:crash, Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 600)}}
        end
      end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, reason} -> {:fail, {:crash, Exception.format_exit(reason)}}
      nil -> {:fail, :timeout}
    end
  end

  defp run_parsed(t, source, params, valid?) do
    case Parser.parse(t["query"], params) do
      {:error, _} when not valid? ->
        :pass

      {:error, e} ->
        {:fail, {:parse_error, e.description}}

      {:ok, _} when not valid? ->
        {:fail, :expected_parse_error}

      {:ok, tree} ->
        case Evaluator.evaluate(tree, source: source, now: @now) do
          {:ok, value} ->
            value = if contains_pos?(t["result"]), do: score_to_pos(value), else: value
            if same?(value, t["result"]), do: :pass, else: {:fail, {:result, value}}

          {:error, message} ->
            {:fail, {:eval_error, message}}
        end
    end
  end

  # The suite states score() results as ranks (`_pos`), as groq-js's runner
  # does in replaceScoreWithPos: equal scores share a rank, highest first.
  defp contains_pos?(%{"_pos" => _}), do: true
  defp contains_pos?(list) when is_list(list), do: Enum.any?(list, &contains_pos?/1)
  defp contains_pos?(%{} = map), do: Enum.any?(map, fn {_k, v} -> contains_pos?(v) end)
  defp contains_pos?(_), do: false

  defp score_to_pos(value) do
    ranks =
      value
      |> collect_scores([])
      |> Enum.uniq()
      |> Enum.sort(:desc)
      |> Enum.with_index(1)
      |> Map.new()

    replace_scores(value, ranks)
  end

  defp collect_scores(%{"_score" => s} = map, acc) when is_number(s),
    do:
      Enum.reduce(Map.delete(map, "_score"), [s * 1.0 | acc], fn {_k, v}, a ->
        collect_scores(v, a)
      end)

  defp collect_scores(%{} = map, acc),
    do: Enum.reduce(map, acc, fn {_k, v}, a -> collect_scores(v, a) end)

  defp collect_scores(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_scores/2)
  defp collect_scores(_, acc), do: acc

  defp replace_scores(%{"_score" => s} = map, ranks) when is_number(s) do
    map
    |> Map.delete("_score")
    |> Map.put("_pos", ranks[s * 1.0])
    |> Map.new(fn {k, v} -> {k, replace_scores(v, ranks)} end)
  end

  defp replace_scores(%{} = map, ranks),
    do: Map.new(map, fn {k, v} -> {k, replace_scores(v, ranks)} end)

  defp replace_scores(list, ranks) when is_list(list),
    do: Enum.map(list, &replace_scores(&1, ranks))

  defp replace_scores(other, _ranks), do: other

  # JSON equality with JavaScript number semantics: every number is a double.
  defp same?(a, b) when is_number(a) and is_number(b), do: a * 1.0 == b * 1.0

  defp same?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> same?(x, y) end)

  defp same?(a, b) when is_map(a) and is_map(b) do
    map_size(a) == map_size(b) and
      Enum.all?(a, fn {k, v} -> Map.has_key?(b, k) and same?(v, b[k]) end)
  end

  defp same?(a, b), do: a === b

  defp format_failure({t, why}) do
    "#{t["filename"]} | #{t["name"]} | #{inspect(t["query"])} | params=#{inspect(t["params"])} | " <>
      "expected=#{inspect(t["result"], limit: 20)} | got=#{inspect(why, limit: 20)}"
  end
end
