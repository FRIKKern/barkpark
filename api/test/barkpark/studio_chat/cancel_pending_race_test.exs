defmodule Barkpark.StudioChat.CancelPendingRaceTest do
  @moduledoc """
  `StudioChat.cancel_pending_approvals/1` against an answer or a new ask that
  commits while the cancel runs (task-52de5429fbdcb68c, rev26731's probe R1).

  The sandbox puts every process on ONE connection, so these run
  `unboxed_run` on real connections and remove their rows themselves. A holder
  connection writes first and keeps its transaction open, so the cancel is
  provably waiting on its row lock before the holder commits.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.LockWaiter
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Message, Session}

  # R1: the cancel read the ask as pending with no lock, the answer committed,
  # and the cancel then wrote "canceled" over the answer by id.
  test "a cancel waiting on an answer that commits leaves the answer standing" do
    with_session(fn sid ->
      ask!(sid, "r1")
      holder = hold(fn -> {:ok, _} = StudioChat.update_approval_status(sid, "r1", "allowed") end)
      {cancel, backend} = LockWaiter.start(fn -> StudioChat.cancel_pending_approvals(sid) end)

      LockWaiter.await_lock!(backend)
      release(holder)

      assert Task.await(cancel, 10_000) == 0, "the answered ask is not the cancel's to cancel"
      assert status(sid, "r1") == "allowed"
      assert StudioChat.get_session(sid).pending_approvals == 0
    end)
  end

  # The cancel set the count to 0, so an ask that arrived while it ran was
  # counted out while its row stayed pending.
  test "a cancel lowers the count only by the asks it canceled" do
    with_session(fn sid ->
      ask!(sid, "old")
      holder = hold(fn -> ask!(sid, "new") end)
      {cancel, backend} = LockWaiter.start(fn -> StudioChat.cancel_pending_approvals(sid) end)

      LockWaiter.await_lock!(backend)
      release(holder)

      assert Task.await(cancel, 10_000) == 1
      assert status(sid, "old") == "canceled"
      assert status(sid, "new") == "pending"
      assert StudioChat.get_session(sid).pending_approvals == 1
    end)
  end

  defp ask!(sid, request_id) do
    {:ok, _} =
      StudioChat.append_message(sid, %{
        role: "approval",
        source_markdown: "Allow Write?",
        metadata: %{"request_id" => request_id, "approval_status" => "pending"}
      })
  end

  defp status(sid, request_id),
    do: StudioChat.get_needs_you_message(sid, request_id).metadata["approval_status"]

  defp with_session(fun) do
    unboxed(fn ->
      {:ok, session} = StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: "/tmp/x"})

      try do
        fun.(session.id)
      after
        Repo.delete_all(from m in Message, where: m.session_id == ^session.id)
        Repo.delete_all(from s in Session, where: s.id == ^session.id)
      end
    end)
  end

  defp hold(take) do
    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            take.()
            send(parent, :held)

            receive do
              :release -> :ok
            after
              10_000 -> :timeout
            end
          end)
        end)
      end)

    assert_receive :held, 5_000
    holder
  end

  defp release(holder) do
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
