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

  A terminal event (`turn_completed`, or an `error`, `process_failed` or
  `protocol_error` that will not retry) is `:ignore`d only from a lease the
  current owner TOOK the turn from, while that turn is open and the owner's
  lease is still live (task-5d1f639852927c4e). `ChatHosts` reads whether a
  newer turn has started before that turn's `turn_started` commits, so such an
  older close can reach the Recorder just after the newer turn began and end
  it. Every other close is taken, because nothing else may ever end the turn:

    * a lease that never owned a turn: one that failed before its
      `turn_started` (its close is its first event), or a Stop's lease, whose
      "no active turn" answer is the only close when the owner's run is gone
      on a host that still renews its lease (no held_leases, before #26823);
    * any close while no turn is open;
    * a close while the owner's lease is no longer live (ended, revoked,
      expired): the owner's own close will not come.

  The Recorder keeps the last eight leases an owner took the turn from.

  Anything else is `:same`. An event with no lease (a managed runtime, or a
  caller that passes `nil`) is always `:same` and changes no owner, so the
  managed path is the path it was. One lease's own repeated `turn_started`
  (an older claude host sends one per message) is `:same` too.
  """

  alias Barkpark.StudioChat.Runtime.Event

  @doc """
  Applies `boundary/3` to the Recorder's state and moves the owner; an ignored
  event comes back as `{:ignore, state}`, for the Recorder not to take it.
  `persist` stores the open text as a reply row and `settle` settles the
  live document against it (the Recorder's `persist_runtime_text/2` and
  `stable_settle/2`).
  """
  @type persist :: (map(), Event.t() -> term())
  @type settle :: (map(), String.t() -> map())

  @spec take(map(), Event.t(), String.t() | nil, persist(), settle()) :: map() | {:ignore, map()}
  def take(state, %Event{} = event, lease_id, persist, settle) do
    case boundary(state, event, lease_id) do
      :ignore ->
        {:ignore, state}

      :same ->
        adopt(state, event, lease_id)

      {:split, open?} ->
        persist.(state, %{event | kind: :turn_completed, terminal_state: nil})

        state
        |> settle.(state.runtime_text)
        |> Map.merge(%{runtime_text: "", runtime_break?: false, runtime_turn_open?: open?})
        |> adopt(event, lease_id)
    end
  end

  @terminal_kinds [:turn_completed, :error, :process_failed, :protocol_error]
  @displaced_kept 8

  @doc """
  How an event from `lease_id` meets the open turn. For a terminal event that
  might be ignored it reads the owner's lease row (`ChatHosts.lease_live?/1`).
  """
  @spec boundary(map(), Event.t(), String.t() | nil) :: :same | :ignore | {:split, boolean()}
  def boundary(_state, _event, nil), do: :same

  def boundary(state, %Event{kind: kind} = event, lease_id) when kind in @terminal_kinds do
    if not Event.retrying_error?(event) and taken_from?(state, lease_id),
      do: :ignore,
      else: :same
  end

  def boundary(state, %Event{kind: kind}, lease_id) when kind in [:turn_started, :text_delta] do
    owner = Map.get(state, :runtime_lease)

    if Map.get(state, :runtime_turn_open?, false) and is_binary(owner) and owner != lease_id,
      do: {:split, kind == :text_delta},
      else: :same
  end

  def boundary(_state, _event, _lease_id), do: :same

  # Did the owner of the open turn take it from `lease_id`, and does the owner
  # still hold a live lease? The row read comes last: only this path pays it.
  defp taken_from?(state, lease_id) do
    owner = Map.get(state, :runtime_lease)

    Map.get(state, :runtime_turn_open?, false) and is_binary(owner) and owner != lease_id and
      lease_id in Map.get(state, :runtime_displaced, []) and
      Barkpark.ChatHosts.lease_live?(owner)
  end

  # Only a lease's own turn takes the turn over: its turn_started or its text.
  # A Stop's lease is newer too but starts no turn, so its ack leaves the owner.
  # The lease it takes over from is remembered as displaced; a lease that takes
  # the turn back is not displaced any more.
  defp adopt(state, _event, nil), do: state

  defp adopt(state, %Event{kind: kind}, lease_id) do
    owner = Map.get(state, :runtime_lease)

    if owner != lease_id and (kind in [:turn_started, :text_delta] or not is_binary(owner)) do
      displaced = Map.get(state, :runtime_displaced, []) |> List.delete(lease_id)

      displaced =
        if is_binary(owner),
          do: Enum.take([owner | List.delete(displaced, owner)], @displaced_kept),
          else: displaced

      Map.merge(state, %{runtime_lease: lease_id, runtime_displaced: displaced})
    else
      state
    end
  end
end
