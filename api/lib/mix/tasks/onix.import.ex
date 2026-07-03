defmodule Mix.Tasks.Onix.Import do
  @moduledoc """
  Import ONIX 3.0 XML as draft book documents.

      mix onix.import path/to/feed.xml
      mix onix.import path/to/feed.xml --dataset staging
      mix onix.import path/to/feed.xml --dry-run

  Parses every `<Product>` element in the input file and creates a draft
  book document via `Barkpark.Content.create_document/3`. The doc_id
  derives from the product's `<RecordReference>` (host prefix stripped),
  falling back to the first `<ProductIdentifier>` `<IDValue>`, then to a
  random `imported-<n>` placeholder.

  `--dry-run` prints what would be created without writing to the DB.
  """

  use Mix.Task

  alias Barkpark.Content
  alias Barkpark.Plugins.OnixEdit.Importer

  @shortdoc "Import ONIX 3.0 XML as draft book documents"

  @switches [dataset: :string, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("unknown switches: #{inspect(invalid)}")
    end

    path =
      case positional do
        [p | _] -> p
        [] -> Mix.raise("usage: mix onix.import <file.xml> [--dataset <name>] [--dry-run]")
      end

    dataset = Keyword.get(opts, :dataset, "production")
    dry_run = Keyword.get(opts, :dry_run, false)

    unless dry_run, do: Mix.Task.run("app.start")

    xml = File.read!(path)

    case Importer.parse(xml) do
      {:ok, []} ->
        Mix.raise(
          "0 <Product> elements parsed from #{path} — check the ONIX namespace/short-tags " <>
            "(the default xmlns strip only handles the reference-3.0 default namespace; a " <>
            "prefixed or short-tag feed parses to nothing). Nothing was imported."
        )

      {:ok, products} ->
        Mix.shell().info("==> parsed #{length(products)} <Product> element(s) from #{path}")

        results = Enum.map(products, &handle_product(&1, dataset, dry_run))
        summarize(results)

      {:error, reason} ->
        Mix.raise("ONIX parse failed: #{inspect(reason)}")
    end
  end

  @doc false
  # Tally per-product outcomes and fail loudly (non-zero exit) if any product
  # failed. Public + @doc false so the exit-code contract is unit-testable
  # without a live DB. Returns :ok only when every product succeeded.
  @spec summarize([:ok | :error]) :: :ok | no_return()
  def summarize(results) do
    total = length(results)
    ok = Enum.count(results, &(&1 == :ok))
    failed = total - ok

    Mix.shell().info("==> done: #{ok} ok, #{failed} failed (of #{total})")

    if failed > 0 do
      Mix.raise(
        "ONIX import: #{failed} of #{total} product(s) failed — see per-product errors above."
      )
    end

    :ok
  end

  @spec handle_product(map(), String.t(), boolean()) :: :ok | :error
  defp handle_product(product, dataset, dry_run) do
    doc_id = Importer.doc_id_for(product)
    title = Importer.title_for(product) || "Untitled (imported)"

    attrs = %{
      "doc_id" => doc_id,
      "title" => title,
      "status" => "draft",
      "content" => product
    }

    if dry_run do
      Mix.shell().info("would create: drafts.#{doc_id} — #{title}")
      :ok
    else
      case Content.create_document("book", attrs, dataset, source: :cli) do
        {:ok, _doc} ->
          Mix.shell().info("created: drafts.#{doc_id} — #{title}")
          :ok

        {:error, {:halted, reason}} ->
          Mix.shell().error("cancelled by plugin: #{doc_id} — #{reason}")
          :error

        {:error, reason} ->
          Mix.shell().error("failed: #{doc_id} — #{inspect(reason)}")
          :error
      end
    end
  end
end
