defmodule BarkparkWeb.ChatFleetSeat do
  @moduledoc """
  The fleet stream (`GET /v1/chat/events`) and the rollup (`GET /v1/chat/rollup`)
  under the registered-host seat (task-1910050f9b350976).

  A chat on a workspace's registered host is seen only by a seat that may drive
  it (`HostExecutionGate.may_see_session?/2`, task-f44bbb6363d28e37). The fleet
  wire carried every session in the caller's tenant scope, so a member saw a host
  chat's id, title and state. Here, per subscriber:

    * the connect snapshot and the ring replay leave out what the caller may not
      see (`visible_rows/2`);
    * live `state`, `heartbeat` and `title` frames are dropped in the forwarder
      process (`start_forwarder/3`), before they reach the connection;
    * the rollup counts leave those sessions out (`rollup/2`), so no count leaks.

  COST. FleetHub's broadcasts carry the owner workspace but not the execution
  target, so the forwarder looks a session up ONCE, the first time its id
  appears (a primary-key read), and caches the answer for the connection. It
  never queries per flip (charter D43h). A session id with no row is left out
  (fail closed).
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Session
  alias BarkparkWeb.HostExecutionGate

  # StudioChat's `@rollup_precedence`, which is private there; the rollup test
  # pins that an all-seeing caller gets exactly `StudioChat.rollup/1`.
  @precedence [:blocked, :working, :idle, :unknown]

  @doc "The fleet snapshot rows (`StudioChat.fleet_snapshot/1`) `principal` may see."
  @spec snapshot(term(), :global | binary()) :: [map()]
  def snapshot(principal, scope), do: visible_rows(principal, StudioChat.fleet_snapshot(scope))

  @doc "`rows` (each with a `:session_id`) without the sessions `principal` may not see."
  @spec visible_rows(term(), [map()]) :: [map()]
  def visible_rows(_principal, []), do: []

  def visible_rows(principal, rows) do
    visible = visible_ids(principal, Enum.map(rows, & &1.session_id))
    Enum.filter(rows, &MapSet.member?(visible, &1.session_id))
  end

  @doc """
  `StudioChat.rollup/1` without the registered-host sessions `principal` may
  not see. A caller who may see every one gets the store's answer unchanged.
  """
  @spec rollup(term(), :global | {:workspace, binary()}) :: map()
  def rollup(principal, scope) do
    rollup = StudioChat.rollup(scope)

    case hidden_states(principal, scope) do
      [] ->
        rollup

      hidden ->
        counts =
          Enum.reduce(hidden, rollup.counts, fn state, acc ->
            Map.update!(acc, String.to_existing_atom(state), &max(&1 - 1, 0))
          end)

        %{counts: counts, precedence: Enum.find(@precedence, :unknown, &(counts[&1] > 0))}
    end
  end

  @doc """
  `ChatController.start_forwarder/2` with the seat: subscribes to `topic` in a
  linked helper and forwards every message to `listener`, except a fleet
  `state`, `heartbeat` or `title` frame for a session `principal` may not see.
  """
  @spec start_forwarder(binary(), pid(), term()) :: pid()
  def start_forwarder(topic, listener, principal) do
    caller = self()
    # The helper reads the DB on the request's behalf: carry the caller chain,
    # as a Task does, so a test sandbox allowance follows it.
    callers = [caller | Process.get(:"$callers", [])]

    pid =
      spawn_link(fn ->
        Process.put(:"$callers", callers)
        Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
        send(caller, {:chat_forwarder_ready, self()})
        forward_loop(listener, principal, %{})
      end)

    receive do
      {:chat_forwarder_ready, ^pid} -> pid
    end
  end

  defp forward_loop(listener, principal, seen) do
    receive do
      :stop ->
        :ok

      msg ->
        {keep?, seen} = keep?(frame_session(msg), principal, seen)
        if keep?, do: send(listener, msg)
        forward_loop(listener, principal, seen)
    end
  end

  defp frame_session({:fleet_flip, %{session_id: sid}}), do: {:session, sid}
  defp frame_session({:fleet_heartbeat, sid, _ts, _owner}), do: {:session, sid}
  defp frame_session({:fleet_title, sid, _title, _owner}), do: {:session, sid}
  defp frame_session(_other), do: :other

  defp keep?(:other, _principal, seen), do: {true, seen}

  defp keep?({:session, sid}, principal, seen) do
    case seen do
      %{^sid => visible?} ->
        {visible?, seen}

      _ ->
        visible? = MapSet.member?(visible_ids(principal, [sid]), sid)
        {visible?, Map.put(seen, sid, visible?)}
    end
  end

  # One read for the batch: managed sessions are visible, a registered-host
  # session takes the seat (asked once per workspace), a missing row is not.
  defp visible_ids(principal, ids) do
    uuids = for id <- Enum.uniq(ids), {:ok, uuid} <- [Ecto.UUID.cast(id)], do: uuid

    from(s in Session,
      where: s.id in ^uuids,
      select: {s.id, s.execution_target, s.owner_workspace_id}
    )
    |> Repo.all()
    |> Enum.reduce({MapSet.new(), %{}}, fn {id, target, ws}, {visible, seats} ->
      {seated?, seats} = seat(principal, target, ws, seats)
      {if(seated?, do: MapSet.put(visible, id), else: visible), seats}
    end)
    |> elem(0)
  end

  defp seat(_principal, target, _ws, seats) when target != "registered_host", do: {true, seats}

  defp seat(principal, target, ws, seats) do
    case seats do
      %{^ws => seated?} ->
        {seated?, seats}

      _ ->
        seated? =
          HostExecutionGate.may_see_session?(principal, %{
            execution_target: target,
            owner_workspace_id: ws
          })

        {seated?, Map.put(seats, ws, seated?)}
    end
  end

  # The agent_state of every live registered-host session in `scope` that
  # `principal` may not see: one read, then the seat once per workspace.
  defp hidden_states(principal, scope) do
    query =
      from(s in Session,
        where: s.execution_target == "registered_host" and is_nil(s.archived_at),
        select: {s.owner_workspace_id, s.agent_state}
      )

    case scope do
      :global -> Repo.all(query)
      {:workspace, ws} -> Repo.all(from(s in query, where: s.owner_workspace_id == ^ws))
      ws when is_binary(ws) -> Repo.all(from(s in query, where: s.owner_workspace_id == ^ws))
      _fail_closed -> []
    end
    |> Enum.reduce({[], %{}}, fn {ws, state}, {hidden, seats} ->
      {seated?, seats} = seat(principal, "registered_host", ws, seats)
      {if(seated?, do: hidden, else: [state | hidden]), seats}
    end)
    |> elem(0)
  end
end
