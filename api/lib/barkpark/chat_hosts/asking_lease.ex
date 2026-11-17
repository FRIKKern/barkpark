defmodule Barkpark.ChatHosts.AskingLease do
  @moduledoc """
  Names the run that asked an approval on the answer leased to its host
  (task-754fd6f9a890e75e).

  An answer was leased with only the session id and the approval id
  (`Runtime.answer_approval/4`), and the Go host routes it by session to its
  one active run. An answer to run A's ask, sent after run B took the session
  (the ask is claimed, then a newer turn displaces it before the answer is
  leased), reached B: Claude refused it as unknown and the failure's close
  ended B's turn; Codex numbers asks per process, so B's own ask with that id
  took A's decision.

  The asking run is the lease whose `approval_requested` event carried the
  approval id. That event is stored before the ask is projected, so it is
  always there by the time anyone can answer. The answer carries the lease id
  as `payload.asked_lease_id`, and the host delivers it only to the run of
  that lease (internal/chathost/answer_lease.go). A host older than this
  ignores the field and answers as before.

  Two runs of one session can ask under one id (Codex). The newest ask is the
  one named, which is the row `ApprovalAnswer` claims
  (`StudioChat.get_needs_you_message/2` takes the newest by seq).
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease}
  alias Barkpark.Repo
  alias Barkpark.StudioChat.Runtime.Command

  @doc "Puts the asking lease on an answer's payload; any other command is returned as it is."
  @spec stamp(map(), Command.t()) :: Command.t()
  def stamp(host, %Command{operation: :answer_approval, payload: payload} = command)
      when is_map(payload) do
    case find(host, command.session_id, command.approval_id) do
      nil -> command
      lease_id -> %{command | payload: Map.put(payload, :asked_lease_id, lease_id)}
    end
  end

  def stamp(_host, command), do: command

  @doc "The id of the lease whose run asked `approval_id` in the session, or nil."
  @spec find(map(), term(), term()) :: String.t() | nil
  def find(host, session_id, approval_id) when is_binary(approval_id) do
    with workspace_id when is_binary(workspace_id) <- field(host, :workspace_id),
         {:ok, session_id} <- Ecto.UUID.cast(session_id) do
      from(e in ExecutionEvent,
        join: l in ExecutionLease,
        on: l.id == e.lease_id,
        where: l.workspace_id == ^workspace_id and l.session_id == ^session_id,
        where: e.kind == "approval_requested",
        where: fragment("?->>'approval_id' = ?", e.payload, ^approval_id),
        order_by: [desc: e.inserted_at],
        limit: 1,
        select: e.lease_id
      )
      |> Repo.one()
    else
      _ -> nil
    end
  end

  def find(_host, _session_id, _approval_id), do: nil

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
