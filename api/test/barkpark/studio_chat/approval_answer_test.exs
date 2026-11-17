defmodule Barkpark.StudioChat.ApprovalAnswerTest do
  @moduledoc """
  `ApprovalAnswer.settle/4` against the two server cancels that land while an
  answer is being delivered (rev26731, #26895 review, probes C7 and C2). Both
  cancels touch only PENDING rows: `DisplacedAsks` through
  `update_approval_status/4` and teardown through `cancel_pending_approvals/1`.
  A cancel that lands during the delivery must stand, and a resend must not
  deliver.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.ApprovalAnswer

  @rid "req-1"

  setup do
    {:ok, session} = StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: "/tmp/x"})

    {:ok, _} =
      StudioChat.append_message(session, %{
        role: "approval",
        source_markdown: "Allow Write /tmp/example?",
        metadata: %{"request_id" => @rid, "tool_name" => "Write", "approval_status" => "pending"}
      })

    %{sid: session.id}
  end

  # C7: a newer lease's turn displaces the ask while its answer is in flight,
  # and the delivery then fails.
  test "a displacing cancel during a failed delivery stands, and a resend delivers nothing",
       %{sid: sid} do
    outcome =
      ApprovalAnswer.settle(sid, @rid, "allowed", fn ->
        StudioChat.update_approval_status(sid, @rid, "canceled", %{
          "cancel_reason" => "superseded_by_newer_turn"
        })

        {:error, :enqueue_failed}
      end)

    assert outcome == {:error, :enqueue_failed}
    assert status(sid) == "canceled", "a cancel that landed during the delivery must stand"
    assert StudioChat.get_session(sid).pending_approvals == 0

    assert {:refused, "canceled"} = ApprovalAnswer.settle(sid, @rid, "allowed", &delivered/0)
    refute_received :delivered
  end

  # C2/C3: the runtime dies, so teardown cancels every pending ask and the
  # delivery exits.
  test "a teardown cancel during a delivery that exits stands, and a resend delivers nothing",
       %{sid: sid} do
    outcome =
      ApprovalAnswer.settle(sid, @rid, "allowed", fn ->
        StudioChat.cancel_pending_approvals(sid)
        exit(:noproc)
      end)

    assert outcome == {:error, {:exit, :noproc}}
    assert status(sid) == "canceled"
    assert StudioChat.get_session(sid).pending_approvals == 0

    assert {:refused, "canceled"} = ApprovalAnswer.settle(sid, @rid, "allowed", nil)
    assert {:refused, "canceled"} = ApprovalAnswer.settle(sid, @rid, "allowed", &delivered/0)
    refute_received :delivered
  end

  # Two answers at once deliver once: the second finds the ask claimed.
  test "an answer sent while another is being delivered is not delivered", %{sid: sid} do
    outcome =
      ApprovalAnswer.settle(sid, @rid, "allowed", fn ->
        send(self(), {:inner, ApprovalAnswer.settle(sid, @rid, "denied", &delivered/0)})
        :ok
      end)

    assert outcome == :delivered
    assert_received {:inner, :noop}
    refute_received :delivered
    assert status(sid) == "allowed"
  end

  test "a claim left by a delivery that never finished expires", %{sid: sid} do
    stale = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
    put_meta!(sid, %{"answer_claimed_at" => stale})

    assert ApprovalAnswer.settle(sid, @rid, "allowed", &delivered/0) == :delivered
    assert_received :delivered
    assert status(sid) == "allowed"
  end

  test "a claim still in flight is not taken over", %{sid: sid} do
    put_meta!(sid, %{"answer_claimed_at" => DateTime.to_iso8601(DateTime.utc_now())})

    assert ApprovalAnswer.settle(sid, @rid, "allowed", &delivered/0) == :noop
    refute_received :delivered
    assert status(sid) == "pending"
  end

  defp delivered do
    send(self(), :delivered)
    :ok
  end

  defp status(sid), do: StudioChat.get_needs_you_message(sid, @rid).metadata["approval_status"]

  defp put_meta!(sid, extra) do
    row = StudioChat.get_needs_you_message(sid, @rid)
    row |> Ecto.Changeset.change(metadata: Map.merge(row.metadata, extra)) |> Repo.update!()
  end
end
