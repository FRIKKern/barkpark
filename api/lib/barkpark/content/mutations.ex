defmodule Barkpark.Content.Mutations do
  @moduledoc """
  The batch-mutation concern (H) — `apply_mutations/2` wraps the per-mutation
  `apply_one` dispatch in a `Repo.transaction`, driving broadcast-deferral:
  PubSub frames queued inside the transaction are flushed after a successful
  commit and discarded on rollback (no ghost SSE events on a failed batch).

  Extracted from `Barkpark.Content` (decomposition Step 13, concern H).
  `Barkpark.Content` keeps facade delegations so every external caller is
  unchanged; the per-mutation write/publish primitives are called back through
  `Barkpark.Content.*`, rev generation through `Content.Writer`, deferral
  through `Content.Broadcast`.
  """

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Broadcast, CallerContext, DraftId, Envelope, Writer}

  @doc """
  Apply a batch of mutations atomically. Returns `{:ok, {transaction_id, results}}`
  or `{:error, reason}` with rollback on any failure.

  `opts` accepts `:source` and `:user_id` and is threaded into every
  per-mutation Content call so lifecycle-hook context (`ctx.source`,
  `ctx.user_id`) is set correctly for each fired hook.

  PubSub broadcasts queued inside the transaction are flushed AFTER a
  successful commit, and discarded on rollback — no ghost events on
  the SSE stream when a batch fails partway through.
  """
  def apply_mutations(mutations, dataset, opts \\ []) when is_list(mutations) do
    # Initialise the deferred-broadcast queue for this process so
    # tap_broadcast/5 knows to queue instead of broadcast immediately.
    Process.put(:barkpark_deferred_broadcasts, [])

    try do
      result =
        Repo.transaction(fn ->
          tx_id = Writer.generate_rev()

          # SECURITY: echo each mutated document through the REAL caller + the
          # type's schema, NOT the `:internal` no-redaction sentinel. A `patch`
          # op merges server-side `existing.content` the caller never supplied,
          # so an :internal echo would leak private/owner_only/readable_by
          # plaintext (and encrypted ciphertext) to a non-admin write or
          # edit-share token — exactly the fields a GET redacts. Admins /
          # admin-tokens still see all via the is_admin bypass; a writer that
          # supplied a field it can't read simply won't see it echoed (it
          # already knows the value it sent). Schema is memoised per type.
          caller = Keyword.get(opts, :caller_context) || CallerContext.anonymous()

          {results, _schema_cache} =
            Enum.map_reduce(mutations, %{}, fn m, cache ->
              case apply_one(m, dataset, opts) do
                {:ok, doc, op} ->
                  {schema, cache} = echo_schema(doc.type, dataset, opts, cache)

                  {%{
                     id: doc.doc_id,
                     operation: op,
                     document: Envelope.render(doc, schema, caller)
                   }, cache}

                {:error, reason} ->
                  Repo.rollback(reason)
              end
            end)

          {tx_id, results}
        end)

      case result do
        {:ok, _} ->
          Broadcast.flush_deferred_broadcasts()
          result

        _ ->
          Broadcast.clear_deferred_broadcasts()
          result
      end
    rescue
      e ->
        Broadcast.clear_deferred_broadcasts()
        reraise(e, __STACKTRACE__)
    end
  end

  # Resolve the type's schema for the redacted echo, memoised across the batch.
  # Same scope-aware lookup the read path uses (`Content.get_schema/3` with the
  # request's scope opts); a missing schema → `nil` (Envelope still drops
  # encrypted ciphertext, but a typed schema is needed to redact non-encrypted
  # private fields, so a real type must resolve its schema here).
  defp echo_schema(type, dataset, opts, cache) do
    case Map.fetch(cache, type) do
      {:ok, schema} ->
        {schema, cache}

      :error ->
        schema =
          case Content.get_schema(type, dataset, opts) do
            {:ok, s} -> s
            _ -> nil
          end

        {schema, Map.put(cache, type, schema)}
    end
  end

  defp apply_one(%{"create" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    # A create must NOT overwrite an existing draft. Skip the lookup when
    # type/id are missing — let create_document/3 surface a validation error
    # (Ecto rejects nil equality comparisons in queries).
    existing =
      if id && type do
        case Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
          {:ok, doc} -> doc
          _ -> nil
        end
      end

    case existing do
      %_{} = doc ->
        case if_rev(attrs) do
          nil -> {:error, :conflict}
          expected -> {:error, {:rev_mismatch, %{expected: expected, actual: doc.rev}}}
        end

      _ ->
        with {:ok, doc} <- Content.create_document(type, attrs, dataset, opts),
             do: {:ok, doc, "create"}
    end
  end

  defp apply_one(%{"createOrReplace" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]
    expected = if_rev(attrs)

    existing =
      case id && Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
        {:ok, doc} -> doc
        _ -> nil
      end

    with :ok <- ensure_rev(existing, expected),
         {:ok, doc} <- Content.create_document(type, attrs, dataset, opts) do
      {:ok, doc, "createOrReplace"}
    end
  end

  defp apply_one(%{"createIfNotExists" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    case id && Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
      {:ok, existing} ->
        case ensure_rev(existing, if_rev(attrs)) do
          :ok -> {:ok, existing, "noop"}
          err -> err
        end

      _ ->
        with {:ok, doc} <- Content.create_document(type, attrs, dataset, opts),
             do: {:ok, doc, "create"}
    end
  end

  defp apply_one(%{"publish" => %{"id" => id, "type" => type}}, dataset, opts) do
    with {:ok, doc} <- Content.publish_document(id, type, dataset, opts),
         do: {:ok, doc, "publish"}
  end

  defp apply_one(%{"unpublish" => %{"id" => id, "type" => type}}, dataset, opts) do
    with {:ok, doc} <- Content.unpublish_document(id, type, dataset, opts),
         do: {:ok, doc, "unpublish"}
  end

  defp apply_one(%{"discardDraft" => %{"id" => id, "type" => type}}, dataset, opts) do
    with {:ok, doc} <- Content.discard_draft(id, type, dataset, opts),
         do: {:ok, doc, "discardDraft"}
  end

  defp apply_one(%{"delete" => %{"id" => id, "type" => type} = op}, dataset, opts) do
    case if_rev(op) do
      nil ->
        with {:ok, doc} <- Content.delete_document(id, type, dataset, opts),
             do: {:ok, doc, "delete"}

      expected ->
        with {:ok, existing} <- Content.get_document(id, type, dataset, opts),
             :ok <- ensure_rev(existing, expected),
             {:ok, doc} <- Content.delete_document(id, type, dataset, opts) do
          {:ok, doc, "delete"}
        end
    end
  end

  defp apply_one(%{"replace" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    with {:ok, existing} <- Content.get_document(id && DraftId.draft_id(id), type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(attrs)),
         {:ok, doc} <- Content.create_document(type, attrs, dataset, opts) do
      {:ok, doc, "replace"}
    end
  end

  # Phase-1B patch ops: setIfMissing / unset / inc / dec / append / prepend,
  # composable with set in one op. Placed BEFORE the set-only clause so any patch
  # carrying one of these lands here — the set clause would otherwise match on
  # `set` and silently ignore them; a pure-set patch carries none of these keys
  # and falls through to it. Order: setIfMissing fills absent defaults → set
  # merges (overriding) → inc/dec adjust the merged numeric values →
  # append/prepend extend list fields → unset removes. Promoted/system fields
  # (title/status/_id/_type/_rev) stay protected throughout; malformed ops (a
  # non-map setIfMissing/inc/dec/append/prepend, a non-list unset, a non-numeric
  # delta, non-list append/prepend items) are ignored, not fatal.
  defp apply_one(%{"patch" => %{"id" => id, "type" => type} = patch}, dataset, opts)
       when is_map_key(patch, "setIfMissing") or is_map_key(patch, "unset") or
              is_map_key(patch, "inc") or is_map_key(patch, "dec") or
              is_map_key(patch, "append") or is_map_key(patch, "prepend") do
    with {:ok, existing} <- Content.get_document(id, type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(patch)) do
      protected = ~w(title status _id _type _rev)
      set_fields = Map.get(patch, "set", %{})
      unset_keys = list_or_empty(Map.get(patch, "unset"))

      merged =
        (existing.content || %{})
        |> put_new_fields(Map.get(patch, "setIfMissing"), protected)
        |> Map.merge(Map.drop(set_fields, protected))
        |> apply_delta(Map.get(patch, "inc"), protected, 1)
        |> apply_delta(Map.get(patch, "dec"), protected, -1)
        |> apply_array_op(Map.get(patch, "append"), protected, :append)
        |> apply_array_op(Map.get(patch, "prepend"), protected, :prepend)
        |> Map.drop(unset_keys -- protected)

      attrs = %{
        "doc_id" => id,
        "title" => set_fields["title"] || existing.title,
        "content" => merged
      }

      with {:ok, doc} <- Content.upsert_document(type, attrs, dataset, opts),
           do: {:ok, doc, "update"}
    end
  end

  defp apply_one(
         %{"patch" => %{"id" => id, "type" => type, "set" => fields} = patch},
         dataset,
         opts
       ) do
    with {:ok, existing} <- Content.get_document(id, type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(patch)) do
      merged =
        Map.merge(
          existing.content || %{},
          Map.drop(fields, ~w(title status _id _type _rev))
        )

      attrs = %{
        "doc_id" => id,
        "title" => fields["title"] || existing.title,
        "content" => merged
      }

      with {:ok, doc} <- Content.upsert_document(type, attrs, dataset, opts),
           do: {:ok, doc, "update"}
    end
  end

  defp apply_one(_, _, _), do: {:error, :malformed}

  defp list_or_empty(l) when is_list(l), do: l
  defp list_or_empty(_), do: []

  # setIfMissing: put each field only if absent (Map.put_new), so it fills
  # defaults without clobbering existing values. Protected keys are skipped; a
  # non-map `fields` (malformed op) is a no-op.
  defp put_new_fields(content, fields, protected) when is_map(fields) do
    Enum.reduce(fields, content, fn {k, v}, acc ->
      if k in protected, do: acc, else: Map.put_new(acc, k, v)
    end)
  end

  defp put_new_fields(content, _fields, _protected), do: content

  # inc/dec: add sign*delta to each numeric field, treating a missing or
  # non-numeric current value as 0. Protected keys and non-numeric deltas are
  # skipped; a non-map `fields` (malformed op) is a no-op.
  defp apply_delta(content, fields, protected, sign) when is_map(fields) do
    Enum.reduce(fields, content, fn
      {k, delta}, acc when is_number(delta) ->
        if k in protected do
          acc
        else
          current = if is_number(acc[k]), do: acc[k], else: 0
          Map.put(acc, k, current + sign * delta)
        end

      {_k, _delta}, acc ->
        acc
    end)
  end

  defp apply_delta(content, _fields, _protected, _sign), do: content

  # append/prepend: extend a LIST field with items. A missing field starts from
  # [] (append/prepend onto nothing are identical); a non-list existing value (a
  # scalar) is left untouched — never clobbered with an array. Protected keys,
  # non-list items, and a non-map `fields` (malformed op) are no-ops.
  defp apply_array_op(content, fields, protected, position) when is_map(fields) do
    Enum.reduce(fields, content, fn
      {k, items}, acc when is_list(items) ->
        cond do
          k in protected ->
            acc

          is_list(Map.get(acc, k)) ->
            current = Map.get(acc, k)
            Map.put(acc, k, if(position == :append, do: current ++ items, else: items ++ current))

          not Map.has_key?(acc, k) ->
            Map.put(acc, k, items)

          true ->
            acc
        end

      {_k, _items}, acc ->
        acc
    end)
  end

  defp apply_array_op(content, _fields, _protected, _position), do: content

  defp if_rev(%{} = attrs), do: attrs["ifRevisionID"] || attrs["ifMatch"]
  defp if_rev(_), do: nil

  defp ensure_rev(_doc, nil), do: :ok
  defp ensure_rev(_doc, ""), do: :ok

  defp ensure_rev(nil, expected),
    do: {:error, {:rev_mismatch, %{expected: expected, actual: nil}}}

  defp ensure_rev(%{rev: r}, r), do: :ok

  defp ensure_rev(%{rev: actual}, expected),
    do: {:error, {:rev_mismatch, %{expected: expected, actual: actual}}}
end
