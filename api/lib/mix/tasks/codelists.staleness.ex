defmodule Mix.Tasks.Codelists.Staleness do
  @moduledoc """
  Phase 8 WI4 — report or revalidate stale ONIX codelist refs.

  Two modes, mutually exclusive:

      mix codelists.staleness --report
      mix codelists.staleness --revalidate --book-id <doc_id>

  ## `--report`

  Iterates every `book` document in the `production` dataset, runs the
  pure `StalenessChecker.detect_stale/2` against the current registry
  issue (default `"73"`, override with `--current-issue`), and prints
  one section per book whose refs include any non-`:current` entries.
  Each section lists the dotted path, codelist id, ref issue, and
  status pill. Books with all-current refs are summarized in a single
  trailing line so the operator sees the full corpus at a glance.

  ## `--revalidate --book-id <doc_id>`

  Loads the named document, calls `StalenessChecker.revalidate/2`, and
  prints the diff (added / removed / changed). Without `--book-id`,
  `--revalidate` errors with usage. The current registry snapshot is
  reconstructed from the codelist values stored in the
  `Barkpark.Content.Codelists` table — see `current_registry/1` below.

  ## Exit codes

    * `0` — success
    * `1` — bad arguments / book not found, or a BLIND report (books were
      scanned and zero codelist refs were recognized, so the run measured
      nothing and must not be read as "no drift")
  """
  @shortdoc "Report or revalidate stale codelist refs"

  use Mix.Task

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Codelists.StalenessChecker
  alias Barkpark.Repo

  import Ecto.Query

  @switches [
    report: :boolean,
    revalidate: :boolean,
    book_id: :string,
    current_issue: :string
  ]
  @default_current_issue "73"
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
          Mix.raise("usage: mix codelists.staleness --report | --revalidate --book-id <id>")
      end
      |> elem(0)

    cond do
      Keyword.get(opts, :report) -> run_report(opts)
      Keyword.get(opts, :revalidate) -> run_revalidate(opts)
      true -> usage_error()
    end
  end

  # ── --report ─────────────────────────────────────────────────────────

  defp run_report(opts) do
    current_issue = Keyword.get(opts, :current_issue, @default_current_issue)
    books = list_books()

    Mix.shell().info("codelist staleness report — current registry issue: #{current_issue}")
    Mix.shell().info(String.duplicate("=", 72))

    scanned =
      Enum.map(books, fn doc -> {doc, StalenessChecker.detect_stale(doc, current_issue)} end)

    {with_drift, all_current} =
      Enum.reduce(scanned, {0, 0}, fn {doc, refs}, {drift, current} ->
        non_current = Enum.reject(refs, fn r -> r.status == :current end)

        if non_current == [] do
          {drift, current + 1}
        else
          print_book_section(doc, non_current)
          {drift + 1, current}
        end
      end)

    Mix.shell().info(String.duplicate("-", 72))

    coverage = StalenessChecker.corpus_coverage(Enum.map(scanned, fn {_doc, refs} -> refs end))
    ref_total = scanned |> Enum.map(fn {_doc, refs} -> length(refs) end) |> Enum.sum()

    Mix.shell().info(
      "books with drift: #{with_drift} | books all-current: #{all_current} | " <>
        "total: #{length(books)} | codelist refs recognized: #{ref_total}"
    )

    # NON-VACUITY GATE. Without this, a corpus in which the analyzer recognizes
    # nothing prints "books with drift: 0" and exits 0 — byte-identical to a
    # genuinely clean corpus. `detect_stale/2` only counts a ref when one map
    # carries BOTH "codelistId" and "issue_version", and nothing writes that
    # shape, so this report is silent for the wrong reason. Refuse loudly rather
    # than hand back a green that means "I looked in the wrong place".
    if coverage == :blind do
      Mix.raise(
        "staleness report is BLIND: scanned #{length(books)} book(s) and recognized 0 " <>
          "codelist refs. Drift is UNMEASURED, not absent — detect_stale/2 requires both " <>
          "\"codelistId\" and \"issue_version\" on one map and no writer produces that " <>
          "shape. Do not read this run as a clean report."
      )
    end

    :ok
  end

  defp print_book_section(%Document{} = doc, refs) do
    Mix.shell().info("")
    Mix.shell().info("book: #{doc.doc_id}  title: #{doc.title || "(untitled)"}")

    Mix.shell().info(
      :io_lib.format("  ~-32s ~-30s ~-10s ~-12s", [
        "path",
        "codelist",
        "ref_issue",
        "status"
      ])
      |> IO.iodata_to_binary()
    )

    Mix.shell().info("  " <> String.duplicate("-", 88))

    Enum.each(refs, fn r ->
      Mix.shell().info(
        :io_lib.format("  ~-32s ~-30s ~-10s ~-12s", [
          r.path |> truncate(32),
          (r.codelist || "") |> truncate(30),
          r.ref_issue || "(none)",
          Atom.to_string(r.status)
        ])
        |> IO.iodata_to_binary()
      )
    end)
  end

  # ── --revalidate ─────────────────────────────────────────────────────

  defp run_revalidate(opts) do
    case Keyword.get(opts, :book_id) do
      nil ->
        Mix.shell().error("--revalidate requires --book-id <doc_id>")
        Mix.raise("usage: mix codelists.staleness --revalidate --book-id <id>")

      "" ->
        Mix.shell().error("--book-id must be a non-empty doc_id")
        Mix.raise("usage: mix codelists.staleness --revalidate --book-id <id>")

      book_id ->
        revalidate_one(book_id)
    end
  end

  defp revalidate_one(book_id) do
    case lookup_book(book_id) do
      {:ok, doc} ->
        registry = current_registry()
        diff = StalenessChecker.revalidate(doc, registry)

        Mix.shell().info("revalidate report for book: #{doc.doc_id}")
        Mix.shell().info(String.duplicate("=", 72))

        print_diff_section("changed", diff.changed, fn entry ->
          "  #{entry.path}  [#{entry.codelist}]  #{entry.from} → #{entry.to}"
        end)

        print_diff_section("removed", diff.removed, fn entry ->
          "  #{entry.path}  [#{entry.codelist}]  code=#{entry.code}"
        end)

        print_diff_section("added", diff.added, fn entry ->
          "  [#{entry.codelist}]  issue_version=#{entry.issue_version}"
        end)

        if diff.changed == [] and diff.removed == [] and diff.added == [] do
          Mix.shell().info("(no diff — document is fully aligned with the current registry)")
        end

        :ok

      {:error, :not_found} ->
        Mix.shell().error("book not found: doc_id=#{inspect(book_id)}")
        Mix.raise("book not found")
    end
  end

  defp print_diff_section(label, [], _fmt) do
    Mix.shell().info("#{label}: (none)")
  end

  defp print_diff_section(label, entries, fmt) do
    Mix.shell().info("#{label}: #{length(entries)}")
    Enum.each(entries, fn e -> Mix.shell().info(fmt.(e)) end)
  end

  # ── data access ──────────────────────────────────────────────────────

  defp list_books do
    Document
    |> where([d], d.type == ^@type_default and d.dataset == ^@dataset_default)
    |> order_by([d], asc: d.doc_id)
    |> Repo.all()
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

  # Build a registry snapshot keyed by `codelistId` from the
  # `Barkpark.Content.Codelists` table. The snapshot's `:codes` entry
  # is left as `:any` — the staleness checker uses it only for
  # membership filtering, and the mix task surfaces issue-level drift,
  # not per-code validation. (The admin LV builds richer snapshots.)
  defp current_registry do
    import Ecto.Query, only: [from: 2]

    from(c in "codelists",
      select: %{plugin_name: c.plugin_name, list_id: c.list_id, issue: c.issue}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn row, acc ->
      key = "#{row.plugin_name}:#{row.list_id}"

      case Map.get(acc, key) do
        nil ->
          Map.put(acc, key, %{issue_version: row.issue, codes: :any})

        %{issue_version: prev} ->
          if compare_issue(row.issue, prev) == :gt do
            Map.put(acc, key, %{issue_version: row.issue, codes: :any})
          else
            acc
          end
      end
    end)
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp compare_issue(a, b) when is_binary(a) and is_binary(b) do
    case {Integer.parse(a), Integer.parse(b)} do
      {{na, ""}, {nb, ""}} ->
        cond do
          na < nb -> :lt
          na > nb -> :gt
          true -> :eq
        end

      _ ->
        cond do
          a < b -> :lt
          a > b -> :gt
          true -> :eq
        end
    end
  end

  defp truncate(nil, _), do: ""

  defp truncate(s, n) when is_binary(s) do
    if String.length(s) <= n, do: s, else: String.slice(s, 0, n - 1) <> "…"
  end

  defp usage_error do
    Mix.shell().error("usage: mix codelists.staleness --report | --revalidate --book-id <id>")
    Mix.raise("missing mode: --report or --revalidate required")
  end
end
