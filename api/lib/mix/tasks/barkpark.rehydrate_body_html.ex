defmodule Mix.Tasks.Barkpark.RehydrateBodyHtml do
  @moduledoc """
  One-shot backfill: re-render the frozen `content["body_html"]` cache of every
  block-bearing document (papers, plus any doc carrying an embedded `body_html`)
  whose cache was written by a DIFFERENT renderer than the current
  `Barkpark.PortableDoc.Render.body_html_render_version/0` — a sha256 digest of
  the renderer's own source, compared by identity (not order).

  `content["body_html"]` is rendered ONCE from `content["blocks"]` at write time
  and served verbatim by HTML-cache readers and the data API/SDK, while the
  block-backed public and Studio readers render the blocks directly. After a
  renderer semantics change (e.g. the #857/#861 tolerance change class) a paper
  last written by the old renderer serves divergent frozen HTML. A generic
  mutation could also change blocks while retaining a current render-version
  stamp, so the stamp alone is not sufficient authority. Each sweep renders the
  expected HTML from the stored blocks with the SAME `render_opts` the write
  path uses, then rewrites when either the digest differs or the cache bytes do.

  Idempotent: a doc at the current stamp whose cache matches a fresh block
  render is left untouched, so a second run rewrites nothing. Docs with no
  block list are skipped — client-supplied HTML can't be re-rendered from blocks.

      mix barkpark.rehydrate_body_html

  Reports scanned doc count and how many caches were rewritten vs left current.
  """
  @shortdoc "Re-render stale body_html caches through the current renderer (idempotent)"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    tally = rehydrate()

    Mix.shell().info(
      "rehydrate_body_html: scanned #{tally.scanned} doc(s) — " <>
        "#{tally.rewritten} rewritten, #{tally.noop} already current, " <>
        "#{tally.conflicts} conflict(s), #{tally.errors} error(s)."
    )

    report_details("conflict", tally.conflict_details)
    report_details("error", tally.error_details)
  end

  @doc """
  Sweep every document carrying both a `content["body_html"]` and a
  `content["blocks"]`, re-rendering the cache from blocks when its
  `content["body_html_sv"]` stamp is absent or differs from the current render
  digest OR the stored HTML differs from a fresh render of those blocks.
  Returns a tally with scanned/rewritten/noop/conflict/error counts plus
  doc-identity details for every conflict/error. Extracted from `run/1` so tests
  can call it inside the DB sandbox without going through `Mix.Task`.

  `:before_fenced_write` and `:persist_fun` are deterministic race/error seams
  used by the focused tests; production callers omit them.
  """
  def rehydrate(opts \\ []) do
    import Ecto.Query
    alias Barkpark.Content.Document
    alias Barkpark.PortableDoc.Render
    alias Barkpark.Repo

    current = Render.body_html_render_version()

    # Narrow the scan to rows carrying a cache and either canonical top-level
    # blocks or the historical content.body.blocks projection. A PRESENT empty
    # top-level list remains authoritative and therefore eligible.
    from(d in Document,
      where:
        not is_nil(fragment("? -> 'body_html'", d.content)) and
          (not is_nil(fragment("? -> 'blocks'", d.content)) or
             not is_nil(fragment("? #> '{body,blocks}'", d.content)))
    )
    |> Repo.all()
    |> Enum.reduce(empty_tally(), fn doc, acc ->
      acc = %{acc | scanned: acc.scanned + 1}

      case rehydrate_doc(doc, current, opts) do
        :rewritten ->
          %{acc | rewritten: acc.rewritten + 1}

        :noop ->
          %{acc | noop: acc.noop + 1}

        {:conflict, detail} ->
          %{
            acc
            | conflicts: acc.conflicts + 1,
              conflict_details: [detail | acc.conflict_details]
          }

        {:error, detail} ->
          %{acc | errors: acc.errors + 1, error_details: [detail | acc.error_details]}
      end
    end)
    |> Map.update!(:conflict_details, &Enum.reverse/1)
    |> Map.update!(:error_details, &Enum.reverse/1)
  end

  # Re-render ONE doc's body_html cache when its version or rendered bytes drift.
  # Skips a doc with no block list (client-supplied HTML — nothing to re-render
  # from). A current stamp is a fast provenance hint, not proof that the blocks
  # stayed unchanged: compare the cache to a fresh render too. Rewrites bump the
  # doc `rev` so downstream caches invalidate.
  defp rehydrate_doc(%Barkpark.Content.Document{content: content} = doc, current, opts)
       when is_map(content) do
    alias Barkpark.Content.{Document, Labels}
    alias Barkpark.PortableDoc.{Projection, Render}
    alias Barkpark.Repo

    blocks = Projection.read_blocks(content)
    cached = Map.get(content, "body_html")
    sv = Map.get(content, "body_html_sv")

    if is_list(blocks) do
      # SAME render_opts the paper write path builds (block_ops ~line 145):
      # the article palette must match, threaded off the doc's stored style.
      scope = [workspace_id: doc.workspace_id, project_id: doc.project_id]

      render_opts =
        Labels.paper_render_opts(doc.dataset, Map.get(content, "style"), scope)

      body_html = Render.render_blocks(blocks, render_opts)

      # EQUALITY, never `>=`. The stamp is a sha256 digest of the renderer's
      # source; a content hash has no total order, so "greater" says nothing
      # about "newer" — an older renderer's digest is lexicographically greater
      # than the current one roughly half the time, and an ordinal test would
      # read that as up-to-date and skip the row forever.
      if sv == current and cached == body_html do
        :noop
      else
        new_content =
          content
          |> Map.put("body_html", body_html)
          |> Map.put("body_html_sv", current)

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
    else
      :noop
    end
  end

  defp rehydrate_doc(_doc, _current, _opts), do: :noop

  defp empty_tally do
    %{
      scanned: 0,
      rewritten: 0,
      noop: 0,
      conflicts: 0,
      errors: 0,
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
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      rev: doc.rev,
      reason: reason
    }
  end

  defp report_details(kind, details) do
    Enum.each(details, fn detail ->
      Mix.shell().info(
        "rehydrate_body_html #{kind}: " <>
          "#{detail.type}/#{detail.doc_id} dataset=#{detail.dataset} " <>
          "workspace=#{inspect(detail.workspace_id)} project=#{inspect(detail.project_id)} " <>
          "rev=#{detail.rev} reason=#{inspect(detail.reason)}"
      )
    end)
  end

  # Opaque row-rev (mutation-spine version) — mirrors the private generator the
  # paper write path uses so a rehydrated doc bumps rev exactly like a save.
  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
