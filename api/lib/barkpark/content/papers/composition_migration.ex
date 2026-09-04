defmodule Barkpark.Content.Papers.CompositionMigration do
  @moduledoc """
  Migrate LEGACY composite blocks — `cards` / `notes` / `pipeline` — to their
  ratified **widget compositions** (epic `composition-doctrine`, task `ct-rollout`):

    * `cards`    → `section{layout: {mode: "grid", tracks: N}}` holding N `card` widgets
    * `notes`    → `section{layout: {mode: "grid", tracks: 1}}` holding N `note` widgets
    * `pipeline` → `section{layout: {mode: "grid", tracks: N}}` holding N `stage` widgets

  The corpus twin of `Barkpark.Content.Papers.DoctrineBackfill` — same shape
  (scan → pure `plan/1` → dry-run default → `--apply`, additive, idempotent,
  human-gated for prod), but a **1-to-N transform**: ONE legacy grid block becomes
  a `section` plus N editable widget children. The section inherits the legacy
  block's `id` (anchors keep resolving); children get derived ids
  (`<id>-card1`, `<id>-note1`, `<id>-stage1`, …).

  ## The SAFETY LAW — parity proven per block, or skip + report

  `plan/1` PROVES every candidate block's re-render before it is allowed into the
  plan, by executing the REAL emitters (`Render.Components`) on both encodings:

    * **`:byte_equal`** — the migrated widget's `:article` render is BYTE-IDENTICAL
      to the legacy per-item render. `notes → note` and `pipeline → stage` hold this
      at HEAD by construction (`note_item_html/1` / `stage_html/1` are the exact
      per-item expressions the legacy loops emit).
    * **`:model_b_equivalence`** — for `cards → card` ONLY. The `card` widget
      graduated to MODEL B (au-w5-card-slot-parity: slots render as semantic
      elements — the title heading as `<h2>`, the body paragraph as `<p>` — no
      `bp-card__t`/`bp-card__d` text-flatten chrome), so strict item bytes moved
      BY RATIFIED DESIGN. The proof here is mechanical: the legacy item bytes,
      rewritten under the TWO-RULE chrome map
      (`<div class="bp-card__t">X</div>` → `<h2>X</h2>`,
      `<div class="bp-card__d">X</div>` → `<p>X</p>`), must equal the widget's
      render EXACTLY — container div + tone class byte-identical, escaped text
      byte-identical, only the ratified chrome swap between them.

  A block that cannot be proven — a missing `id` (anchors could not be preserved),
  keys outside the legacy vocabulary (unknown semantics), an item/node outside the
  item vocabulary, a parity mismatch, or a legacy block NESTED inside a container
  (1-to-N inside a container is unreviewed territory) — is **SKIPPED and
  reported, never force-migrated**. Each migrated block's report entry carries
  which proof grounded it.

  ## The documented WRAPPER equivalence (reviewed, not byte-equal)

  The per-item bytes are proven; the WRAPPER around them changes by ratified
  doctrine design (each widget's @doc: "the grid/section owns the wrapper"):

    * `<div class="bp-cards">` (auto-fill grid, 12px gap) → section grid,
      `tracks: min(N,2)` + `gap: "sm"` — the `SECTION_OF_CARDS` fixture shape.
    * `<div class="bp-notes">` (flex column, 0.9rem gap) → section grid,
      `tracks: 1` + `gap: "sm"` — one note row per cell.
    * `<div class="bp-pipe-scroll"><div class="bp-pipe">` (horizontal flow,
      `→` arrow separators) → section grid, `tracks: N` + `gap: "sm"`. The
      arrows and the horizontal scroll are legacy-wrapper chrome and do NOT
      survive — the WEAKEST leg of the equivalence, called out per block in the
      report so the human gate reviews it before `--apply`.

  Parity is proven at the `:article` reader surface (the persisted `body_html`);
  the email/TUI surfaces ride each widget's own ratified twin renderers.

  ## Corpus targeting

  `portabledoc-showcase` (an INTENTIONAL legacy+widget parity fixture — its
  legacy blocks are the point) and wave papers (`*-wave-YYYY-MM-DD`, ephemeral)
  are EXCLUDED by slug and reported as such.

  ## Dry-run is the default

  `run/1` defaults to `dry_run: true` — it scans every paper and emits a
  per-paper plan, writing NOTHING. `run(dry_run: false)` (the Mix task's
  `--apply`) persists like the real writer: re-render `content["body_html"]`,
  re-project `content["body"]`, bump both revs, preserve the row's scope
  columns. Idempotent: a migrated paper carries no legacy composite blocks, so a
  second run plans 0 changes.

  ## Human runbook (the apply is HUMAN-GATED)

  DO NOT run `--apply` against prod / guerrilla unattended:

      # 1. Dry-run — inspect the per-paper plan (migrated blocks + their parity
      #    proof, skipped blocks + why, excluded fixtures). Writes nothing.
      mix barkpark.paper.composition_migrate

      # 2. Review every SKIPPED entry and the pipeline wrapper notes by hand.

      # 3. Apply, then re-run the dry-run to confirm it now plans 0.
      mix barkpark.paper.composition_migrate --apply
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Barkpark.Repo
  alias Barkpark.Content.Document
  alias Barkpark.Content.Labels
  alias Barkpark.Content.Papers.Hollow
  alias Barkpark.Content.Papers.Template
  alias Barkpark.PortableDoc.Projection
  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Components
  alias Barkpark.PortableDoc.Slots

  @paper_type "paper"

  @legacy_types ~w(cards notes pipeline)

  # Slugs that carry legacy blocks ON PURPOSE — never migrated, reported as excluded.
  @excluded_slugs ["portabledoc-showcase"]
  # Ephemeral wave papers (e.g. composition-doctrine-wave-2026-07-10).
  @wave_slug ~r/-wave-\d{4}-\d{2}-\d{2}/

  # The full legacy vocabulary per block / item. Keys OUTSIDE these sets mean
  # semantics this migration does not understand → skip + report, never guess.
  @block_keys %{
    "cards" => ~w(id type items),
    "notes" => ~w(id type items),
    "pipeline" => ~w(id type nodes)
  }
  @item_keys %{
    "cards" => ~w(title text tone),
    "notes" => ~w(label lead text),
    "pipeline" => ~w(kind title detail files source)
  }

  @type parity :: :byte_equal | :model_b_equivalence

  @type migrated_entry :: %{
          id: String.t(),
          from: String.t(),
          children: non_neg_integer(),
          parity: parity()
        }

  @type skipped_entry :: %{id: String.t() | nil, type: String.t(), reason: String.t()}

  @type plan_meta :: %{migrated: [migrated_entry()], skipped: [skipped_entry()]}

  @type plan_result ::
          :conforms
          | {:excluded, String.t()}
          | {:change, [map()], plan_meta()}
          | {:skips_only, [skipped_entry()]}

  @type change_entry :: %{
          slug: String.t(),
          dataset: String.t(),
          migrated: [migrated_entry()],
          skipped: [skipped_entry()]
        }

  @type skip_report :: %{slug: String.t(), dataset: String.t(), skipped: [skipped_entry()]}

  @type stats :: %{
          scanned: non_neg_integer(),
          conforms: non_neg_integer(),
          excluded: [%{slug: String.t(), dataset: String.t(), reason: String.t()}],
          changed_papers: non_neg_integer(),
          blocks_migrated: non_neg_integer(),
          blocks_skipped: non_neg_integer(),
          dry_run: boolean(),
          changes: [change_entry()],
          skips_only: [skip_report()],
          unfixable: [%{slug: String.t(), dataset: String.t(), reason: String.t()}]
        }

  @doc """
  Scan the WHOLE paper corpus and (unless dry-run) migrate legacy composite
  blocks to widget compositions.

  `opts`:

    * `:dry_run` (boolean, default `true`) — when `true`, compute the per-paper
      plan and write nothing. The default is SAFE: a bare call never mutates.

  Returns `{:ok, stats}` — see `t:stats/0`. Idempotent: a second run over an
  already-migrated corpus returns `changed_papers: 0`.
  """
  @spec run(keyword()) :: {:ok, stats()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)

    papers = all_papers()

    acc0 = %{
      conforms: 0,
      excluded: [],
      changes: [],
      skips_only: [],
      unfixable: []
    }

    acc =
      Enum.reduce(papers, acc0, fn doc, acc ->
        case plan(doc) do
          :conforms ->
            %{acc | conforms: acc.conforms + 1}

          {:excluded, reason} ->
            entry = %{slug: doc.doc_id, dataset: doc.dataset, reason: reason}
            %{acc | excluded: [entry | acc.excluded]}

          {:skips_only, skipped} ->
            entry = %{slug: doc.doc_id, dataset: doc.dataset, skipped: skipped}
            %{acc | skips_only: [entry | acc.skips_only]}

          {:change, new_blocks, meta} ->
            case if(dry_run?, do: {:ok, doc}, else: persist(doc, new_blocks)) do
              {:ok, _} ->
                entry = %{
                  slug: doc.doc_id,
                  dataset: doc.dataset,
                  migrated: meta.migrated,
                  skipped: meta.skipped
                }

                %{acc | changes: [entry | acc.changes]}

              {:error, changeset} ->
                # A refused save is NEVER reported as changed — the report stays
                # honest and the corpus pass continues (re-run after fixing).
                reason = "persist refused by the changeset: #{inspect(changeset.errors)}"

                Logger.error(
                  "composition_migration: REFUSED save for #{inspect(doc.doc_id)} (#{doc.dataset}) — #{reason}"
                )

                entry = %{slug: doc.doc_id, dataset: doc.dataset, reason: reason}
                %{acc | unfixable: [entry | acc.unfixable]}
            end
        end
      end)

    changes = Enum.reverse(acc.changes)
    skips_only = Enum.reverse(acc.skips_only)

    stats = %{
      scanned: length(papers),
      conforms: acc.conforms,
      excluded: Enum.reverse(acc.excluded),
      changed_papers: length(changes),
      blocks_migrated: changes |> Enum.map(&length(&1.migrated)) |> Enum.sum(),
      blocks_skipped:
        Enum.sum(Enum.map(changes, &length(&1.skipped))) +
          Enum.sum(Enum.map(skips_only, &length(&1.skipped))),
      dry_run: dry_run?,
      changes: changes,
      skips_only: skips_only,
      unfixable: Enum.reverse(acc.unfixable)
    }

    {:ok, stats}
  end

  # Every paper document, UNSCOPED — one pass across all workspaces / projects /
  # datasets, exactly like DoctrineBackfill.
  defp all_papers do
    Repo.all(from(d in Document, where: d.type == @paper_type))
  end

  @doc """
  Classify ONE paper (pure — no DB). Returns:

    * `:conforms` — no TOP-LEVEL legacy composite block (nothing to migrate;
      includes HTML-only papers). Leave BYTE-IDENTICAL.
    * `{:excluded, reason}` — an intentional fixture / wave paper; never migrated.
    * `{:change, new_blocks, meta}` — at least one legacy block PROVED and
      migrated; `meta.migrated` carries each block's parity proof,
      `meta.skipped` any block left in place with its reason.
    * `{:skips_only, skipped}` — legacy blocks exist but NONE could be proven;
      nothing is written, everything is reported.

  This is the SINGLE source of the migration decision — `run/1` calls it per
  paper and only PERSISTS on `{:change, …}`.
  """
  @spec plan(struct()) :: plan_result()
  def plan(%Document{doc_id: slug, content: content}) do
    blocks = is_map(content) && Map.get(content, "blocks")

    cond do
      excluded_reason(slug) != nil ->
        {:excluded, excluded_reason(slug)}

      not is_list(blocks) ->
        # HTML-only / pre-doctrine paper: no block list, no legacy composite
        # blocks to migrate. Not this migration's concern.
        :conforms

      not has_legacy_blocks?(blocks) ->
        :conforms

      true ->
        build_change(blocks)
    end
  end

  def plan(_), do: {:skips_only, [%{id: nil, type: "?", reason: "not a paper document"}]}

  defp excluded_reason(slug) when is_binary(slug) do
    cond do
      slug in @excluded_slugs ->
        "intentional legacy+widget parity fixture — its legacy blocks are the point"

      slug =~ @wave_slug ->
        "ephemeral wave paper — not corpus debt"

      true ->
        nil
    end
  end

  defp excluded_reason(_), do: nil

  # A paper participates when a legacy composite block exists ANYWHERE (top level
  # or nested) — nested ones are then reported as skipped, never silently ignored.
  defp has_legacy_blocks?(blocks) do
    Enum.any?(blocks, fn b -> legacy?(b) or nested_legacy(b) != [] end)
  end

  defp legacy?(%{"type" => t}) when t in @legacy_types, do: true
  defp legacy?(_), do: false

  # Legacy blocks nested inside container blocks (section/terminal `blocks` or
  # `children`, columns' list-of-lists). 1-to-N inside a container is unreviewed
  # territory — they are surfaced as skips, never migrated in place.
  defp nested_legacy(block) when is_map(block) do
    children =
      List.wrap(Map.get(block, "children") || Map.get(block, "blocks")) ++
        (block |> Map.get("columns") |> List.wrap() |> List.flatten())

    Enum.flat_map(children, fn child ->
      direct = if legacy?(child), do: [child], else: []
      direct ++ nested_legacy(child)
    end)
  end

  defp nested_legacy(_), do: []

  # Walk the top-level list: migrate every PROVEN legacy block in place, collect
  # skips (unproven + nested), leave everything else byte-identical.
  defp build_change(blocks) do
    {new_blocks_rev, migrated_rev, skipped_rev} =
      Enum.reduce(blocks, {[], [], []}, fn block, {bs, ms, ss} ->
        nested_skips =
          Enum.map(nested_legacy(block), fn nb ->
            %{
              id: Map.get(nb, "id"),
              type: Map.get(nb, "type"),
              reason:
                "nested inside a container block — 1-to-N in place is unreviewed; manual review"
            }
          end)

        cond do
          legacy?(block) ->
            case migrate_block(block) do
              {:ok, section, entry} -> {[section | bs], [entry | ms], ss}
              {:skip, skip} -> {[block | bs], ms, [skip | ss]}
            end

          true ->
            {[block | bs], ms, Enum.reverse(nested_skips) ++ ss}
        end
      end)

    new_blocks = Enum.reverse(new_blocks_rev)
    migrated = Enum.reverse(migrated_rev)
    skipped = Enum.reverse(skipped_rev)

    cond do
      migrated == [] ->
        {:skips_only, skipped}

      (errors = Template.validate(new_blocks)) != [] ->
        {:skips_only,
         demote_all(
           migrated,
           skipped,
           "template violated after migration: " <> Enum.join(errors, "; ")
         )}

      not unique_ids?(new_blocks) ->
        # NEVER write a duplicate-id paper (the canvas-diff corruption) — a
        # derived child id collided with an existing block id.
        {:skips_only,
         demote_all(migrated, skipped, "derived child ids would not be unique — manual review")}

      Hollow.hollow?(new_blocks) ->
        # The hollow-paper law: one predicate at every write seam. Structurally
        # unreachable here (the transform preserves content), kept as the seam guard.
        {:skips_only,
         demote_all(migrated, skipped, "migration would leave a hollow paper — refused")}

      true ->
        {:change, new_blocks, %{migrated: migrated, skipped: skipped}}
    end
  end

  # A whole-paper guard failed AFTER per-block proofs: demote every would-be
  # migration to a skip so the report explains why nothing was written.
  defp demote_all(migrated, skipped, reason) do
    Enum.map(migrated, fn m -> %{id: m.id, type: m.from, reason: reason} end) ++ skipped
  end

  # ── the three transforms (each returns {:ok, section, entry} | {:skip, entry}) ──

  defp migrate_block(%{"type" => type} = block) do
    with :ok <- require_id(block),
         :ok <- known_keys(block, type),
         {:ok, items} <- require_items(block, type),
         :ok <- known_item_keys(items, type),
         {:ok, children, parity} <- build_children(block, items, type) do
      id = Map.get(block, "id")

      section = %{
        "id" => id,
        "type" => "section",
        "layout" => %{"mode" => "grid", "tracks" => tracks(type, length(children)), "gap" => "sm"},
        "blocks" => children
      }

      {:ok, section, %{id: id, from: type, children: length(children), parity: parity}}
    else
      {:skip, reason} ->
        {:skip, %{id: Map.get(block, "id"), type: type, reason: reason}}
    end
  end

  defp require_id(block) do
    case Map.get(block, "id") do
      id when is_binary(id) and id != "" ->
        :ok

      _ ->
        {:skip,
         "block has no id — run barkpark.paper.backfill_block_ids first (anchors must survive)"}
    end
  end

  defp known_keys(block, type) do
    case Map.keys(block) -- Map.fetch!(@block_keys, type) do
      [] ->
        :ok

      extra ->
        {:skip, "carries keys outside the legacy vocabulary (#{inspect(extra)}) — manual review"}
    end
  end

  defp require_items(block, type) do
    key = if type == "pipeline", do: "nodes", else: "items"

    case Map.get(block, key) do
      [_ | _] = items ->
        {:ok, items}

      _ ->
        {:skip,
         "empty or missing #{key} — the legacy render is already \"\"; nothing provable to migrate"}
    end
  end

  defp known_item_keys(items, type) do
    allow = Map.fetch!(@item_keys, type)

    items
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn {item, i} ->
      cond do
        not is_map(item) ->
          {:skip, "item #{i} is not a map — manual review"}

        (extra = Map.keys(item) -- allow) != [] ->
          {:skip,
           "item #{i} carries keys outside the legacy vocabulary (#{inspect(extra)}) — manual review"}

        true ->
          nil
      end
    end)
  end

  # tracks: the SECTION_OF_CARDS-blessed 2-up grid for cards (min for a lone
  # card), one note row per line, one column per pipeline stage (the flow).
  defp tracks("cards", n), do: min(n, 2)
  defp tracks("notes", _n), do: 1
  defp tracks("pipeline", n), do: n

  # Build the widget children AND prove parity per item — the safety law. The
  # weakest item's proof grades the whole block (:byte_equal only when every
  # item is byte-equal); ONE unprovable item skips the whole block.
  defp build_children(block, items, type) do
    base_id = Map.get(block, "id")

    items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], :byte_equal}, fn {item, i}, {:ok, acc, worst} ->
      child = build_child(item, type, "#{base_id}-#{child_suffix(type)}#{i}")

      case prove_item_parity(item, child, type) do
        {:ok, parity} ->
          {:cont, {:ok, [child | acc], max_parity(worst, parity)}}

        {:error, detail} ->
          {:halt, {:skip, "item #{i} failed the parity proof — #{detail}"}}
      end
    end)
    |> case do
      {:ok, children_rev, parity} -> {:ok, Enum.reverse(children_rev), parity}
      {:skip, reason} -> {:skip, reason}
    end
  end

  defp child_suffix("cards"), do: "card"
  defp child_suffix("notes"), do: "note"
  defp child_suffix("pipeline"), do: "stage"

  defp max_parity(:byte_equal, p), do: p
  defp max_parity(:model_b_equivalence, _), do: :model_b_equivalence

  # ONE legacy cards item → a slots-native `card` widget (the smoke/cards.mjs
  # CARD fixture shape: heading title slot, plain-paragraph body slot, tone chrome).
  defp build_child(item, "cards", id) do
    title = item |> Map.get("title") |> stringish()
    text = item |> Map.get("text") |> stringish()
    tone = item |> Map.get("tone") |> stringish()

    slots =
      %{}
      |> put_present("title", title != "", [%{"type" => "heading", "text" => title}])
      |> put_present("body", text != "", [text_paragraph(text)])

    %{"id" => id, "type" => "card"}
    |> put_present("tone", tone != "", tone)
    |> put_present("slots", slots != %{}, slots)
  end

  # ONE legacy notes item → a `note` widget. Flat fields first (the byte-identity
  # accessors read both), then `Slots.normalize_widget/1` dual-writes the slots —
  # the canonical persisted form.
  defp build_child(item, "notes", id) do
    label = item |> Map.get("label") |> stringish()
    lead = item |> Map.get("lead") |> stringish()
    text = item |> Map.get("text") |> stringish()

    %{"id" => id, "type" => "note", "label" => label, "text" => text}
    |> put_present("lead", lead != "", lead)
    |> Slots.normalize_widget()
  end

  # ONE legacy pipeline node → a `stage` widget. kind/title/detail become the
  # scalar compat encoding (normalize_widget dual-writes the slots and drops
  # empties); `files`/`source` are widget CHROME and copy VERBATIM when present.
  defp build_child(node, "pipeline", id) do
    %{"id" => id, "type" => "stage"}
    |> copy_present(node, "kind")
    |> copy_present(node, "title")
    |> copy_present(node, "detail")
    |> copy_present(node, "files")
    |> copy_present(node, "source")
    |> Slots.normalize_widget()
  end

  defp put_present(map, _key, false, _value), do: map
  defp put_present(map, key, true, value), do: Map.put(map, key, value)

  defp copy_present(map, source, key) do
    case Map.fetch(source, key) do
      {:ok, v} -> Map.put(map, key, v)
      :error -> map
    end
  end

  defp text_paragraph(text),
    do: %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  # ── the parity proofs (the REAL emitters, both sides) ───────────────────────

  # The legacy per-item bytes: render a single-item legacy block through the real
  # emitter and strip the wrapper the section replaces (documented equivalence).
  defp legacy_item_html(item, "cards"),
    do: unwrap(Components.cards_html(%{"items" => [item]}), ~s(<div class="bp-cards">), "</div>")

  defp legacy_item_html(item, "notes"),
    do: unwrap(Components.notes_html(%{"items" => [item]}), ~s(<div class="bp-notes">), "</div>")

  defp legacy_item_html(node, "pipeline"),
    do:
      unwrap(
        Components.pipeline_html(%{"nodes" => [node]}),
        ~s(<div class="bp-pipe-scroll"><div class="bp-pipe">),
        "</div></div>"
      )

  defp unwrap(html, prefix, suffix) do
    inner_len = byte_size(html) - byte_size(prefix) - byte_size(suffix)

    # Slice EXACTLY one prefix + one suffix (String.trim_trailing would eat the
    # item's own closing `</div>`s, not just the wrapper's).
    if inner_len >= 0 and String.starts_with?(html, prefix) and String.ends_with?(html, suffix) do
      {:ok, binary_part(html, byte_size(prefix), inner_len)}
    else
      {:error, "legacy render did not match the documented wrapper shape"}
    end
  end

  # The widget bytes: the SAME function `compose_block(widget, :article)` routes
  # to inside a section cell, so this IS what the migrated paper will render.
  defp widget_html(child, "cards"), do: Components.card_html(child)
  defp widget_html(child, "notes"), do: Components.note_item_html(child)
  defp widget_html(child, "pipeline"), do: Components.stage_html(child)

  defp prove_item_parity(item, child, type) do
    with {:ok, legacy} <- legacy_item_html(item, type) do
      new = widget_html(child, type)

      cond do
        new == legacy ->
          {:ok, :byte_equal}

        type == "cards" and new == model_b_map(legacy) ->
          {:ok, :model_b_equivalence}

        true ->
          {:error,
           "widget render diverges from the legacy item render beyond the documented equivalence"}
      end
    end
  end

  # The TWO-RULE model-B chrome map (au-w5-card-slot-parity, GRADUATED): the
  # legacy text-flatten wrappers become the semantic elements the card widget's
  # slot recursion emits. Escaped text can contain no `<`, so `[^<]*` is exact.
  defp model_b_map(legacy_item_html) do
    legacy_item_html
    |> String.replace(~r|<div class="bp-card__t">([^<]*)</div>|, "<h2>\\1</h2>")
    |> String.replace(~r|<div class="bp-card__d">([^<]*)</div>|, "<p>\\1</p>")
  end

  defp stringish(s) when is_binary(s), do: s
  defp stringish(n) when is_integer(n), do: Integer.to_string(n)
  defp stringish(_), do: ""

  # Post-condition guard (the DoctrineBackfill net): every block id — top-level,
  # nested containers, and widget slot children — is unique after the plan.
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

  # Scope-preserving save — the DoctrineBackfill persist, minus the title recast
  # (this migration never touches the title block): re-render the cached
  # `body_html` with the paper's own style, re-project the body, bump both revs.
  # Direct `Repo.update` (no broadcast) — an offline migration, not a live edit.
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

    doc
    |> Document.changeset(%{"content" => new_content, "rev" => generate_rev()})
    |> Repo.update()
  end

  defp next_content_rev(content) do
    case Map.get(content, "rev") do
      n when is_integer(n) -> n + 1
      _ -> 1
    end
  end

  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc """
  Emit a one-line summary plus per-paper lines. Pure (no DB) so the `run/1` stats
  drive reporting; used by the Mix task.
  """
  @spec log_report(stats(), (String.t() -> any())) :: :ok
  def log_report(%{} = stats, emit) when is_function(emit, 1) do
    mode = if stats.dry_run, do: "DRY-RUN (no writes)", else: "APPLY (writes)"

    emit.("legacy composite → widget-composition migration — #{mode}")
    emit.("  papers scanned:       #{stats.scanned}")
    emit.("  nothing to migrate:   #{stats.conforms}")
    emit.("  excluded fixtures:    #{length(stats.excluded)}")
    emit.("  papers to migrate:    #{stats.changed_papers}")
    emit.("  blocks migrated:      #{stats.blocks_migrated}")
    emit.("  blocks skipped:       #{stats.blocks_skipped} (reported, never forced)")

    Enum.each(stats.excluded, fn e ->
      emit.("    ∅ #{e.slug} (#{e.dataset}) — EXCLUDED: #{e.reason}")
    end)

    Enum.each(stats.changes, fn c ->
      emit.("    • #{c.slug} (#{c.dataset})")

      Enum.each(c.migrated, fn m ->
        emit.("        #{m.from} #{m.id} → section + #{m.children} widgets [#{m.parity}]")
      end)

      Enum.each(c.skipped, fn s ->
        emit.("        ✗ SKIPPED #{s.type} #{s.id || "?"} — #{s.reason}")
      end)
    end)

    Enum.each(stats.skips_only, fn r ->
      emit.("    ! #{r.slug} (#{r.dataset}) — legacy blocks present, NONE provable:")

      Enum.each(r.skipped, fn s ->
        emit.("        ✗ #{s.type} #{s.id || "?"} — #{s.reason}")
      end)
    end)

    if stats.unfixable != [] do
      emit.("  !! REFUSED saves: #{length(stats.unfixable)}")

      Enum.each(stats.unfixable, fn u ->
        emit.("    ✗ #{u.slug} (#{u.dataset}) — #{u.reason}")
      end)
    end

    :ok
  end
end
