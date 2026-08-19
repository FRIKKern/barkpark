defmodule Barkpark.AuditSavepointClaimTest do
  @moduledoc """
  INVERSE TRIPWIRE. This test pins TODAY's behaviour, not a desired one.

  `Barkpark.Audit.emit/1` used to be documented as "safe to call inside an
  enclosing `Repo.transaction` — it opens a savepoint, so a failed emit rolls
  back only itself", and `Barkpark.Content.Broadcast`'s `emit_audit/6` carried
  the same sentence. Both were FALSE: Ecto opens no savepoint for a nested
  `Repo.transaction` — the inner call joins the enclosing one, and the
  `Repo.rollback/1` inside `emit/1` dooms the WHOLE transaction, taking the
  caller's write with it. `mode: :savepoint` is never passed.

  The code is deliberate — a failed audit row SHOULD be loud — so the sentences
  were corrected rather than the behaviour. This test locks the corrected
  sentences to the runtime: it asserts the enclosing transaction returns
  `{:error, :rollback}` and that its own rows do not survive.

  IF A FUTURE CHANGE PASSES `mode: :savepoint` (or otherwise makes a failed
  emit roll back only itself), THIS TEST SHOULD RED — that is the signal, not a
  regression. When it does, the corrected comments at `audit.ex`'s `emit/1` and
  `broadcast.ex`'s `emit_audit/6` must be rewritten in the same commit, or the
  repo is back to shipping a phantom warrant.

  Not covered here, deliberately: the non-sandboxed production connection. The
  sandbox already holds an outer transaction, so the enclosing
  `Repo.transaction` below is itself nested. The nesting rule under test is the
  same one the live mutate path hits, but this test does not prove it there.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Audit
  alias Barkpark.Repo

  @ws Ecto.UUID.generate()

  defp bad_emit(ws) do
    # `category` is validated by `Event.insert_changeset/1`, so this insert
    # fails the changeset and `emit/1` calls `Repo.rollback/1`. In production
    # the same arm is reached by `unique_index(:audit_events, [:hash])`.
    Audit.emit(%{category: "not-a-real-category", action: "x", workspace_id: ws})
  end

  describe "a failed emit inside an enclosing transaction" do
    test "aborts the ENCLOSING transaction — it does not roll back only itself" do
      result =
        Repo.transaction(fn ->
          {:ok, keeper} =
            Audit.emit(%{category: "auth", action: "login_succeeded", workspace_id: @ws})

          # The caller sees a plain `{:error, changeset}` here and may well log
          # and continue, exactly as `broadcast.ex`'s `emit_audit/6` does. That
          # rescue/log is decorative: the transaction is already doomed.
          {:error, %Ecto.Changeset{}} = bad_emit(@ws)

          keeper.id
        end)

      assert {:error, :rollback} = result
    end

    test "the enclosing transaction's own rows do not survive" do
      Repo.transaction(fn ->
        {:ok, _keeper} =
          Audit.emit(%{category: "auth", action: "login_succeeded", workspace_id: @ws})

        # Result deliberately unmatched: this test asserts on what SURVIVES,
        # so it stays meaningful even if emit's error shape changes.
        _ = bad_emit(@ws)
        :ok
      end)

      assert Audit.list_for_workspace(@ws) == []
    end
  end
end
