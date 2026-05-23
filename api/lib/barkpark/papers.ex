defmodule Barkpark.Papers do
  @moduledoc """
  Context for paperflow papers (convergence masterplan Figure 6;
  block-streaming in Wave 4).

  A paper is a slug-keyed row. Two storage modes coexist:

    * **block-backed (Wave 4):** `blocks` (a portable-doc block list) is the
      source of truth; `body_html` is a derived cache rendered by
      `Barkpark.PortableDoc.Render` on every write.
    * **HTML-only (Wave 3, legacy):** `blocks` is `nil`; the opaque
      `body_html` is stored and rendered verbatim. No backfill.

  Broadcasts ride the **same** per-doc PubSub topic shape Barkpark already uses
  for documents — `doc:<dataset>:<type>:<id>` — so `BarkparkWeb.PaperLive`
  rides the existing `Phoenix.PubSub → LiveView` spine. No new broadcast
  engine, no GenServer-per-document.

  ## Two broadcast frames

    * `{:paper_updated, %{slug, dataset, html, rev, …}}` — the **whole-HTML**
      frame (Wave 3). Used on initial create / HTML-only upsert / fallback.
      PaperLive re-assigns the full container.
    * `{:paper_block, %{op_kind, block_id, fragment_html, position, rev}}` — the
      **delta** frame (Wave 4). Emitted on a successful block op. PaperLive
      appends/patches the single affected stream item — no whole re-assign.

  Every write bumps a **monotonic per-paper integer** `rev` and stamps the
  broadcast with it, so PaperLive can spot a missed delta (received rev !=
  expected rev) and refetch the full doc.

  ## Coalescing (T4.7) — deferred, by design

  Each block op flushes exactly one delta frame (flush-per-op). A debounce
  buffer was deliberately NOT added: it would need a GenServer-per-paper and
  would break the per-op `rev` contract that rev-gap recovery depends on (each
  op must carry its own consecutive rev). The consumer cost per frame is a
  single `stream_insert`, which morphdom patches in place — cheap. Coalescing
  becomes worthwhile only under sustained high-frequency bursts; until a real
  workload demands it, flush-per-op is the simpler correct behaviour.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.Papers.Paper
  alias Barkpark.PortableDoc.{Patch, Render}

  @default_dataset "paperflow"
  # Matches the `type` segment used in the documents per-doc topic; papers
  # are their own logical type on the shared spine.
  @paper_type "paper"

  @doc "The default dataset papers live under (mirrors the paperflow side)."
  def default_dataset, do: @default_dataset

  @doc """
  Per-doc PubSub topic for a paper. Same shape as the documents spine:
  `doc:<dataset>:<type>:<id>`. PaperLive subscribes to this; writes broadcast
  to it.
  """
  def topic(slug, dataset \\ @default_dataset) when is_binary(slug) do
    "doc:#{dataset}:#{@paper_type}:#{slug}"
  end

  @doc "Fetch a paper by slug (and dataset). Returns the struct or nil."
  def get_paper(slug, dataset \\ @default_dataset) when is_binary(slug) do
    Repo.one(from p in Paper, where: p.slug == ^slug and p.dataset == ^dataset)
  end

  @doc """
  The paper's block list, or `nil` for an HTML-only (legacy) paper.
  """
  def get_blocks(slug, dataset \\ @default_dataset) when is_binary(slug) do
    case get_paper(slug, dataset) do
      nil -> nil
      %Paper{blocks: blocks} -> blocks
    end
  end

  @doc """
  Upsert a paper keyed by `{dataset, slug}` and broadcast a **whole-HTML**
  frame on the per-doc topic.

  `attrs` accepts string or atom keys: `slug` (required), and either
  `body_html` OR `blocks`. When `blocks` is given, `body_html` is (re)rendered
  from it as the derived cache; when only `body_html` is given, the paper stays
  HTML-only (`blocks` left as-is / nil). Optionally `dataset`, `source_doc`,
  `goal_id`, `event_type`. `rev` is bumped to the next integer on every write.

  On success, broadcasts `{:paper_updated, %{slug, dataset, html, rev, …}}` to
  `topic(slug, dataset)` and returns `{:ok, paper}`. Returns `{:error,
  changeset}` on validation/constraint failure.
  """
  def upsert_paper(attrs) when is_map(attrs) do
    attrs = normalize(attrs)
    slug = attrs["slug"]
    dataset = attrs["dataset"] || @default_dataset
    attrs = Map.put(attrs, "dataset", dataset)

    existing = slug && get_paper(slug, dataset)

    # When blocks are supplied, render the HTML cache from them so the two stay
    # in lockstep. When only HTML is supplied, store it opaquely (legacy path).
    attrs =
      case attrs["blocks"] do
        blocks when is_list(blocks) ->
          Map.put(attrs, "body_html", Render.render_blocks(blocks))

        _ ->
          attrs
      end

    attrs = Map.put(attrs, "rev", next_rev(existing))

    changeset = Paper.changeset(existing || %Paper{}, attrs)

    result =
      if existing do
        Repo.update(changeset)
      else
        Repo.insert(changeset)
      end

    case result do
      {:ok, paper} ->
        broadcast_update(paper)
        {:ok, paper}

      error ->
        error
    end
  end

  @doc """
  Apply a single portable-doc `op` (a DocPatchOp map) to a paper's block list,
  persist the new block list + a refreshed `body_html` cache + a bumped `rev`,
  then broadcast a **delta** frame.

  Flow:

    1. Load the paper. Unknown slug ⇒ `{:error, :not_found}`. A paper that has
       never carried blocks (HTML-only) seeds an empty block list, so the first
       op can `append-block` into it.
    2. Apply via `Barkpark.PortableDoc.Patch.apply_patch/2`. A patch failure
       surfaces structurally as `{:error, {code, target, op_kind}}` (e.g.
       `{:error, {:block_not_found, "x", "patch-block"}}`).
    3. Render just the affected block via `Barkpark.PortableDoc.Render` and
       refresh the whole `body_html` cache from the new block list.
    4. Persist `blocks` + `body_html` + bumped `rev`.
    5. Broadcast `{:paper_block, %{op_kind, block_id, fragment_html, position,
       rev}}` on the per-doc topic.

  Returns `{:ok, %{block:, fragment_html:, op_kind:, block_id:, position:,
  rev:}}` on success.
  """
  def apply_block_op(slug, op, dataset \\ @default_dataset)
      when is_binary(slug) and is_map(op) do
    with %Paper{} = paper <- get_paper(slug, dataset),
         blocks = paper.blocks || [],
         {:ok, new_blocks} <- Patch.apply_patch(blocks, op),
         {:ok, affected} <- locate_affected(op, new_blocks) do
      op_kind = Map.get(op, "op")
      rev = next_rev(paper)
      body_html = Render.render_blocks(new_blocks)

      fragment_html =
        case affected.block do
          nil -> nil
          block -> Render.render_block(block)
        end

      changeset =
        Paper.changeset(paper, %{
          "blocks" => new_blocks,
          "body_html" => body_html,
          "rev" => rev
        })

      case Repo.update(changeset) do
        {:ok, _saved} ->
          frame = %{
            op_kind: op_kind,
            block_id: affected.block_id,
            fragment_html: fragment_html,
            position: affected.position,
            rev: rev
          }

          broadcast_block(slug, dataset, frame)

          {:ok,
           %{
             block: affected.block,
             fragment_html: fragment_html,
             op_kind: op_kind,
             block_id: affected.block_id,
             position: affected.position,
             rev: rev
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  # ── Internal ────────────────────────────────────────────────────────────

  # Resolve which block an op affected (post-apply) plus its position, so the
  # delta frame can tell PaperLive whether to append, insert-after, patch, or
  # remove the stream item. `position` is the 0-based index in the TOP-LEVEL
  # block list (the common flat-list case the streaming consumer keys on);
  # `nil` for ops on a nested-section block or a remove.
  defp locate_affected(%{"op" => "append-block", "block" => block}, new_blocks) do
    {:ok,
     %{block: block, block_id: Map.get(block, "id"), position: length(new_blocks) - 1}}
  end

  defp locate_affected(%{"op" => "insert-after", "block" => block}, new_blocks) do
    id = Map.get(block, "id")
    {:ok, %{block: block, block_id: id, position: top_level_index(new_blocks, id)}}
  end

  defp locate_affected(%{"op" => kind, "id" => id}, new_blocks)
       when kind in ["patch-block", "replace-block"] do
    block = find_block(new_blocks, id)
    {:ok, %{block: block, block_id: id, position: top_level_index(new_blocks, id)}}
  end

  defp locate_affected(%{"op" => "remove-block", "id" => id}, _new_blocks) do
    # The block is gone; the frame carries only its id so the consumer can
    # delete the stream item. No fragment to render.
    {:ok, %{block: nil, block_id: id, position: nil}}
  end

  defp locate_affected(op, _new_blocks), do: {:error, {:invalid_op, op}}

  # 0-based index of `id` in the top-level list, or nil if it lives in a section.
  defp top_level_index(blocks, id) do
    Enum.find_index(blocks, fn b -> Map.get(b, "id") == id end)
  end

  # Find a block by id anywhere in the tree (recurses sections).
  defp find_block(blocks, id) do
    Enum.find_value(blocks, fn block ->
      cond do
        Map.get(block, "id") == id -> block
        Map.get(block, "type") == "section" -> find_block(Map.get(block, "blocks", []), id)
        true -> nil
      end
    end)
  end

  defp broadcast_update(%Paper{} = paper) do
    msg =
      {:paper_updated,
       %{
         slug: paper.slug,
         dataset: paper.dataset,
         html: paper.body_html,
         rev: paper.rev,
         source_doc: paper.source_doc,
         goal_id: paper.goal_id,
         event_type: paper.event_type
       }}

    Phoenix.PubSub.broadcast(Barkpark.PubSub, topic(paper.slug, paper.dataset), msg)
  end

  defp broadcast_block(slug, dataset, frame) do
    Phoenix.PubSub.broadcast(Barkpark.PubSub, topic(slug, dataset), {:paper_block, frame})
  end

  # Allow callers to pass atom OR string keys (controller params are strings,
  # internal callers/tests may use atoms). Stringify, dropping nils.
  defp normalize(attrs) do
    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      if is_nil(v), do: acc, else: Map.put(acc, key, v)
    end)
  end

  # Next monotonic rev for a paper. Starts at 1 for a fresh paper; increments
  # the stored integer otherwise.
  defp next_rev(nil), do: 1
  defp next_rev(%Paper{rev: rev}) when is_integer(rev), do: rev + 1
  defp next_rev(%Paper{}), do: 1
end
