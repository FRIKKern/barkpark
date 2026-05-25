defmodule Mix.Tasks.Search.Eval do
  @shortdoc "Run golden search evaluation (Phase 7)"
  @moduledoc """
  Evaluates golden queries under `test/search_golden/{surface}/test.jsonl`.

      mix search.eval
      mix search.eval --surface documents --dataset pipeline
      mix search.eval --baseline test/search_golden/baseline.json

  Exits non-zero when expected ids are missing or baseline regresses.
  """

  use Mix.Task

  @switches [
    surface: :string,
    dataset: :string,
    baseline: :string,
    fixtures_dir: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    surface = opts[:surface] || "documents"
    dataset = opts[:dataset] || "production"
    eval_opts = if dir = opts[:fixtures_dir], do: [fixtures_dir: dir], else: []

    unless surface in ["documents", "media"] do
      Mix.raise("surface must be documents or media")
    end

    metrics = Barkpark.Search.GoldenEval.run(surface, dataset, eval_opts)

    IO.puts("""
    Golden eval (#{surface}/#{dataset})
      queries:       #{metrics.queries}
      zero_hit_rate: #{metrics.zero_hit_rate}
      MRR:           #{metrics.mrr}
      NDCG@10:       #{metrics.ndcg_at_10}
      failures:      #{length(metrics.failures)}
    """)

    if metrics.failures != [] do
      IO.puts(:stderr, "Failures:")
      Enum.each(metrics.failures, fn f -> IO.puts(:stderr, "  #{f.q}: #{f.reason}") end)
    end

    case opts[:baseline] do
      nil ->
        :ok

      path ->
        baseline = path |> File.read!() |> Jason.decode!()

        case Barkpark.Search.GoldenEval.compare(metrics, baseline) do
          :ok ->
            IO.puts("Baseline OK")

          {:error, msgs} ->
            Enum.each(msgs, &IO.puts(:stderr, &1))
            System.halt(1)
        end
    end

    if metrics.failures != [] do
      System.halt(1)
    end
  end
end
