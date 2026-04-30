defmodule Mix.Tasks.Bokbasen.Status do
  @moduledoc """
  Inspect Bokbasen publish status for `book` documents.

  Phase 7 WI6. Pure DB read — no HTTP, never logs credentials.

  ## Usage

      mix bokbasen.status                  # summary table: count per state
      mix bokbasen.status --book-id <id>   # detail for one book

  ## Detail mode

  Prints the parsed `bp_export_status` map for one document:

    * `state`            — current lifecycle state (one of the 9 below)
    * `last_action_at`   — `updated_at` from the status JSON
    * `submission_id`    — Bokbasen `bokbasen_submission_id`, if any
    * `last_error`       — error envelope (`type` + summary), if any

  ## Summary mode

  Prints a count of documents per state across the entire `book` corpus.
  All 9 lifecycle states are listed (rows with no documents show 0):

      pending, staging, staged, polling, accepted,
      rejected, failed, cancelled, cannot_cancel

  Documents with no `bp_export_status` are bucketed under `(none)`.

  ## Exit codes

    * `0` — success
    * `1` — book not found / DB error / bad arguments
  """
  @shortdoc "Inspect Bokbasen publish status (per-book or summary)"

  use Mix.Task

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Repo

  import Ecto.Query

  @switches [book_id: :string]
  @type_default "book"
  @dataset_default "production"
  @states ~w(pending staging staged polling accepted rejected failed cancelled cannot_cancel)

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts =
      try do
        OptionParser.parse!(argv, strict: @switches)
      rescue
        e in OptionParser.ParseError ->
          Mix.shell().error("invalid arguments: #{Exception.message(e)}")
          Mix.raise("usage: mix bokbasen.status [--book-id <doc_id>]")
      end
      |> elem(0)

    case Keyword.get(opts, :book_id) do
      nil -> summary()
      "" -> summary()
      id -> detail(id)
    end
  end

  defp detail(book_id) do
    case lookup_book(book_id) do
      {:ok, doc} ->
        status = PublishWorker.read_status(doc)
        state = Map.get(status, "state") || "(none)"
        last_action_at = Map.get(status, "updated_at") || "(never)"
        submission_id = Map.get(status, "bokbasen_submission_id") || "(none)"
        last_error = format_error(Map.get(status, "last_error"))

        Mix.shell().info("doc_id           : #{doc.doc_id}")
        Mix.shell().info("title            : #{doc.title || "(untitled)"}")
        Mix.shell().info("state            : #{state}")
        Mix.shell().info("last_action_at   : #{last_action_at}")
        Mix.shell().info("submission_id    : #{submission_id}")
        Mix.shell().info("last_error       : #{last_error}")
        :ok

      {:error, :not_found} ->
        Mix.shell().error("book not found: doc_id=#{inspect(book_id)}")
        Mix.raise("book not found")
    end
  end

  defp summary do
    counts = count_by_state()
    total = Enum.reduce(counts, 0, fn {_k, v}, acc -> acc + v end)

    Mix.shell().info(:io_lib.format("~-20s ~10s", ["state", "count"]) |> IO.iodata_to_binary())
    Mix.shell().info(String.duplicate("-", 32))

    Enum.each(@states, fn state ->
      n = Map.get(counts, state, 0)
      Mix.shell().info(:io_lib.format("~-20s ~10w", [state, n]) |> IO.iodata_to_binary())
    end)

    none_count = Map.get(counts, "(none)", 0)

    Mix.shell().info(
      :io_lib.format("~-20s ~10w", ["(none)", none_count])
      |> IO.iodata_to_binary()
    )

    Mix.shell().info(String.duplicate("-", 32))
    Mix.shell().info(:io_lib.format("~-20s ~10w", ["total", total]) |> IO.iodata_to_binary())
    :ok
  end

  defp count_by_state do
    Document
    |> where([d], d.type == ^@type_default and d.dataset == ^@dataset_default)
    |> Repo.all()
    |> Enum.reduce(%{}, fn doc, acc ->
      key =
        case Map.get(PublishWorker.read_status(doc), "state") do
          s when is_binary(s) and s != "" -> s
          _ -> "(none)"
        end

      Map.update(acc, key, 1, &(&1 + 1))
    end)
  end

  defp lookup_book(book_id) do
    with {:error, :not_found} <- Content.get_document(book_id, @type_default, @dataset_default) do
      drafts_id =
        if String.starts_with?(book_id, "drafts."),
          do: book_id,
          else: "drafts." <> book_id

      Content.get_document(drafts_id, @type_default, @dataset_default)
    end
  end

  defp format_error(nil), do: "(none)"
  defp format_error(""), do: "(none)"

  defp format_error(%{} = err) do
    type = Map.get(err, "type") || "unknown"

    summary =
      Map.get(err, "summary") ||
        Map.get(err, "reason") ||
        Map.get(err, "note") ||
        Map.get(err, "details") ||
        ""

    "#{type}: #{inspect(summary, limit: 200)}"
  end

  defp format_error(other), do: inspect(other, limit: 200)
end
