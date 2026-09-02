defmodule Barkpark.Content.PublishEventAtomicityTest do
  @moduledoc """
  [acrc-publish-atomicity-txn-boundary] The document write and its
  `mutation_events` row must land or fail TOGETHER on the writer single-write
  path and on the publish path.

  ## The hole

  `Broadcast.tap_broadcast/7` runs `save_revision` (non-fatal, logs) and
  `save_event` (`Repo.insert!` — RAISES) AFTER the document write has already
  landed:

    * `Writer.upsert_after_gate/6` and `Writer.create_after_dedup/6` pipe a bare
      `Repo.update` / `Repo.insert` straight into `tap_broadcast`, with NO
      surrounding transaction.
    * `Lifecycle.publish_document/4` CLOSES its `Repo.transaction` (the
      published upsert + the fenced draft delete) and only then calls
      `tap_broadcast` on the result — outside the boundary.

  In production those writes AUTO-COMMIT. A fault on the `mutation_events`
  insert then leaves a COMMITTED document with no event row: SSE, webhooks, the
  nextjs revalidate consumer and the push outbox never learn the write happened.
  The symptom is the ABSENCE of a symptom — nothing errors on the next request,
  nothing retries, and the write side cannot see the gap. `insert!` was chosen
  precisely so this aborts, and it only achieves that inside `apply_mutations`'
  own transaction (`mutations.ex`), never here.

  ## Why the assertion is "the document is not there"

  Every test runs inside the SQL sandbox's transaction, so nothing here really
  commits and "committed doc, missing event" cannot be read back from a second
  connection. What IS decisive is whether the doc write is FENCED OFF from the
  event fault on this connection: unfixed, the row is written outside any
  boundary the fault can undo, so it is still readable after the raise (and in
  production that same row is already committed). Fixed, the pair shares one
  `Repo.transaction` — a SAVEPOINT under the sandbox — so the fault rolls the
  document back with it and the read finds nothing.

  ## The fault, and why it is a `RETURN NULL` trigger and not a `RAISE`

  A `BEFORE INSERT` trigger on `mutation_events` that returns NULL: Postgres
  silently skips the row, Ecto sees `num_rows: 0` where it required one, and
  `Repo.insert!` raises `Ecto.StaleEntryError`. That is an ELIXIR-level
  exception with the Postgres transaction still healthy — exactly the shape of
  the production fault (a raise between the committed write and the derived
  rows), and the only shape this test can read afterwards.

  A `RAISE EXCEPTION` trigger was tried first and is NOT a usable instrument
  here: the Postgres error puts the connection in the aborted state, DBConnection
  tears it down, and the sandbox owner reconnects — which wipes rows the test
  itself created and made two of these four cases pass VACUOUSLY against the
  unfixed tree. Recorded so nobody re-derives it.

  Real DB fault injection, no production test hook and no mocking library (this
  repo carries neither `mox` nor `meck`). The trigger is created inside the
  test's own sandbox transaction, so it is invisible to every other test and
  rolled back at exit.

  `async: false`: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock on
  `mutation_events`, which sits on the write path of every document mutation in
  the suite. Serialising this file keeps that lock window short.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Repo

  @dataset "atomicity_test"

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Install the fault: from here on every INSERT into `mutation_events` on this
  # connection is skipped, and `save_event`'s `Repo.insert!` raises.
  defp break_mutation_events! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION bp_test_swallow_mutation_event() RETURNS trigger AS $fn$
    BEGIN
      RETURN NULL;
    END;
    $fn$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER bp_test_swallow_mutation_event_trg
    BEFORE INSERT ON mutation_events
    FOR EACH ROW EXECUTE FUNCTION bp_test_swallow_mutation_event()
    """)

    :ok
  end

  # EXACT id. Used wherever the test holds the doc_id the writer actually
  # returned, and for the published id on the publish path — where a dual-id
  # lookup would match the surviving DRAFT and quietly invert the assertion.
  defp fetch(doc_id, type),
    do: Repo.get_by(Document, doc_id: doc_id, type: type, dataset: @dataset)

  # "Did ANY row get written under this base id?" — for the birth cases, where
  # the write raised before returning an id and EITHER shape would be a failure.
  # `create_document`/`upsert_document` normalise a bare `_id` into the DRAFT id
  # (`drafts.<id>`), so a bare-id `get_by` answers `nil` for a row that is very
  # much there. That made two of these cases pass VACUOUSLY against the unfixed
  # tree until a probe printed the doc_id the writer actually wrote.
  defp any_row?(base_id, type) do
    Repo.exists?(
      from(d in Document,
        where:
          d.dataset == ^@dataset and d.type == ^type and
            d.doc_id in [^base_id, ^("drafts." <> base_id)]
      )
    )
  end

  describe "writer single-write path" do
    test "a save_event fault leaves NO document behind on create" do
      doc_id = unique_id("atomic-create")
      break_mutation_events!()

      assert_raise Ecto.StaleEntryError, fn ->
        Content.create_document("note", %{"_id" => doc_id, "title" => "T"}, @dataset)
      end

      refute any_row?(doc_id, "note"),
             "the document survived a failed mutation_event insert — in production it " <>
               "is already committed, and no consumer ever learns the write happened"
    end

    test "a save_event fault leaves NO document behind on upsert-create" do
      doc_id = unique_id("atomic-upsert")
      break_mutation_events!()

      assert_raise Ecto.StaleEntryError, fn ->
        Content.upsert_document("note", %{"_id" => doc_id, "title" => "T"}, @dataset)
      end

      refute any_row?(doc_id, "note")
    end

    test "a save_event fault does NOT advance an existing document on update" do
      doc_id = unique_id("atomic-update")

      {:ok, doc} =
        Content.create_document("note", %{"_id" => doc_id, "title" => "before"}, @dataset)

      break_mutation_events!()

      assert_raise Ecto.StaleEntryError, fn ->
        Content.upsert_document("note", %{"_id" => doc_id, "title" => "after"}, @dataset)
      end

      kept = fetch(doc.doc_id, "note")
      assert kept, "the pre-existing row vanished — the fault escaped its boundary"

      assert kept.title == "before" and kept.rev == doc.rev,
             "the update landed without its mutation_event"
    end
  end

  describe "save_revision stays non-fatal" do
    # The other half of the criterion, and the half a careless txn-wrap breaks.
    # `save_revision` deliberately LOGS a failed insert and lets the content
    # write stand — history is an audit artifact, and losing a valid write
    # because its snapshot could not be persisted is worse than a logged gap.
    # Putting that insert inside a transaction voids that promise unless it is
    # savepointed: an `{:error, changeset}` from a declared constraint poisons
    # the enclosing transaction, silently turning "keep the write" into "lose
    # the write". `Repo.insert(mode: :savepoint)` is what holds the line.
    #
    # The fault is the exact one `revision.ex` documents as reachable: a
    # `document_id` pointing at a row that is not there (a concurrently
    # hard-deleted scope). The declared `foreign_key_constraint(:document_id)`
    # turns the Postgres rejection into `{:error, changeset}` — the arm whose
    # non-fatality is under test.
    test "a revision FK fault is logged and the document write still lands" do
      doc_id = unique_id("atomic-revision")

      Repo.query!("""
      CREATE OR REPLACE FUNCTION bp_test_break_revision_fk() RETURNS trigger AS $fn$
      BEGIN
        NEW.document_id := '00000000-0000-0000-0000-0000000000ff'::uuid;
        RETURN NEW;
      END;
      $fn$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER bp_test_break_revision_fk_trg
      BEFORE INSERT ON revisions
      FOR EACH ROW EXECUTE FUNCTION bp_test_break_revision_fk()
      """)

      assert {:ok, doc} =
               Content.create_document("note", %{"_id" => doc_id, "title" => "T"}, @dataset)

      assert fetch(doc.doc_id, "note"),
             "a failed REVISION insert must not undo the content write"

      assert Repo.exists?(
               from(e in MutationEvent, where: e.doc_id == ^doc.doc_id and e.dataset == ^@dataset)
             ),
             "the mutation_event must still be written when only the revision failed"
    end
  end

  describe "publish path" do
    test "a save_event fault leaves the draft intact and nothing published" do
      pid = unique_id("atomic-publish")

      {:ok, draft} =
        Content.create_document(
          "note",
          %{"_id" => "drafts.#{pid}", "title" => "D", "status" => "draft"},
          @dataset
        )

      break_mutation_events!()

      assert_raise Ecto.StaleEntryError, fn ->
        Content.publish_document(pid, "note", @dataset)
      end

      refute fetch(pid, "note"),
             "a published row survived a failed mutation_event insert"

      kept = fetch(draft.doc_id, "note")

      assert kept && kept.rev == draft.rev,
             "the fenced draft delete committed while the publish event was lost"
    end
  end
end
