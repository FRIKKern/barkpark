defmodule Barkpark.ChatSessionResidue do
  @moduledoc """
  Clear COMMITTED `chat_sessions` residue from a shared test database WITHOUT
  ever issuing a DELETE against an append-only ledger.

  ## Why residue exists at all

  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` COMMITS — that is its point: a lock
  ordering test needs two real Postgres connections that actually block each
  other, which one sandbox transaction cannot express. Every row such a drive
  writes therefore OUTLIVES the test. `CycleFleet.prepare_runtime_attempt/3`
  mints a `chat_sessions` row for the attempt, and `Tenancy.delete_workspace/1`
  does NOT reach it: `chat_sessions.owner_workspace_id` carries no foreign key,
  so the workspace teardown leaves the session behind. A committed session
  escapes every LATER test's sandbox rollback and rides `list_sessions/2`'s
  recency-desc ordering ahead of that test's own pinned fixtures.

  The leak's SOURCE is closed in `runtime_usage_test.exs`, which now purges its
  own committed residue after the workspace teardown. This module exists for the
  residue ALREADY COMMITTED on a long-lived developer box — rows no fix can
  retroactively un-commit.

  ## Why this is not just `Repo.delete_all(Session)`

  Two children of `chat_sessions` are append-only ledgers whose DB triggers raise
  on any direct DELETE, and BOTH hold an `ON DELETE RESTRICT` foreign key to
  `chat_sessions`:

    * `epic_assignment_runtime_attempts` (`barkpark_epic_ledger_immutable`)
    * `chat_runtime_usage_receipts` (`barkpark_runtime_usage_receipts_immutable`)

  So a session pinned by either child can be neither deleted nor unpinned from
  test code. The five studio-chat setups used to clear the children first with
  two unqualified table-wide DELETEs each — ten armed statements that pass
  SILENTLY while the tables are empty (a FOR EACH ROW trigger cannot fire on
  zero rows) and raise the moment either holds a single row.

  This module does the same job with no DELETE against either ledger:

    1. DELETE the sessions that nothing pins (the overwhelming majority; their
       `on_delete: :delete_all` children — messages, telemetry, leases — go with
       them).
    2. ARCHIVE whatever survives. `list_sessions/2` and `rollup/1` filter
       `archived_at IS NULL` on every default listing, so pinned residue can
       never reach a later test's sidebar, cap, or recency assertions again
       while both ledgers stay at FULL STRENGTH against a real direct DELETE.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.StudioChat.Session

  @doc """
  Clear every `chat_sessions` row visible to the caller: delete the unpinned
  ones, archive the rest. Returns `:ok`.

  Safe to call from a sandboxed `setup` block — the writes run inside the test's
  transaction and roll back with it.
  """
  @spec purge!() :: :ok
  def purge! do
    Repo.delete_all(from(s in Session, where: ^unpinned()))

    Repo.update_all(
      from(s in Session, where: is_nil(s.archived_at)),
      set: [archived_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    :ok
  end

  # NOT EXISTS against both RESTRICT children, as a dynamic so the two fragments
  # stay adjacent to the tables they name.
  defp unpinned do
    dynamic(
      [s],
      fragment(
        "NOT EXISTS (SELECT 1 FROM epic_assignment_runtime_attempts a WHERE a.session_id = ?)",
        s.id
      ) and
        fragment(
          "NOT EXISTS (SELECT 1 FROM chat_runtime_usage_receipts r WHERE r.session_id = ?)",
          s.id
        )
    )
  end
end
