defmodule BarkparkWeb.Studio.StudioLive.Shared.Paper do
  @moduledoc """
  Paper-editing helpers extracted from `StudioLive.Shared` (Modularity gate).

  These are the cohesive `paper_*` block-op / stream / view-setup helpers that
  drive the paper editor surface: applying block ops, reordering, descriptor
  expectations, backlink loading, the `:paper_blocks` stream, and live-delta
  application. They thread `socket` explicitly and are behaviour-preserving —
  moved verbatim from `Shared`. All are `@doc false`: an internal seam, not a
  public API. `Shared` re-exports each via `defdelegate` so existing
  `Shared.<fn>(...)` call sites keep working unchanged.

  The one call back into the staying module is `Shared.hook_opts/1` (used by
  `document_op/2`); `Shared` in turn calls `Paper.setup_paper_view/2` and
  `Paper.clear_paper_view/1` from `rebuild_panes/1`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias Barkpark.PortableDoc.{Projection, Render}
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas
  alias BarkparkWeb.Studio.StudioLive.Shared

  @doc false
  def paper_op(socket, op) do
    cond do
      socket.assigns[:editor_view] == :form and socket.assigns[:editor_mode] == :beta and
          socket.assigns[:editor_doc] != nil ->
        document_op(socket, op)

      true ->
        paper_pane_op(socket, op)
    end
  end

  @doc false
  def paper_pane_op(socket, op) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    cond do
      is_nil(slug) ->
        socket

      true ->
        case Content.apply_paper_block_op(slug, op, dataset) do
          {:ok, _result} ->
            sync_paper_edit_doc(socket)

          {:error, _reason} ->
            put_flash(socket, :error, "Edit failed")
        end
    end
  end

  @doc false
  # Phase-4 S2: fold an ORDERED ARRAY of ops (one bp-canvas-ops batch from a
  # <bp-paper-canvas> run) through the PAPER-PANE persist + sync path —
  # specifically paper_pane_op/2's (NOT the full paper_op/2, which also has a
  # document_op branch for the Beta per-document editor). That is safe because
  # the canvas is gated to the paper pane only (paper_block_editor canvas_eligible
  # — see components/paper_editor.ex), so a batch never originates in the
  # document editor. Only the batch primitive differs from the per-block path:
  # apply_paper_block_ops/4 vs apply_paper_block_op/3 (both atomic, both folding
  # via Patch.apply_patch). No new model / schema / storage. Guards a non-list or
  # empty batch — and a nil paper_doc — as a no-op so a stray event never writes.
  # Mirrors paper_pane_op/2's load (current paper_doc slug), apply (atomic fold),
  # persist (one Repo.update), and re-sync (sync_paper_edit_doc → View re-streams).
  def paper_ops(socket, ops) when is_list(ops) and ops != [] do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    cond do
      is_nil(slug) ->
        socket

      true ->
        case Content.apply_paper_block_ops(slug, ops, dataset) do
          {:ok, _result} ->
            # Re-read the paper (apply_paper_block_ops returns only the batch
            # receipt %{slug, op_count, rev, block_ids} — NOT the post-apply
            # blocks), assigning the fresh paper_doc. The View pane re-streams off
            # that, AND it carries the CONFIRMED blocks we echo back to the canvas.
            socket
            |> sync_paper_edit_doc()
            |> push_canvas_echo()

          {:error, _reason} ->
            put_flash(socket, :error, "Edit failed")
        end
    end
  end

  def paper_ops(socket, _ops), do: socket

  @doc false
  # Phase-4 S4a: ECHO the server-CONFIRMED blocks back to the <bp-paper-canvas>.
  #
  # Reads the post-apply blocks off the FRESH paper_doc (sync_paper_edit_doc just
  # assigned it), partitions them into the SAME maximal prose runs the editor
  # mounts (PaperCanvas.partition_runs — the identical keying components.ex uses),
  # and pushes `bp:canvas-update` carrying ONE entry per prose RUN: %{run_id:
  # <"run-"<>ordinal>, blocks: <run blocks>}.
  #
  # Bug #1a: each run is keyed by its ORDINAL in the partition (via the SAME
  # PaperCanvas.with_run_ordinals/1 helper components.ex uses for the wrapper id),
  # NOT its mutable first-block id. So the echo for run `i` always matches the
  # wrapper "paper-canvas-run-<i>" that components.ex rendered for run `i` — even
  # when the run's LEADING block was just deleted/merged (the run stays at the same
  # ordinal). The inbound hook routes each run to its element by that id.
  # Only `{:run, _}` segments are echoed — the non-prose `{:block, _}` boundaries
  # have no canvas to update. The canvas treats its OWN echo as a pure baseline
  # reset (no caret move); an external edit lands as a confirmed re-render. This
  # advances the canvas diff baseline so the NEXT batch is INCREMENTAL, not
  # cumulative-from-mount. No-op when the canvas flag is OFF (no canvas is mounted
  # to receive the event, but we also gate so the OFF path pushes nothing).
  def push_canvas_echo(socket) do
    if PaperCanvas.paper_canvas_enabled?() do
      blocks =
        case socket.assigns[:paper_doc] do
          %{content: %{"blocks" => blocks}} when is_list(blocks) -> blocks
          _ -> []
        end

      runs =
        blocks
        |> PaperCanvas.partition_runs()
        |> PaperCanvas.with_run_ordinals()
        |> Enum.flat_map(fn
          {:run, run_blocks, ordinal} ->
            [%{run_id: PaperCanvas.run_id(ordinal), blocks: run_blocks}]

          {:block, _block} ->
            []
        end)

      push_event(socket, "bp:canvas-update", %{runs: runs})
    else
      socket
    end
  end

  @doc false
  def document_op(socket, op) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    case Content.apply_document_block_op(doc.doc_id, type, op, dataset, Shared.hook_opts(socket)) do
      {:ok, _result} ->
        sync_editor_blocks(socket)

      {:error, _reason} ->
        put_flash(socket, :error, "Edit failed")
    end
  end

  @doc false
  def sync_editor_blocks(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    with %{doc_id: doc_id} <- doc,
         {:ok, fresh} <-
           Content.get_document(doc_id, type, dataset, ScopeHelpers.scope_opts(socket)) do
      {blocks, synth?} = Content.resolve_blocks_for_edit(fresh, type, dataset)

      assign(socket,
        editor_doc: fresh,
        editor_blocks: blocks,
        editor_blocks_synth?: synth?,
        editor_form: Content.doc_to_form(fresh, socket.assigns[:editor_schema])
      )
    else
      _ -> socket
    end
  end

  @doc false
  def paper_reorder(socket, _blocks, nil, _dir), do: socket

  def paper_reorder(socket, blocks, idx, "up") when idx > 0 do
    moved = Enum.at(blocks, idx)
    after_id = if idx >= 2, do: Map.get(Enum.at(blocks, idx - 2), "id"), else: nil
    paper_op(socket, %{"op" => "move-block", "id" => Map.get(moved, "id"), "after" => after_id})
  end

  def paper_reorder(socket, blocks, idx, "down") when idx < length(blocks) - 1 do
    moved = Enum.at(blocks, idx)
    anchor_id = Map.get(Enum.at(blocks, idx + 1), "id")
    paper_op(socket, %{"op" => "move-block", "id" => Map.get(moved, "id"), "after" => anchor_id})
  end

  def paper_reorder(socket, _blocks, _idx, _dir), do: socket

  @doc false
  def sync_paper_edit_doc(socket) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id

    case slug && Content.get_paper(slug, socket.assigns.dataset) do
      %{} = fresh -> assign(socket, paper_doc: fresh)
      _ -> socket
    end
  end

  @doc false
  def paper_top_level_blocks(socket) do
    cond do
      socket.assigns[:editor_view] == :form and socket.assigns[:editor_mode] == :beta and
          is_list(socket.assigns[:editor_blocks]) ->
        socket.assigns[:editor_blocks]

      true ->
        case socket.assigns[:paper_doc] do
          %{content: %{"blocks" => blocks}} when is_list(blocks) -> blocks
          _ -> []
        end
    end
  end

  @doc false
  def paper_top_level_free(socket) do
    socket |> paper_top_level_blocks() |> Projection.partition() |> elem(1)
  end

  @doc false
  # Every expected `field` descriptor for the live editor block list (incl.
  # bound-and-at-cap). [] when there is no schema/Expectation.
  def paper_all_descriptors(socket) do
    case slash_expectation(socket) do
      %{layout: _} = expectation ->
        Content.all_expected_fields(
          paper_top_level_blocks(socket),
          expectation,
          socket.assigns[:editor_schema]
        )

      _ ->
        []
    end
  end

  @doc false
  def slash_insert_op(after_id, block) when is_binary(after_id) and after_id != "",
    do: %{"op" => "insert-after", "afterId" => after_id, "block" => block}

  def slash_insert_op(_after_id, block),
    do: %{"op" => "append-block", "block" => block}

  @doc false
  def expected_field_blocked?(socket, field_name) do
    case slash_expectation(socket) do
      %{layout: _} = expectation ->
        Content.expected_field_blocked?(
          paper_top_level_blocks(socket),
          expectation,
          field_name
        )

      _ ->
        false
    end
  end

  @doc false
  def slash_expectation(socket) do
    case socket.assigns[:editor_schema] do
      %Barkpark.Content.SchemaDefinition{} = schema -> Content.resolve_expectation(schema)
      _ -> nil
    end
  end

  @doc false
  def paper_block_by_id(socket, id) do
    Blocks.find_paper_block(paper_top_level_blocks(socket), id)
  end

  @doc false
  def setup_paper_view(socket, %{content: content} = paper) when is_map(content) do
    blocks = Map.get(content, "blocks")
    rev = Map.get(content, "rev") || 0
    html = Map.get(content, "body_html") || ""
    {linked, unlinked} = load_backlinks(socket, paper)

    if is_list(blocks) do
      socket
      |> assign(
        editor_view: :paper,
        paper_doc: paper,
        paper_rev: rev,
        paper_html: html,
        paper_block_mode: true,
        paper_edit_mode: false,
        backlinks_linked: linked,
        backlinks_unlinked: unlinked,
        backlinks_open: true
      )
      |> stream(
        :paper_blocks,
        paper_stream_items(blocks, socket.assigns.dataset, ScopeHelpers.scope_opts(socket)),
        reset: true
      )
    else
      socket
      |> assign(
        editor_view: :paper,
        paper_doc: paper,
        paper_rev: rev,
        paper_html: html,
        paper_block_mode: false,
        paper_edit_mode: false,
        backlinks_linked: linked,
        backlinks_unlinked: unlinked,
        backlinks_open: true
      )
      |> stream(:paper_blocks, [], reset: true)
    end
  end

  def setup_paper_view(socket, _paper), do: clear_paper_view(socket)

  @doc """
  Read-only inbound-reference load for the backlinks panel. Resolves the paper's
  published id and runs the arrayOf-aware `Content.Graph.reverse_referencers/2`
  ONCE (scope + dataset bound), then partitions the single result into two
  mutually-exclusive lists by edge origin:

    * `linked`  — direct schema-field reference edges (`plugin_source == nil`),
                  i.e. real "Linked mentions".
    * `derived` — plugin/derived inbound edges (`plugin_source` set).

  Returns `{[], []}` for a draft / unresolvable / never-referenced paper — the
  panel renders an empty state, never crashes.
  """
  def load_backlinks(socket, %{doc_id: doc_id}) when is_binary(doc_id) do
    published_id = Content.published_id(doc_id)
    opts = [dataset: socket.assigns.dataset] ++ ScopeHelpers.scope_opts(socket)

    published_id
    |> Content.Graph.reverse_referencers(opts)
    |> Enum.split_with(fn ref -> is_nil(ref[:plugin_source]) end)
  end

  def load_backlinks(_socket, _paper), do: {[], []}

  @doc false
  def clear_paper_view(socket) do
    if socket.assigns[:editor_view] == :paper do
      assign(socket,
        editor_view: :form,
        paper_doc: nil,
        paper_rev: 0,
        paper_html: "",
        paper_block_mode: false,
        paper_edit_mode: false,
        backlinks_linked: [],
        backlinks_unlinked: [],
        backlinks_open: true
      )
    else
      assign(socket,
        editor_view: :form,
        backlinks_linked: [],
        backlinks_unlinked: [],
        backlinks_open: true
      )
    end
  end

  @doc false
  def paper_stream_items(blocks, dataset, scope) do
    resolver = fn value, ref_type -> Content.reference_title(value, ref_type, dataset, scope) end

    codelist_resolver = fn plugin, codelist_id, code ->
      Content.codelist_label(plugin, codelist_id, code)
    end

    # Pre-resolve every wikilink target ONCE so the view-mode render emits
    # navigable <a> links for resolved targets (unresolved → the dotted span).
    wikilinks = Content.resolve_wikilinks_in_blocks(blocks, dataset, scope)

    # Pre-resolve every note-embed (`![[note]]`) target ONCE so the view-mode
    # render transcludes the target paper's HTML (unresolved → broken-embed
    # fallback). Mirrors the wikilinks wiring; one-level + cycle-safe (each
    # target renders with an empty embed map — see resolve_embeds_in_blocks/3).
    embeds = Content.resolve_embeds_in_blocks(blocks, dataset, scope)

    opts = %{
      ref_resolver: resolver,
      codelist_resolver: codelist_resolver,
      style: :article,
      wikilinks: wikilinks,
      embeds: embeds
    }

    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, index} ->
      %{id: paper_stream_block_id(block, index), html: Render.render_block(block, opts)}
    end)
  end

  @doc false
  def paper_stream_block_id(block, index) do
    case Map.get(block, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> "block-#{index}"
    end
  end

  @doc false
  def paper_block_dom_id(id), do: "paper_blocks-#{id}"

  @doc false
  def paper_gap?(last_rev, incoming_rev)
      when is_integer(last_rev) and is_integer(incoming_rev) do
    incoming_rev != last_rev + 1
  end

  def paper_gap?(_last, _incoming), do: true

  @doc false
  def apply_paper_delta(socket, %{op_kind: "remove-block", block_id: id} = frame) do
    socket
    |> stream_delete_by_dom_id(:paper_blocks, paper_block_dom_id(id))
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  def apply_paper_delta(
        socket,
        %{op_kind: kind, block_id: id, fragment_html: html, position: pos} = frame
      )
      when kind in ["append-block", "insert-after"] and is_integer(pos) do
    socket
    |> stream_insert(:paper_blocks, %{id: id, html: html}, at: pos)
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  def apply_paper_delta(
        socket,
        %{op_kind: "move-block", block_id: id, fragment_html: html, position: pos} = frame
      )
      when is_integer(pos) do
    socket
    |> stream_delete_by_dom_id(:paper_blocks, paper_block_dom_id(id))
    |> stream_insert(:paper_blocks, %{id: id, html: html}, at: pos)
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  def apply_paper_delta(socket, %{block_id: id, fragment_html: html} = frame) do
    socket
    |> stream_insert(:paper_blocks, %{id: id, html: html})
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  @doc false
  def refetch_paper(socket) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    case slug && Content.get_paper(slug, dataset) do
      nil ->
        socket

      paper ->
        content = paper.content || %{}

        case Map.get(content, "blocks") do
          blocks when is_list(blocks) ->
            socket
            |> stream(
              :paper_blocks,
              paper_stream_items(blocks, dataset, ScopeHelpers.scope_opts(socket)),
              reset: true
            )
            |> assign(:paper_doc, paper)
            |> assign(:paper_rev, Map.get(content, "rev") || 0)
            |> assign(:paper_block_mode, true)

          _ ->
            socket
            |> assign(:paper_doc, paper)
            |> assign(:paper_html, Map.get(content, "body_html") || "")
            |> assign(:paper_rev, Map.get(content, "rev") || 0)
            |> assign(:paper_block_mode, false)
        end
    end
  end
end
