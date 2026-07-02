defmodule Barkpark.Sync.Applier do
  @moduledoc """
  Applies one parsed mutation envelope into the LOCAL workspace via Content's
  PUBLIC API only (`Content.apply_mutations/3`, `Content.delete_document/4`) —
  it never touches `content.ex`'s internals.

  ## Echo-dedup (Phase 1)

  Dedup rests on the integer cursor high-water mark, NOT on revisions: every
  local write mints a fresh RANDOM rev (`Content.Writer.generate_rev/0`) and
  the incoming `_rev` is dropped (`@reserved_in`), so the local rev is
  uncorrelated with the source rev and cannot be used to detect "already have
  this". Instead, before applying, the Applier compares the event's id against
  the persisted cursor and SKIPS (`{:ok, :skipped}`) anything `<= cursor`. The
  cursor is advanced AFTER a successful apply/skip. `createOrReplace` is
  content-idempotent, so at-least-once re-apply in the narrow
  crash-between-apply-and-advance window is harmless (Phase 1 deliberately does
  NOT pay for an in-content `__syncRev` stash).

  ## Op scope (Phase 1)

  Deliberately narrow and explicit. Routing keys on the mutation KIND first,
  then falls back to result-shape:

    * `mutation == "delete"` → `Content.delete_document/4`, REGARDLESS of
      `result` contents. Barkpark's own producer stamps the still-fully-
      populated deleted document onto the delete event's `result`
      (`broadcast.ex` save_event), so routing on emptiness alone would mistake
      a delete for an upsert and re-create the doc the remote just deleted;
    * otherwise a non-empty `result` envelope → `createOrReplace` (lands as
      `drafts.<id>` via `DraftId.draft_id`). When the source document is
      PUBLISHED (`result["_draft"] == false`) a `publish` mutation is appended
      IN THE SAME BATCH so status fidelity is preserved locally;
    * otherwise an empty/nil `result` (a delete signalled by a non-Barkpark
      producer) → `Content.delete_document/4`, cursor-guarded with
      not-found-treated-as-ok.

  `update`/`unpublish`/`discardDraft` and other ops are out of Phase-1 scope —
  the producer's `result` envelope is always the full post-write document, so
  `createOrReplace` reconstructs the local state faithfully.
  """

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  alias Barkpark.Sync.{Cursor, DeadLetter, PushDocRev}

  @typedoc """
  Apply context: cursor source, dataset string, and local write scope.

  `:scope` is a `[workspace_id:, project_id:]` keyword, or the `:unresolved`
  sentinel when the configured workspace slug did not resolve — in which case
  `apply_event/2` refuses to write (guarding the tenancy invariant).
  """
  @type ctx :: %{
          required(:source) => String.t(),
          required(:dataset) => String.t(),
          required(:scope) => keyword() | :unresolved,
          optional(:max_attempts) => pos_integer()
        }

  @doc """
  Echo-dedup then apply one parsed SSE event into the local workspace.

  Returns `{:ok, :applied}`, `{:ok, :skipped}` (already at/under the cursor), or
  `{:error, term}` (the cursor is NOT advanced on error, so the event is
  retried on the next pass).
  """
  @spec apply_event(Barkpark.Sync.SSE.event(), ctx()) ::
          {:ok, :applied | :skipped | :dead_lettered} | {:error, term()}
  def apply_event(_event, %{scope: :unresolved}) do
    Logger.warning(
      "[Sync] configured workspace did not resolve — refusing to apply (would be a NULL/global write). " <>
        "Check BARKPARK_SYNC_WORKSPACE."
    )

    {:error, :unresolved_workspace}
  end

  def apply_event(%{id: id, envelope: envelope}, %{source: source, dataset: dataset} = ctx) do
    event_id = id || envelope["eventId"]

    cond do
      not is_integer(event_id) ->
        {:error, :missing_event_id}

      event_id <= Cursor.get(source, dataset) ->
        {:ok, :skipped}

      true ->
        case apply_envelope(envelope, source, dataset, Map.get(ctx, :scope, [])) do
          {:ok, :applied} ->
            Cursor.put(source, dataset, event_id)
            {:ok, :applied}

          {:error, reason} ->
            max = Map.get(ctx, :max_attempts, 5)
            attempts = DeadLetter.record_failure(source, dataset, event_id, envelope, reason)

            if attempts >= max do
              DeadLetter.mark_dead(source, dataset, event_id)

              Logger.error(
                "[Sync] DEAD-LETTER event #{event_id} (#{source}/#{dataset}) after " <>
                  "#{attempts} attempts: #{inspect(reason)} — recorded + advancing cursor past it"
              )

              # Advance ONLY after the durable DL write (write-then-advance, R1/R2):
              # an inspectable quarantine, never a silent skip.
              Cursor.put(source, dataset, event_id)
              {:ok, :dead_lettered}
            else
              # Below threshold → halt + replay; invariant #3 unchanged.
              {:error, reason}
            end
        end
    end
  end

  defp apply_envelope(envelope, source, dataset, scope) do
    result = envelope["result"] || envelope["document"]
    type = envelope["type"] || (is_map(result) && result["_type"])

    cond do
      # Route on the mutation KIND first: Barkpark's own producer stamps the
      # still-fully-populated deleted document onto a delete event's `result`
      # (broadcast.ex save_event), so result-emptiness alone would mistake a
      # delete for an upsert and re-create the doc the remote just deleted.
      envelope["mutation"] == "delete" ->
        apply_delete(envelope, type, dataset, scope)

      is_map(result) and map_size(result) > 0 ->
        with {:ok, :applied} <- apply_upsert(result, type, dataset, scope) do
          prime_push_ledger(source, dataset, result)
          {:ok, :applied}
        end

      # Fallback for non-Barkpark producers that signal a delete via an
      # empty/nil result (no explicit `mutation` field).
      true ->
        apply_delete(envelope, type, dataset, scope)
    end
  end

  # Prime the CAS ledger with the REMOTE rev so a later LOCAL edit pushes the
  # correct ifRevisionID (clone -> edit -> push-back works, no spurious conflict).
  # Keyed by the SAME Settings.source the pusher reads. mutation_events.doc_id is
  # either "drafts.<id>" or "<id>" depending on the write, so prime BOTH; an
  # unmatched key is non-fatal — F2 turns a missed prime into a SAFE conflict,
  # never an overwrite. Inert when push is off (table only; invariant #1 intact).
  defp prime_push_ledger(source, dataset, %{"_id" => id, "_rev" => rev})
       when is_binary(id) and is_binary(rev) do
    PushDocRev.put(source, dataset, DraftId.draft_id(id), rev)
    PushDocRev.put(source, dataset, DraftId.published_id(id), rev)
    :ok
  end

  defp prime_push_ledger(_source, _dataset, _result), do: :ok

  defp apply_upsert(result, type, dataset, scope) do
    mutations =
      [%{"createOrReplace" => result}] ++ maybe_publish(result, type)

    case Content.apply_mutations(mutations, dataset, scope ++ [source: :sync]) do
      {:ok, _} -> {:ok, :applied}
      {:error, _} = err -> err
    end
  end

  # Preserve status fidelity: a PUBLISHED source doc (`_draft == false`) is
  # republished locally in the same batch — createOrReplace alone would land it
  # as a draft (DraftId.draft_id + default status "draft").
  defp maybe_publish(%{"_draft" => false} = result, type) when is_binary(type) do
    case published_id(result) do
      nil -> []
      pub_id -> [%{"publish" => %{"id" => pub_id, "type" => type}}]
    end
  end

  defp maybe_publish(_result, _type), do: []

  defp published_id(result) do
    case result["_publishedId"] || result["_id"] do
      id when is_binary(id) -> Content.published_id(id)
      _ -> nil
    end
  end

  # Delete is cursor-guarded (we only reach here for an un-applied event) and
  # not-found-is-ok: a doc the remote deleted that we never had is a no-op.
  defp apply_delete(envelope, type, dataset, scope) do
    doc_id = envelope["documentId"]

    cond do
      is_binary(doc_id) and is_binary(type) ->
        case Content.delete_document(doc_id, type, dataset, scope ++ [source: :sync]) do
          {:ok, _} -> {:ok, :applied}
          {:error, :not_found} -> {:ok, :applied}
          {:error, _} = err -> err
        end

      true ->
        Logger.debug("[Sync] delete envelope missing documentId/type — skipping")
        {:ok, :applied}
    end
  end
end
