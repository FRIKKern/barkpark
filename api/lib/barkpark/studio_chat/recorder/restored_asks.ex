defmodule Barkpark.StudioChat.Recorder.RestoredAsks do
  @moduledoc """
  Rebuilds the Recorder's pending asks, and the turn that asked them, from the
  store when a Recorder starts (task-442a665f443e38a8, rev26735 on #26941).

  A Recorder that restarts (a crash, an idle reap) begins with no tracked
  `pending_asks` and no turn owner. When the asking run later closes its own
  turn, `DisplacedAsks.cancel_ended/1` finds nothing to cancel, and the ask
  stays "pending" in the store: a live card for a turn that has ended.

  So, before the Recorder replays the events it missed:

    * `pending_asks` is the session's stored asks that are still "pending";
    * the owner (`runtime_lease`) is the newest lease that asked one of them,
      and its turn counts as open, as it was when that lease asked.

  The owner keeps `TurnOwner` working across the restart: the owner's own
  close cancels its asks (turn_ended), a refused newer send_turn's close leaves
  them pending (#26941), and a newer lease's turn displaces them
  (superseded_by_newer_turn). A session with no lease (a managed runtime) gets
  its pending asks back and no owner.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease}
  alias Barkpark.Repo
  alias Barkpark.StudioChat.Message

  @doc "Returns `state` with its stored pending asks and their asking lease restored."
  @spec restore(map()) :: map()
  def restore(%{session_id: session_id, pending_asks: asks} = state)
      when is_binary(session_id) do
    case pending(session_id) do
      [] ->
        state

      ids ->
        state = %{state | pending_asks: MapSet.union(asks, MapSet.new(ids))}

        case asking_lease(session_id, ids) do
          nil -> state
          lease_id -> Map.merge(state, %{runtime_lease: lease_id, runtime_turn_open?: true})
        end
    end
  end

  def restore(state), do: state

  defp pending(session_id) do
    from(m in Message,
      where: m.session_id == ^session_id,
      where: fragment("?->>'approval_status' = 'pending'", m.metadata),
      where: not is_nil(fragment("?->>'request_id'", m.metadata)),
      select: fragment("?->>'request_id'", m.metadata)
    )
    |> Repo.all()
  end

  defp asking_lease(session_id, ids) do
    from(e in ExecutionEvent,
      join: l in ExecutionLease,
      on: l.id == e.lease_id,
      where: l.session_id == ^session_id and e.kind == "approval_requested",
      where: fragment("?->>'approval_id'", e.payload) in ^ids,
      order_by: [desc: l.inserted_at, desc: e.inserted_at],
      limit: 1,
      select: l.id
    )
    |> Repo.one()
  end
end
