defmodule Barkpark.Content.Papers.CanvasRunContext do
  @moduledoc false

  @type context ::
          %{container_id: String.t(), container_run_ids: [String.t()]}
          | %{
              container_kind: String.t(),
              container_id: String.t(),
              container_run_ids: [String.t()]
            }
          | %{
              container_kind: String.t(),
              container_id: String.t(),
              container_column_index: non_neg_integer(),
              container_run_ids: [String.t()]
            }
          | %{
              container_kind: String.t(),
              container_id: String.t(),
              container_row_id: String.t(),
              container_run_ids: [String.t()]
            }

  @spec normalize(nil | map()) :: {:ok, nil | context()} | {:error, atom()}
  def normalize(nil), do: {:ok, nil}

  def normalize(context) when is_map(context) do
    with {:ok, container_id, _id_present?} <- context_field(context, :container_id),
         {:ok, run_ids, _run_present?} <- context_field(context, :container_run_ids),
         {:ok, kind, kind_present?} <- context_field(context, :container_kind),
         {:ok, row_id, row_present?} <- context_field(context, :container_row_id),
         {:ok, column_index, column_present?} <-
           context_field(context, :container_column_index),
         true <- valid_base?(container_id, run_ids) do
      cond do
        not kind_present? and not row_present? and not column_present? ->
          {:ok, %{container_id: container_id, container_run_ids: run_ids}}

        kind in ["steps", "tabs"] and kind_present? and row_present? and
          not column_present? and nonblank?(row_id) ->
          {:ok,
           %{
             container_kind: kind,
             container_id: container_id,
             container_row_id: row_id,
             container_run_ids: run_ids
           }}

        kind == "figure" and kind_present? and not row_present? and not column_present? and
            length(run_ids) == 1 ->
          {:ok,
           %{
             container_kind: kind,
             container_id: container_id,
             container_run_ids: run_ids
           }}

        kind == "section" and kind_present? and not row_present? and not column_present? ->
          {:ok,
           %{
             container_kind: kind,
             container_id: container_id,
             container_run_ids: run_ids
           }}

        kind == "columns" and kind_present? and not row_present? and column_present? and
            valid_column_index?(column_index) ->
          {:ok,
           %{
             container_kind: kind,
             container_id: container_id,
             container_column_index: column_index,
             container_run_ids: run_ids
           }}

        true ->
          {:error, :invalid_canvas_run_context}
      end
    else
      _invalid -> {:error, :invalid_canvas_run_context}
    end
  end

  def normalize(_context), do: {:error, :invalid_canvas_run_context}

  @doc """
  Resolves one container's exact baseline child segment, lets `fun` transform
  only that segment, and splices the result back through the same visible alias.

  The helper is pure. It deliberately knows nothing about canvas eligibility or
  run ordinals: the mounted host supplies the ordered ids from the confirmed run.
  """
  @spec map_run([map()], context(), ([map()] -> {:ok, [map()], term()} | {:error, term()})) ::
          {:ok, [map()], term()} | {:error, term()}
  def map_run(blocks, context, fun) when is_list(blocks) and is_function(fun, 1) do
    with {:ok, normalized} <- normalize(context),
         true <- is_map(normalized) || {:error, :invalid_canvas_run_context} do
      map_normalized_run(blocks, normalized, fun)
    end
  end

  def map_run(_blocks, _context, _fun), do: {:error, :invalid_canvas_run_context}

  defp map_normalized_run(blocks, %{container_kind: "figure"} = context, fun) do
    before_counts = id_occurrences(blocks)

    with {:ok, match} <- unique_figure(blocks, context),
         result <- fun.([match.child]) do
      case result do
        {:ok, [next_child], value} when is_map(next_child) ->
          next_blocks = put_path(blocks, match.path ++ ["child"], next_child)

          with :ok <- reject_increased_duplicate_ids(before_counts, id_occurrences(next_blocks)) do
            {:ok, next_blocks, value}
          end

        {:ok, _next_run, _value} ->
          {:error, :canvas_run_figure_cardinality}

        {:error, _reason} = error ->
          error

        _other ->
          {:error, :invalid_canvas_run_result}
      end
    end
  end

  defp map_normalized_run(blocks, %{container_run_ids: run_ids} = context, fun) do
    before_counts = id_occurrences(blocks)

    with {:ok, match} <- unique_container_run(blocks, context),
         {:ok, start} <- unique_contiguous_start(match.children, run_ids),
         run = Enum.slice(match.children, start, length(run_ids)),
         {:ok, next_run, result} <- fun.(run),
         true <- is_list(next_run) || {:error, :invalid_canvas_run_result},
         next_children <-
           Enum.take(match.children, start) ++
             next_run ++ Enum.drop(match.children, start + length(run_ids)),
         next_blocks <- put_children(blocks, match.path, match.alias, next_children),
         :ok <- reject_increased_duplicate_ids(before_counts, id_occurrences(next_blocks)) do
      {:ok, next_blocks, result}
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_canvas_run_result}
    end
  end

  defp unique_container_run(
         blocks,
         %{container_kind: "steps", container_id: container_id, container_row_id: row_id}
       ),
       do: unique_steps_row(blocks, container_id, row_id)

  defp unique_container_run(
         blocks,
         %{container_kind: "tabs", container_id: container_id, container_row_id: row_id}
       ),
       do: unique_tabs_row(blocks, container_id, row_id)

  defp unique_container_run(
         blocks,
         %{container_kind: "section", container_id: container_id}
       ),
       do: unique_section(blocks, container_id)

  defp unique_container_run(
         blocks,
         %{
           container_kind: "columns",
           container_id: container_id,
           container_column_index: column_index
         }
       ),
       do: unique_column(blocks, container_id, column_index)

  defp unique_container_run(blocks, %{container_id: container_id} = context)
       when not is_map_key(context, :container_kind),
       do: unique_expandable(blocks, container_id)

  defp unique_figure(
         blocks,
         %{container_id: container_id, container_run_ids: [run_id]}
       ),
       do: unique_figure(blocks, container_id, run_id)

  defp unique_figure(blocks, container_id, run_id) do
    case find_containers(blocks, "figure", container_id, []) do
      [%{child: child} = match] when is_map(child) ->
        if block_id(child) == run_id,
          do: {:ok, match},
          else: {:error, :canvas_run_not_found}

      [_one] ->
        {:error, :canvas_run_figure_cardinality}

      [] ->
        {:error, :canvas_run_container_not_found}

      [_first | _rest] ->
        {:error, :canvas_run_container_ambiguous}
    end
  end

  defp unique_expandable(blocks, container_id) do
    case find_containers(blocks, "expandable", container_id, []) do
      [%{alias: alias} = match] when alias in ["children", "blocks"] -> {:ok, match}
      [_one] -> {:error, :canvas_run_container_children_invalid}
      [] -> {:error, :canvas_run_container_not_found}
      [_first | _rest] -> {:error, :canvas_run_container_ambiguous}
    end
  end

  defp unique_section(blocks, container_id) do
    case find_containers(blocks, "section", container_id, []) do
      [%{alias: "blocks"} = match] -> {:ok, match}
      [_one] -> {:error, :canvas_run_container_children_invalid}
      [] -> {:error, :canvas_run_container_not_found}
      [_first | _rest] -> {:error, :canvas_run_container_ambiguous}
    end
  end

  defp unique_column(blocks, container_id, column_index) do
    case find_containers(blocks, "columns", container_id, []) do
      [%{columns: columns, path: path}] when is_list(columns) ->
        case Enum.fetch(columns, column_index) do
          {:ok, children} when is_list(children) ->
            {:ok,
             %{
               path: path ++ ["columns"],
               alias: {:column, column_index},
               children: children
             }}

          {:ok, _invalid} ->
            {:error, :canvas_run_container_children_invalid}

          :error ->
            {:error, :canvas_run_container_column_not_found}
        end

      [_one] ->
        {:error, :canvas_run_container_children_invalid}

      [] ->
        {:error, :canvas_run_container_not_found}

      [_first | _rest] ->
        {:error, :canvas_run_container_ambiguous}
    end
  end

  defp unique_steps_row(blocks, container_id, row_id) do
    case find_containers(blocks, "steps", container_id, []) do
      [%{rows: rows, path: path}] when is_list(rows) ->
        matches =
          rows
          |> Enum.with_index()
          |> Enum.filter(fn
            {row, _index} when is_map(row) -> Map.get(row, "id") == row_id
            {_row, _index} -> false
          end)

        case matches do
          [{row, index}] ->
            {alias_key, children} = effective_children(row)

            if alias_key in ["children", "blocks"] do
              {:ok,
               %{
                 path: path ++ ["steps", {:row, index, row_id}],
                 alias: alias_key,
                 children: children
               }}
            else
              {:error, :canvas_run_container_children_invalid}
            end

          [] ->
            {:error, :canvas_run_container_row_not_found}

          [_first | _rest] ->
            {:error, :canvas_run_container_row_ambiguous}
        end

      [_one] ->
        {:error, :canvas_run_container_children_invalid}

      [] ->
        {:error, :canvas_run_container_not_found}

      [_first | _rest] ->
        {:error, :canvas_run_container_ambiguous}
    end
  end

  defp unique_tabs_row(blocks, container_id, row_id) do
    case find_containers(blocks, "tabs", container_id, []) do
      [%{rows: rows, path: path}] when is_list(rows) ->
        matches =
          rows
          |> Enum.with_index()
          |> Enum.filter(fn
            {row, _index} when is_map(row) -> Map.get(row, "id") == row_id
            {_row, _index} -> false
          end)

        case matches do
          [{%{"blocks" => children}, index}] when is_list(children) ->
            {:ok,
             %{
               path: path ++ ["tabs", {:row, index, row_id}],
               alias: "blocks",
               children: children
             }}

          [{_row, _index}] ->
            {:error, :canvas_run_container_children_invalid}

          [] ->
            {:error, :canvas_run_container_row_not_found}

          [_first | _rest] ->
            {:error, :canvas_run_container_row_ambiguous}
        end

      [_one] ->
        {:error, :canvas_run_container_children_invalid}

      [] ->
        {:error, :canvas_run_container_not_found}

      [_first | _rest] ->
        {:error, :canvas_run_container_ambiguous}
    end
  end

  defp find_containers(blocks, type, container_id, path) do
    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {block, index} when is_map(block) ->
        current_path = path ++ [index]

        own =
          if Map.get(block, "type") == type and Map.get(block, "id") == container_id do
            [container_match(block, current_path)]
          else
            []
          end

        nested =
          block
          |> recursive_child_entries()
          |> Enum.flat_map(fn {suffix, children} ->
            find_containers(children, type, container_id, current_path ++ suffix)
          end)

        own ++ nested

      {_other, _index} ->
        []
    end)
  end

  defp container_match(%{"type" => "steps"} = block, path),
    do: %{path: path, rows: Map.get(block, "steps")}

  defp container_match(%{"type" => "tabs"} = block, path),
    do: %{path: path, rows: Map.get(block, "tabs")}

  defp container_match(%{"type" => "figure"} = block, path),
    do: %{path: path, child: Map.get(block, "child")}

  defp container_match(%{"type" => "section"} = block, path) do
    case Map.get(block, "blocks") do
      blocks when is_list(blocks) -> %{path: path, alias: "blocks", children: blocks}
      _invalid -> %{path: path, alias: nil, children: []}
    end
  end

  defp container_match(%{"type" => "columns"} = block, path),
    do: %{path: path, columns: Map.get(block, "columns")}

  defp container_match(block, path) do
    {alias_key, children} = effective_children(block)
    %{path: path, alias: alias_key, children: children}
  end

  defp effective_children(container) do
    case Map.get(container, "children") do
      children when children not in [nil, false] ->
        if is_list(children), do: {"children", children}, else: {nil, []}

      _absent ->
        case Map.get(container, "blocks") do
          blocks when is_list(blocks) -> {"blocks", blocks}
          _other -> {nil, []}
        end
    end
  end

  defp recursive_child_entries(%{"type" => "expandable"} = block) do
    case effective_children(block) do
      {key, children} when key in ["children", "blocks"] -> [{[key], children}]
      _invalid -> []
    end
  end

  defp recursive_child_entries(%{"type" => "section", "blocks" => blocks})
       when is_list(blocks),
       do: [{["blocks"], blocks}]

  defp recursive_child_entries(%{"type" => "columns", "columns" => columns})
       when is_list(columns) do
    columns
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {children, index} when is_list(children) -> [{["columns", {:column, index}], children}]
      {_opaque, _index} -> []
    end)
  end

  defp recursive_child_entries(%{"type" => "steps", "steps" => rows}) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {row, index} when is_map(row) ->
        case effective_children(row) do
          {key, children} when key in ["children", "blocks"] ->
            [{["steps", {:row, index, Map.get(row, "id")}, key], children}]

          _invalid ->
            []
        end

      {_row, _index} ->
        []
    end)
  end

  defp recursive_child_entries(%{"type" => "tabs", "tabs" => rows}) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"blocks" => children} = row, index} when is_list(children) ->
        [{["tabs", {:row, index, Map.get(row, "id")}, "blocks"], children}]

      {_row, _index} ->
        []
    end)
  end

  defp recursive_child_entries(%{"type" => "figure", "child" => child}) when is_map(child),
    do: [{[{:singular, "child"}], [child]}]

  defp recursive_child_entries(_block), do: []

  defp put_children(blocks, path, alias_key, children) do
    put_path(blocks, path ++ [alias_key], children)
  end

  defp put_path(_current, [], replacement), do: replacement

  defp put_path(current, [index | rest], replacement)
       when is_list(current) and is_integer(index) do
    List.update_at(current, index, &put_path(&1, rest, replacement))
  end

  defp put_path(current, [{:row, index, row_id} | rest], replacement)
       when is_list(current) do
    List.update_at(current, index, fn row ->
      if is_map(row) and Map.get(row, "id") == row_id do
        put_path(row, rest, replacement)
      else
        row
      end
    end)
  end

  defp put_path(current, [{:column, index} | rest], replacement)
       when is_list(current) and is_integer(index) do
    List.update_at(current, index, &put_path(&1, rest, replacement))
  end

  defp put_path(current, [{:singular, key} | rest], replacement)
       when is_map(current) and is_binary(key) do
    case Map.fetch(current, key) do
      {:ok, child} when is_map(child) ->
        case put_path([child], rest, replacement) do
          [next_child] when is_map(next_child) -> Map.put(current, key, next_child)
          _invalid -> current
        end

      _invalid ->
        current
    end
  end

  defp put_path(current, [key | rest], replacement) when is_map(current) and is_binary(key) do
    case Map.fetch(current, key) do
      {:ok, child} -> Map.put(current, key, put_path(child, rest, replacement))
      :error -> current
    end
  end

  defp unique_contiguous_start(children, run_ids) do
    wanted = length(run_ids)

    starts =
      if wanted <= length(children) do
        0..(length(children) - wanted)
        |> Enum.filter(fn start ->
          children
          |> Enum.slice(start, wanted)
          |> Enum.map(&block_id/1)
          |> Kernel.==(run_ids)
        end)
      else
        []
      end

    case starts do
      [start] -> {:ok, start}
      [] -> {:error, :canvas_run_not_found}
      [_first | _rest] -> {:error, :canvas_run_ambiguous}
    end
  end

  defp id_occurrences(blocks) do
    Enum.reduce(blocks, %{}, fn block, counts ->
      identities =
        case block do
          %{"type" => "steps", "steps" => rows} when is_list(rows) -> [block | rows]
          %{"type" => "tabs", "tabs" => rows} when is_list(rows) -> [block | rows]
          _ -> [block]
        end

      counts =
        Enum.reduce(identities, counts, fn value, acc ->
          case block_id(value) do
            id when is_binary(id) and id != "" -> Map.update(acc, id, 1, &(&1 + 1))
            _ -> acc
          end
        end)

      block
      |> all_child_lists()
      |> Enum.reduce(counts, fn children, acc ->
        Map.merge(acc, id_occurrences(children), fn _, a, b -> a + b end)
      end)
    end)
  end

  defp all_child_lists(%{"type" => "expandable"} = block) do
    [Map.get(block, "children"), Map.get(block, "blocks")]
    |> Enum.filter(&is_list/1)
  end

  defp all_child_lists(%{"type" => "section", "blocks" => blocks}) when is_list(blocks),
    do: [blocks]

  defp all_child_lists(%{"type" => "columns", "columns" => columns}) when is_list(columns),
    do: Enum.filter(columns, &is_list/1)

  defp all_child_lists(%{"type" => "steps", "steps" => rows}) when is_list(rows) do
    Enum.flat_map(rows, fn
      row when is_map(row) ->
        [Map.get(row, "children"), Map.get(row, "blocks")]
        |> Enum.filter(&is_list/1)

      _row ->
        []
    end)
  end

  defp all_child_lists(%{"type" => "tabs", "tabs" => rows}) when is_list(rows) do
    Enum.flat_map(rows, fn
      %{"blocks" => children} when is_list(children) -> [children]
      _row -> []
    end)
  end

  defp all_child_lists(%{"type" => "figure", "child" => child}) when is_map(child),
    do: [[child]]

  defp all_child_lists(_block), do: []

  defp reject_increased_duplicate_ids(before_counts, after_counts) do
    if Enum.any?(after_counts, fn {id, count} ->
         count > 1 and count > Map.get(before_counts, id, 0)
       end) do
      {:error, :canvas_run_id_collision}
    else
      :ok
    end
  end

  defp block_id(block) when is_map(block), do: Map.get(block, "id")
  defp block_id(_block), do: nil

  defp valid_base?(container_id, run_ids) do
    nonblank?(container_id) and is_list(run_ids) and run_ids != [] and
      Enum.all?(run_ids, &nonblank?/1) and Enum.uniq(run_ids) == run_ids
  end

  defp context_field(context, key) do
    atom_value = Map.fetch(context, key)
    string_value = Map.fetch(context, Atom.to_string(key))

    case {atom_value, string_value} do
      {:error, :error} -> {:ok, nil, false}
      {{:ok, value}, :error} -> {:ok, value, true}
      {:error, {:ok, value}} -> {:ok, value, true}
      {{:ok, value}, {:ok, value}} -> {:ok, value, true}
      {{:ok, _atom}, {:ok, _string}} -> {:error, :ambiguous}
    end
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_column_index?(value),
    do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991
end
