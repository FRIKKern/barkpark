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

  A taken refusal now cancels the one ask the refused answer was for
  (`StudioChat.ApprovalAnswer.refused_by_host/2`). An approval id does not
  name one ask: Codex numbers asks per process, so two runs of a session ask
  under the same id (rev26739 on #26949). So the ask is found from the
  answer's own lease, never from the host's event:

    * the lease must be an answer lease for this approval id
      (`approval_id` and `asked_lease_id`, stored when it was leased,
      `answer_link/1`);
    * the ask is the needs-you row with that id stored after the asking
      lease's `approval_requested` event, and before any other lease asked
      under the same id. A row outside that window is another run's, and is
      left alone. No row in it (the asking run's ask was superseded and made
      no card) cancels nothing.

  It is read whether or not the event is projected: a refusal stored while a
  newer turn is open is superseded and never reaches the Recorder, and the
  ask must still not read "allowed".
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease}
  alias Barkpark.Repo
  alias Barkpark.StudioChat.ApprovalAnswer
  alias Barkpark.StudioChat.Message
  alias Barkpark.StudioChat.Runtime.Command

  @doc """
  The lease columns an approval answer carries: the approval it answers and
  the asking lease `AskingLease.stamp/2` put on its payload. Empty for any
  other command.
  """
  @spec answer_link(Command.t()) :: map()
  def answer_link(%Command{operation: :answer_approval, approval_id: id, payload: payload})
      when is_binary(id) and id != "" do
    %{approval_id: id, asked_lease_id: asked(payload)}
  end

  def answer_link(_command), do: %{}

  @doc "Cancels the ask a taken refusal is about; anything else is left alone."
  @spec settle(term(), String.t(), map()) :: :canceled | :unchanged | :ok
  def settle({:ok, taken}, lease_id, %{"kind" => "control_completed"} = event)
      when taken == :superseded or (is_tuple(taken) and elem(taken, 0) == :accepted) do
    with "answer_approval" <- event["operation"],
         refused when is_binary(refused) and refused != "" <- event["refused"],
         approval_id when is_binary(approval_id) and approval_id != "" <- event["approval_id"],
         %ExecutionLease{session_id: session_id, approval_id: ^approval_id, asked_lease_id: asked}
         when is_binary(session_id) and is_binary(asked) <- Repo.get(ExecutionLease, lease_id),
         %Message{} = ask <- asked_row(session_id, asked, approval_id) do
      ApprovalAnswer.refused_by_host(session_id, ask)
    else
      _ -> :ok
    end
  end

  def settle(_result, _lease_id, _event), do: :ok

  defp asked(%{asked_lease_id: id}) when is_binary(id), do: id
  defp asked(%{"asked_lease_id" => id}) when is_binary(id), do: id
  defp asked(_payload), do: nil

  defp asked_row(session_id, asked, approval_id) do
    with %DateTime{} = asked_at <- ask_time(session_id, approval_id, asked) do
      cutoff = next_ask_time(session_id, approval_id, asked, asked_at)

      from(m in Message,
        where: m.session_id == ^session_id and m.inserted_at > ^asked_at,
        where: fragment("?->>'request_id' = ?", m.metadata, ^approval_id),
        where: not is_nil(fragment("?->>'approval_status'", m.metadata)),
        order_by: [asc: m.seq],
        limit: 1
      )
      |> before(cutoff)
      |> Repo.one()
    end
  end

  defp before(query, nil), do: query
  defp before(query, cutoff), do: from(m in query, where: m.inserted_at < ^cutoff)

  # When the asking lease's run asked this id (its newest such ask).
  defp ask_time(session_id, approval_id, asked) do
    from([e, _l] in asks(session_id, approval_id),
      where: e.lease_id == ^asked,
      order_by: [desc: e.inserted_at],
      limit: 1,
      select: e.inserted_at
    )
    |> Repo.one()
  end

  # When another lease next asked under the same id, or nil.
  defp next_ask_time(session_id, approval_id, asked, asked_at) do
    from([e, _l] in asks(session_id, approval_id),
      where: e.lease_id != ^asked and e.inserted_at > ^asked_at,
      select: min(e.inserted_at)
    )
    |> Repo.one()
  end

  defp asks(session_id, approval_id) do
    from(e in ExecutionEvent,
      join: l in ExecutionLease,
      on: l.id == e.lease_id,
      where: l.session_id == ^session_id and e.kind == "approval_requested",
      where: fragment("?->>'approval_id' = ?", e.payload, ^approval_id)
    )
  end
end
