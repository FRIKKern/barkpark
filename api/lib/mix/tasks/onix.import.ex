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
      {:ok, products} ->
        Mix.shell().info("==> parsed #{length(products)} <Product> element(s) from #{path}")
        Enum.each(products, &handle_product(&1, dataset, dry_run))

      {:error, reason} ->
        Mix.raise("ONIX parse failed: #{inspect(reason)}")
    end
  end

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
    else
      case Content.create_document("book", attrs, dataset) do
        {:ok, _doc} ->
          Mix.shell().info("created: drafts.#{doc_id} — #{title}")

        {:error, reason} ->
          Mix.shell().error("failed: #{doc_id} — #{inspect(reason)}")
      end
    end
  end
end
