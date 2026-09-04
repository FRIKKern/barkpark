defmodule Barkpark.Plugins.Media.MediaDeleteSavepointReproductionTest do
  @moduledoc """
  task-1116dcb208496fc7 criterion 0 — REPRODUCE the #15827 prod 500, and name
  why `mix test` could not see it.

  ## The failure, mechanically

  PR #15827 (f5de14bdcc) wrapped `Media.delete_file/2`'s two DB deletes in

      Repo.transaction(fn -> ... end, mode: :savepoint)

  and matched only `{:ok, _}`, `{:error, {:row, cs}}`, `{:error, {:asset_doc, r}}`.
  On guerrilla EVERY `DELETE /v1/media/production/<id>` then answered 500
  (request_id GNHlOfn4otoBOqYAACoR):

      (DBConnection.TransactionError) transaction is not started
      (CaseClauseError) no case clause matching: {:error, :rollback}
        lib/barkpark/media.ex:680 Barkpark.Media.delete_file/2

  The chain, every link in a dependency this repo vendors:

    1. `Ecto.Adapters.SQL.checkout_or_transaction/4` passes the pool (NOT a
       checked-out conn) when the caller is not already in a transaction, so
       `DBConnection.transaction/3` takes its `begin/3` path.
    2. `Postgrex.Protocol.handle_begin/2` has exactly one `:savepoint` clause —
       `:savepoint when postgres == :transaction` → `SAVEPOINT postgrex_savepoint`.
       On an `:idle` connection that clause does not match, and the catch-all
       `mode when mode in [:transaction, :savepoint] -> {postgres, s}` returns
       the STATUS `:idle`.
    3. `DBConnection.run_begin/3` maps a returned status to
       `status_disconnect/3` → `%DBConnection.TransactionError{status: :idle,
       message: "transaction is not started"}`, and DISCONNECTS the connection.
    4. `DBConnection.transaction/3`'s `rollback_or_raise/1` turns that
       `TransactionError` into the literal `{:error, :rollback}` — the tuple
       #15827's `case` had no clause for.

  So it is NOT a nested `Repo.rollback` from
  `Content.Lifecycle.do_delete_document/4`, which is what the task row's
  hypothesis named. That inner rollback IS real (arm 3 below pins it), but it
  never got the chance to fire: `mode: :savepoint` at the TOP level fails at
  BEGIN, before the delete transaction body runs at all — which is also why
  prod deleted NOTHING and failed on every single request, not just on
  contended documents.

  ## Why CI was green (the criterion's second half)

  `Ecto.Adapters.SQL.Sandbox` issues a `BEGIN` on the checked-out connection and
  never commits it. So under `mix test` the Postgrex `postgres` state is
  `:transaction`, step 2's `:savepoint when postgres == :transaction` clause
  matches, a real `SAVEPOINT postgrex_savepoint` is issued, and the call
  SUCCEEDS. The failing clause is simply unreachable from a sandboxed test — the
  first test below states exactly that, as behaviour.

  Two traps worth naming, because both look like the mask and are not:

    * `Repo.in_transaction?/0` answers FALSE in a sandboxed test body. It reads
      the process dictionary, which only `Repo.transaction/2` populates; the
      sandbox hands out its connection through the ownership pool instead. Do
      not use it as the premise for "we are inside a transaction here".
    * `DBConnection.transaction/3`'s first clause matches
      `%DBConnection{conn_mode: :transaction}` and takes `_opts` — it IGNORES
      `:mode` entirely. That is a genuine code fact about a call nested inside
      an explicit `Repo.transaction`, and it means #15827's "the failure is
      local to this file" claim was untrue there too. It is NOT what the sandbox
      does, though: the sandbox path goes through `begin/3` and issues a real
      savepoint.

  `Sandbox.unboxed_run/2` is the instrument that removes the mask: it hands a
  fresh process a connection with NO ambient transaction — the same `:idle`
  state a Phoenix request handler holds on prod.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @dataset "production"

  describe "the MASK: the Ecto SQL sandbox is why mix test could not see it" do
    test "inside the sandbox the SAME call succeeds — that is the whole mask" do
      # NOT an assertion about `Repo.in_transaction?/0`: that reads the PROCESS
      # DICTIONARY, which only `Repo.transaction/2` populates, so it answers
      # false in a sandboxed test body even though the checked-out connection is
      # sitting inside an open BEGIN. The mask lives one layer down, in
      # Postgrex.Protocol's `postgres` connection state: the sandbox's BEGIN puts
      # it at `:transaction`, so `handle_begin/2`'s
      # `:savepoint when postgres == :transaction` clause matches and issues a
      # real SAVEPOINT.
      #
      # This assertion IS the mask, stated as behaviour: the exact call that
      # 500'd every prod delete returns {:ok, _} here.
      assert Repo.transaction(fn -> :ran_under_sandbox end, mode: :savepoint) ==
               {:ok, :ran_under_sandbox},
             "the sandbox connection is supposed to be mid-BEGIN, which is what makes " <>
               "mode: :savepoint appear to work under mix test"
    end
  end

  describe "the REPRODUCTION: outside the sandbox, mode: :savepoint IS the 500" do
    test "a top-level Repo.transaction(mode: :savepoint) answers {:error, :rollback}" do
      {savepoint_result, plain_result} =
        unboxed(fn ->
          # THE PROD SHAPE. #15827 called exactly this, from a connection in
          # exactly this state, on every DELETE /v1/media/:dataset/:id.
          savepoint_result = Repo.transaction(fn -> :never_reached end, mode: :savepoint)

          # The SAME call without the option is fine — isolating the option as
          # the cause rather than "transactions are broken unboxed".
          plain_result = Repo.transaction(fn -> :ran end)

          {savepoint_result, plain_result}
        end)

      assert savepoint_result == {:error, :rollback},
             "expected the #15827 prod failure — DBConnection.rollback_or_raise/1 turning " <>
               "%DBConnection.TransactionError{status: :idle, message: \"transaction is " <>
               "not started\"} into {:error, :rollback} — got #{inspect(savepoint_result)}"

      assert plain_result == {:ok, :ran},
             "a plain top-level transaction must still work; if this reds, the failure " <>
               "above is not about mode: :savepoint at all"
    end

    test "DETECTOR: delete_file/2 succeeds on an :idle connection (red with the #15827 shape)" do
      # THIS is the mutation detector for the fix. Re-apply f5de14bdcc's
      # `Repo.transaction(fn -> ... end, mode: :savepoint)` in
      # `Media.delete_row_with_asset_doc/1` and this test reds with
      # {:error, :rollback} (or, with #15827's exact `case`, a CaseClauseError)
      # while every sandboxed test in the media suite stays green — which is
      # precisely the CI/prod split that shipped the incident.
      id = unboxed(fn -> insert_unboxed_blob!() end)

      try do
        result = unboxed(fn -> Media.delete_file(id) end)

        assert match?({:ok, %MediaFile{}}, result),
               "delete_file/2 on an :idle connection answered #{inspect(result)}; " <>
                 "{:error, :rollback} here IS the prod 500 (an unmatched tuple upstream)"

        assert unboxed(fn -> Media.get_file(id) end) == {:error, :not_found}
      after
        # Belt and braces: unboxed writes are NOT rolled back with the test.
        unboxed(fn -> Repo.delete_all(from m in MediaFile, where: m.id == ^id) end)
      end
    end
  end

  # Run `fun` in a FRESH process holding a connection outside the sandbox
  # transaction. A fresh process is required: this test's own process already
  # owns a sandboxed connection, and `unboxed_run/2` checks one out itself.
  defp unboxed(fun) do
    Task.async(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end)
    |> Task.await(30_000)
  end

  defp insert_unboxed_blob!() do
    unique = System.unique_integer([:positive])

    {:ok, file} =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: "sp-repro-#{unique}.png",
        original_name: "sp-repro-#{unique}.png",
        path: "sp-repro-#{unique}.png",
        mime_type: "image/png",
        size: 12,
        dataset: @dataset
      })
      |> Repo.insert()

    file.id
  end
end
