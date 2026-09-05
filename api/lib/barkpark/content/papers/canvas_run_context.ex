defmodule Barkpark.Content.Papers.CanvasRunContext do
  @moduledoc false

  @type context :: %{
          container_id: String.t(),
          container_run_ids: [String.t()]
        }

  @spec normalize(nil | map()) :: {:ok, nil | context()} | {:error, atom()}
  def normalize(nil), do: {:ok, nil}

  def normalize(context) when is_map(context) do
    container_id = Map.get(context, :container_id) || Map.get(context, "container_id")
    run_ids = Map.get(context, :container_run_ids) || Map.get(context, "container_run_ids")

    if nonblank?(container_id) and is_list(run_ids) and run_ids != [] and
         Enum.all?(run_ids, &nonblank?/1) and Enum.uniq(run_ids) == run_ids do
      {:ok, %{container_id: container_id, container_run_ids: run_ids}}
    else
      {:error, :invalid_canvas_run_context}
    end
  end

  def normalize(_context), do: {:error, :invalid_canvas_run_context}

  @doc """
  Resolves one expandable's exact baseline child segment, lets `fun` transform
  only that segment, and splices the result back through the same visible alias.

  The helper is pure. It deliberately knows nothing about canvas eligibility or
  run ordinals: the mounted host supplies the ordered ids from the confirmed run.
  """
  @spec map_run([map()], context(), ([map()] -> {:ok, [map()], term()} | {:error, term()})) ::
          {:ok, [map()], term()} | {:error, term()}
  def map_run(blocks, %{container_id: container_id, container_run_ids: run_ids}, fun)
      when is_list(blocks) and is_function(fun, 1) do
    before_counts = id_occurrences(blocks)

    with {:ok, match} <- unique_expandable(blocks, container_id),
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

  def map_run(_blocks, _context, _fun), do: {:error, :invalid_canvas_run_context}

  defp unique_expandable(blocks, container_id) do
    case find_expandables(blocks, container_id, []) do
      [%{alias: alias} = match] when alias in ["children", "blocks"] -> {:ok, match}
      [_one] -> {:error, :canvas_run_container_children_invalid}
      [] -> {:error, :canvas_run_container_not_found}
      [_first | _rest] -> {:error, :canvas_run_container_ambiguous}
    end
  end

  defp find_expandables(blocks, container_id, path) do
    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {block, index} when is_map(block) ->
        current_path = path ++ [index]

        own =
          if Map.get(block, "type") == "expandable" and Map.get(block, "id") == container_id do
            {alias_key, children} = effective_children(block)
            [%{path: current_path, alias: alias_key, children: children}]
          else
            []
          end

        nested =
          case recursive_children(block) do
            {key, children} -> find_expandables(children, container_id, current_path ++ [key])
            nil -> []
          end

        own ++ nested

      {_other, _index} ->
        []
    end)
  end

  defp effective_children(%{"children" => children}) when is_list(children),
    do: {"children", children}

  defp effective_children(%{"blocks" => blocks}) when is_list(blocks), do: {"blocks", blocks}
  defp effective_children(_block), do: {nil, []}

  defp recursive_children(%{"type" => "expandable"} = block), do: child_entry(block)

  defp recursive_children(%{"type" => "section", "blocks" => blocks}) when is_list(blocks),
    do: {"blocks", blocks}

  defp recursive_children(_block), do: nil

  defp child_entry(block) do
    case effective_children(block) do
      {key, children} when key in ["children", "blocks"] -> {key, children}
      _ -> nil
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

  defp put_children(blocks, [index], alias_key, children) do
    List.update_at(blocks, index, &Map.put(&1, alias_key, children))
  end

  defp put_children(blocks, [index, key | rest], alias_key, children) do
    List.update_at(blocks, index, fn block ->
      Map.update!(block, key, &put_children(&1, rest, alias_key, children))
    end)
  end

  defp id_occurrences(blocks) do
    Enum.reduce(blocks, %{}, fn block, counts ->
      counts =
        case block_id(block) do
          id when is_binary(id) and id != "" -> Map.update(counts, id, 1, &(&1 + 1))
          _ -> counts
        end

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

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
