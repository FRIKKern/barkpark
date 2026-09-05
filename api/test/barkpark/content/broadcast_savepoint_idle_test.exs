defmodule Barkpark.Content.BroadcastSavepointIdleTest do
  @moduledoc """
  task-1b70b1121fa3faad criterion 1 — REPRODUCE the #15715 first-boot crash, on
  a REAL `:idle` connection, and name why `mix test` could not see it.

  ## The failure, mechanically

  PR #15715 (fb3b48450) changed `Content.Broadcast.save_revision/5` to

      |> Repo.insert(mode: :savepoint)

  and asserted in its own comment that "outside a transaction the option is
  inert". It is not. On an `:idle` connection `mode: :savepoint` falls through
  `Postgrex.Protocol.handle_begin/2`'s `:savepoint when postgres == :transaction`
  clause, the catch-all returns the STATUS `:idle`, `DBConnection.run_begin/3`
  turns that into `%DBConnection.TransactionError{message: "transaction is not
  started"}` and DISCONNECTS the connection. That is the IDENTICAL trap #15827
  shipped for `Media.delete_file/2` and #15874/#15895 reverted the same day —
  the full mechanical chain is recorded at `api/lib/barkpark/media.ex:621-646`
  and reproduced by `media_delete_savepoint_reproduction_test.exs`.

  On main it crashed the api container at FIRST BOOT (compose-smoke red since
  886b22001), on the seed path:

      Seeds.Clean.seed_welcome_paper/1
        -> Papers.BlockOps.persist_blocks_doc/9
        -> BlockOps.save_upsert_revision/5
        -> Content.Broadcast.save_revision/5   (broadcast.ex:515)
        -> ** (DBConnection.TransactionError) transaction is not started

  and it 500'd every paper save on any deployed box AFTER the document write had
  already committed — so `save_revision`'s own log-and-continue arm, the arm
  #15715 existed to protect, was never reached.

  ## Why CI was green

  `Ecto.Adapters.SQL.Sandbox` issues a `BEGIN` on the checked-out connection and
  never commits it, so under `mix test` the Postgrex `postgres` state is
  `:transaction`, the `:savepoint` clause matches, a real SAVEPOINT is issued,
  and the insert succeeds. Every sandboxed test in the suite stayed green while
  every real request raised.

  `Sandbox.unboxed_run/2` is the instrument that removes the mask: it hands a
  fresh process a connection with NO ambient transaction — the same `:idle`
  state the seed task and a Phoenix request handler hold on a real box.

  ## Cleanup

  Unboxed writes are NOT rolled back with the test. Every row this file creates
  is deleted in an `after` block, unboxed, by the slug it was created under.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Revision}
  alias Barkpark.LabelFixtures
  alias Barkpark.Repo

  @dataset "production"

  describe "the MASK: the Ecto SQL sandbox is why mix test could not see it" do
    test "inside the sandbox a mode: :savepoint write succeeds — that is the whole mask" do
      # NOT an assertion about `Repo.in_transaction?/0`: that reads the PROCESS
      # DICTIONARY, which only `Repo.transaction/2` populates, so it answers
      # false in a sandboxed test body even though the checked-out connection
      # is sitting inside an open BEGIN. The mask lives one layer down, in
      # Postgrex.Protocol's `postgres` connection state.
      refute Repo.in_transaction?(),
             "the sandbox does not populate the process dictionary — if this flips, the " <>
               "premise of the fix's in_transaction? guard has changed"

      assert Repo.transaction(fn -> :ran_under_sandbox end, mode: :savepoint) ==
               {:ok, :ran_under_sandbox},
             "the sandbox connection is supposed to be mid-BEGIN, which is what makes " <>
               "mode: :savepoint appear to work under mix test"
    end
  end

  describe "the REPRODUCTION: save_revision on an :idle connection" do
    test "DETECTOR: upsert_paper/2 succeeds unboxed and leaves a revision (red with the #15715 shape)" do
      # THIS is the mutation detector for the fix. Restore fb3b48450's
      # unconditional `Repo.insert(mode: :savepoint)` in
      # `Content.Broadcast.save_revision/5` and this test reds with
      # ** (DBConnection.TransactionError) transaction is not started
      # while every sandboxed test in `test/barkpark/content` stays green —
      # precisely the CI/prod split that took compose-smoke red.
      #
      # `upsert_paper/2` is the smallest PUBLIC caller that opens no
      # transaction: it is the same `BlockOps.persist_blocks_doc/9 ->
      # save_upsert_revision/5 -> save_revision/5` tail the first-boot seed
      # crashed on.
      slug = "savepoint-idle-#{System.unique_integer([:positive])}"

      # The fixture attrs are built INSIDE an unboxed block on purpose: building
      # them registers E3 tag rows, and a row written from this (sandboxed)
      # process is invisible to the unboxed connection that has to read it back.
      # It is a SEPARATE unboxed call from the upsert so that `tag_names` exists
      # for the cleanup below even when the upsert raises (which is exactly what
      # the unfixed code does).
      attrs =
        unboxed(fn ->
          LabelFixtures.paper_attrs(%{
            "slug" => slug,
            "dataset" => @dataset,
            "blocks" => blocks("Savepoint idle reproduction", "Real body content for the wall.")
          })
        end)

      tag_names = Enum.map(attrs["tags"], & &1["tag"])

      try do
        result = unboxed(fn -> Content.upsert_paper(attrs) end)

        assert match?({:ok, %Document{}}, result),
               "upsert_paper/2 on an :idle connection answered #{inspect(result)}"

        # The revision is the point: before the fix the document write committed
        # and THEN the revision insert raised, so a green document assertion
        # alone would not have caught it.
        assert unboxed(fn -> revision_count(slug) end) == 1,
               "save_revision/5 must land exactly one revision row for the paper birth"
      after
        # The `revisions` row this test proves EXISTS cannot be deleted: the
        # table carries an append-only trigger ("revision history is
        # append-only", P0001) and the document delete deliberately preserves
        # history (migration 20260719020200). Deleting the document is
        # therefore the whole cleanup — one orphaned revision row per run is
        # what append-only history costs, and it is scoped to a unique slug.
        unboxed(fn ->
          Repo.delete_all(
            from(d in Document,
              where: d.doc_id == ^slug and d.type == "paper" and d.dataset == @dataset
            )
          )

          Repo.delete_all(
            from(d in Document,
              where: d.doc_id in ^tag_names and d.type == "tag" and d.dataset == @dataset
            )
          )
        end)
      end
    end
  end

  defp revision_count(slug) do
    Repo.one(from(r in Revision, where: r.doc_id == ^slug, select: count(r.id)))
  end

  defp blocks(title, body) do
    [
      %{
        "id" => "tpl-title",
        "type" => "heading",
        "level" => 1,
        "role" => "title",
        "locked" => true,
        "text" => title
      },
      %{"id" => "p1", "type" => "paragraph", "content" => [%{"type" => "text", "value" => body}]}
    ]
  end

  # Run `fun` in a FRESH process holding a connection outside the sandbox
  # transaction. A fresh process is required: this test's own process already
  # owns a sandboxed connection, and `unboxed_run/2` checks one out itself.
  defp unboxed(fun) do
    Task.async(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end)
    |> Task.await(30_000)
  end
end
