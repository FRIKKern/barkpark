defmodule Barkpark.Plugins.Github.Cursor do
  @moduledoc """
  Durable per-dataset high-water mark for the OUTBOUND GitHub mirror.

  This is the at-least-once SOURCE for the outbound Barkpark→GitHub Issues
  mirror (epic D1/D2): it tracks the largest LOCAL `mutation_events.id` that the
  mirror has already consumed for a dataset. A wave-2 drain worker reads `get/1`,
  drains `id > cursor` task events from `Barkpark.Plugins.Github.Outbox`, enqueues
  a debounced per-task MirrorJob, and only then advances the cursor — never past
  an un-drained event on a transient failure (write-then-advance discipline).

  Storage REUSES the proven `sync_push_cursors` table (already keyed on an opaque
  `source` string) under the reserved source key `"github:outbound"`, so there is
  NO new migration and this cursor lives in the SAME monotonic-upsert machinery as
  `Barkpark.Sync.PushCursor`. The `sync_push_cursors` id-space (local
  `mutation_events.id`) is exactly what the mirror needs; the pull cursor's remote
  id-space is never mixed in.

  Structural copy of `Barkpark.Sync.PushCursor` — `put/4` is a MONOTONIC upsert
  (never rewinds, even under out-of-order calls) and `bootstrap_if_absent/3` seeds
  the cursor to the dataset head (`MAX(mutation_events.id)`) ONLY when no row
  exists, so first enable NEVER mass-mirrors the pre-enable backlog to GitHub.

  ## Workspace attribution (charter D55)

  `sync_push_cursors` gained a per-workspace `workspace_id` attribution column,
  but the outbound GitHub mirror is deliberately PER-DATASET, not per-workspace:
  one cursor tracks a dataset's `mutation_events` head across every workspace that
  shares the slug. So this cursor stamps `NULL` — its rows are workspace-agnostic
  mirror infrastructure and are NOT part of any single workspace's bundle or
  teardown (the FK cascade only removes rows whose `workspace_id` matches the
  deleted workspace). The `{source, dataset}` key is unchanged.
  """

  alias Barkpark.Sync.PushCursor

  @source "github:outbound"

  @doc "The reserved `sync_push_cursors.source` key for the outbound GitHub mirror."
  @spec source() :: String.t()
  def source, do: @source

  @doc "Current outbound-mirror high-water mark for `dataset`; 0 when none is stored."
  @spec get(String.t()) :: non_neg_integer()
  def get(dataset) when is_binary(dataset) do
    PushCursor.get(@source, dataset)
  end

  @doc """
  Monotonically advance the stored high-water mark for `dataset` to `event_id`.
  A no-op when the stored value is already `>= event_id` (delegates to the shared
  `PushCursor.put/3` monotonic upsert).
  """
  @spec put(String.t(), non_neg_integer()) :: :ok
  def put(dataset, event_id)
      when is_binary(dataset) and is_integer(event_id) and event_id >= 0 do
    # NULL workspace_id — the outbound mirror cursor is per-dataset, not per-workspace.
    PushCursor.put(nil, @source, dataset, event_id)
  end

  @doc """
  One-time, idempotent init of the outbound-mirror high-water mark for `dataset`
  to the dataset's current head (`MAX(mutation_events.id)`, 0 when empty) — ONLY
  when no cursor row exists. Skips ALL pre-enablement history so first enable
  never mass-mirrors the backlog to GitHub (no backlog flood). `on_conflict:
  :nothing` (inside `PushCursor.bootstrap_if_absent/2`) makes this a NO-OP once a
  row exists — it never rewinds an already-advanced cursor and is safe to call on
  every boot.

  NOTE: this deliberately delegates to `PushCursor.bootstrap_if_absent/2`, which
  seeds the head over ALL `mutation_events` in the dataset (any type), so a first
  enable cannot replay non-task history either. Steady-state post-enable loop-cut
  is handled by the Outbox `source != "github"` exclusion.
  """
  @spec bootstrap_if_absent(String.t()) :: :ok
  def bootstrap_if_absent(dataset) when is_binary(dataset) do
    # NULL workspace_id — the outbound mirror cursor is per-dataset, not per-workspace.
    PushCursor.bootstrap_if_absent(nil, @source, dataset)
  end
end
