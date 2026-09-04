defmodule Barkpark.Content.Papers.DoctrineBackfill do
  @moduledoc """
  Backfill the PortableDoc **doctrine template** onto LEGACY papers — the corpus
  twin of the locked-template enforcement in `Barkpark.Content.Papers.Template`
  (paper `pd-doctrine`, task pdd-t5).

  Existing papers predate the locked template (a `role: "title"` heading at block
  0, a `role: "featured"` image at block 1). Enforcement is ADDITIVE — a paper
  with no locked blocks passes `Template.validate/1` untouched — so nothing is
  BRICKED. But a legacy paper that never opens in the canvas also never gains the
  doctrine shape. This module walks the whole paper corpus and, per paper, either
  reports it already conforms, plans the doctrine backfill, or reports why it
  cannot be fixed automatically.

  ## Dry-run is the default (D3)

  `run/1` defaults to `dry_run: true` — it SCANS every Bulldocs paper and emits a
  per-paper classification, writing NOTHING. `--apply` (the Mix task) / `run(dry_run:
  false)` performs the backfill. A bare call NEVER mutates.

  ## What `--apply` does

  For each paper that does NOT already conform (and is fixable):

    1. **Synthesize the locked title block at index 0** — stamped exactly per
       `Template.template_blocks/1`'s seed shape (a locked `role: "title"` level-1
       heading). The title text is derived from `doc.title`, else the paper's
       first non-blank heading block (the two synthesis heuristics). Dedup — no
       double title in the render: when the text came from the first heading,
       that heading is CONSUMED (removed, wherever it sits — its text now lives
       in the title block); when it came from `doc.title` and block 0 is a
       heading with the same (trimmed) text, that heading is REPLACED. Otherwise
       the title block is prepended — a differing block-0 heading is real
       content and survives.
    2. **Insert the featured image block at index 1 — ONLY when the paper already
       carries an image asset** (an existing FREE `type: "image"` block with a
       non-blank `src`; a field-BOUND image belongs to its field and is never
       promoted). That image is promoted to the locked `role: "featured"` block
       at index 1 (moved, not duplicated). Assets are NEVER invented — an
       asset-less paper gets NO featured block (t13's placeholder handles the
       asset-less featured case; `Template.validate/1` constrains a featured
       block — after the title, at most one — only when one EXISTS).
    3. **Persist like the real writer** — re-render `content["body_html"]` from
       the new block list (with the paper's `style`), re-project
       `content["body"]`/`content[fieldName]` (`Projection.project/3`, the same
       call `upsert_paper` makes), and bump both revs (the streaming
       `content["rev"]` and the opaque row `rev`) so the cached render, the
       projection, and the version spine all stay honest — the doctrine's render
       parity (canvas = frontend). Unlike `BackfillBlockIds` (whose passes are
       render-identical), adding a title heading changes the render, so every
       derived surface must be refreshed.

  After `--apply` every TOUCHED paper passes `Template.validate/1`; a paper that
  would still violate the template after the plan — or whose planned block ids
  are not unique (a pre-existing duplicate, or a block already squatting on the
  template id) — is REFUSED (never written) and surfaced as `unfixable` so the
  run reports it instead of writing a broken shape. A save the changeset refuses
  is likewise reported (never counted as changed).

  ## Contract

    * **Byte-stable for conformers (D3)** — a paper that already conforms (block 0
      is a locked `role: "title"` heading and `Template.validate/1` is clean) is
      left BYTE-IDENTICAL. `plan/1` returns `:conforms` and nothing is written.
    * **Idempotent** — `plan/1` over a paper this module already backfilled returns
      `:conforms`, so a second `--apply` writes nothing (running apply twice = no
      second diff).
    * **Tenancy-complete** — the scan reads EVERY `type: "paper"` document across
      all workspaces / projects / datasets in one Repo pass; each save preserves
      the row's own scope columns and `status` (only `content`, the derived row
      `title`, and a fresh row `rev` are cast).
    * **Never invents assets** — a featured block is added ONLY when a real image
      `src` already exists in the paper.

  ## Human runbook (the apply is HUMAN-GATED)

  DO NOT run `--apply` against prod / guerrilla data unattended. The safe order:

      # 1. Dry-run — inspect the per-paper report (conforms / synthesizable /
      #    featured present-or-skipped / unfixable + why). Writes nothing.
      mix barkpark.paper.doctrine_backfill

      # 2. Review the `unfixable` list. HTML-only papers and papers with no
      #    derivable title are reported, never guessed at — decide those by hand.

      # 3. Apply on a snapshot / staging copy first, re-run the dry-run to confirm
      #    everything now conforms (changed count → 0 on the second dry-run).
      mix barkpark.paper.doctrine_backfill --apply

  `plan/1` is the pure classifier (no DB) and the unit-test surface; `run/1` wraps
  it with the DB scan + persist.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Barkpark.Repo
  alias Barkpark.Content.Document
  alias Barkpark.Content.Labels
  alias Barkpark.Content.Papers.Template
  alias Barkpark.PortableDoc.Projection
  alias Barkpark.PortableDoc.Render

  @paper_type "paper"

  @title_role "title"
  @featured_role "featured"

  @type title_source :: :doc_title | :first_heading
  @type featured_disposition :: :inserted | :skipped

  @type plan_meta :: %{
          title_source: title_source(),
          title_text: String.t(),
          featured: featured_disposition()
        }

  @type plan_result ::
          :conforms
          | {:change, [map()], plan_meta()}
          | {:unfixable, String.t()}

  @type change_entry :: %{
          slug: String.t(),
          dataset: String.t(),
          title_source: title_source(),
          title_text: String.t(),
          featured: featured_disposition()
        }

  @type unfixable_entry :: %{slug: String.t(), dataset: String.t(), reason: String.t()}

  @type stats :: %{
          scanned: non_neg_integer(),
          conforms: non_neg_integer(),
          changed_papers: non_neg_integer(),
          titles_synthesized: non_neg_integer(),
          featured_inserted: non_neg_integer(),
          featured_skipped: non_neg_integer(),
          dry_run: boolean(),
          changes: [change_entry()],
          unfixable: [unfixable_entry()]
        }

  @doc """
  Scan the WHOLE paper corpus and (unless dry-run) backfill the doctrine template.

  `opts`:

    * `:dry_run` (boolean, default `true`) — when `true`, compute the per-paper
      plan and write nothing. The default is SAFE: a bare call never mutates.

  Returns `{:ok, stats}` — see `t:stats/0`. Idempotent: a second run over an
  already-backfilled corpus returns `changed_papers: 0`.
  """
  @spec run(keyword()) :: {:ok, stats()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)

    papers = all_papers()

    acc0 = %{
      conforms: 0,
      changes: [],
      titles: 0,
      featured_inserted: 0,
      featured_skipped: 0,
      unfixable: []
    }

    acc =
      Enum.reduce(papers, acc0, fn doc, acc ->
        case plan(doc) do
          :conforms ->
            %{acc | conforms: acc.conforms + 1}

          {:change, new_blocks, meta} ->
            case if(dry_run?, do: {:ok, doc}, else: persist(doc, new_blocks)) do
              {:ok, _} ->
                entry = %{
                  slug: doc.doc_id,
                  dataset: doc.dataset,
                  title_source: meta.title_source,
                  title_text: meta.title_text,
                  featured: meta.featured
                }

                %{
                  acc
                  | changes: [entry | acc.changes],
                    titles: acc.titles + 1,
                    featured_inserted:
                      acc.featured_inserted + if(meta.featured == :inserted, do: 1, else: 0),
                    featured_skipped:
                      acc.featured_skipped + if(meta.featured == :skipped, do: 1, else: 0)
                }

              {:error, changeset} ->
                # A refused save must NOT be reported as changed — the report
                # stays honest, the run continues (one bad row never aborts the
                # rest of an idempotent corpus pass; re-run after fixing it).
                reason = "persist refused by the changeset: #{inspect(changeset.errors)}"

                Logger.error(
                  "doctrine_backfill: REFUSED save for #{inspect(doc.doc_id)} (#{doc.dataset}) — #{reason}"
                )

                entry = %{slug: doc.doc_id, dataset: doc.dataset, reason: reason}
                %{acc | unfixable: [entry | acc.unfixable]}
            end

          {:unfixable, reason} ->
            entry = %{slug: doc.doc_id, dataset: doc.dataset, reason: reason}
            %{acc | unfixable: [entry | acc.unfixable]}
        end
      end)

    stats = %{
      scanned: length(papers),
      conforms: acc.conforms,
      changed_papers: length(acc.changes),
      titles_synthesized: acc.titles,
      featured_inserted: acc.featured_inserted,
      featured_skipped: acc.featured_skipped,
      dry_run: dry_run?,
      changes: Enum.reverse(acc.changes),
      unfixable: Enum.reverse(acc.unfixable)
    }

    {:ok, stats}
  end

  # Every paper document, UNSCOPED — one pass across all workspaces / projects /
  # datasets. The whole struct is selected so `plan/1` sees `title` + `content`
  # and `persist/2` keeps the row's scope columns untouched.
  defp all_papers do
    Repo.all(from(d in Document, where: d.type == @paper_type))
  end

  @doc """
  Classify ONE paper (pure — no DB). Returns:

    * `:conforms` — block 0 is a locked `role: "title"` heading and
      `Template.validate/1` is clean. Leave BYTE-IDENTICAL.
    * `{:change, new_blocks, meta}` — the doctrine backfill plan. `new_blocks` is
      the doctrine-shaped block list (title@0, featured@1 when an asset exists);
      `meta` carries `:title_source`, `:title_text`, `:featured`.
    * `{:unfixable, reason}` — cannot be backfilled automatically (HTML-only, no
      derivable title, an already-present but misplaced title block, a plan that
      would still fail `Template.validate/1`, or non-unique block ids after the
      plan — a pre-existing duplicate or a block squatting on the template id).

  This is the SINGLE source of the migration decision — `run/1` calls it per
  paper and only PERSISTS on `{:change, …}`.
  """
  @spec plan(struct()) :: plan_result()
  def plan(%Document{content: content} = doc) do
    blocks = is_map(content) && Map.get(content, "blocks")

    cond do
      not is_list(blocks) ->
        {:unfixable,
         "html-only paper (no block list); the doctrine template requires a block document"}

      conforms?(blocks) ->
        :conforms

      has_role?(blocks, @title_role) ->
        # Already carries a role:"title" block but does NOT conform (misplaced /
        # duplicated). Auto-synthesizing a second title would violate the
        # single-title rule — leave it for manual review rather than write a
        # broken shape.
        {:unfixable,
         "already carries a role:\"title\" block but block 0 is not the locked title — manual review"}

      true ->
        build_change(doc, blocks)
    end
  end

  def plan(_), do: {:unfixable, "not a paper document"}

  # A paper conforms when block 0 is a locked role:"title" heading AND the full
  # template gate is clean (single title @0, featured @1 when present). This is
  # exactly the shape `--apply` produces, so `plan/1` over our own output returns
  # `:conforms` (idempotence).
  defp conforms?([%{"type" => "heading", "role" => @title_role} = head | _] = blocks) do
    Template.locked?(head) and Template.validate(blocks) == []
  end

  defp conforms?(_), do: false

  # Plan the doctrine backfill for a non-conforming, fixable paper.
  defp build_change(%Document{} = doc, blocks) do
    case derive_title(doc, blocks) do
      {:ok, title_text, title_source} ->
        with_title = place_title(blocks, title_text, title_source)
        {new_blocks, featured} = maybe_place_featured(with_title)

        cond do
          (errors = Template.validate(new_blocks)) != [] ->
            {:unfixable, "template still violated after backfill: " <> Enum.join(errors, "; ")}

          not unique_ids?(new_blocks) ->
            # Same safety net as BackfillBlockIds: NEVER write a duplicate-id
            # paper (duplicate ids are the canvas-diff corruption). Either the
            # corpus row already carried a duplicate (run backfill_block_ids
            # first) or a block squats on the "tpl-title" template id.
            {:unfixable,
             "block ids would not be unique after backfill (pre-existing duplicate, or a block already uses the template id) — manual review"}

          true ->
            {:change, new_blocks,
             %{title_source: title_source, title_text: title_text, featured: featured}}
        end

      :error ->
        {:unfixable,
         "cannot derive a title (no doc.title and no heading block to synthesize from)"}
    end
  end

  # Title synthesis: `doc.title` wins (the doctrine truth — the row title IS the
  # locked title block's text), else the first heading block's text. `:error`
  # when neither yields a non-blank string.
  defp derive_title(%Document{title: title}, blocks) do
    cond do
      (t = blank_to_nil(title)) != nil -> {:ok, t, :doc_title}
      (h = first_heading_text(blocks)) != nil -> {:ok, h, :first_heading}
      true -> :error
    end
  end

  # Place the canonical seed title block at index 0, deduping by TITLE SOURCE.
  #
  # `:first_heading` — the title text was synthesized FROM the paper's first
  # non-blank heading, so that heading is CONSUMED wherever it sits (a legacy
  # paper often opens with an image or standfirst before its heading); keeping
  # it would render the same text twice (title block + body heading).
  defp place_title(blocks, title_text, :first_heading) do
    title_block = seed_title_block(title_text)

    idx =
      Enum.find_index(blocks, fn
        %{"type" => "heading", "text" => text} -> blank_to_nil(text) != nil
        _ -> false
      end)

    # `idx` is never nil here: `:first_heading` implies `first_heading_text/1`
    # found exactly this block.
    [title_block | List.delete_at(blocks, idx)]
  end

  # `:doc_title` — the row title wins. When block 0 is ALREADY a heading whose
  # (trimmed) text IS the derived title, REPLACE it (dedup — a legacy
  # heading-titled paper must not render two identical H1s). Otherwise PREPEND —
  # never clobber a block-0 heading that is real content (a differing heading,
  # or a section heading that merely happens to sit first).
  defp place_title(blocks, title_text, :doc_title) do
    title_block = seed_title_block(title_text)

    case blocks do
      [%{"type" => "heading", "text" => text} | rest] when is_binary(text) ->
        if String.trim(text) == String.trim(title_text) do
          [title_block | rest]
        else
          [title_block | blocks]
        end

      _ ->
        [title_block | blocks]
    end
  end

  defp seed_title_block(title_text), do: Template.template_blocks(title_text) |> hd()

  # Promote the first image ASSET (a FREE `type: "image"` block with a non-blank
  # `src`) to the locked featured block at index 1 — moved, not duplicated. No
  # asset → no featured block (assets are never invented). A field-BOUND image
  # (non-blank `fieldName`) is a field value, not body art — moving it would
  # entangle the field projection with the locked template, so it never
  # qualifies.
  defp maybe_place_featured([title | rest]) do
    case pop_first_featured_candidate(rest) do
      {nil, _rest} ->
        {[title | rest], :skipped}

      {img, remaining} ->
        featured = Map.merge(img, %{"role" => @featured_role, "locked" => true})
        {[title, featured | remaining], :inserted}
    end
  end

  defp pop_first_featured_candidate(blocks) do
    case Enum.find_index(blocks, &featured_candidate?/1) do
      nil -> {nil, blocks}
      idx -> {Enum.at(blocks, idx), List.delete_at(blocks, idx)}
    end
  end

  defp featured_candidate?(%{"type" => "image"} = block) do
    src_present? =
      case Map.get(block, "src") do
        src when is_binary(src) -> String.trim(src) != ""
        _ -> false
      end

    bound? =
      case Map.get(block, "fieldName") do
        name when is_binary(name) -> String.trim(name) != ""
        _ -> false
      end

    src_present? and not bound?
  end

  defp featured_candidate?(_), do: false

  # Post-condition guard: every block id (top-level + nested "blocks"
  # containers) in the planned list is unique. Mirrors BackfillBlockIds'
  # duplicate-id refusal — a duplicate-id paper is the canvas-diff corruption
  # both backfills exist to prevent. Id-less blocks don't count (the id
  # backfill owns filling those).
  defp unique_ids?(blocks) do
    ids = flat_ids(blocks)
    length(ids) == length(Enum.uniq(ids))
  end

  defp flat_ids(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, fn block ->
      id =
        case is_map(block) && Map.get(block, "id") do
          v when is_binary(v) and v != "" -> [v]
          _ -> []
        end

      nested =
        case is_map(block) && Map.get(block, "blocks") do
          children when is_list(children) -> flat_ids(children)
          _ -> []
        end

      id ++ nested
    end)
  end

  defp flat_ids(_), do: []

  defp first_heading_text(blocks) do
    Enum.find_value(blocks, fn
      %{"type" => "heading", "text" => text} -> blank_to_nil(text)
      _ -> nil
    end)
  end

  defp has_role?(blocks, role) do
    Enum.any?(blocks, fn
      %{"role" => ^role} -> true
      _ -> false
    end)
  end

  # Scope-preserving save that refreshes EVERY derived surface the real writer
  # (`write_encrypted_paper` in block_ops.ex) refreshes — this backfill changes
  # the render, so unlike BackfillBlockIds' metadata-only save it must not leave
  # any derived copy stale:
  #
  #   * `content["body_html"]` + `body_html_sv` — the cached render, re-rendered
  #     with the paper's own `style` (the doctrine's render parity).
  #   * `content["body"]` / `content[fieldName]` — `Projection.project/3`, the
  #     SAME call the write path makes, on the SAME `paper_render_opts/3` that
  #     rendered the cache above (task-1d095b61a47bf057; it used to pass plain
  #     style-less `Labels.render_opts/2` and re-project on the `:email`
  #     default). Skipping it would leave the projected body showing the
  #     pre-doctrine structure.
  #   * both revs — the streaming `content["rev"]` (+1) and a fresh opaque row
  #     `rev`, like every real content writer; a changed body under an unchanged
  #     rev would defeat rev-keyed consumers.
  #
  # The row `title` is re-derived from the new title block (pdd-t4: one truth).
  # Only `content`/`title`/`rev` are cast, so the row's workspace/project/dataset
  # columns (and `status`) are preserved. Direct `Repo.update` (no broadcast) —
  # this is an offline migration, not a live edit.
  defp persist(%Document{content: content} = doc, new_blocks) do
    style = get_in(content, ["style"])
    scope = [workspace_id: doc.workspace_id, project_id: doc.project_id]
    render_opts = Labels.paper_render_opts(doc.dataset, style, scope)
    body_html = Render.render_blocks(new_blocks, render_opts)

    new_content =
      content
      |> Map.put("blocks", new_blocks)
      |> Map.put("body_html", body_html)
      |> Map.put("body_html_sv", Render.body_html_render_version())
      |> Map.put("rev", next_content_rev(content))
      # task-1d095b61a47bf057: the projected body rides the SAME `render_opts`
      # the body_html cache above was rendered with (i.e. `paper_render_opts/3`,
      # which now always names `:style, :article`). It used to call plain
      # `Labels.render_opts/2` — style-less — so this backfill re-projected
      # `content["body"]["html"]` on the renderer's `:email` default and put
      # mail typography back into a screen surface on every sweep.
      |> Projection.project(new_blocks, render_opts)

    title = title_block_text(new_blocks) || doc.title

    doc
    |> Document.changeset(%{"content" => new_content, "title" => title, "rev" => generate_rev()})
    |> Repo.update()
  end

  # The monotonic integer streaming rev (same rule as block_ops' paper_next_rev).
  defp next_content_rev(content) do
    case Map.get(content, "rev") do
      n when is_integer(n) -> n + 1
      _ -> 1
    end
  end

  # The document's opaque string row `rev` (mutation-spine version) — the same
  # generator every writer uses, duplicated here like block_ops duplicates it so
  # this module owns its own row-rev generation.
  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp title_block_text([%{"type" => "heading", "role" => @title_role, "text" => text} | _])
       when is_binary(text),
       do: blank_to_nil(text)

  defp title_block_text(_), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      _ -> s
    end
  end

  defp blank_to_nil(_), do: nil

  @doc """
  Emit a one-line summary plus per-paper lines. Pure (no DB) so the `run/1` stats
  drive reporting; used by the Mix task.
  """
  @spec log_report(stats(), (String.t() -> any())) :: :ok
  def log_report(%{} = stats, emit) when is_function(emit, 1) do
    mode = if stats.dry_run, do: "DRY-RUN (no writes)", else: "APPLY (writes)"

    emit.("paper doctrine backfill — #{mode}")
    emit.("  papers scanned:        #{stats.scanned}")
    emit.("  already conforms:      #{stats.conforms}")
    emit.("  papers to backfill:    #{stats.changed_papers}")
    emit.("  titles synthesized:    #{stats.titles_synthesized}")
    emit.("  featured inserted:     #{stats.featured_inserted}")
    emit.("  featured skipped:      #{stats.featured_skipped} (no image asset)")

    Enum.each(stats.changes, fn c ->
      title = "title←#{c.title_source} #{inspect(c.title_text)}"
      featured = "featured #{c.featured}"
      emit.("    • #{c.slug} (#{c.dataset}) — #{title}, #{featured}")
    end)

    if stats.unfixable != [] do
      emit.("  !! UNFIXABLE (reported, never written): #{length(stats.unfixable)}")

      Enum.each(stats.unfixable, fn u ->
        emit.("    ✗ #{u.slug} (#{u.dataset}) — #{u.reason}")
      end)
    end

    :ok
  end
end
