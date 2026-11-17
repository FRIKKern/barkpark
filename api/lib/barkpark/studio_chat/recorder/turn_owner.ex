defmodule Barkpark.StudioChat.Recorder.TurnOwner do
  @moduledoc """
  Which registered-host lease owns the Recorder's open turn
  (task-b0cbddc9d0f2e2aa).

  The Recorder keeps one turn's text at a time. Two leases of one session can
  both be live: another host, or a Go host older than #24702, starts a newer
  turn while the older one still runs. `ChatHosts` keeps an older lease's
  events out of the Recorder while a newer turn is open (#26812), but not the
  older text taken before the newer `turn_started`, nor the older text that
  comes once the newer lease has ended. Joined, they made one row,
  "Older.\\n\\nNewer." or "Newer.Older.".

  So a projected host event names its lease, beside the event and never in it
  (`Runtime.Event` goes on the wire). The first lease seen owns the turn. When
  an event from another lease arrives while the turn is open, the open turn's
  text is stored as its own row, then:

    * a `turn_started` starts a fresh turn (`{:split, false}`: the turn is
      closed, so the Recorder's `turn_started` arm opens a new one);
    * a `text_delta` goes on in the same open turn for its lease
      (`{:split, true}`).

  Only a `turn_started` or a `text_delta` makes its lease the owner (or any
  event when there is none yet): a Stop's lease is newer too but starts no
  turn, so its ack leaves the stopped turn's owner in place.

  Anything else is `:same`. An event with no lease (a managed runtime, or a
  caller that passes `nil`) is always `:same` and changes no owner, so the
  managed path is the path it was. One lease's own repeated `turn_started`
  (an older claude host sends one per message) is `:same` too.
  """

  alias Barkpark.StudioChat.Runtime.Event

  @doc """
  Applies `boundary/3` to the Recorder's state, then makes `lease_id` the
  owner. `persist` stores the open text as a reply row and `settle` settles the
  live document against it (the Recorder's `persist_runtime_text/2` and
  `stable_settle/2`).
  """
  @type persist :: (map(), Event.t() -> term())
  @type settle :: (map(), String.t() -> map())

  @spec take(map(), Event.t(), String.t() | nil, persist(), settle()) :: map()
  def take(state, %Event{} = event, lease_id, persist, settle) do
    case boundary(state, event, lease_id) do
      :same ->
        state

      {:split, open?} ->
        persist.(state, %{event | kind: :turn_completed, terminal_state: nil})

        state
        |> settle.(state.runtime_text)
        |> Map.merge(%{runtime_text: "", runtime_break?: false, runtime_turn_open?: open?})
    end
    |> adopt(event, lease_id)
  end

  @spec boundary(map(), Event.t(), String.t() | nil) :: :same | {:split, boolean()}
  def boundary(_state, _event, nil), do: :same

  def boundary(state, %Event{kind: kind}, lease_id) when kind in [:turn_started, :text_delta] do
    owner = Map.get(state, :runtime_lease)

    if Map.get(state, :runtime_turn_open?, false) and is_binary(owner) and owner != lease_id,
      do: {:split, kind == :text_delta},
      else: :same
  end

  def boundary(_state, _event, _lease_id), do: :same

  # Only a lease's own turn takes the turn over: its turn_started or its text.
  # A Stop's lease is newer too but starts no turn, so its ack leaves the owner.
  defp adopt(state, _event, nil), do: state

  defp adopt(state, %Event{kind: kind}, lease_id) do
    if kind in [:turn_started, :text_delta] or not is_binary(Map.get(state, :runtime_lease)),
      do: Map.put(state, :runtime_lease, lease_id),
      else: state
  end
end
