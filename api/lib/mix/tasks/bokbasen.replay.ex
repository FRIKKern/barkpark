defmodule Mix.Tasks.Bokbasen.Replay do
  @moduledoc """
  Re-run a Bokbasen publish for a single `book` document — either by enqueuing
  a real `Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker` Oban job, or in
  `--dry-run` mode by re-rendering the ONIX 3.0 XML in-memory without calling
  the live Bokbasen API.

  Phase 7 WI6. Operator tool — reads/writes the local DB, never logs
  credentials.

  ## Usage

      mix bokbasen.replay --book-id <doc_id>
      mix bokbasen.replay --book-id <doc_id> --dry-run

  ## Behaviour

    * Without `--dry-run` — enqueues a `PublishWorker` job via
      `Oban.insert/1` and prints the resulting `job.id` and `job.state`. The
      worker handles the rest of the lifecycle. No HTTP from this task.

    * With `--dry-run` — calls `Barkpark.Plugins.OnixEdit.Export.to_iodata/1`
      against the document's `book` content, runs the same XSD gate the
      worker would run, prints the first ~20 lines of the rendered XML plus
      a summary (byte count, validation result). Does NOT enqueue and does
      NOT call the Bokbasen API.

  Lookup tries `doc_id == <id>` first, then `drafts.<id>` if not found.

  ## Exit codes

    * `0` — success (job enqueued, or dry-run rendered cleanly)
    * `1` — bad arguments / book not found / XSD-invalid render

  ## Examples

      mix bokbasen.replay --book-id b-001
      mix bokbasen.replay --book-id drafts.b-001 --dry-run
  """
  @shortdoc "Re-run a Bokbasen publish (enqueue or dry-run XML render)"

  use Mix.Task

  alias Barkpark.Content
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Plugins.OnixEdit.Export

  @switches [book_id: :string, dry_run: :boolean]
  @type_default "book"
  @dataset_default "production"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts =
      try do
        OptionParser.parse!(argv, strict: @switches)
      rescue
        e in OptionParser.ParseError ->
          Mix.shell().error("invalid arguments: #{Exception.message(e)}")
          Mix.raise("usage: mix bokbasen.replay --book-id <doc_id> [--dry-run]")
      end
      |> elem(0)

    book_id = Keyword.get(opts, :book_id)
    dry_run? = Keyword.get(opts, :dry_run, false)

    if is_nil(book_id) or book_id == "" do
      Mix.shell().error("--book-id is required")
      Mix.raise("usage: mix bokbasen.replay --book-id <doc_id> [--dry-run]")
    end

    case lookup_book(book_id) do
      {:ok, doc} ->
        if dry_run?, do: dry_run(doc), else: enqueue(doc)

      {:error, :not_found} ->
        Mix.shell().error(
          "book not found: doc_id=#{inspect(book_id)} (also tried drafts.#{book_id})"
        )

        Mix.raise("book not found")
    end
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

  defp enqueue(doc) do
    args = %{
      "document_id" => doc.doc_id,
      "type" => doc.type,
      "dataset" => doc.dataset
    }

    case args |> PublishWorker.new() |> Oban.insert() do
      {:ok, job} ->
        Mix.shell().info("enqueued PublishWorker job")
        Mix.shell().info("  job_id    : #{job.id}")
        Mix.shell().info("  job_state : #{job.state}")
        Mix.shell().info("  document  : #{doc.doc_id} (type=#{doc.type}, dataset=#{doc.dataset})")
        :ok

      {:error, reason} ->
        Mix.shell().error("Oban.insert failed: #{inspect(reason)}")
        Mix.raise("could not enqueue job")
    end
  end

  defp dry_run(doc) do
    book_doc =
      (doc.content || %{})
      |> Map.delete("bp_export_status")
      |> Map.put("_id", doc.doc_id)
      |> Map.put("_publishedId", Content.published_id(doc.doc_id))
      |> Map.put("_type", doc.type)

    case Export.to_iodata(book_doc) do
      {:ok, iodata} ->
        binary = IO.iodata_to_binary(iodata)
        lines = binary |> String.split("\n") |> Enum.take(20)

        Mix.shell().info("==> dry-run XML render (first 20 lines):")
        Enum.each(lines, &Mix.shell().info/1)

        Mix.shell().info("")
        Mix.shell().info("==> summary")
        Mix.shell().info("  document   : #{doc.doc_id}")
        Mix.shell().info("  type       : #{doc.type}")
        Mix.shell().info("  dataset    : #{doc.dataset}")
        Mix.shell().info("  bytes      : #{byte_size(binary)}")
        Mix.shell().info("  xsd_valid  : true")
        Mix.shell().info("  enqueued   : false (dry-run)")
        :ok

      {:error, {:xsd_invalid, reasons}} ->
        Mix.shell().error("==> XSD validation FAILED")
        Enum.each(reasons, fn r -> Mix.shell().error("  - #{r}") end)
        Mix.raise("XSD validation failed")
    end
  end
end
