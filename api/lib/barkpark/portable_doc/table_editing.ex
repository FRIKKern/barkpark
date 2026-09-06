defmodule Barkpark.PortableDoc.TableEditing do
  @moduledoc """
  Lossless storage lens for the strict first editable Table grammar.

  The editor projection collapses authored row/cell carriers into one grid, but
  the shape vector records their exact storage kinds. Merges and structural
  actions always re-project the freshly loaded authoritative Table and write
  through its original carriers; unsupported reader dialects remain read-only.
  """

  alias Barkpark.Content.Papers.BlockOps

  @max_safe_integer 9_007_199_254_740_991
  @aliases ~w(content header headers columns)
  @indexed_actions ~w(remove-row up-row down-row remove-column left-column right-column)

  @type projection :: %{shape: map(), head: nil | [list()], rows: [[list()]]}

  @spec project(term()) :: {:ok, projection()} | {:error, :read_only_shape}
  def project(%{"id" => id, "type" => "table", "rows" => rows} = table)
      when is_binary(id) and is_list(rows) do
    with true <- id != "" and String.trim(id) == id,
         true <- Enum.all?(@aliases, &(not Map.has_key?(table, &1))),
         {:ok, row_shapes, projected_rows, width} <- project_body_rows(rows),
         {:ok, head_shape, projected_head} <- project_head(table, width),
         true <- BlockOps.normalize_render_shapes([table]) == [table] do
      {:ok,
       %{
         shape: %{"v" => 1, "head" => head_shape, "rows" => row_shapes},
         head: projected_head,
         rows: projected_rows
       }}
    else
      _ -> {:error, :read_only_shape}
    end
  end

  def project(_table), do: {:error, :read_only_shape}

  @spec merge_cells(term(), term(), term()) ::
          {:ok, map()} | {:error, :read_only_shape | :stale_shape | :invalid_cells}
  def merge_cells(table, expected_shape, changes) do
    with {:ok, projection} <- project(table),
         true <- projection.shape == expected_shape,
         {:ok, changes} <- validate_changes(changes, projection),
         {:ok, updated} <- apply_cell_changes(table, changes) do
      case project(updated) do
        {:ok, _updated_projection} -> {:ok, updated}
        {:error, :read_only_shape} -> {:error, :invalid_cells}
      end
    else
      {:error, :read_only_shape} = error -> error
      false -> {:error, :stale_shape}
      _ -> {:error, :invalid_cells}
    end
  end

  @spec apply_action(term(), term(), term()) ::
          {:ok, map()} | {:error, :read_only_shape | :stale_shape | :invalid_action}
  def apply_action(table, expected_shape, action) do
    with {:ok, projection} <- project(table),
         true <- projection.shape == expected_shape,
         {:ok, parsed_action} <- parse_action(action),
         {:ok, updated} <- apply_parsed_action(table, projection, parsed_action),
         {:ok, _projection} <- project(updated) do
      {:ok, updated}
    else
      {:error, :read_only_shape} = error -> error
      false -> {:error, :stale_shape}
      _ -> {:error, :invalid_action}
    end
  end

  defp project_body_rows([]), do: :error

  defp project_body_rows(rows) do
    with {:ok, projected} <- map_rows(rows),
         [{_shape, first_cells} | _] <- projected,
         width when width > 0 <- length(first_cells),
         true <- Enum.all?(projected, fn {_shape, cells} -> length(cells) == width end) do
      {:ok, Enum.map(projected, &elem(&1, 0)), Enum.map(projected, &elem(&1, 1)), width}
    else
      _ -> :error
    end
  end

  defp map_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case project_row(row) do
        {:ok, shape, cells} -> {:cont, {:ok, [{shape, cells} | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp project_row(cells) when is_list(cells), do: project_cells(cells, "array")

  defp project_row(%{"cells" => cells} = row) when is_list(cells) do
    if Map.has_key?(row, "header"), do: :error, else: project_cells(cells, "cells-map")
  end

  defp project_row(_row), do: :error

  defp project_cells([], _kind), do: :error

  defp project_cells(cells, kind) do
    Enum.reduce_while(cells, {:ok, [], []}, fn cell, {:ok, shapes, projected} ->
      case project_cell(cell) do
        {:ok, shape, inline} -> {:cont, {:ok, [shape | shapes], [inline | projected]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, shapes, projected} ->
        {:ok, %{"kind" => kind, "cells" => Enum.reverse(shapes)}, Enum.reverse(projected)}

      :error ->
        :error
    end
  end

  defp project_cell(inline) when is_list(inline) do
    if valid_inline?(inline), do: {:ok, "inline-array", inline}, else: :error
  end

  defp project_cell(%{"content" => inline} = cell) when is_list(inline) do
    if valid_inline?(inline) and not Map.has_key?(cell, "header") and
         cell["type"] not in ["tableHeader", "table_header"] do
      {:ok, "content-map", inline}
    else
      :error
    end
  end

  defp project_cell(_cell), do: :error

  defp project_head(table, width) do
    cond do
      not Map.has_key?(table, "head") ->
        {:ok, %{"state" => "absent"}, nil}

      is_nil(table["head"]) ->
        {:ok, %{"state" => "null"}, nil}

      table["head"] == [] ->
        {:ok, %{"state" => "empty"}, nil}

      is_list(table["head"]) ->
        case project_cells(table["head"], "array") do
          {:ok, row_shape, cells} when length(cells) == width ->
            {:ok, %{"state" => "row", "row" => row_shape}, cells}

          _ ->
            :error
        end

      true ->
        :error
    end
  end

  defp validate_changes(changes, projection) when is_list(changes) do
    Enum.reduce_while(changes, {:ok, nil, []}, fn change, {:ok, previous, acc} ->
      case validate_change(change, projection) do
        {:ok, key} when is_nil(previous) or key > previous ->
          {:cont, {:ok, key, [change | acc]}}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, _last, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp validate_changes(_changes, _projection), do: :error

  defp validate_change(
         %{"area" => area, "row" => row, "column" => column, "content" => content} = change,
         projection
       )
       when area in ["head", "body"] do
    with true <- exact_keys?(change, ~w(area row column content)),
         true <- safe_index?(row) and safe_index?(column),
         true <- valid_inline?(content),
         true <- change_in_bounds?(area, row, column, projection) do
      {:ok, {area_rank(area), row, column}}
    else
      _ -> :error
    end
  end

  defp validate_change(_change, _projection), do: :error

  defp change_in_bounds?("head", 0, column, %{head: head}) when is_list(head),
    do: column < length(head)

  defp change_in_bounds?("body", row, column, %{rows: rows}) do
    case Enum.at(rows, row) do
      cells when is_list(cells) -> column < length(cells)
      _ -> false
    end
  end

  defp change_in_bounds?(_area, _row, _column, _projection), do: false

  defp area_rank("head"), do: 0
  defp area_rank("body"), do: 1

  defp apply_cell_changes(table, changes) do
    Enum.reduce_while(changes, {:ok, table}, fn change, {:ok, current} ->
      case put_changed_cell(current, change) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp put_changed_cell(table, %{
         "area" => "head",
         "row" => 0,
         "column" => column,
         "content" => inline
       }) do
    with {:ok, row} <- put_row_cell(table["head"], column, inline) do
      {:ok, Map.put(table, "head", row)}
    end
  end

  defp put_changed_cell(table, %{
         "area" => "body",
         "row" => row_index,
         "column" => column,
         "content" => inline
       }) do
    with row when not is_nil(row) <- Enum.at(table["rows"], row_index),
         {:ok, updated_row} <- put_row_cell(row, column, inline) do
      {:ok, Map.put(table, "rows", List.replace_at(table["rows"], row_index, updated_row))}
    else
      _ -> :error
    end
  end

  defp put_row_cell(row, index, inline) do
    with cells when is_list(cells) <- row_cells(row),
         cell when not is_nil(cell) <- Enum.at(cells, index),
         {:ok, updated_cell} <- put_cell_content(cell, inline) do
      {:ok, put_row_cells(row, List.replace_at(cells, index, updated_cell))}
    else
      _ -> :error
    end
  end

  defp put_cell_content(cell, inline) when is_list(cell), do: {:ok, inline}

  defp put_cell_content(%{"content" => _old} = cell, inline),
    do: {:ok, Map.put(cell, "content", inline)}

  defp put_cell_content(_cell, _inline), do: :error

  defp parse_action(action) when action in ~w(add-row add-column add-header remove-header),
    do: {:ok, {action, nil}}

  defp parse_action(action) when is_binary(action) do
    with [kind, encoded] <- String.split(action, ":", parts: 2),
         true <- kind in @indexed_actions,
         true <- canonical_index_string?(encoded),
         {index, ""} <- Integer.parse(encoded),
         true <- safe_index?(index) do
      {:ok, {kind, index}}
    else
      _ -> :error
    end
  end

  defp parse_action(_action), do: :error

  defp canonical_index_string?(encoded) do
    encoded != "" and byte_size(encoded) <= 16 and
      String.match?(encoded, ~r/^(0|[1-9][0-9]*)$/)
  end

  defp apply_parsed_action(table, projection, {"add-row", nil}) do
    width = projection.rows |> hd() |> length()
    {:ok, Map.update!(table, "rows", &(&1 ++ [List.duplicate([], width)]))}
  end

  defp apply_parsed_action(table, projection, {"remove-row", index}) do
    if length(projection.rows) > 1 and index < length(projection.rows),
      do: {:ok, Map.update!(table, "rows", &List.delete_at(&1, index))},
      else: :error
  end

  defp apply_parsed_action(table, projection, {"up-row", index}) do
    if index > 0 and index < length(projection.rows),
      do: {:ok, Map.update!(table, "rows", &swap(&1, index, index - 1))},
      else: :error
  end

  defp apply_parsed_action(table, projection, {"down-row", index}) do
    if index + 1 < length(projection.rows),
      do: {:ok, Map.update!(table, "rows", &swap(&1, index, index + 1))},
      else: :error
  end

  defp apply_parsed_action(table, projection, {"add-column", nil}) do
    {:ok, map_all_rows(table, projection, fn cells -> cells ++ [[]] end)}
  end

  defp apply_parsed_action(table, projection, {"remove-column", index}) do
    width = projection.rows |> hd() |> length()

    if width > 1 and index < width,
      do: {:ok, map_all_rows(table, projection, &List.delete_at(&1, index))},
      else: :error
  end

  defp apply_parsed_action(table, projection, {"left-column", index}) do
    width = projection.rows |> hd() |> length()

    if index > 0 and index < width,
      do: {:ok, map_all_rows(table, projection, &swap(&1, index, index - 1))},
      else: :error
  end

  defp apply_parsed_action(table, projection, {"right-column", index}) do
    width = projection.rows |> hd() |> length()

    if index + 1 < width,
      do: {:ok, map_all_rows(table, projection, &swap(&1, index, index + 1))},
      else: :error
  end

  defp apply_parsed_action(table, %{head: nil, rows: [first | _]}, {"add-header", nil}),
    do: {:ok, Map.put(table, "head", List.duplicate([], length(first)))}

  defp apply_parsed_action(table, %{head: head}, {"remove-header", nil}) when is_list(head),
    do: {:ok, Map.put(table, "head", [])}

  defp apply_parsed_action(_table, _projection, _action), do: :error

  defp map_all_rows(table, projection, fun) do
    rows = Enum.map(table["rows"], &map_row_cells(&1, fun))
    table = Map.put(table, "rows", rows)

    if is_list(projection.head),
      do: Map.put(table, "head", map_row_cells(table["head"], fun)),
      else: table
  end

  defp map_row_cells(row, fun), do: put_row_cells(row, fun.(row_cells(row)))

  defp row_cells(%{"cells" => cells}), do: cells
  defp row_cells(cells) when is_list(cells), do: cells
  defp row_cells(_row), do: nil

  defp put_row_cells(%{"cells" => _old} = row, cells), do: Map.put(row, "cells", cells)
  defp put_row_cells(_row, cells), do: cells

  defp swap(list, left, right) do
    left_value = Enum.at(list, left)
    right_value = Enum.at(list, right)

    list
    |> List.replace_at(left, right_value)
    |> List.replace_at(right, left_value)
  end

  defp safe_index?(index), do: is_integer(index) and index >= 0 and index <= @max_safe_integer

  defp valid_inline?(nodes) when is_list(nodes) do
    Enum.reduce_while(nodes, {:ok, nil}, fn node, {:ok, previous_signature} ->
      case inline_node_signature(node, -1) do
        {:ok, signature} when signature != previous_signature ->
          {:cont, {:ok, signature}}

        _ ->
          {:halt, :error}
      end
    end) != :error
  end

  defp valid_inline?(_nodes), do: false

  defp inline_node_signature(%{"type" => "text", "value" => value} = node, _rank)
       when is_binary(value) and value != "" do
    if exact_keys?(node, ~w(type value)), do: {:ok, []}, else: :error
  end

  defp inline_node_signature(%{"type" => "code", "value" => value} = node, rank)
       when is_binary(value) and value != "" do
    if inline_rank("code") > rank and exact_keys?(node, ~w(type value)),
      do: {:ok, [{"code"}]},
      else: :error
  end

  defp inline_node_signature(%{"type" => type, "children" => [child]} = node, rank)
       when type in ~w(strong em underline strikethrough) do
    node_rank = inline_rank(type)

    with true <- node_rank > rank,
         true <- exact_keys?(node, ~w(type children)),
         {:ok, signature} <- inline_node_signature(child, node_rank) do
      {:ok, [{type} | signature]}
    else
      _ -> :error
    end
  end

  defp inline_node_signature(
         %{"type" => "link", "href" => href, "children" => [child]} = node,
         rank
       )
       when is_binary(href) do
    with true <- inline_rank("link") > rank,
         true <- exact_keys?(node, ~w(type href children)),
         {:ok, signature} <- inline_node_signature(child, inline_rank("link")) do
      {:ok, [{"link", href} | signature]}
    else
      _ -> :error
    end
  end

  defp inline_node_signature(
         %{"type" => "wikilink", "target" => target, "children" => [child]} = node,
         rank
       )
       when is_binary(target) do
    with true <- inline_rank("wikilink") > rank,
         true <- subset_keys?(node, ~w(type target children alias docId)),
         true <- required_keys?(node, ~w(type target children)),
         true <- optional_non_nil?(node, "alias") and optional_non_nil?(node, "docId"),
         {:ok, signature} <- inline_node_signature(child, inline_rank("wikilink")) do
      attrs = {Map.get(node, "alias", :absent), Map.get(node, "docId", :absent)}
      {:ok, [{"wikilink", target, attrs} | signature]}
    else
      _ -> :error
    end
  end

  defp inline_node_signature(
         %{"type" => "blockref", "target" => target, "anchor" => anchor} = node,
         rank
       )
       when is_binary(target) and is_binary(anchor) do
    if inline_rank("blockref") > rank and exact_keys?(node, ~w(type target anchor)),
      do: {:ok, [{"blockref", target, anchor}]},
      else: :error
  end

  defp inline_node_signature(%{"type" => "tag", "name" => name} = node, rank)
       when is_binary(name) do
    if inline_rank("tag") > rank and exact_keys?(node, ~w(type name)),
      do: {:ok, [{"tag", name}]},
      else: :error
  end

  defp inline_node_signature(
         %{"type" => "valueref", "target" => target, "field" => field} = node,
         rank
       )
       when is_binary(target) and is_binary(field) do
    allowed = ~w(type target field as fallback label children)

    if inline_rank("valueref") > rank and subset_keys?(node, allowed) and
         required_keys?(node, ~w(type target field)) and
         Enum.all?(~w(as fallback label children), &optional_non_nil?(node, &1)) do
      attrs = Enum.map(~w(as fallback label children), &Map.get(node, &1, :absent))
      {:ok, [{"valueref", target, field, attrs}]}
    else
      :error
    end
  end

  defp inline_node_signature(_node, _rank), do: :error

  defp inline_rank("link"), do: 0
  defp inline_rank("wikilink"), do: 1
  defp inline_rank("strong"), do: 2
  defp inline_rank("em"), do: 3
  defp inline_rank("underline"), do: 4
  defp inline_rank("strikethrough"), do: 5
  defp inline_rank("code"), do: 6
  defp inline_rank("blockref"), do: 7
  defp inline_rank("tag"), do: 8
  defp inline_rank("valueref"), do: 9

  defp exact_keys?(map, keys), do: MapSet.new(Map.keys(map)) == MapSet.new(keys)

  defp subset_keys?(map, keys),
    do: MapSet.subset?(MapSet.new(Map.keys(map)), MapSet.new(keys))

  defp required_keys?(map, keys), do: Enum.all?(keys, &Map.has_key?(map, &1))
  defp optional_non_nil?(map, key), do: not Map.has_key?(map, key) or not is_nil(map[key])
end
