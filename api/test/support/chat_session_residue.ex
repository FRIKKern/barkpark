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
       `archived_at IS NULL` on every default listing, so pinned residue is kept
       off the ACTIVE shelf — the sidebar, cap and recency assertions that read
       the default listing — while both ledgers stay at FULL STRENGTH against a
       real direct DELETE.

  ## What step 2 does NOT do — the ARCHIVED shelf

  Archiving is not disappearing. `list_sessions(archived: true, …)` is the same
  query with `archived_filter/2` inverted (`studio_chat.ex:298-299`), and the
  flat `/studio/chat` mount lists `:global` with its tenancy clamp deliberately
  open (`chat_live.ex:5290-5294`, `5376-5383`). So step 2 does not remove pinned
  residue from view — it MOVES it onto the archived shelf, which is the one
  shelf two tests assert the exact contents of:

    * `chat_key_jump_palette_test.exs` — `visible_ids(view) == [gamma]` after
      `toggle-archived`.
    * `chat_live_test.exs` — "the empty archived shelf teaches instead of
      showing nothing" (`assert html =~ "No archived chats"`).

  This sentence used to read "pinned residue can never reach a later test's
  sidebar, cap, or recency assertions again", full stop. That was false for the
  archived shelf, and it is why five suites believed themselves protected while
  those two reproducibly red on any box carrying a pinned row
  (spd-w19r-live-studio-suite-flake: 6/6 red on the shared `barkpark_test`,
  20/20 green at the same seeds under `MIX_TEST_PARTITION`).

  A pinned row can be neither deleted nor unpinned from test code — the FK is
  `ON DELETE RESTRICT` and the ledger trigger fires `BEFORE DELETE OR UPDATE` —
  so there is no purge that fixes this. The REMEDY IS ENVIRONMENTAL: run against
  a private database (`MIX_TEST_PARTITION=<name> mix test …`). What this module
  can do is make the cause SELF-DESCRIBING rather than a list diff, which is
  `assert_archived_shelf_clean!/0` below.
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

  @doc """
  The ids `purge!/0` could not delete: sessions pinned by a RESTRICT child.

  Read AFTER `purge!/0` in the same transaction, this is exactly the set that is
  now sitting on the archived shelf.
  """
  @spec pinned_ids() :: [binary()]
  def pinned_ids do
    Repo.all(from(s in Session, where: ^pinned(), select: s.id))
  end

  @doc """
  Fail with a NAMED cause when pinned residue would contaminate an
  archived-shelf assertion.

  Call this immediately before an assertion that reads
  `list_sessions(archived: true, …)` for its exact contents. Without it the test
  reds as an unexplained list diff — two foreign UUIDs against one expected id —
  and the last three readers of that diff all spent their time looking at the
  test instead of at the database (spd-w19r-live-studio-suite-flake).

  `purge!/0` is NOT the place for this check. `runtime_usage_test.exs` is the
  helper's own control: it MANUFACTURES a pinned session and then asserts
  `:ok = purge!()` with the row archived and both ledgers intact. A `purge!/0`
  that raised on surviving pinned residue would red that control on every box,
  CI included — the pin is the thing it exists to exercise.
  """
  @spec assert_archived_shelf_clean!() :: :ok
  def assert_archived_shelf_clean! do
    case pinned_ids() do
      [] ->
        :ok

      ids ->
        raise """
        COMMITTED chat_sessions RESIDUE — this database cannot support an \
        archived-shelf assertion.

        #{length(ids)} session(s) are pinned by an append-only ledger \
        (epic_assignment_runtime_attempts / chat_runtime_usage_receipts), so \
        `ChatSessionResidue.purge!/0` could neither delete nor unpin them and \
        ARCHIVED them instead. They are now on the archived shelf that the \
        assertion below reads, and they will out-number your fixtures there:

        #{Enum.map_join(ids, "\n", &("  " <> &1))}

        This is NOT a defect in the code under test and NOT an order- or \
        load-dependent flake. The rows were committed by \
        `Sandbox.unboxed_run/2` on an earlier run on this box and no fix can \
        un-commit them: the FK is ON DELETE RESTRICT and the ledger trigger \
        fires BEFORE DELETE OR UPDATE.

        THE REMEDY IS A PRIVATE DATABASE:

            MIX_TEST_PARTITION=<yourname> mix test test/barkpark_web/live/studio/

        (config/test.exs:16 appends it to the database name; every agent on a \
        shared box otherwise shares one `barkpark_test`.)
        """
    end
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

  # The complement, written out rather than `not (^unpinned())`: Ecto interpolates
  # a dynamic only at the TOP level of a `where`, so negating one inline raises
  # `Ecto.QueryError` at runtime — proven by run, not assumed.
  defp pinned do
    dynamic(
      [s],
      fragment(
        "EXISTS (SELECT 1 FROM epic_assignment_runtime_attempts a WHERE a.session_id = ?)",
        s.id
      ) or
        fragment(
          "EXISTS (SELECT 1 FROM chat_runtime_usage_receipts r WHERE r.session_id = ?)",
          s.id
        )
    )
  end
end
