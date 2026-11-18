defmodule Barkpark.StudioChat.Recorder.DisplacedAsks do
  @moduledoc """
  Cancels the pending asks a turn leaves behind: the asks of a lease a newer
  turn displaced (task-bc312d78041663a8), and the asks still pending when
  their own turn ends (task-6b2fede385c12f8d).

  When `Recorder.TurnOwner` splits the turn, the asks the Recorder holds were
  asked by the displaced lease. That lease's run cannot get an answer: an
  answer is leased with only the session id and approval id
  (`Runtime.answer_approval/4`), and the host routes it by session to its one
  active run, the NEWER one, which does not know the ask
  ("unknown Claude approval"). That answer lease's close would then end the
  newer turn. Keeping the ask also showed the newer turn as "needs you" for its
  whole length.

  A turn that completes or fails with an ask still pending is the same case:
  its run will not take an answer. The Recorder used to drop only its own
  tracking, and the stored row stayed "pending", so Studio showed a live card
  for a turn that had ended, and a later run of the session could show two
  pending cards under one id.

  So each one is canceled in the store (`approval_status: "canceled"`, with a
  `cancel_reason`), live viewers flip its card through the same
  `{:chat_permission_resolved, request_id, :canceled}` a resolving tab sends,
  and the Recorder stops tracking it. Each cancel is
  `StudioChat.update_approval_status/4`: it locks the pending row
  (`FOR UPDATE`), so an answer that commits first stands, and the session's
  pending count drops by one per row canceled.
  """

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder

  @displaced %{"cancel_reason" => "superseded_by_newer_turn"}
  @ended %{"cancel_reason" => "turn_ended"}

  @doc "Cancels a displaced lease's `state.pending_asks` and returns `state` with none."
  @spec cancel(map()) :: map()
  def cancel(state), do: cancel_with(state, @displaced)

  @doc """
  Cancels the asks still pending when their turn ended; returns `state` with
  none tracked. Called after the turn-end activity publish at the three turn
  ends (a managed Claude result, a runtime `turn_completed`, a runtime
  failure). When `Recorder.TurnOwner` marked the closing event as not the
  asking run's (`asks_closer?: false`: a refused newer send_turn's close while
  the owner's run is live), the asks stay pending and answerable, and stay
  TRACKED under the owner: the owner's own close, when it comes, is what
  cancels them (task-fe4832b24ab1c40b). Dropping them here left that close
  nothing to cancel, and the ask a live card for a turn that had ended.
  """
  @spec cancel_ended(map()) :: map()
  def cancel_ended(state) do
    case Map.pop(state, :asks_closer?, true) do
      {true, state} -> cancel_with(state, @ended)
      {false, state} -> state
    end
  end

  defp cancel_with(%{pending_asks: asks, session_id: session_id} = state, reason) do
    Enum.each(asks, fn request_id ->
      case StudioChat.update_approval_status(session_id, request_id, "canceled", reason) do
        {:ok, _message} ->
          Phoenix.PubSub.broadcast(
            Barkpark.PubSub,
            Recorder.topic(session_id),
            {:chat_permission_resolved, request_id, :canceled}
          )

        {:error, _already_resolved} ->
          :ok
      end
    end)

    %{state | pending_asks: MapSet.new()}
  end

  defp cancel_with(state, _reason), do: state
end
