defmodule Barkpark.Tasks.LockKey do
  @moduledoc """
  THE ONE PLACE a task advisory-lock key is built.

  Every task lifecycle writer serializes on `pg_advisory_xact_lock(hashtext(K))`.
  The whole mutex is the STRING K: two writers that build K differently do not
  exclude each other, and nothing anywhere raises — the lock is simply taken on
  a different integer and both transactions proceed. That failure is silent by
  construction, which is why the key is a function and not a literal.

  ## The families

    * `task/1` — `"task:" <> uuid`, keyed on the document's UUID PRIMARY KEY.
      THIS IS THE CONVERGED FAMILY. Every writer that has already resolved the
      row takes it: close, release, move, stage, stamp, landed, fence,
      mutations, pulse, renew, the TTL sweeper, the compactor, the compaction
      restore, and the targeted claim (after it resolves).

    * `task_doc_id/1` — `"task:" <> doc_id`, keyed on the SLUG. The ONE
      legitimate use is the pre-resolution guard in
      `Barkpark.Tasks.Claim.claim_by_id/3`: before the row is fetched the uuid
      is not known yet, so two concurrent targeted claims for the same slug
      have nothing else to serialize on. It is a claim-vs-claim guard ONLY and
      excludes NOTHING in the `task/1` family — claim_by_id takes the `task/1`
      lock as well, immediately after it resolves the uuid and BEFORE it takes
      the `FOR UPDATE` row lock (advisory-before-row-lock, so a claim and a
      close cannot deadlock by acquiring the two in opposite orders).

    * `resources/0` — the global `--resources` overlap guard. Not per-task.

    * `listener/1` — `"listener:" <> logical_id`, the fleet listener beat. A
      DIFFERENT domain that happens to live under `Barkpark.Tasks`; it must
      never be confused for a task lock.

  ## Why the uuid and not the slug

  A slug is not unique across datasets (`documents` is unique on
  `(doc_id, type, dataset_id)`) and a draft twin carries a `drafts.` prefix, so
  `"task:" <> doc_id` can name TWO rows or MISS the row a sibling writer holds.
  The uuid is the primary key: one row, one key, no prefix.

  ## The tripwire

  `test/barkpark/tasks/advisory_lock_key_convergence_test.exs` enumerates every
  `pg_advisory_xact_lock` call site under `lib/barkpark/tasks` and refuses any
  whose key argument is not one of these functions. Inlining `"task:\#{id}"` at
  a call site reds it by file and line.
  """

  @task_prefix "task:"

  @doc """
  The converged per-task key: `"task:" <> uuid`, for any writer that has
  already resolved the document's UUID primary key.
  """
  @spec task(binary()) :: binary()
  def task(uuid) when is_binary(uuid), do: @task_prefix <> uuid

  @doc """
  The pre-resolution claim guard: `"task:" <> doc_id` on the SLUG.

  Only `Claim.claim_by_id/3` may use this, and only BEFORE it knows the uuid.
  It serializes claim-vs-claim; it does NOT serialize against `task/1`.
  """
  @spec task_doc_id(binary()) :: binary()
  def task_doc_id(doc_id) when is_binary(doc_id), do: @task_prefix <> doc_id

  @doc "The global resource-overlap guard for `--resources` claims."
  @spec resources() :: binary()
  def resources, do: "task-resources"

  @doc "The fleet listener beat key — a different domain from the task family."
  @spec listener(binary()) :: binary()
  def listener(logical_id) when is_binary(logical_id), do: "listener:" <> logical_id
end
