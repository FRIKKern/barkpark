defmodule Barkpark.StudioChat.Recorder.DisplacedAsks do
  @moduledoc """
  Cancels the pending asks of the lease a newer turn displaced
  (task-bc312d78041663a8).

  When `Recorder.TurnOwner` splits the turn, the asks the Recorder holds were
  asked by the displaced lease. That lease's run cannot get an answer: an
  answer is leased with only the session id and approval id
  (`Runtime.answer_approval/4`), and the host routes it by session to its one
  active run, the NEWER one, which does not know the ask
  ("unknown Claude approval"). That answer lease's close would then end the
  newer turn. Keeping the ask also showed the newer turn as "needs you" for its
  whole length.

  So each one is canceled in the store (`approval_status: "canceled"`,
  `cancel_reason: "superseded_by_newer_turn"`), live viewers flip its card
  through the same `{:chat_permission_resolved, request_id, :canceled}` a
  resolving tab sends, and the Recorder stops tracking it.
  """

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder

  @reason %{"cancel_reason" => "superseded_by_newer_turn"}

  @doc "Cancels `state.pending_asks` and returns `state` with none."
  @spec cancel(map()) :: map()
  def cancel(%{pending_asks: asks, session_id: session_id} = state) do
    Enum.each(asks, fn request_id ->
      case StudioChat.update_approval_status(session_id, request_id, "canceled", @reason) do
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

  def cancel(state), do: state
end
