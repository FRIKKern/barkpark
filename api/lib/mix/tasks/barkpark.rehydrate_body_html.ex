defmodule Mix.Tasks.Barkpark.RehydrateBodyHtml do
  @moduledoc """
  Backfill: re-render the frozen `content["body_html"]` cache of block-bearing
  documents (papers, plus any doc carrying an embedded `body_html`) whose cache
  drifted from a fresh render of their own blocks, or whose cache was written by
  a DIFFERENT renderer than the current
  `Barkpark.PortableDoc.Render.body_html_render_version/0` — a sha256 digest of
  the renderer's own source, compared by identity (not order).

  `content["body_html"]` is rendered ONCE from `content["blocks"]` at write time
  and served verbatim by HTML-cache readers and the data API/SDK, while the
  block-backed public and Studio readers render the blocks directly. After a
  renderer semantics change (e.g. the #857/#861 tolerance class) a paper last
  written by the old renderer serves divergent frozen HTML. A generic mutation
  could also change blocks while retaining a current render-version stamp, so
  the stamp alone is not sufficient authority. Each sweep renders the expected
  HTML from the stored blocks with the SAME `render_opts` the write path uses,
  then rewrites when either the digest differs or the cache bytes do.

  ## Dry run is the default

  This walks production content, so `mix barkpark.rehydrate_body_html` REPORTS
  and writes nothing. Writes require an explicit `--write`.

      mix barkpark.rehydrate_body_html                          # report only
      mix barkpark.rehydrate_body_html --type paper --published-only
      mix barkpark.rehydrate_body_html --type paper --published-only --write

  ### Flags

    * `--write` — actually persist (default is dry run)
    * `--dry-run` — explicit form of the default
    * `--type` — restrict to one doc type (e.g. `paper`)
    * `--dataset` — restrict to one dataset
    * `--status` — restrict to one status (e.g. `published`)
    * `--published-only` — shorthand for `--status published`
    * `--batch-size` — rows fetched per keyset page (default 200)
    * `--limit` — stop after scanning N rows

  ## The divergent class is REPORTED, never rewritten

  A row whose stored HTML differs from a fresh render of its blocks AND which
  carries no honest provenance (`content["body_html_sv"]` absent) is left
  BYTE-IDENTICAL and reported. The paper write path clears the stamp when a
  caller supplies `body_html` verbatim, precisely because that HTML is not
  derived from the blocks — so an absent stamp plus diverging bytes is the
  signature of content the blocks cannot reproduce. Rehydration is for drift,
  not for adjudicating divergence: overwriting here would destroy exactly the
  content the stamp clear was protecting.

  An absent stamp whose bytes ALREADY match a fresh render is safe and is
  re-stamped (bytes unchanged) — that is the legacy backfill this sweep exists
  for. A present-but-foreign stamp is honest provenance from an older renderer,
  so its divergence is drift and is rehydrated.

  Divergent reports are annotated `resolver_dependent=true` when the row's
  blocks contain `field-reference` / `codelist` blocks, whose rendered text
  comes from a LIVE lookup: a renamed referent makes such a row look divergent
  with blocks, cache, stamp and renderer all untouched. Those rows are external
  referent drift, not divergence, and the annotation keeps the two apart in the
  report without freezing a resolved label into the cache (which would serve a
  stale title behind a matching stamp — a silent wrong value).

  Idempotent: a doc at the current stamp whose cache matches a fresh block
  render is left untouched, so a second run rewrites nothing. Docs with no
  block list are skipped — client-supplied HTML can't be re-rendered from
  blocks.
  """
  @shortdoc "Report (or --write) stale body_html caches through the current renderer"

  use Mix.Task

  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @default_batch_size 200

  @switches [
    write: :boolean,
    dry_run: :boolean,
    type: :string,
    dataset: :string,
    status: :string,
    published_only: :boolean,
    batch_size: :integer,
    limit: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {parsed, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    opts = [
      # DRY RUN IS THE DEFAULT: only an explicit --write persists.
      dry_run: not Keyword.get(parsed, :write, false),
      type: Keyword.get(parsed, :type),
      dataset: Keyword.get(parsed, :dataset),
      status: status_opt(parsed),
      batch_size: Keyword.get(parsed, :batch_size, @default_batch_size),
      limit: Keyword.get(parsed, :limit)
    ]

    tally = rehydrate(opts)

    mode = if tally.dry_run, do: "DRY RUN (no writes — pass --write to persist)", else: "WRITING"

    Mix.shell().info(
      "rehydrate_body_html [#{mode}] scope: " <>
        "type=#{opts[:type] || "*"} dataset=#{opts[:dataset] || "*"} " <>
        "status=#{opts[:status] || "*"}"
    )

    Mix.shell().info(
      "rehydrate_body_html: scanned #{tally.scanned} doc(s) — " <>
        "#{tally.planned} to rewrite, #{tally.rewritten} rewritten, " <>
        "#{tally.noop} already current, #{tally.divergent} divergent (SKIPPED), " <>
        "#{tally.conflicts} conflict(s), #{tally.errors} error(s)."
    )

    report_details("would-rewrite", tally.planned_details)
    report_details("divergent-skipped", tally.divergent_details)
    report_details("conflict", tally.conflict_details)
    report_details("error", tally.error_details)
  end

  defp status_opt(parsed) do
    cond do
      status = Keyword.get(parsed, :status) -> status
      Keyword.get(parsed, :published_only, false) -> "published"
      true -> nil
    end
  end

  @doc """
  Sweep documents carrying both a `content["body_html"]` and a
  `content["blocks"]`, re-rendering the cache from blocks when its
  `content["body_html_sv"]` stamp is absent or differs from the current render
  digest OR the stored HTML differs from a fresh render of those blocks —
  EXCEPT the divergent class (absent stamp + diverging bytes), which is
  reported and left byte-identical.

  Returns a tally with scanned/planned/rewritten/noop/divergent/conflict/error
  counts plus doc-identity details for every planned/divergent/conflict/error
  row. Extracted from `run/1` so tests can call it inside the DB sandbox
  without going through `Mix.Task`.

  Options: `:dry_run` (default `false` here — the MIX TASK defaults it to
  `true`; this function is the programmatic surface), `:type`, `:dataset`,
  `:status`, `:batch_size`, `:limit`. `:before_fenced_write` and `:persist_fun`
  are deterministic race/error seams used by the focused tests; production
  callers omit them.
  """
  def rehydrate(opts \\ []) do
    alias Barkpark.PortableDoc.Render

    current = Render.body_html_render_version()
    dry_run = Keyword.get(opts, :dry_run, false)

    opts
    |> scan_query()
    |> reduce_batches(
      Keyword.get(opts, :batch_size) || @default_batch_size,
      Keyword.get(opts, :limit),
      empty_tally(dry_run),
      fn doc, acc ->
        acc = %{acc | scanned: acc.scanned + 1}

        case rehydrate_doc(doc, current, opts) do
          :rewritten ->
            %{acc | rewritten: acc.rewritten + 1}

          :noop ->
            %{acc | noop: acc.noop + 1}

          {:planned, detail} ->
            %{acc | planned: acc.planned + 1, planned_details: [detail | acc.planned_details]}

          {:divergent, detail} ->
            %{
              acc
              | divergent: acc.divergent + 1,
                divergent_details: [detail | acc.divergent_details]
            }

          {:conflict, detail} ->
            %{
              acc
              | conflicts: acc.conflicts + 1,
                conflict_details: [detail | acc.conflict_details]
            }

          {:error, detail} ->
            %{acc | errors: acc.errors + 1, error_details: [detail | acc.error_details]}
        end
      end
    )
    |> Map.update!(:planned_details, &Enum.reverse/1)
    |> Map.update!(:divergent_details, &Enum.reverse/1)
    |> Map.update!(:conflict_details, &Enum.reverse/1)
    |> Map.update!(:error_details, &Enum.reverse/1)
  end

  # Narrow the scan to rows carrying a cache and either canonical top-level
  # blocks or the historical content.body.blocks projection. A PRESENT empty
  # top-level list remains authoritative and therefore eligible. Scoping flags
  # narrow it further so a production run is deliberate rather than
  # database-wide.
  defp scan_query(opts) do
    query =
      from(d in Document,
        where:
          not is_nil(fragment("? -> 'body_html'", d.content)) and
            (not is_nil(fragment("? -> 'blocks'", d.content)) or
               not is_nil(fragment("? #> '{body,blocks}'", d.content))),
        order_by: [asc: d.id]
      )

    query
    |> narrow(:type, Keyword.get(opts, :type))
    |> narrow(:dataset, Keyword.get(opts, :dataset))
    |> narrow(:status, Keyword.get(opts, :status))
  end

  defp narrow(query, _field, nil), do: query
  defp narrow(query, :type, value), do: from(d in query, where: d.type == ^value)
  defp narrow(query, :dataset, value), do: from(d in query, where: d.dataset == ^value)
  defp narrow(query, :status, value), do: from(d in query, where: d.status == ^value)

  # Keyset pagination over `id` instead of one unbounded `Repo.all/1`: the sweep
  # touches every published paper, and loading them all into one list is the
  # difference between a bounded backfill and an OOM. A rewrite bumps `rev`, not
  # `id`, so the cursor stays stable across the writes this very loop performs.
  defp reduce_batches(query, batch_size, row_limit, acc, fun) do
    do_reduce_batches(query, batch_size, row_limit, nil, 0, acc, fun)
  end

  defp do_reduce_batches(query, batch_size, row_limit, cursor, seen, acc, fun) do
    take = if row_limit, do: min(batch_size, row_limit - seen), else: batch_size

    if take <= 0 do
      acc
    else
      rows =
        query
        |> after_cursor(cursor)
        |> limit(^take)
        |> Repo.all()

      case rows do
        [] ->
          acc

        rows ->
          acc = Enum.reduce(rows, acc, fun)

          if length(rows) < take do
            acc
          else
            do_reduce_batches(
              query,
              batch_size,
              row_limit,
              List.last(rows).id,
              seen + length(rows),
              acc,
              fun
            )
          end
      end
    end
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, cursor), do: from(d in query, where: d.id > ^cursor)

  # Re-render ONE doc's body_html cache when its version or rendered bytes drift.
  # Skips a doc with no block list (client-supplied HTML — nothing to re-render
  # from). A current stamp is a fast provenance hint, not proof that the blocks
  # stayed unchanged: compare the cache to a fresh render too. Rewrites bump the
  # doc `rev` so downstream caches invalidate.
  defp rehydrate_doc(%Barkpark.Content.Document{content: content} = doc, current, opts)
       when is_map(content) do
    alias Barkpark.PortableDoc.Projection

    blocks = Projection.read_blocks(content)
    cached = Map.get(content, "body_html")
    sv = Map.get(content, "body_html_sv")

    if is_list(blocks) do
      # The RENDER is inside the rescue, not merely the persist: one bad row
      # used to raise uncaught and abort the sweep for every remaining doc with
      # no partial-progress checkpoint. Now it is reported and the sweep walks on.
      case safe_render(doc, content, blocks) do
        {:ok, body_html} ->
          classify_and_write(doc, content, blocks, cached, sv, body_html, current, opts)

        {:error, reason} ->
          {:error, detail(doc, reason)}
      end
    else
      :noop
    end
  end

  defp rehydrate_doc(_doc, _current, _opts), do: :noop

  # SAME render_opts the paper write path builds (block_ops ~line 145): the
  # article palette must match, threaded off the doc's stored style. Both the
  # opts build (whose resolver closures run live Ecto queries) and the render
  # itself are fenced.
  defp safe_render(doc, content, blocks) do
    alias Barkpark.Content.Labels
    alias Barkpark.PortableDoc.Render

    scope = [workspace_id: doc.workspace_id, project_id: doc.project_id]

    try do
      render_opts = Labels.paper_render_opts(doc.dataset, Map.get(content, "style"), scope)
      {:ok, Render.render_blocks(blocks, render_opts)}
    rescue
      error -> {:error, "render raised: #{Exception.message(error)}"}
    catch
      kind, value -> {:error, "render #{kind}: #{inspect(value)}"}
    end
  end

  defp classify_and_write(doc, content, blocks, cached, sv, body_html, current, opts) do
    # EQUALITY, never `>=`. The stamp is a sha256 digest of the renderer's
    # source; a content hash has no total order, so "greater" says nothing
    # about "newer" — an older renderer's digest is lexicographically greater
    # than the current one roughly half the time, and an ordinal test would
    # read that as up-to-date and skip the row forever.
    cond do
      sv == current and cached == body_html ->
        :noop

      # THE DIVERGENT CLASS. No honest provenance AND the blocks cannot
      # reproduce the stored bytes — the signature of verbatim HTML whose stamp
      # the write path cleared. Report it; never overwrite it.
      is_nil(sv) and cached != body_html ->
        {:divergent, divergent_detail(doc, blocks, cached, body_html)}

      true ->
        new_content =
          content
          |> Map.put("body_html", body_html)
          |> Map.put("body_html_sv", current)

        if Keyword.get(opts, :dry_run, false) do
          {:planned, detail(doc, rewrite_reason(sv, current, cached, body_html))}
        else
          persist(doc, new_content, opts)
        end
    end
  end

  defp rewrite_reason(sv, current, cached, body_html) do
    stamp =
      cond do
        is_nil(sv) -> "stamp absent"
        sv == current -> "stamp current"
        true -> "stamp foreign (#{String.slice(to_string(sv), 0, 12)}…)"
      end

    bytes = if cached == body_html, do: "bytes match", else: "bytes drift"

    "#{stamp}, #{bytes}"
  end

  defp persist(doc, new_content, opts) do
    before_fenced_write = Keyword.get(opts, :before_fenced_write)
    persist_fun = Keyword.get(opts, :persist_fun, &Repo.update/1)

    with :ok <- run_before_fenced_write(before_fenced_write, doc) do
      changeset =
        doc
        |> Document.changeset(%{"content" => new_content})
        |> Ecto.Changeset.optimistic_lock(:rev, fn _ -> generate_rev() end)

      try do
        case persist_fun.(changeset) do
          {:ok, _saved} -> :rewritten
          {:error, changeset} -> {:error, detail(doc, changeset_errors(changeset))}
          other -> {:error, detail(doc, "persist_fun returned #{inspect(other)}")}
        end
      rescue
        Ecto.StaleEntryError -> {:conflict, detail(doc, "rev changed before update")}
        error -> {:error, detail(doc, Exception.message(error))}
      end
    else
      {:error, reason} -> {:error, detail(doc, reason)}
    end
  end

  defp divergent_detail(doc, blocks, cached, body_html) do
    doc
    |> detail(
      "stored HTML diverges from a fresh block render and the row carries no " <>
        "provenance stamp — left untouched (#{byte_size(to_string(cached))} stored bytes vs " <>
        "#{byte_size(body_html)} rendered)"
    )
    |> Map.put(:resolver_dependent, resolver_dependent?(blocks))
  end

  # A `field-reference` / `codelist` block renders text fetched LIVE at render
  # time, so a renamed referent alone makes a row diverge. Annotating (rather
  # than resolving) keeps external referent drift distinguishable from genuine
  # divergence in the report. Walks the whole block JSON because these types
  # nest inside container blocks.
  defp resolver_dependent?(term) when is_list(term), do: Enum.any?(term, &resolver_dependent?/1)

  defp resolver_dependent?(%{} = term) do
    Map.get(term, "type") in ["field-reference", "codelist"] or
      Enum.any?(Map.values(term), &resolver_dependent?/1)
  end

  defp resolver_dependent?(_term), do: false

  defp empty_tally(dry_run) do
    %{
      dry_run: dry_run,
      scanned: 0,
      planned: 0,
      rewritten: 0,
      noop: 0,
      divergent: 0,
      conflicts: 0,
      errors: 0,
      planned_details: [],
      divergent_details: [],
      conflict_details: [],
      error_details: []
    }
  end

  defp run_before_fenced_write(nil, _doc), do: :ok

  defp run_before_fenced_write(callback, doc) when is_function(callback, 1) do
    try do
      case callback.(doc) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, "before_fenced_write returned #{inspect(other)}"}
      end
    rescue
      error -> {:error, "before_fenced_write raised: #{Exception.message(error)}"}
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp detail(doc, reason) do
    %{
      id: doc.id,
      doc_id: doc.doc_id,
      type: doc.type,
      dataset: doc.dataset,
      status: doc.status,
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      rev: doc.rev,
      reason: reason
    }
  end

  defp report_details(kind, details) do
    Enum.each(details, fn detail ->
      annotation =
        case Map.get(detail, :resolver_dependent) do
          true -> " resolver_dependent=true"
          false -> " resolver_dependent=false"
          _ -> ""
        end

      Mix.shell().info(
        "rehydrate_body_html #{kind}: " <>
          "#{detail.type}/#{detail.doc_id} dataset=#{detail.dataset} " <>
          "status=#{detail.status} " <>
          "workspace=#{inspect(detail.workspace_id)} project=#{inspect(detail.project_id)} " <>
          "rev=#{detail.rev}#{annotation} reason=#{inspect(detail.reason)}"
      )
    end)
  end

  # Opaque row-rev (mutation-spine version) — mirrors the private generator the
  # paper write path uses so a rehydrated doc bumps rev exactly like a save.
  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
