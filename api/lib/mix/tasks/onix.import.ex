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
  deterministic `imported-<hash>` placeholder.

  ## Withdrawal notices

  A `<Product>` carrying `<NotificationType>05</NotificationType>` (ONIX
  codelist 1: "Delete") or a non-empty `<DeletionText>` is a WITHDRAWAL, not
  a record to store. Those products are routed to
  `Barkpark.Content.delete_document/4` instead of `create_document/3`, which
  removes both the published and draft variants (revision history is
  preserved by the delete path). Before this branch existed the task created
  a fresh draft for every product unconditionally, so a withdrawn ISBN
  resurfaced as a new draft on every single sync — the exact opposite of what
  the notice asks for.

  A withdrawal for a record that was never imported is a no-op success, not a
  failure: `{:error, :not_found}` means the feed and the store already agree.

  `--dry-run` prints what would be created or withdrawn without writing to
  the DB.
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

    # parse_feed/1, not parse/1: one malformed <Product> must not discard the
    # rest of a publisher's feed, and xmerl `exit`s (not raises) on an
    # undeclared entity, which parse/1's rescue does not catch.
    case Importer.parse_feed(xml) do
      {:error, :no_products} ->
        Mix.raise(
          "0 <Product> elements parsed from #{path} — check the ONIX namespace/short-tags " <>
            "(the default xmlns strip only handles the reference-3.0 default namespace; a " <>
            "prefixed or short-tag feed parses to nothing). Nothing was imported."
        )

      {:error, {:all_products_failed, errors}} ->
        Enum.each(errors, &Mix.shell().error("skipped product ##{&1.index}: #{&1.reason}"))

        Mix.raise(
          "every <Product> in #{path} failed to parse (#{length(errors)} of #{length(errors)}). " <>
            "Nothing was imported."
        )

      {:ok, %{products: products, skipped: skipped, errors: errors}} ->
        Mix.shell().info(
          "==> parsed #{length(products)} <Product> element(s) from #{path}" <>
            if(skipped > 0, do: " (#{skipped} skipped)", else: "")
        )

        Enum.each(errors, &Mix.shell().error("skipped product ##{&1.index}: #{&1.reason}"))

        results = Enum.map(products, &handle_product(&1, dataset, dry_run))

        # A skipped node is a failed product: it must count toward the
        # non-zero exit, otherwise a feed that silently lost records still
        # exits 0.
        summarize(results ++ List.duplicate(:error, skipped))

      {:error, reason} ->
        Mix.raise("ONIX parse failed: #{inspect(reason)}")
    end
  end

  @doc false
  # True when a parsed product is an ONIX WITHDRAWAL rather than a record to
  # store. Two independent signals, either is sufficient:
  #
  #   * `<NotificationType>05</NotificationType>` — ONIX codelist 1 value 05,
  #     "Delete". (03 is "Notification confirmed on publication", the normal
  #     case; 05 is the only delete code in the list.)
  #   * a non-empty `<DeletionText>` — the free-text reason that accompanies a
  #     deletion notice. Senders that omit the code but supply the text still
  #     mean withdrawal, so the check is an OR, not an AND.
  #
  # Public + @doc false so the classification is unit-testable without a DB.
  @spec withdrawal?(map()) :: boolean()
  def withdrawal?(product) when is_map(product) do
    Map.get(product, "notificationType") == "05" or
      presence(Map.get(product, "deletionText")) != nil
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

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

  @doc false
  # Public + @doc false so the withdraw-vs-create branch is testable against a
  # real DB without reaching through run/1 and a temp file.
  @spec handle_product(map(), String.t(), boolean()) :: :ok | :error
  def handle_product(product, dataset, dry_run) do
    if withdrawal?(product) do
      handle_withdrawal(product, dataset, dry_run)
    else
      handle_upsert(product, dataset, dry_run)
    end
  end

  defp handle_withdrawal(product, dataset, dry_run) do
    doc_id = Importer.doc_id_for(product)
    reason = presence(Map.get(product, "deletionText")) || "NotificationType 05"

    if dry_run do
      Mix.shell().info("would withdraw: #{doc_id} — #{reason}")
      :ok
    else
      case Content.delete_document(doc_id, "book", dataset, source: :cli) do
        {:ok, _} ->
          Mix.shell().info("withdrawn: #{doc_id} — #{reason}")
          :ok

        # The feed withdraws a record we never held. Feed and store already
        # agree, so this is a no-op success — counting it as a failure would
        # make every re-sync of a historical withdrawal exit non-zero.
        {:error, :not_found} ->
          Mix.shell().info("already absent: #{doc_id} — #{reason}")
          :ok

        {:error, {:halted, halt_reason}} ->
          Mix.shell().error("withdrawal cancelled by plugin: #{doc_id} — #{halt_reason}")
          :error

        {:error, other} ->
          Mix.shell().error("withdrawal failed: #{doc_id} — #{inspect(other)}")
          :error
      end
    end
  end

  defp handle_upsert(product, dataset, dry_run) do
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
