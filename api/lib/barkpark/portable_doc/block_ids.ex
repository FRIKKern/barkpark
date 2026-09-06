defmodule Barkpark.PortableDoc.BlockIds do
  @moduledoc """
  Stable, collision-free block ids for a PortableDoc block list — the kernel
  half of the write chokepoint.

  ## Why it lives here

  `ensure_block_ids/1` used to live in `Barkpark.Content.Papers.BlockOps`, and
  `PortableDoc.Bpml.Diff.derive/2` aliased it to mint ids for the blocks a
  `bp paper push` introduces — a KERNEL module reaching UP into the *papers*
  feature (boundary edge `portable_doc>papers`, task-9d06bca37668f76a). The
  dependency was real: the BPML diff must mint ids "via the same
  `ensure_block_ids/1` every write path uses", or the ops it derives address
  blocks that do not exist yet. The PLACEMENT was wrong — this function knows
  nothing about papers, documents, `Repo` or ops. It is a pure function over a
  block list, i.e. over the PortableDoc block shape itself, so it moved DOWN to
  the layer that defines that shape.

  `BlockOps.ensure_block_ids/1` delegates here and stays the name every write
  path speaks (`upsert_paper`, `Content.Writer`, the op-folds, the backfill Mix
  task, `Content.ensure_block_ids/1`), so the "SINGLE chokepoint" property is
  unchanged — there is still exactly one implementation, and it is this one.

  Pure: no `Repo`, no schema, no deps.
  """

  @doc """
  R2 fix (Option A). Walk a block list and fill a stable positional id
  (`block-<index>`, sections recurse with a `<parent>.<index>` prefix) for
  any block that lacks one. A block already carrying a non-blank "id" is left
  untouched, so author/op-supplied ids — which DocPatchOps address blocks by —
  survive byte-identical and stay resolvable. Visible containers recurse so a
  nested id-less child also gets a unique id (the stream only keys on top-level
  ids, but `apply_paper_block_op` addresses children too).

  Coverage (the three id-less shapes a block can take):

    * ABSENT — no `"id"` key at all → gets `<prefix>-<index>`.
    * BLANK  — `"id" => ""` or `"id" => nil` → gets `<prefix>-<index>`.
    * NESTED — recursion covers `"blocks"` lists, expandable `"children"`, each
      steps row's reader-visible body, each plain-tabs row's canonical
      `"blocks"`, and a Terminal's canonical `"children"`, plus the singular
      map-valued `"child"` of a `figure` and its visible descendants, and map
      children inside each list row of an exact `columns.columns` list. Steps
      and tabs rows gain stable row ids; columns do not gain synthetic row
      identities. Scalar column rows/elements and hidden / opaque aliases remain
      untouched. A figure with a missing, nil, scalar, or array child is opaque,
      as are any figure, Terminal, or columns compatibility aliases. Composite /
      arrayOf inline children under `"items"` / `"content"` are NOT recursed.
      Child prefixes use the parent's (or row/column index's) ensured id, keeping
      minted ids deterministic.

  Collision-safe across the authored tree. Before minting, every present
  non-blank block, steps-row, tabs-row, canonical figure-child, Terminal child,
  and valid column descendant id is reserved globally, including ids in hidden
  steps and Terminal `children` / `blocks` aliases. Only reader-visible paths are
  projected, but a minted positional id can never collide with authored identity
  elsewhere in the document. If taken, a deterministic suffix
  (`-<k>`, k incrementing from 1) is appended until free.

  Idempotent: re-running over an already-id-bearing list is a no-op (a present
  non-blank id is preserved exactly). This is the SINGLE chokepoint every write
  path that persists `content["blocks"]` routes through — the paper upsert path
  (`upsert_paper`), the document write path (`Content.Writer.create_document` /
  `upsert_document`, covering the Sanity-shaped mutation + legacy-create
  ingress), the op-fold paths (`apply_paper_block_op` / `apply_paper_block_ops`),
  and the backfill Mix task all call it, so an id-less block can never reach
  storage.

  Existing explicit duplicate ids are preserved byte-identical. Revision-fenced
  identified document operations reject such an ambiguous target before traversal.
  """
  @spec ensure_block_ids(list()) :: list()
  def ensure_block_ids(blocks) when is_list(blocks) do
    {ensured, _taken} = ensure_block_ids(blocks, "block", MapSet.new(authored_tree_ids(blocks)))
    ensured
  end

  @doc """
  Project stable ids only when every authored block, steps-row, tabs-row,
  canonical figure-child, canonical Terminal child, and valid column-descendant
  identity is unambiguous across the full visible tree. Hidden steps and Terminal
  body aliases participate in the duplicate fence even when they are not
  projected; malformed and compatibility-only aliases remain opaque.
  """
  @spec project_block_ids_safely(list()) ::
          {:ok, list()} | {:error, {:duplicate_id, String.t()}}
  def project_block_ids_safely(blocks) when is_list(blocks) do
    ids = authored_tree_ids(blocks)
    counts = Enum.frequencies(ids)

    case Enum.find(ids, &(Map.fetch!(counts, &1) > 1)) do
      nil -> {:ok, ensure_block_ids(blocks)}
      id -> {:error, {:duplicate_id, id}}
    end
  end

  defp ensure_block_ids(blocks, prefix, taken) when is_list(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.map_reduce(taken, fn {block, index}, taken ->
      ensure_block_id(block, prefix, index, taken)
    end)
  end

  # Returns `{ensured_block, taken'}` — the block with a guaranteed-unique id
  # (recursing into its canonical visible descendants), and the working id-set
  # extended with any id this block now occupies. A present non-blank id is
  # preserved exactly (already in `taken`); an id-less block mints a
  # collision-free positional id.
  defp ensure_block_id(block, prefix, index, taken) when is_map(block) do
    {block, taken} = ensure_identity(block, prefix, index, taken)
    id = block["id"]

    {block, taken} =
      case block do
        %{"type" => "steps", "steps" => rows} when is_list(rows) ->
          {rows, taken} = ensure_step_ids(rows, id <> "-step", taken)
          {Map.put(block, "steps", rows), taken}

        %{"type" => "tabs"} ->
          case Map.get(block, "tabs") do
            rows when is_list(rows) ->
              {rows, taken} = ensure_tab_ids(rows, id <> "-tab", taken)
              {Map.put(block, "tabs", rows), taken}

            _opaque ->
              {block, taken}
          end

        %{"type" => "expandable"} ->
          ensure_visible_body_ids(block, id, taken)

        %{"type" => "columns", "columns" => columns} when is_list(columns) ->
          {columns, taken} = ensure_column_ids(columns, id, taken)
          {Map.put(block, "columns", columns), taken}

        %{"type" => "columns"} ->
          {block, taken}

        %{"type" => "figure", "child" => child} when is_map(child) ->
          {child, taken} = ensure_block_id(child, id <> "-child", 0, taken)
          {Map.put(block, "child", child), taken}

        %{"type" => "figure"} ->
          {block, taken}

        %{"type" => "terminal", "children" => children} when is_list(children) ->
          if Map.has_key?(block, "blocks") do
            {block, taken}
          else
            {children, taken} = ensure_block_ids(children, id, taken)
            {Map.put(block, "children", children), taken}
          end

        %{"type" => "terminal"} ->
          {block, taken}

        %{"blocks" => children} when is_list(children) ->
          {children, taken} = ensure_block_ids(children, id, taken)
          {Map.put(block, "blocks", children), taken}

        _ ->
          {block, taken}
      end

    {block, taken}
  end

  defp ensure_block_id(block, _prefix, _index, taken), do: {block, taken}

  defp ensure_identity(value, prefix, index, taken) do
    case Map.get(value, "id") do
      existing when is_binary(existing) and existing != "" ->
        {value, taken}

      _ ->
        id = unique_id(prefix, index, taken)
        {Map.put(value, "id", id), MapSet.put(taken, id)}
    end
  end

  defp ensure_step_ids(rows, prefix, taken) do
    rows
    |> Enum.with_index()
    |> Enum.map_reduce(taken, fn
      {row, index}, taken when is_map(row) ->
        {row, taken} = ensure_identity(row, prefix, index, taken)

        # A row is not a block. Project its selected body only; do not let
        # generic blocks recursion rewrite a hidden compatibility alias.
        ensure_visible_body_ids(row, row["id"], taken)

      {other, _index}, taken ->
        {other, taken}
    end)
  end

  defp ensure_tab_ids(rows, prefix, taken) do
    rows
    |> Enum.with_index()
    |> Enum.map_reduce(taken, fn
      {row, index}, taken when is_map(row) ->
        {row, taken} = ensure_identity(row, prefix, index, taken)

        case Map.get(row, "blocks") do
          children when is_list(children) ->
            {children, taken} = ensure_block_ids(children, row["id"], taken)
            {Map.put(row, "blocks", children), taken}

          _opaque ->
            {row, taken}
        end

      {other, _index}, taken ->
        {other, taken}
    end)
  end

  defp ensure_column_ids(columns, prefix, taken) do
    columns
    |> Enum.with_index()
    |> Enum.map_reduce(taken, fn
      {children, index}, taken when is_list(children) ->
        ensure_block_ids(children, prefix <> "-column-" <> Integer.to_string(index), taken)

      {opaque, _index}, taken ->
        {opaque, taken}
    end)
  end

  defp ensure_visible_body_ids(container, prefix, taken) do
    case visible_body_key(container) do
      nil ->
        {container, taken}

      key ->
        {children, taken} = ensure_block_ids(Map.fetch!(container, key), prefix, taken)
        {Map.put(container, key, children), taken}
    end
  end

  defp authored_tree_ids(blocks) when is_list(blocks),
    do: Enum.flat_map(blocks, &authored_block_tree_ids/1)

  defp authored_block_tree_ids(block) when is_map(block) do
    nested =
      case block do
        %{"type" => "steps", "steps" => rows} when is_list(rows) ->
          Enum.flat_map(rows, &authored_step_tree_ids/1)

        %{"type" => "tabs"} ->
          case Map.get(block, "tabs") do
            rows when is_list(rows) -> Enum.flat_map(rows, &authored_tab_tree_ids/1)
            _opaque -> []
          end

        %{"type" => "expandable"} ->
          authored_body_alias_ids(block)

        %{"type" => "columns", "columns" => columns} when is_list(columns) ->
          Enum.flat_map(columns, fn
            children when is_list(children) -> authored_tree_ids(children)
            _opaque -> []
          end)

        %{"type" => "columns"} ->
          []

        %{"type" => "figure", "child" => child} when is_map(child) ->
          authored_block_tree_ids(child)

        %{"type" => "figure"} ->
          []

        %{"type" => "terminal"} ->
          authored_body_alias_ids(block)

        %{"blocks" => children} when is_list(children) ->
          authored_tree_ids(children)

        _ ->
          []
      end

    authored_identity(block) ++ nested
  end

  defp authored_block_tree_ids(_block), do: []

  defp authored_step_tree_ids(row) when is_map(row),
    do: authored_identity(row) ++ authored_body_alias_ids(row)

  defp authored_step_tree_ids(_row), do: []

  defp authored_tab_tree_ids(row) when is_map(row) do
    nested =
      case Map.get(row, "blocks") do
        children when is_list(children) -> authored_tree_ids(children)
        _opaque -> []
      end

    authored_identity(row) ++ nested
  end

  defp authored_tab_tree_ids(_row), do: []

  defp authored_body_alias_ids(container) do
    Enum.flat_map(["children", "blocks"], fn key ->
      case Map.get(container, key) do
        children when is_list(children) -> authored_tree_ids(children)
        _other -> []
      end
    end)
  end

  defp authored_identity(%{"id" => id}) when is_binary(id) and id != "", do: [id]
  defp authored_identity(_value), do: []

  defp visible_body_key(container) do
    case Map.get(container, "children") do
      children when is_list(children) ->
        "children"

      absent when absent in [nil, false] ->
        if is_list(Map.get(container, "blocks")), do: "blocks"

      _ ->
        nil
    end
  end

  # The positional candidate `<prefix>-<index>`, disambiguated deterministically
  # if already taken: append `-1`, `-2`, … until free. Deterministic (no
  # randomness) so the same input always yields the same ids, and the appended
  # suffix is itself re-checked against `taken` so it can never collide.
  defp unique_id(prefix, index, taken) do
    candidate = "#{prefix}-#{index}"

    if MapSet.member?(taken, candidate) do
      disambiguate(candidate, taken, 1)
    else
      candidate
    end
  end

  defp disambiguate(base, taken, k) do
    candidate = "#{base}-#{k}"

    if MapSet.member?(taken, candidate) do
      disambiguate(base, taken, k + 1)
    else
      candidate
    end
  end
end
