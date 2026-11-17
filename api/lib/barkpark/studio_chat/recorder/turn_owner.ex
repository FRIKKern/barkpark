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

  So a projected host event names its lease (beside the event, never in it:
  `Runtime.Event` goes on the wire). The first lease seen owns the turn. When
  an event from another lease arrives while the turn is open:

    * a `turn_started` ends the old owner's text as its own row and starts a
      fresh turn (`{:split, false}`);
    * a `text_delta` ends the old owner's text as its own row and the turn
      stays open for the new owner (`{:split, true}`).

  Anything else is `:same`. An event with no lease (a managed runtime, or a
  caller that does not pass one) is always `:same` and changes no owner, so
  the managed path is the path it was. One lease's own repeated `turn_started`
  (an older claude host sends one per message) is `:same` too.
  """

  alias Barkpark.StudioChat.Runtime.Event

  @spec boundary(map(), Event.t(), String.t() | nil) :: :same | {:split, boolean()}
  def boundary(_state, _event, nil), do: :same

  def boundary(state, %Event{kind: kind}, lease_id) when kind in [:turn_started, :text_delta] do
    owner = Map.get(state, :runtime_lease)

    if Map.get(state, :runtime_turn_open?, false) and is_binary(owner) and owner != lease_id,
      do: {:split, kind == :text_delta},
      else: :same
  end

  def boundary(_state, _event, _lease_id), do: :same

  @doc "The lease of the event just taken owns the turn; no lease changes nothing."
  @spec adopt(map(), String.t() | nil) :: map()
  def adopt(state, nil), do: state
  def adopt(state, lease_id), do: Map.put(state, :runtime_lease, lease_id)
end
