defmodule Barkpark.Content.Papers.ContextualHistory do
  @moduledoc """
  Pure, server-derived continuations for the narrow contextual Paper fields
  that do not yet participate in the canvas history stack.

  A continuation is not authority and is never accepted from a browser as an
  inverse patch. `capture/3` derives it only from authoritative pre-write and
  post-write block trees. `apply/2` then re-resolves the target in the current
  authoritative tree and changes only the recorded field when its exact state
  still matches the continuation guard.

  Supported fields are `figure.caption`, `image.src`, `paper-links.title`, and
  `paper-links.description`, including singular Figure image children.
  A private version-2 continuation additionally supports one authored
  `paper-links` reference title or description. It binds the reference's exact
  index, raw slug, and non-copy metadata without storing the surrounding refs.
  A private version-3 continuation supports only the label of an existing
  singleton canonical Card action without storing the surrounding slots.
  A private version-4 continuation supports only the source of an existing
  singleton canonical Card media element. It binds the media element's exact
  absent, null, or image type without storing its other fields.
  A private version-5 continuation supports only the text of an existing
  singleton canonical Card title heading. It binds the title's exact heading
  type and absent, null, or empty content state without storing its other
  fields.
  Unsupported or ambiguous edits remain valid edits without a continuation.
  Values are exact JSON values; absent and present-with-null are distinct.
  Continuations are capped at 16 KiB encoded and never truncated.
  """

  alias Barkpark.PortableDoc.BlockIds

  @version 1
  @reference_version 2
  @card_action_version 3
  @card_media_version 4
  @card_title_version 5
  @max_encoded_bytes 16 * 1024
  @continuation_keys ~w(action expect field replace target version)
  @target_keys ~w(id type)
  @reference_continuation_keys ~w(action expect field identity replace target version)
  @card_media_identity_keys ~w(type)
  @card_title_identity_keys ~w(content type)
  @reference_target_keys ~w(id ref_index ref_slug type)
  @reference_fields ~w(title description)
  @allowed_fields MapSet.new([
                    {"figure", "caption"},
                    {"image", "src"},
                    {"paper-links", "title"},
                    {"paper-links", "description"}
                  ])

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
    case capture_reference_copy(before_blocks, after_blocks, ops) do
      {:ok, %{} = continuation} ->
        {:ok, continuation}

      {:ok, nil} ->
        case capture_card_action_label(before_blocks, after_blocks, ops) do
          {:ok, %{} = continuation} ->
            {:ok, continuation}

          {:ok, nil} ->
            case capture_card_media_src(before_blocks, after_blocks, ops) do
              {:ok, %{} = continuation} ->
                {:ok, continuation}

              {:ok, nil} ->
                case capture_card_title_text(before_blocks, after_blocks, ops) do
                  {:ok, %{} = continuation} -> {:ok, continuation}
                  {:ok, nil} -> capture_block_field(before_blocks, after_blocks, ops)
                end
            end
        end
    end
  end

  defp capture_block_field(before_blocks, after_blocks, ops) do
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
  def validate(%{"version" => @version} = continuation)
      when is_map(continuation) and not is_struct(continuation) do
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

  def validate(%{"version" => @reference_version} = continuation)
      when is_map(continuation) and not is_struct(continuation) do
    with true <- exact_keys?(continuation, @reference_continuation_keys),
         %{
           "action" => action,
           "target" => target,
           "field" => field,
           "identity" => identity,
           "expect" => expect,
           "replace" => replace
         } <- continuation,
         true <- action in ["undo", "redo"],
         true <- field in @reference_fields,
         true <- valid_reference_target?(target),
         true <- valid_reference_identity?(identity, target["ref_slug"]),
         true <- valid_scalar_state?(expect),
         true <- valid_scalar_state?(replace),
         false <- expect === replace,
         true <- encoded_within_cap?(continuation) do
      :ok
    else
      _invalid -> {:error, :invalid_history}
    end
  end

  def validate(%{"version" => @card_action_version} = continuation)
      when is_map(continuation) and not is_struct(continuation) do
    with true <- exact_keys?(continuation, @continuation_keys),
         %{
           "action" => action,
           "target" => target,
           "field" => "action.label",
           "expect" => expect,
           "replace" => replace
         } <- continuation,
         true <- action in ["undo", "redo"],
         true <- valid_card_action_target?(target),
         true <- valid_card_action_state?(expect),
         true <- valid_card_action_state?(replace),
         false <- expect === replace,
         true <- encoded_within_cap?(continuation) do
      :ok
    else
      _invalid -> {:error, :invalid_history}
    end
  end

  def validate(%{"version" => @card_media_version} = continuation)
      when is_map(continuation) and not is_struct(continuation) do
    with true <- exact_keys?(continuation, @reference_continuation_keys),
         %{
           "action" => action,
           "target" => target,
           "field" => "media.src",
           "identity" => identity,
           "expect" => expect,
           "replace" => replace
         } <- continuation,
         true <- action in ["undo", "redo"],
         true <- valid_card_action_target?(target),
         true <- valid_card_media_identity?(identity),
         true <- valid_card_media_src_state?(expect),
         true <- valid_card_media_src_state?(replace),
         false <- expect === replace,
         true <- encoded_within_cap?(continuation) do
      :ok
    else
      _invalid -> {:error, :invalid_history}
    end
  end

  def validate(%{"version" => @card_title_version} = continuation)
      when is_map(continuation) and not is_struct(continuation) do
    with true <- exact_keys?(continuation, @reference_continuation_keys),
         %{
           "action" => action,
           "target" => target,
           "field" => "title.text",
           "identity" => identity,
           "expect" => expect,
           "replace" => replace
         } <- continuation,
         true <- action in ["undo", "redo"],
         true <- valid_card_action_target?(target),
         true <- valid_card_title_identity?(identity),
         true <- valid_card_title_text_state?(expect),
         true <- valid_card_title_text_state?(replace),
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
    case validate(continuation) do
      :ok -> apply_validated(blocks, continuation)
      {:error, :invalid_history} = error -> error
    end
  end

  defp apply_validated(blocks, %{"version" => @version} = continuation) do
    with %{
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

  defp apply_validated(blocks, %{"version" => @reference_version} = continuation) do
    with %{
           "action" => action,
           "target" => %{
             "id" => id,
             "type" => "paper-links",
             "ref_index" => ref_index,
             "ref_slug" => ref_slug
           },
           "field" => field,
           "identity" => identity,
           "expect" => expect,
           "replace" => replace
         } <- continuation,
         {:ok, current} <- unique_target_for_apply(blocks, id),
         true <- Map.get(current, "type") === "paper-links" || {:error, :history_conflict},
         refs when is_list(refs) <- Map.get(current, "refs"),
         current_ref when is_map(current_ref) <- Enum.at(refs, ref_index),
         true <- Map.get(current_ref, "slug") === ref_slug || {:error, :history_conflict},
         true <-
           unique_selected_ref_slug?(refs, ref_index, ref_slug) ||
             {:error, :history_conflict},
         true <- reference_identity(current_ref) === identity || {:error, :history_conflict},
         true <- field_state(current_ref, field) === expect || {:error, :history_conflict},
         next_ref <- put_field_state(current_ref, field, replace),
         next_refs <- List.replace_at(refs, ref_index, next_ref),
         {:ok, next_blocks} <-
           replace_target_field(blocks, id, "refs", %{"present" => true, "value" => next_refs}),
         next <-
           reference_continuation(
             toggle(action),
             id,
             ref_index,
             ref_slug,
             field,
             identity,
             replace,
             expect
           ),
         :ok <- validate(next) do
      {:ok, next_blocks, next}
    else
      {:error, reason}
      when reason in [:invalid_history, :history_conflict, :block_not_found, :duplicate_id] ->
        {:error, reason}

      _changed_or_malformed ->
        {:error, :history_conflict}
    end
  end

  defp apply_validated(blocks, %{"version" => @card_action_version} = continuation) do
    with %{
           "action" => action,
           "target" => %{"id" => id, "type" => "card"},
           "field" => "action.label",
           "expect" => expect,
           "replace" => replace
         } <- continuation,
         {:ok, current} <- unique_target_for_apply(blocks, id),
         true <- Map.get(current, "type") === "card" || {:error, :history_conflict},
         {:ok, _current_action, current_state} <- card_action_label(current),
         true <- current_state === expect || {:error, :history_conflict},
         {:ok, next_blocks} <- replace_card_action_label(blocks, id, replace),
         next <- card_action_continuation(toggle(action), id, replace, expect),
         :ok <- validate(next) do
      {:ok, next_blocks, next}
    else
      {:error, reason}
      when reason in [:invalid_history, :history_conflict, :block_not_found, :duplicate_id] ->
        {:error, reason}

      _changed_or_malformed ->
        {:error, :history_conflict}
    end
  end

  defp apply_validated(blocks, %{"version" => @card_media_version} = continuation) do
    with %{
           "action" => action,
           "target" => %{"id" => id, "type" => "card"},
           "field" => "media.src",
           "identity" => %{"type" => type_state},
           "expect" => expect,
           "replace" => replace
         } <- continuation,
         {:ok, current} <- unique_target_for_apply(blocks, id),
         true <- Map.get(current, "type") === "card" || {:error, :history_conflict},
         {:ok, _current_media, current_type_state, current_src_state} <- card_media_src(current),
         true <- current_type_state === type_state || {:error, :history_conflict},
         true <- current_src_state === expect || {:error, :history_conflict},
         {:ok, next_blocks} <- replace_card_media_src(blocks, id, replace),
         next <- card_media_continuation(toggle(action), id, type_state, replace, expect),
         :ok <- validate(next) do
      {:ok, next_blocks, next}
    else
      {:error, reason}
      when reason in [:invalid_history, :history_conflict, :block_not_found, :duplicate_id] ->
        {:error, reason}

      _changed_or_malformed ->
        {:error, :history_conflict}
    end
  end

  defp apply_validated(blocks, %{"version" => @card_title_version} = continuation) do
    with %{
           "action" => action,
           "target" => %{"id" => id, "type" => "card"},
           "field" => "title.text",
           "identity" => identity,
           "expect" => expect,
           "replace" => replace
         } <- continuation,
         {:ok, current} <- unique_target_for_apply(blocks, id),
         true <- Map.get(current, "type") === "card" || {:error, :history_conflict},
         {:ok, _current_title, current_identity, current_state} <- card_title_text(current),
         true <- current_identity === identity || {:error, :history_conflict},
         true <- current_state === expect || {:error, :history_conflict},
         {:ok, next_blocks} <- replace_card_title_text(blocks, id, replace),
         next <- card_title_continuation(toggle(action), id, identity, replace, expect),
         :ok <- validate(next) do
      {:ok, next_blocks, next}
    else
      {:error, reason}
      when reason in [:invalid_history, :history_conflict, :block_not_found, :duplicate_id] ->
        {:error, reason}

      _changed_or_malformed ->
        {:error, :history_conflict}
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

  defp capture_reference_copy(before_blocks, after_blocks, ops) do
    with {:ok, id} <- eligible_reference_op(ops),
         {:ok, before_target} <- unique_target(before_blocks, id),
         {:ok, after_target} <- unique_target(after_blocks, id),
         true <- Map.get(before_target, "type") === "paper-links",
         true <- Map.get(after_target, "type") === "paper-links",
         true <- Map.delete(before_target, "refs") === Map.delete(after_target, "refs"),
         before_refs when is_list(before_refs) <- Map.get(before_target, "refs"),
         after_refs when is_list(after_refs) <- Map.get(after_target, "refs"),
         true <- length(before_refs) === length(after_refs),
         {:ok, ref_index, ref_slug, field, identity, before_state, after_state} <-
           reference_copy_change(before_refs, after_refs),
         true <- unique_selected_ref_slug?(before_refs, ref_index, ref_slug),
         true <- unique_selected_ref_slug?(after_refs, ref_index, ref_slug),
         {:ok, projected_after} <-
           replace_target_field(
             before_blocks,
             id,
             "refs",
             %{"present" => true, "value" => after_refs}
           ),
         true <- projected_after === after_blocks,
         continuation <-
           reference_continuation(
             "undo",
             id,
             ref_index,
             ref_slug,
             field,
             identity,
             after_state,
             before_state
           ),
         :ok <- validate(continuation) do
      {:ok, continuation}
    else
      _unsupported_or_ambiguous -> {:ok, nil}
    end
  end

  defp eligible_reference_op([
         %{"op" => "patch-block", "id" => id, "patch" => %{"refs" => _refs} = patch}
       ])
       when is_binary(id) and id != "" and map_size(patch) == 1,
       do: {:ok, id}

  defp eligible_reference_op(_ops), do: {:error, :unsupported}

  defp capture_card_action_label(before_blocks, after_blocks, ops) do
    with {:ok, id} <- eligible_card_action_op(ops),
         {:ok, before_target} <- unique_target(before_blocks, id),
         {:ok, after_target} <- unique_target(after_blocks, id),
         true <- Map.get(before_target, "type") === "card",
         true <- Map.get(after_target, "type") === "card",
         {:ok, _before_action, before_state} <- card_action_label(before_target),
         {:ok, _after_action, after_state} <- card_action_label(after_target),
         false <- before_state === after_state,
         {:ok, projected_after} <- replace_card_action_label(before_blocks, id, after_state),
         true <- projected_after === after_blocks,
         continuation <- card_action_continuation("undo", id, after_state, before_state),
         :ok <- validate(continuation) do
      {:ok, continuation}
    else
      _unsupported_or_ambiguous -> {:ok, nil}
    end
  end

  defp eligible_card_action_op([
         %{"op" => "patch-block", "id" => id, "patch" => %{"slots" => _slots} = patch}
       ])
       when is_binary(id) and id != "" and map_size(patch) == 1,
       do: {:ok, id}

  defp eligible_card_action_op(_ops), do: {:error, :unsupported}

  defp capture_card_media_src(before_blocks, after_blocks, ops) do
    with {:ok, id} <- eligible_card_media_op(ops),
         {:ok, before_target} <- unique_target(before_blocks, id),
         {:ok, after_target} <- unique_target(after_blocks, id),
         true <- Map.get(before_target, "type") === "card",
         true <- Map.get(after_target, "type") === "card",
         {:ok, _before_media, before_type_state, before_src_state} <-
           card_media_src(before_target),
         {:ok, _after_media, after_type_state, after_src_state} <- card_media_src(after_target),
         true <- before_type_state === after_type_state,
         false <- before_src_state === after_src_state,
         {:ok, projected_after} <- replace_card_media_src(before_blocks, id, after_src_state),
         true <- projected_after === after_blocks,
         continuation <-
           card_media_continuation(
             "undo",
             id,
             after_type_state,
             after_src_state,
             before_src_state
           ),
         :ok <- validate(continuation) do
      {:ok, continuation}
    else
      _unsupported_or_ambiguous -> {:ok, nil}
    end
  end

  defp eligible_card_media_op([
         %{"op" => "patch-block", "id" => id, "patch" => %{"slots" => _slots} = patch}
       ])
       when is_binary(id) and id != "" and map_size(patch) == 1,
       do: {:ok, id}

  defp eligible_card_media_op(_ops), do: {:error, :unsupported}

  defp capture_card_title_text(before_blocks, after_blocks, ops) do
    with {:ok, id} <- eligible_card_title_op(ops),
         {:ok, before_target} <- unique_target(before_blocks, id),
         {:ok, after_target} <- unique_target(after_blocks, id),
         true <- Map.get(before_target, "type") === "card",
         true <- Map.get(after_target, "type") === "card",
         {:ok, _before_title, before_identity, before_state} <- card_title_text(before_target),
         {:ok, _after_title, after_identity, after_state} <- card_title_text(after_target),
         true <- before_identity === after_identity,
         false <- before_state === after_state,
         {:ok, projected_after} <- replace_card_title_text(before_blocks, id, after_state),
         true <- projected_after === after_blocks,
         continuation <-
           card_title_continuation("undo", id, after_identity, after_state, before_state),
         :ok <- validate(continuation) do
      {:ok, continuation}
    else
      _unsupported_or_ambiguous -> {:ok, nil}
    end
  end

  defp eligible_card_title_op([
         %{"op" => "patch-block", "id" => id, "patch" => %{"slots" => _slots} = patch}
       ])
       when is_binary(id) and id != "" and map_size(patch) == 1,
       do: {:ok, id}

  defp eligible_card_title_op(_ops), do: {:error, :unsupported}

  defp reference_copy_change(before_refs, after_refs) do
    changed =
      before_refs
      |> Enum.zip(after_refs)
      |> Enum.with_index()
      |> Enum.filter(fn {{before_ref, after_ref}, _index} -> before_ref !== after_ref end)

    case changed do
      [{{before_ref, after_ref}, ref_index}]
      when is_map(before_ref) and is_map(after_ref) and not is_struct(before_ref) and
             not is_struct(after_ref) ->
        before_identity = reference_identity(before_ref)
        after_identity = reference_identity(after_ref)
        ref_slug = Map.get(before_ref, "slug")

        changed_fields =
          Enum.filter(@reference_fields, fn field ->
            field_state(before_ref, field) !== field_state(after_ref, field)
          end)

        with true <- before_identity === after_identity,
             true <- valid_reference_identity?(before_identity, ref_slug),
             [field] <- changed_fields,
             before_state <- field_state(before_ref, field),
             after_state <- field_state(after_ref, field),
             true <- valid_scalar_state?(before_state),
             true <- valid_scalar_state?(after_state) do
          {:ok, ref_index, ref_slug, field, before_identity, before_state, after_state}
        else
          _unsupported -> {:error, :unsupported}
        end

      _none_or_many ->
        {:error, :unsupported}
    end
  end

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

  defp reference_continuation(
         action,
         id,
         ref_index,
         ref_slug,
         field,
         identity,
         expect,
         replace
       ) do
    %{
      "version" => @reference_version,
      "action" => action,
      "target" => %{
        "id" => id,
        "type" => "paper-links",
        "ref_index" => ref_index,
        "ref_slug" => ref_slug
      },
      "field" => field,
      "identity" => identity,
      "expect" => expect,
      "replace" => replace
    }
  end

  defp card_action_continuation(action, id, expect, replace) do
    %{
      "version" => @card_action_version,
      "action" => action,
      "target" => %{"id" => id, "type" => "card"},
      "field" => "action.label",
      "expect" => expect,
      "replace" => replace
    }
  end

  defp card_media_continuation(action, id, type_state, expect, replace) do
    %{
      "version" => @card_media_version,
      "action" => action,
      "target" => %{"id" => id, "type" => "card"},
      "field" => "media.src",
      "identity" => %{"type" => type_state},
      "expect" => expect,
      "replace" => replace
    }
  end

  defp card_title_continuation(action, id, identity, expect, replace) do
    %{
      "version" => @card_title_version,
      "action" => action,
      "target" => %{"id" => id, "type" => "card"},
      "field" => "title.text",
      "identity" => identity,
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

  defp valid_reference_target?(target) when is_map(target) and not is_struct(target) do
    exact_keys?(target, @reference_target_keys) and nonblank_binary?(target["id"]) and
      target["type"] === "paper-links" and is_integer(target["ref_index"]) and
      target["ref_index"] >= 0 and nonblank_binary?(target["ref_slug"])
  end

  defp valid_reference_target?(_target), do: false

  defp valid_card_action_target?(target) when is_map(target) and not is_struct(target) do
    exact_keys?(target, @target_keys) and nonblank_binary?(target["id"]) and
      target["type"] === "card"
  end

  defp valid_card_action_target?(_target), do: false

  defp valid_card_media_identity?(identity)
       when is_map(identity) and not is_struct(identity) do
    exact_keys?(identity, @card_media_identity_keys) and
      valid_card_media_type_state?(identity["type"])
  end

  defp valid_card_media_identity?(_identity), do: false

  defp valid_card_title_identity?(identity)
       when is_map(identity) and not is_struct(identity) do
    exact_keys?(identity, @card_title_identity_keys) and
      identity["type"] === %{"present" => true, "value" => "heading"} and
      valid_card_title_content_state?(identity["content"])
  end

  defp valid_card_title_identity?(_identity), do: false

  defp valid_reference_identity?(identity, ref_slug)
       when is_map(identity) and not is_struct(identity) do
    json_value?(identity) and not Map.has_key?(identity, "title") and
      not Map.has_key?(identity, "description") and Map.get(identity, "slug") === ref_slug and
      Map.get(identity, "prefer_authored_copy") === true and
      not is_nil(canonical_ref_slug(ref_slug))
  end

  defp valid_reference_identity?(_identity, _ref_slug), do: false

  defp allowed_field?(type, field), do: MapSet.member?(@allowed_fields, {type, field})

  defp valid_state?(%{"present" => false} = state), do: exact_keys?(state, ["present"])

  defp valid_state?(%{"present" => true, "value" => value} = state),
    do: exact_keys?(state, ["present", "value"]) and json_value?(value)

  defp valid_state?(_state), do: false

  defp valid_scalar_state?(%{"present" => false} = state), do: exact_keys?(state, ["present"])

  defp valid_scalar_state?(%{"present" => true, "value" => value} = state),
    do:
      exact_keys?(state, ["present", "value"]) and
        (is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value))

  defp valid_scalar_state?(_state), do: false

  defp valid_card_action_state?(%{"present" => false} = state),
    do: exact_keys?(state, ["present"])

  defp valid_card_action_state?(%{"present" => true, "value" => value} = state),
    do: exact_keys?(state, ["present", "value"]) and (is_nil(value) or is_binary(value))

  defp valid_card_action_state?(_state), do: false

  defp valid_card_media_type_state?(%{"present" => false} = state),
    do: exact_keys?(state, ["present"])

  defp valid_card_media_type_state?(%{"present" => true, "value" => value} = state),
    do: exact_keys?(state, ["present", "value"]) and value in [nil, "image"]

  defp valid_card_media_type_state?(_state), do: false

  defp valid_card_media_src_state?(%{"present" => false} = state),
    do: exact_keys?(state, ["present"])

  defp valid_card_media_src_state?(%{"present" => true, "value" => value} = state),
    do: exact_keys?(state, ["present", "value"]) and (is_nil(value) or is_binary(value))

  defp valid_card_media_src_state?(_state), do: false

  defp valid_card_title_content_state?(%{"present" => false} = state),
    do: exact_keys?(state, ["present"])

  defp valid_card_title_content_state?(%{"present" => true, "value" => value} = state),
    do: exact_keys?(state, ["present", "value"]) and value in [nil, []]

  defp valid_card_title_content_state?(_state), do: false

  defp valid_card_title_text_state?(%{"present" => true, "value" => value} = state),
    do: exact_keys?(state, ["present", "value"]) and is_binary(value)

  defp valid_card_title_text_state?(_state), do: false

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

  defp reference_identity(ref), do: Map.drop(ref, @reference_fields)

  defp unique_selected_ref_slug?(refs, ref_index, raw_slug)
       when is_list(refs) and is_integer(ref_index) and ref_index >= 0 and is_binary(raw_slug) do
    canonical_slug = canonical_ref_slug(raw_slug)
    selected = Enum.at(refs, ref_index)

    is_binary(canonical_slug) and is_map(selected) and not is_struct(selected) and
      Map.get(selected, "slug") === raw_slug and
      Enum.count(refs, &(canonical_ref_slug(&1) === canonical_slug)) == 1
  end

  defp unique_selected_ref_slug?(_refs, _ref_index, _raw_slug), do: false

  defp canonical_ref_slug(slug) when is_binary(slug) do
    case String.trim(slug) do
      "" -> nil
      canonical -> canonical
    end
  end

  defp canonical_ref_slug(%{"slug" => slug}), do: canonical_ref_slug(slug)
  defp canonical_ref_slug(_ref), do: nil

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

  defp replace_card_action_label(blocks, id, state) do
    case transform_blocks(blocks, id, fn block ->
           {:ok, action, _current_state} = card_action_label(block)
           slots = Map.fetch!(block, "slots")

           Map.put(
             block,
             "slots",
             Map.put(slots, "action", [put_field_state(action, "label", state)])
           )
         end) do
      {next_blocks, 1} -> {:ok, next_blocks}
      _missing_or_duplicate -> {:error, :invalid_history}
    end
  rescue
    _malformed -> {:error, :history_conflict}
  end

  defp replace_card_media_src(blocks, id, state) do
    case transform_blocks(blocks, id, fn block ->
           {:ok, media, _type_state, _src_state} = card_media_src(block)
           slots = Map.fetch!(block, "slots")

           Map.put(
             block,
             "slots",
             Map.put(slots, "media", [put_field_state(media, "src", state)])
           )
         end) do
      {next_blocks, 1} -> {:ok, next_blocks}
      _missing_or_duplicate -> {:error, :invalid_history}
    end
  rescue
    _malformed -> {:error, :history_conflict}
  end

  defp replace_card_title_text(blocks, id, state) do
    case transform_blocks(blocks, id, fn block ->
           {:ok, title, _identity, _current_state} = card_title_text(block)
           slots = Map.fetch!(block, "slots")

           Map.put(
             block,
             "slots",
             Map.put(slots, "title", [put_field_state(title, "text", state)])
           )
         end) do
      {next_blocks, 1} -> {:ok, next_blocks}
      _missing_or_duplicate -> {:error, :invalid_history}
    end
  rescue
    _malformed -> {:error, :history_conflict}
  end

  defp card_action_label(%{"slots" => slots})
       when is_map(slots) and not is_struct(slots) do
    case Map.get(slots, "action") do
      [action] when is_map(action) and not is_struct(action) ->
        state = field_state(action, "label")

        if Map.get(action, "type") === "action" and optional_binary?(action, "href") and
             optional_binary?(action, "priority") and valid_card_action_state?(state) do
          {:ok, action, state}
        else
          {:error, :history_conflict}
        end

      _missing_or_malformed ->
        {:error, :history_conflict}
    end
  end

  defp card_action_label(_block), do: {:error, :history_conflict}

  defp card_media_src(%{"slots" => slots})
       when is_map(slots) and not is_struct(slots) do
    case Map.get(slots, "media") do
      [media] when is_map(media) and not is_struct(media) ->
        type_state = field_state(media, "type")
        src_state = field_state(media, "src")

        if valid_card_media_type_state?(type_state) and valid_card_media_src_state?(src_state) and
             optional_binary?(media, "alt") do
          {:ok, media, type_state, src_state}
        else
          {:error, :history_conflict}
        end

      _missing_or_malformed ->
        {:error, :history_conflict}
    end
  end

  defp card_media_src(_block), do: {:error, :history_conflict}

  defp card_title_text(%{"slots" => slots})
       when is_map(slots) and not is_struct(slots) do
    case Map.get(slots, "title") do
      [title] when is_map(title) and not is_struct(title) ->
        identity = %{
          "type" => field_state(title, "type"),
          "content" => field_state(title, "content")
        }

        text_state = field_state(title, "text")

        if valid_card_title_identity?(identity) and valid_card_title_text_state?(text_state) and
             valid_card_title_level?(title) do
          {:ok, title, identity, text_state}
        else
          {:error, :history_conflict}
        end

      _missing_or_malformed ->
        {:error, :history_conflict}
    end
  end

  defp card_title_text(_block), do: {:error, :history_conflict}

  defp valid_card_title_level?(title) do
    case Map.fetch(title, "level") do
      :error -> true
      {:ok, nil} -> true
      {:ok, level} -> level in [1, 2, 3, "1", "2", "3"]
    end
  end

  defp optional_binary?(map, key) do
    not Map.has_key?(map, key) or is_nil(map[key]) or is_binary(map[key])
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
