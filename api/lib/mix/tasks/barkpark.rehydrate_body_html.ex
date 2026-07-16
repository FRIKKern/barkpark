defmodule Mix.Tasks.Barkpark.RehydrateBodyHtml do
  @moduledoc """
  One-shot backfill: re-render the frozen `content["body_html"]` cache of every
  block-bearing document (papers, plus any doc carrying an embedded `body_html`)
  whose cache was written by an OLDER renderer than the current
  `Barkpark.PortableDoc.Render.body_html_render_version/0`.

  `content["body_html"]` is rendered ONCE from `content["blocks"]` at write time
  and served verbatim by HTML-cache readers and the data API/SDK, while the
  block-backed public and Studio readers render the blocks directly. After a
  renderer semantics change (e.g. the #857/#861 tolerance change class) a paper
  last written by the old renderer serves divergent frozen HTML. A generic
  mutation could also change blocks while retaining a current render-version
  stamp, so the stamp alone is not sufficient authority. Each sweep renders the
  expected HTML from the stored blocks with the SAME `render_opts` the write
  path uses, then rewrites when either the version lags or the cache bytes differ.

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
        "#{tally.rewritten} rewritten, #{tally.noop} already current."
    )
  end

  @doc """
  Sweep every document carrying both a `content["body_html"]` and a
  `content["blocks"]`, re-rendering the cache from blocks when its
  `content["body_html_sv"]` stamp is absent/lags the current render version OR
  the stored HTML differs from a fresh render of those blocks.
  Returns a `%{scanned, rewritten, noop}` tally. Extracted from `run/1` so tests
  can call it inside the DB sandbox without going through `Mix.Task`.
  """
  def rehydrate do
    import Ecto.Query
    alias Barkpark.Content.Document
    alias Barkpark.PortableDoc.Render
    alias Barkpark.Repo

    current = Render.body_html_render_version()

    # Narrow the scan in SQL to rows that even carry both keys (the `->` operator
    # yields NULL for an absent key, dodging the jsonb `?`/param-placeholder
    # escaping tangle). Precise eligibility — a non-empty block LIST and a stale
    # stamp — is decided per row in `rehydrate_doc/2`.
    from(d in Document,
      where:
        not is_nil(fragment("? -> 'body_html'", d.content)) and
          not is_nil(fragment("? -> 'blocks'", d.content))
    )
    |> Repo.all()
    |> Enum.reduce(%{scanned: 0, rewritten: 0, noop: 0}, fn doc, acc ->
      acc = %{acc | scanned: acc.scanned + 1}

      case rehydrate_doc(doc, current) do
        :rewritten -> %{acc | rewritten: acc.rewritten + 1}
        :noop -> %{acc | noop: acc.noop + 1}
      end
    end)
  end

  # Re-render ONE doc's body_html cache when its version or rendered bytes drift.
  # Skips a doc with no block list (client-supplied HTML — nothing to re-render
  # from). A current stamp is a fast provenance hint, not proof that the blocks
  # stayed unchanged: compare the cache to a fresh render too. Rewrites bump the
  # doc `rev` so downstream caches invalidate.
  defp rehydrate_doc(%Barkpark.Content.Document{content: content} = doc, current)
       when is_map(content) do
    alias Barkpark.Content.{Document, Labels}
    alias Barkpark.PortableDoc.Render
    alias Barkpark.Repo

    blocks = Map.get(content, "blocks")
    cached = Map.get(content, "body_html")
    sv = Map.get(content, "body_html_sv")

    if is_list(blocks) and blocks != [] do
      # SAME render_opts the paper write path builds (block_ops ~line 145):
      # the article palette must match, threaded off the doc's stored style.
      render_opts = Labels.paper_render_opts(doc.dataset, Map.get(content, "style"))
      body_html = Render.render_blocks(blocks, render_opts)

      if is_integer(sv) and sv >= current and cached == body_html do
        :noop
      else
        new_content =
          content
          |> Map.put("body_html", body_html)
          |> Map.put("body_html_sv", current)

        {:ok, _saved} =
          doc
          |> Document.changeset(%{"content" => new_content, "rev" => generate_rev()})
          |> Repo.update()

        :rewritten
      end
    else
      :noop
    end
  end

  defp rehydrate_doc(_doc, _current), do: :noop

  # Opaque row-rev (mutation-spine version) — mirrors the private generator the
  # paper write path uses so a rehydrated doc bumps rev exactly like a save.
  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
