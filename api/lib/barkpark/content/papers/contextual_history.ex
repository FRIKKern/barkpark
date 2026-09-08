defmodule Barkpark.Content.Papers.ContextualHistory do
  @moduledoc """
  Pure, server-derived continuations for the narrow contextual Paper fields
  that do not yet participate in the canvas history stack.

  A continuation is not authority and is never accepted from a browser as an
  inverse patch. `capture/3` derives it only from authoritative pre-write and
  post-write block trees. `apply/2` then re-resolves the target in the current
  authoritative tree and changes only the recorded field when its exact state
  still matches the continuation guard.

  Phase one supports `figure.caption` and the singular Figure image child's
  `image.src`. Unsupported or ambiguous edits remain valid edits without a
  continuation. Values are exact JSON values; absent and present-with-null are
  distinct. Continuations are capped at 16 KiB encoded and never truncated.
  """

  alias Barkpark.PortableDoc.BlockIds

  @version 1
  @max_encoded_bytes 16 * 1024
  @continuation_keys ~w(action expect field replace target version)
  @target_keys ~w(id type)
  @allowed_fields MapSet.new([{"figure", "caption"}, {"image", "src"}])

  @type continuation :: %{required(String.t()) => term()}
  @type apply_error ::
          :invalid_history | :history_conflict | :block_not_found | :duplicate_id

  @doc """
  Derives one guarded undo continuation from authoritative block trees.

  Only a single one-field `patch-block` for an allowlisted contextual field is
  eligible. A no-op, unsupported operation, structural change, malformed tree,
  duplicate identity, or oversized value returns `{:ok, nil}`; it does not turn
  an otherwise accepted content edit into a failure.
  """
  @spec capture(term(), term(), term()) :: {:ok, nil | continuation()}
  def capture(before_blocks, after_blocks, ops) do
    with {:ok, id, field} <- eligible_op(ops),
         {:ok, before_target} <- unique_target(before_blocks, id),
         {:ok, after_target} <- unique_target(after_blocks, id),
         type when is_binary(type) <- Map.get(before_target, "type"),
         ^type <- Map.get(after_target, "type"),
         true <- allowed_field?(type, field),
         before_state <- field_state(before_target, field),
         after_state <- field_state(after_target, field),
         false <- before_state === after_state,
         {:ok, projected_after} <- replace_target_field(before_blocks, id, field, after_state),
         true <- projected_after === after_blocks,
         continuation <- continuation("undo", id, type, field, after_state, before_state),
         :ok <- validate(continuation) do
      {:ok, continuation}
    else
      _unsupported_or_ambiguous -> {:ok, nil}
    end
  end

  @doc """
  Strictly validates a server-internal continuation without reading a tree.

  This is the receipt-normalization boundary. It rejects unknown keys, unknown
  versions/actions/fields, malformed exact states, non-JSON values, no-op
  continuations, and values above the encoded-size cap.
  """
  @spec validate(term()) :: :ok | {:error, :invalid_history}
  def validate(continuation) when is_map(continuation) and not is_struct(continuation) do
    with true <- exact_keys?(continuation, @continuation_keys),
         %{
           "version" => @version,
           "action" => action,
           "target" => target,
           "field" => field,
           "expect" => expect,
           "replace" => replace
         } <- continuation,
         true <- action in ["undo", "redo"],
         true <- valid_target?(target),
         true <- allowed_field?(target["type"], field),
         true <- valid_state?(expect),
         true <- valid_state?(replace),
         false <- expect === replace,
         true <- encoded_within_cap?(continuation) do
      :ok
    else
      _invalid -> {:error, :invalid_history}
    end
  end

  def validate(_continuation), do: {:error, :invalid_history}

  @doc """
  Applies one guarded continuation and returns its exact opposite.

  Unrelated current fields and nodes are preserved. The target field must still
  equal `expect`; a newer edit therefore conflicts instead of being overwritten.
  Missing, duplicate, moved-with-type-change, or forged targets fail closed.
  """
  @spec apply(term(), term()) ::
          {:ok, [map()], continuation()} | {:error, apply_error()}
  def apply(blocks, continuation) do
    with :ok <- validate(continuation),
         %{
           "action" => action,
           "target" => %{"id" => id, "type" => type},
           "field" => field,
           "expect" => expect,
           "replace" => replace
         } <- continuation,
         {:ok, current} <- unique_target_for_apply(blocks, id),
         true <- Map.get(current, "type") === type || {:error, :history_conflict},
         true <- field_state(current, field) === expect || {:error, :history_conflict},
         {:ok, next_blocks} <- replace_target_field(blocks, id, field, replace),
         next <- continuation(toggle(action), id, type, field, replace, expect),
         :ok <- validate(next) do
      {:ok, next_blocks, next}
    else
      {:error, reason}
      when reason in [:invalid_history, :history_conflict, :block_not_found, :duplicate_id] ->
        {:error, reason}

      _invalid ->
        {:error, :invalid_history}
    end
  end

  defp eligible_op([
         %{"op" => "patch-block", "id" => id, "patch" => patch}
       ])
       when is_binary(id) and id != "" and is_map(patch) and map_size(patch) == 1 do
    case Map.to_list(patch) do
      [{field, _submitted_value}] when is_binary(field) -> {:ok, id, field}
      _invalid -> {:error, :unsupported}
    end
  end

  defp eligible_op(_ops), do: {:error, :unsupported}

  defp continuation(action, id, type, field, expect, replace) do
    %{
      "version" => @version,
      "action" => action,
      "target" => %{"id" => id, "type" => type},
      "field" => field,
      "expect" => expect,
      "replace" => replace
    }
  end

  defp toggle("undo"), do: "redo"
  defp toggle("redo"), do: "undo"

  defp valid_target?(target) when is_map(target) and not is_struct(target) do
    exact_keys?(target, @target_keys) and nonblank_binary?(target["id"]) and
      nonblank_binary?(target["type"])
  end

  defp valid_target?(_target), do: false

  defp allowed_field?(type, field), do: MapSet.member?(@allowed_fields, {type, field})

  defp valid_state?(%{"present" => false} = state), do: exact_keys?(state, ["present"])

  defp valid_state?(%{"present" => true, "value" => value} = state),
    do: exact_keys?(state, ["present", "value"]) and json_value?(value)

  defp valid_state?(_state), do: false

  defp field_state(block, field) do
    if Map.has_key?(block, field) do
      %{"present" => true, "value" => Map.fetch!(block, field)}
    else
      %{"present" => false}
    end
  end

  defp put_field_state(block, field, %{"present" => false}), do: Map.delete(block, field)

  defp put_field_state(block, field, %{"present" => true, "value" => value}),
    do: Map.put(block, field, value)

  defp exact_keys?(map, expected) when is_map(map),
    do: Enum.sort(Map.keys(map)) == Enum.sort(expected)

  defp nonblank_binary?(value), do: is_binary(value) and value != ""

  defp encoded_within_cap?(continuation) do
    case Jason.encode(continuation) do
      {:ok, encoded} -> byte_size(encoded) <= @max_encoded_bytes
      {:error, _reason} -> false
    end
  rescue
    _error -> false
  end

  defp json_value?(nil), do: true
  defp json_value?(value) when is_boolean(value) or is_binary(value) or is_number(value), do: true
  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json_value?(item) end)

  defp json_value?(_value), do: false

  defp unique_target(blocks, id) do
    case inspect_tree(blocks, id) do
      {:ok, [target]} -> {:ok, target}
      _missing_duplicate_or_malformed -> {:error, :unsupported}
    end
  end

  defp unique_target_for_apply(blocks, id) do
    case inspect_tree(blocks, id) do
      {:ok, [target]} -> {:ok, target}
      {:ok, []} -> {:error, :block_not_found}
      {:ok, _duplicates} -> {:error, :duplicate_id}
      {:error, :duplicate_id} -> {:error, :duplicate_id}
      {:error, :invalid_tree} -> {:error, :invalid_history}
    end
  end

  defp inspect_tree(blocks, id) when is_list(blocks) and is_binary(id) do
    with {:ok, projected} <- BlockIds.project_block_ids_safely(blocks),
         true <- projected === blocks || {:error, :invalid_tree},
         {:ok, visible_blocks} <- collect_visible_blocks(blocks) do
      {:ok, Enum.filter(visible_blocks, &(Map.get(&1, "id") === id))}
    else
      {:error, {:duplicate_id, _id}} -> {:error, :duplicate_id}
      {:error, :invalid_tree} -> {:error, :invalid_tree}
      _invalid -> {:error, :invalid_tree}
    end
  end

  defp inspect_tree(_blocks, _id), do: {:error, :invalid_tree}

  defp collect_visible_blocks(blocks) when is_list(blocks) do
    Enum.reduce_while(blocks, {:ok, []}, fn
      block, {:ok, acc} when is_map(block) and not is_struct(block) ->
        if nonblank_binary?(Map.get(block, "id")) and
             nonblank_binary?(Map.get(block, "type")) do
          case collect_visible_child_blocks(block) do
            {:ok, nested} -> {:cont, {:ok, [block | nested] ++ acc}}
            {:error, :invalid_tree} = error -> {:halt, error}
          end
        else
          {:halt, {:error, :invalid_tree}}
        end

      _malformed, _acc ->
        {:halt, {:error, :invalid_tree}}
    end)
  end

  defp collect_visible_child_blocks(block) do
    block
    |> visible_child_lists()
    |> Enum.reduce_while({:ok, []}, fn children, {:ok, acc} ->
      case collect_visible_blocks(children) do
        {:ok, nested} -> {:cont, {:ok, nested ++ acc}}
        {:error, :invalid_tree} = error -> {:halt, error}
      end
    end)
  end

  defp replace_target_field(blocks, id, field, state) do
    case transform_blocks(blocks, id, &put_field_state(&1, field, state)) do
      {next_blocks, 1} -> {:ok, next_blocks}
      _missing_or_duplicate -> {:error, :invalid_history}
    end
  end

  defp transform_blocks(blocks, id, fun) do
    Enum.map_reduce(blocks, 0, fn block, count ->
      if Map.get(block, "id") === id do
        {fun.(block), count + 1}
      else
        {next_block, nested_count} = transform_block_children(block, id, fun)
        {next_block, count + nested_count}
      end
    end)
  end

  defp transform_block_children(%{"type" => "section", "blocks" => children} = block, id, fun)
       when is_list(children),
       do: transform_child_list(block, "blocks", children, id, fun)

  defp transform_block_children(%{"type" => "expandable"} = block, id, fun),
    do: transform_visible_alias(block, id, fun)

  defp transform_block_children(%{"type" => "terminal", "children" => children} = block, id, fun)
       when is_list(children) do
    if Map.has_key?(block, "blocks"),
      do: {block, 0},
      else: transform_child_list(block, "children", children, id, fun)
  end

  defp transform_block_children(%{"type" => "steps", "steps" => rows} = block, id, fun)
       when is_list(rows) do
    {next_rows, count} =
      Enum.map_reduce(rows, 0, fn
        row, count when is_map(row) ->
          {next_row, nested_count} = transform_visible_alias(row, id, fun)
          {next_row, count + nested_count}

        opaque, count ->
          {opaque, count}
      end)

    {Map.put(block, "steps", next_rows), count}
  end

  defp transform_block_children(%{"type" => "tabs", "tabs" => rows} = block, id, fun)
       when is_list(rows) do
    {next_rows, count} =
      Enum.map_reduce(rows, 0, fn
        %{"blocks" => children} = row, count when is_list(children) ->
          {next_children, nested_count} = transform_blocks(children, id, fun)
          {Map.put(row, "blocks", next_children), count + nested_count}

        opaque, count ->
          {opaque, count}
      end)

    {Map.put(block, "tabs", next_rows), count}
  end

  defp transform_block_children(%{"type" => "columns", "columns" => columns} = block, id, fun)
       when is_list(columns) do
    {next_columns, count} =
      Enum.map_reduce(columns, 0, fn
        children, count when is_list(children) ->
          {next_children, nested_count} = transform_blocks(children, id, fun)
          {next_children, count + nested_count}

        opaque, count ->
          {opaque, count}
      end)

    {Map.put(block, "columns", next_columns), count}
  end

  defp transform_block_children(%{"type" => "figure", "child" => child} = block, id, fun)
       when is_map(child) do
    {[next_child], count} = transform_blocks([child], id, fun)
    {Map.put(block, "child", next_child), count}
  end

  defp transform_block_children(block, _id, _fun), do: {block, 0}

  defp transform_child_list(block, key, children, id, fun) do
    {next_children, count} = transform_blocks(children, id, fun)
    {Map.put(block, key, next_children), count}
  end

  defp transform_visible_alias(block, id, fun) do
    case visible_alias(block) do
      {key, children} -> transform_child_list(block, key, children, id, fun)
      nil -> {block, 0}
    end
  end

  defp visible_child_lists(%{"type" => "section", "blocks" => children})
       when is_list(children),
       do: [children]

  defp visible_child_lists(%{"type" => "expandable"} = block),
    do: alias_child_lists(block)

  defp visible_child_lists(%{"type" => "terminal", "children" => children} = block)
       when is_list(children),
       do: if(Map.has_key?(block, "blocks"), do: [], else: [children])

  defp visible_child_lists(%{"type" => "steps", "steps" => rows}) when is_list(rows) do
    Enum.flat_map(rows, fn
      row when is_map(row) -> alias_child_lists(row)
      _opaque -> []
    end)
  end

  defp visible_child_lists(%{"type" => "tabs", "tabs" => rows}) when is_list(rows) do
    Enum.flat_map(rows, fn
      %{"blocks" => children} when is_list(children) -> [children]
      _opaque -> []
    end)
  end

  defp visible_child_lists(%{"type" => "columns", "columns" => columns})
       when is_list(columns),
       do: Enum.filter(columns, &is_list/1)

  defp visible_child_lists(%{"type" => "figure", "child" => child}) when is_map(child),
    do: [[child]]

  defp visible_child_lists(_block), do: []

  defp alias_child_lists(block) do
    case visible_alias(block) do
      {_key, children} -> [children]
      nil -> []
    end
  end

  defp visible_alias(container) do
    case Map.get(container, "children") do
      children when children not in [nil, false] ->
        if is_list(children), do: {"children", children}

      _absent ->
        case Map.get(container, "blocks") do
          blocks when is_list(blocks) -> {"blocks", blocks}
          _other -> nil
        end
    end
  end
end
