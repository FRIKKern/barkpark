defmodule Barkpark.Content.PatchLock do
  @moduledoc """
  Serialize a write sequence (read current → merge → write) on one document,
  for callers that merge the AUTHOR's change onto whatever "current" state
  they read before writing it back — `mutations.ex`'s SDK `patch` ops
  (task-bfb66a2ff491f6e7 c1) and `Forms.upsert_draft` (task-324b4d00706a6cfb)
  alike.

  Without this, two concurrent callers racing the SAME document each read
  the SAME base, merge their own (different) change onto it, and the later
  write wins outright — the earlier caller's change is gone, with no error
  from either side. Worse, when NEITHER caller sees an existing draft (a
  patch on a published doc with no draft forked yet), both attempt to FORK
  it: one's `Repo.insert` wins, the other's hits
  `documents_doc_id_type_dataset_id_index` — or, if it lands in the gap
  between a caller's own read and the writer's internal re-read, can take an
  UNFENCED update branch and silently overwrite the winner's row.

  `with_lock/4` closes every one of these: a transaction-scoped Postgres
  advisory lock on `(workspace_id, dataset, published_id)`, acquired before
  the read, held for the whole read-merge-write sequence, released at commit
  or rollback. The second caller waits for the first to finish (commit or
  rollback) before it even reads, so it always merges onto the real result,
  never a stale snapshot. `fun` runs inside `Repo.transaction/1` ONLY when
  there is not already one open (nesting a lock acquire in an EXISTING
  caller-held transaction extends its scope rather than opening a redundant
  one Ecto would need to roll back separately).
  """

  alias Barkpark.Content.Broadcast
  alias Barkpark.Content.DraftId
  alias Barkpark.Repo

  # Two-key form so this never shares a lock class with the single-key
  # audit-chain locks elsewhere in the write path.
  @lock_class 0x7061

  @doc """
  Run `fun` with the per-document advisory lock held. `id` is any id naming
  the document (bare published or `drafts.`-prefixed — normalized to the
  published id so both name the same lock). `opts` reads `:workspace_id`.
  A non-binary `id` runs `fun` unlocked (nothing to key the lock on).
  """
  @spec with_lock(String.t() | nil, String.t(), keyword(), (-> result)) :: result
        when result: term()
  def with_lock(id, dataset, opts, fun) when is_binary(id) and is_function(fun, 0) do
    if Repo.in_transaction?() do
      acquire(id, dataset, opts)
      fun.()
    else
      # Claims the deferred broadcast/webhook queue BEFORE the transaction
      # opens and flushes it after a commit (`Broadcast.with_deferred_queue/1`
      # — the documented pattern for exactly this shape: a caller opening its
      # OWN `Repo.transaction` around a write that defers broadcasts via the
      # nested `Broadcast.write_atomically/1` inside `Content.upsert_document`).
      # Without it every broadcast/webhook this write would have fired is
      # silently lost (logged as `deferred_broadcast_orphan`).
      Broadcast.with_deferred_queue(fn ->
        Repo.transaction(fn ->
          acquire(id, dataset, opts)
          fun.()
        end)
      end)
      |> unwrap_transaction_result()
    end
  end

  def with_lock(_id, _dataset, _opts, fun) when is_function(fun, 0), do: fun.()

  defp acquire(id, dataset, opts) do
    key =
      :erlang.crc32("#{Keyword.get(opts, :workspace_id)}:#{dataset}:#{DraftId.published_id(id)}") -
        2_147_483_648

    Repo.query!("SELECT pg_advisory_xact_lock($1::int, $2::int)", [@lock_class, key])
    :ok
  end

  # `Repo.transaction/1` wraps a non-:ok/:error return as `{:ok, value}`; a
  # caller here never rolls back explicitly, so unwrap unconditionally. Kept
  # OUTSIDE `with_deferred_queue`'s own fun so its flush/clear decision still
  # sees the RAW `{:ok, value} | {:error, reason}` that `Repo.transaction/1`
  # produces, not whatever shape `fun` itself returned.
  defp unwrap_transaction_result({:ok, result}), do: result
end
