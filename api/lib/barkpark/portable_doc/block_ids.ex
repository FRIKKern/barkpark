defmodule Barkpark.PortableDoc.BlockIds do
  @optional_tab_projection_marker :__barkpark_optional_tab_id_projection__

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

  `BlockOps.ensure_block_ids/1` delegates here for reader/editor projection.
  Persistence paths use `ensure_persisted_block_ids/1`, which shares the same
  implementation but preserves the optional omission of a plain-tabs row id.

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
  non-blank id is preserved exactly). Persistence paths use the companion
  `ensure_persisted_block_ids/1`; ordinary blocks still cannot reach storage
  without an id, while a plain-tabs row may retain its schema-valid absent id.

  Existing explicit duplicate ids are preserved byte-identical. Revision-fenced
  identified document operations reject such an ambiguous target before traversal.
  """
  @spec ensure_block_ids(list()) :: list()
  def ensure_block_ids(blocks) when is_list(blocks) do
    {ensured, _taken} =
      ensure_block_ids(blocks, "block", MapSet.new(authored_tree_ids(blocks)), :project)

    ensured
  end

  @doc false
  @spec project_block_ids_for_edit(list()) :: list()
  def project_block_ids_for_edit(blocks) when is_list(blocks) do
    {projected, _taken} =
      ensure_block_ids(blocks, "block", MapSet.new(authored_tree_ids(blocks)), :edit)

    projected
  end

  @doc """
  Fill block identities before persistence while preserving an absent `id` on
  a plain-tabs row. PortableDoc makes that row identity optional; readers and
  revision-fenced editors may project one in memory with `ensure_block_ids/1`,
  but an unrelated write must not turn the projection into authored data.

  Explicit row ids, including ids minted by a client for a newly inserted row,
  remain byte-identical. Blank or nil ids are still repaired because they are
  present invalid identities, not an omitted optional field.
  """
  @spec ensure_persisted_block_ids(list()) :: list()
  def ensure_persisted_block_ids(blocks) when is_list(blocks) do
    {ensured, _taken} =
      ensure_block_ids(blocks, "block", MapSet.new(authored_tree_ids(blocks)), :persist)

    ensured
  end

  @doc """
  Remove only tab-row identities carrying server-side projection provenance,
  then apply the persistence normalizer. The provenance is an internal atom
  attached by `project_block_ids_for_edit_safely/1`; it cannot arrive in a JSON
  op payload. A coarse replacement therefore keeps an explicitly authored id,
  even when it equals the deterministic id previously projected for an omitted
  row. Opaque aliases and metadata are never traversed as visible tab rows.
  """
  @spec restore_optional_tab_id_omissions(list(), list()) :: list()
  def restore_optional_tab_id_omissions(blocks, _authored) when is_list(blocks) do
    blocks
    |> restore_optional_tab_projection_ids()
    |> strip_optional_tab_projection_markers()
    |> ensure_persisted_block_ids()
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
    project_block_ids_safely(blocks, :project)
  end

  @doc false
  @spec project_block_ids_for_edit_safely(list()) ::
          {:ok, list()} | {:error, {:duplicate_id, String.t()}}
  def project_block_ids_for_edit_safely(blocks) when is_list(blocks) do
    project_block_ids_safely(blocks, :edit)
  end

  defp project_block_ids_safely(blocks, mode) do
    ids = authored_tree_ids(blocks)
    counts = Enum.frequencies(ids)

    case Enum.find(ids, &(Map.fetch!(counts, &1) > 1)) do
      nil ->
        {projected, _taken} = ensure_block_ids(blocks, "block", MapSet.new(ids), mode)
        {:ok, projected}

      id ->
        {:error, {:duplicate_id, id}}
    end
  end

  defp ensure_block_ids(blocks, prefix, taken, mode) when is_list(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.map_reduce(taken, fn {block, index}, taken ->
      ensure_block_id(block, prefix, index, taken, mode)
    end)
  end

  # Returns `{ensured_block, taken'}` — the block with a guaranteed-unique id
  # (recursing into its canonical visible descendants), and the working id-set
  # extended with any id this block now occupies. A present non-blank id is
  # preserved exactly (already in `taken`); an id-less block mints a
  # collision-free positional id.
  defp ensure_block_id(block, prefix, index, taken, mode) when is_map(block) do
    {block, taken} = ensure_identity(block, prefix, index, taken)
    id = block["id"]

    {block, taken} =
      case block do
        %{"type" => "steps", "steps" => rows} when is_list(rows) ->
          {rows, taken} = ensure_step_ids(rows, id <> "-step", taken, mode)
          {Map.put(block, "steps", rows), taken}

        %{"type" => "tabs"} ->
          case Map.get(block, "tabs") do
            rows when is_list(rows) ->
              {rows, taken} = ensure_tab_ids(rows, id <> "-tab", taken, mode)
              {Map.put(block, "tabs", rows), taken}

            _opaque ->
              {block, taken}
          end

        %{"type" => "expandable"} ->
          ensure_visible_body_ids(block, id, taken, mode)

        %{"type" => "columns", "columns" => columns} when is_list(columns) ->
          {columns, taken} = ensure_column_ids(columns, id, taken, mode)
          {Map.put(block, "columns", columns), taken}

        %{"type" => "columns"} ->
          {block, taken}

        %{"type" => "figure", "child" => child} when is_map(child) ->
          {child, taken} = ensure_block_id(child, id <> "-child", 0, taken, mode)
          {Map.put(block, "child", child), taken}

        %{"type" => "figure"} ->
          {block, taken}

        %{"type" => "terminal", "children" => children} when is_list(children) ->
          if Map.has_key?(block, "blocks") do
            {block, taken}
          else
            {children, taken} = ensure_block_ids(children, id, taken, mode)
            {Map.put(block, "children", children), taken}
          end

        %{"type" => "terminal"} ->
          {block, taken}

        %{"blocks" => children} when is_list(children) ->
          {children, taken} = ensure_block_ids(children, id, taken, mode)
          {Map.put(block, "blocks", children), taken}

        _ ->
          {block, taken}
      end

    {block, taken}
  end

  defp ensure_block_id(block, _prefix, _index, taken, _mode), do: {block, taken}

  defp ensure_identity(value, prefix, index, taken) do
    case Map.get(value, "id") do
      existing when is_binary(existing) and existing != "" ->
        {value, taken}

      _ ->
        id = unique_id(prefix, index, taken)
        {Map.put(value, "id", id), MapSet.put(taken, id)}
    end
  end

  defp ensure_step_ids(rows, prefix, taken, mode) do
    rows
    |> Enum.with_index()
    |> Enum.map_reduce(taken, fn
      {row, index}, taken when is_map(row) ->
        {row, taken} = ensure_identity(row, prefix, index, taken)

        # A row is not a block. Project its selected body only; do not let
        # generic blocks recursion rewrite a hidden compatibility alias.
        ensure_visible_body_ids(row, row["id"], taken, mode)

      {other, _index}, taken ->
        {other, taken}
    end)
  end

  defp ensure_tab_ids(rows, prefix, taken, mode) do
    rows
    |> Enum.with_index()
    |> Enum.map_reduce(taken, fn
      {row, index}, taken when is_map(row) ->
        {row, row_prefix, taken} = ensure_tab_identity(row, prefix, index, taken, mode)

        case Map.get(row, "blocks") do
          children when is_list(children) ->
            {children, taken} = ensure_block_ids(children, row_prefix, taken, mode)
            {Map.put(row, "blocks", children), taken}

          _opaque ->
            {row, taken}
        end

      {other, _index}, taken ->
        {other, taken}
    end)
  end

  defp ensure_tab_identity(row, prefix, index, taken, :persist)
       when not is_map_key(row, "id") do
    {row, unique_id(prefix, index, taken), taken}
  end

  defp ensure_tab_identity(row, prefix, index, taken, :edit)
       when not is_map_key(row, "id") do
    {row, taken} = ensure_identity(row, prefix, index, taken)
    {Map.put(row, @optional_tab_projection_marker, true), row["id"], taken}
  end

  defp ensure_tab_identity(row, prefix, index, taken, _mode) do
    {row, taken} = ensure_identity(row, prefix, index, taken)
    {row, row["id"], taken}
  end

  defp ensure_column_ids(columns, prefix, taken, mode) do
    columns
    |> Enum.with_index()
    |> Enum.map_reduce(taken, fn
      {children, index}, taken when is_list(children) ->
        ensure_block_ids(children, prefix <> "-column-" <> Integer.to_string(index), taken, mode)

      {opaque, _index}, taken ->
        {opaque, taken}
    end)
  end

  defp ensure_visible_body_ids(container, prefix, taken, mode) do
    case visible_body_key(container) do
      nil ->
        {container, taken}

      key ->
        {children, taken} = ensure_block_ids(Map.fetch!(container, key), prefix, taken, mode)
        {Map.put(container, key, children), taken}
    end
  end

  defp restore_optional_tab_projection_ids(blocks) when is_list(blocks),
    do: Enum.map(blocks, &restore_optional_tab_projection_block/1)

  defp restore_optional_tab_projection_block(block) when is_map(block) do
    case block do
      %{"type" => "steps", "steps" => rows} when is_list(rows) ->
        Map.put(block, "steps", Enum.map(rows, &restore_optional_tab_projection_row_body/1))

      %{"type" => "tabs", "tabs" => rows} when is_list(rows) ->
        Map.put(block, "tabs", Enum.map(rows, &restore_optional_tab_projection_tab_row/1))

      %{"type" => "expandable"} ->
        restore_optional_tab_projection_body(block)

      %{"type" => "columns", "columns" => columns} when is_list(columns) ->
        columns =
          Enum.map(columns, fn
            children when is_list(children) -> restore_optional_tab_projection_ids(children)
            opaque -> opaque
          end)

        Map.put(block, "columns", columns)

      %{"type" => "figure", "child" => child} when is_map(child) ->
        Map.put(block, "child", restore_optional_tab_projection_block(child))

      %{"type" => "terminal", "children" => children} when is_list(children) ->
        if Map.has_key?(block, "blocks"),
          do: block,
          else: Map.put(block, "children", restore_optional_tab_projection_ids(children))

      %{"type" => "terminal"} ->
        block

      %{"blocks" => children} when is_list(children) ->
        Map.put(block, "blocks", restore_optional_tab_projection_ids(children))

      _opaque ->
        block
    end
  end

  defp restore_optional_tab_projection_block(other), do: other

  defp restore_optional_tab_projection_tab_row(row) when is_map(row) do
    row =
      if row[@optional_tab_projection_marker] == true,
        do: row |> Map.delete("id") |> Map.delete(@optional_tab_projection_marker),
        else: row

    case row["blocks"] do
      children when is_list(children) ->
        Map.put(row, "blocks", restore_optional_tab_projection_ids(children))

      _opaque ->
        row
    end
  end

  defp restore_optional_tab_projection_tab_row(other), do: other

  defp restore_optional_tab_projection_row_body(row) when is_map(row),
    do: restore_optional_tab_projection_body(row)

  defp restore_optional_tab_projection_row_body(other), do: other

  defp restore_optional_tab_projection_body(container) do
    case visible_body_key(container) do
      nil ->
        container

      key ->
        Map.put(container, key, restore_optional_tab_projection_ids(Map.fetch!(container, key)))
    end
  end

  # A projection marker is an internal atom and can never be authored by JSON.
  # Strip any orphan defensively without interpreting the surrounding payload or
  # deleting an id from an opaque/hidden tabs-shaped map.
  defp strip_optional_tab_projection_markers(value) when is_list(value),
    do: Enum.map(value, &strip_optional_tab_projection_markers/1)

  defp strip_optional_tab_projection_markers(value) when is_map(value) do
    value
    |> Map.delete(@optional_tab_projection_marker)
    |> Map.new(fn {key, child} -> {key, strip_optional_tab_projection_markers(child)} end)
  end

  defp strip_optional_tab_projection_markers(other), do: other

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
