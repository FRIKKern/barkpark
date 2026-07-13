defmodule Barkpark.Workers.TagDistribution do
  @moduledoc """
  Daily heartbeat for the per-type tag-count distribution (authoring-excellence
  D45).

  The distribution itself is a pure, derivable query
  (`Barkpark.Content.TagDistribution.per_type/2`) — nothing is persisted (no new
  table, anti-inventory). This worker exists only to give it a regular cadence:
  once a day it computes the distribution over the walled types
  (`paper`, `task`) and `Logger.info`s the top-N tags per type, so the label
  vocabulary's shape is visible in prod logs without standing up a store that
  has no consumer yet.

  Failure mode this guards: without a heartbeat, tag fragmentation (a hundred
  near-duplicate tag names across the corpus) is invisible until someone thinks
  to run the query by hand. The daily log line makes drift observable.

  Runs on the shared `:default` queue with `max_attempts: 1` — a read-only
  summary that will run again tomorrow, so a single failed run should not
  retry-storm the queue.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias Barkpark.Content.TagDistribution

  # The publish wall's `@walled_types` — the types whose tags are governed and
  # therefore worth watching. Kept in sync with `Content.Lifecycle`.
  @walled_types ~w(paper task)
  @default_dataset "production"
  @default_top_n 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    dataset = Map.get(args, "dataset", @default_dataset)
    top_n = Map.get(args, "top_n", @default_top_n)

    @walled_types
    |> TagDistribution.per_type(dataset)
    |> log_distribution(dataset, top_n)

    :ok
  end

  defp log_distribution(rows, dataset, top_n) do
    rows
    |> Enum.group_by(& &1.type)
    |> Enum.each(fn {type, type_rows} ->
      summary =
        type_rows
        |> Enum.sort_by(& &1.count, :desc)
        |> Enum.take(top_n)
        |> Enum.map_join(", ", fn %{tag: tag, count: count} -> "#{tag}=#{count}" end)

      Logger.info(
        "[tag_distribution] dataset=#{dataset} type=#{type} distinct_tags=#{length(type_rows)} top#{top_n}: #{summary}"
      )
    end)
  end
end
