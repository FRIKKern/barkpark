defmodule Barkpark.ChatHosts.RefusedAnswer do
  @moduledoc """
  Reads the Go host's refusal of an approval answer (task-746c02d760f26ce7).

  Since #26925 the host delivers an answer only to the run that asked it, and
  acknowledges any other as `control_completed` with a `refused` reason and
  the `approval_id` (internal/chathost/answer_lease.go). The server took that
  ack like a delivered one: the Recorder's `control_completed` arm is a no-op.
  When the answer had already flipped the ask to "allowed" (it flips before
  the displacing turn's first event cancels it), the card read "allowed"
  although the answer reached no run.

  A taken refusal now cancels the stored ask
  (`StudioChat.ApprovalAnswer.refused_by_host/2`). It is read whether or not
  the event is projected: a refusal stored while a newer turn is open is
  superseded and never reaches the Recorder, and the ask must still not read
  "allowed".
  """

  alias Barkpark.ChatHosts.ExecutionLease
  alias Barkpark.Repo
  alias Barkpark.StudioChat.ApprovalAnswer

  @doc "Cancels the ask a taken refusal names; anything else is left alone."
  @spec settle(term(), String.t(), map()) :: :canceled | :unchanged | :ok
  def settle({:ok, taken}, lease_id, %{"kind" => "control_completed"} = event)
      when taken == :superseded or (is_tuple(taken) and elem(taken, 0) == :accepted) do
    with "answer_approval" <- event["operation"],
         refused when is_binary(refused) and refused != "" <- event["refused"],
         approval_id when is_binary(approval_id) and approval_id != "" <- event["approval_id"],
         %ExecutionLease{session_id: session_id} when is_binary(session_id) <-
           Repo.get(ExecutionLease, lease_id) do
      ApprovalAnswer.refused_by_host(session_id, approval_id)
    else
      _ -> :ok
    end
  end

  def settle(_result, _lease_id, _event), do: :ok
end
