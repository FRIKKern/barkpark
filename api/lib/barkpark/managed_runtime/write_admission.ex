defmodule Barkpark.ManagedRuntime.WriteAdmission do
  @moduledoc """
  Internal, explicitly started admission coordinator for a dedicated runtime.

  This module is not wired to content/media writers or the application tree and
  advertises no seal capability. It cannot yet establish runtime exclusivity.
  The host must exclusively own the instance and journal directory across OS
  processes; the registered name prevents duplicate coordinators within a node.

  Every outer admission and settlement is synced to a private DETS journal
  before acknowledgement. Nested admission belongs to the same caller process.
  Closing rejects new owners and becomes held only after admitted owners settle.
  Owner death or an interrupted journal state requires reconciliation: there is
  deliberately no force-reopen API. A timeout is not permission to retry a write.

  `initialize: true` is only for first provisioning and refuses an existing file.
  Normal startup refuses missing, corrupt, foreign or repair-needing journals.
  Process-restart evidence is distinct from a power-loss durability guarantee.
  """

  use GenServer

  @max_writers 128
  @phases [:open, :closing, :held, :recovery_required]

  def start_link(opts) do
    journal = opts |> Keyword.fetch!(:journal) |> Path.expand()

    GenServer.start_link(__MODULE__, Keyword.put(opts, :journal, journal),
      name: {:global, {__MODULE__, Keyword.fetch!(opts, :instance_id)}}
    )
  end

  @doc "Admit the calling process; nested calls require matching settlements."
  def checkout(server), do: GenServer.call(server, :checkout)

  @doc "Acknowledge that all effects owned by this admission have settled."
  def checkin(server, ticket), do: GenServer.call(server, {:checkin, ticket})

  @doc "Retain an uncertain effect; it must not count as successful settlement."
  def uncertain(server, ticket), do: GenServer.call(server, {:uncertain, ticket})

  @doc "Close new admission. A closing response is not a held seal."
  def begin_hold(server, operation, generation),
    do: GenServer.call(server, {:begin_hold, operation, generation})

  @doc "Observe the matching hold, without releasing exclusion."
  def held?(server, hold), do: GenServer.call(server, {:held?, hold})

  @doc "Abort a held operation before authority selection; rotates generation."
  def reopen(server, hold), do: GenServer.call(server, {:reopen, hold})

  @doc "Inspect state without exposing owner tickets or hold capabilities."
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    journal = Keyword.fetch!(opts, :journal)
    instance = Keyword.fetch!(opts, :instance_id)
    table = {__MODULE__, journal}
    exists = File.exists?(journal)
    initialize = Keyword.get(opts, :initialize, false)

    with true <- valid_id?(instance),
         :ok <- claim_journal(journal),
         :ok <- provisioning(exists, initialize),
         {:ok, ^table} <-
           :dets.open_file(table,
             file: String.to_charlist(journal),
             type: :set,
             repair: false,
             auto_save: :infinity
           ),
         {:ok, record} <- load(table, instance, initialize) do
      phase =
        if record.phase == :open and record.pending == [], do: :open, else: :recovery_required

      record = %{record | phase: phase, generation: record.generation + 1}
      state = %{table: table, record: record, boot: random_id(), writers: %{}, holder: nil}

      case persist(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:stop, {:journal_unavailable, reason}}
      end
    else
      false -> {:stop, :invalid_instance}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    view = Map.take(state.record, [:instance_id, :phase, :generation, :operation, :sequence])
    {:reply, Map.merge(view, %{boot: state.boot, pending: length(state.record.pending)}), state}
  end

  def handle_call(:checkout, {owner, _}, state) do
    case Map.get(state.writers, owner) do
      %{tickets: tickets} = writer when state.record.phase in [:open, :closing] ->
        ticket = {state.boot, state.record.generation, random_id()}

        {:reply, {:ok, ticket},
         put_in(state.writers[owner], %{writer | tickets: MapSet.put(tickets, ticket)})}

      nil when state.record.phase == :open and map_size(state.writers) < @max_writers ->
        ticket = {state.boot, state.record.generation, random_id()}

        writer = %{
          root: elem(ticket, 2),
          tickets: MapSet.new([ticket]),
          monitor: Process.monitor(owner)
        }

        state = put_in(state.writers[owner], writer)
        state = put_in(state.record.pending, [elem(ticket, 2) | state.record.pending])
        commit(state, {:ok, ticket})

      nil when state.record.phase == :open ->
        {:reply, {:error, :capacity}, state}

      _ ->
        {:reply, {:error, :admission_closed}, state}
    end
  end

  def handle_call({:checkin, ticket}, {owner, _}, state) do
    case Map.get(state.writers, owner) do
      %{tickets: tickets} = writer ->
        cond do
          not MapSet.member?(tickets, ticket) ->
            {:reply, {:error, :invalid_ticket}, state}

          MapSet.size(tickets) > 1 ->
            {:reply, :ok,
             put_in(state.writers[owner], %{writer | tickets: MapSet.delete(tickets, ticket)})}

          true ->
            Process.demonitor(writer.monitor, [:flush])
            state = %{state | writers: Map.delete(state.writers, owner)}
            state = put_in(state.record.pending, List.delete(state.record.pending, writer.root))
            commit(maybe_held(state), :ok)
        end

      _ ->
        {:reply, {:error, :invalid_ticket}, state}
    end
  end

  def handle_call({:begin_hold, operation, generation}, {owner, _}, state) do
    cond do
      not valid_id?(operation) ->
        {:reply, {:error, :invalid_operation}, state}

      generation !== state.record.generation ->
        {:reply, {:error, :stale_generation}, state}

      match?(%{owner: ^owner, operation: ^operation}, state.holder) and
          state.record.phase in [:closing, :held] ->
        {:reply, {:ok, state.record.phase, state.holder.ticket}, state}

      state.record.phase != :open ->
        {:reply, {:error, :admission_closed}, state}

      Map.has_key?(state.writers, owner) ->
        {:reply, {:error, :caller_has_write}, state}

      true ->
        ticket = {state.boot, state.record.generation, random_id()}

        holder = %{
          owner: owner,
          operation: operation,
          ticket: ticket,
          monitor: Process.monitor(owner)
        }

        state = %{
          state
          | holder: holder,
            record: %{state.record | phase: :closing, operation: operation}
        }

        state = maybe_held(state)
        commit(state, {:ok, state.record.phase, ticket})
    end
  end

  def handle_call({:uncertain, ticket}, {owner, _}, state) do
    case Map.get(state.writers, owner) do
      %{tickets: tickets} ->
        if MapSet.member?(tickets, ticket),
          do: commit(put_in(state.record.phase, :recovery_required), :ok),
          else: {:reply, {:error, :invalid_ticket}, state}

      _ ->
        {:reply, {:error, :invalid_ticket}, state}
    end
  end

  def handle_call({:held?, ticket}, {owner, _}, state) do
    case state.holder do
      %{owner: ^owner, ticket: ^ticket} -> {:reply, state.record.phase == :held, state}
      _ -> {:reply, {:error, :invalid_hold}, state}
    end
  end

  def handle_call({:reopen, ticket}, {owner, _}, state) do
    case state.holder do
      %{owner: ^owner, ticket: ^ticket, monitor: monitor} when state.record.phase == :held ->
        Process.demonitor(monitor, [:flush])

        record = %{
          state.record
          | phase: :open,
            operation: nil,
            generation: state.record.generation + 1
        }

        commit(%{state | holder: nil, record: record}, :ok)

      _ ->
        {:reply, {:error, :invalid_hold}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    lost_writer = match?(%{monitor: ^monitor}, Map.get(state.writers, owner))
    lost_holder = match?(%{monitor: ^monitor}, state.holder)

    if lost_writer or lost_holder do
      # Keep pending evidence. Process death says nothing about a blob or child
      # effect that may already have escaped; it is not a successful settlement.
      state = put_in(state.record.phase, :recovery_required)

      case persist(state) do
        {:ok, state} -> {:noreply, state}
        {:error, reason} -> {:stop, {:journal_unavailable, reason}, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state), do: :dets.close(state.table)

  @impl true
  def format_status(status) do
    status
    |> Map.update!(:state, fn state ->
      Map.take(state.record, [:phase, :generation, :sequence])
    end)
    |> Map.replace(:message, :admission_message_redacted)
  end

  defp maybe_held(%{record: %{phase: :closing, pending: []}} = state),
    do: put_in(state.record.phase, :held)

  defp maybe_held(state), do: state

  defp commit(state, reply) do
    case persist(state) do
      {:ok, state} ->
        {:reply, reply, state}

      {:error, reason} ->
        {:stop, {:journal_unavailable, reason}, {:error, :journal_unavailable}, state}
    end
  end

  defp persist(state) do
    record = %{state.record | sequence: state.record.sequence + 1}

    with :ok <- :dets.insert(state.table, {:state, record}),
         :ok <- :dets.sync(state.table) do
      {:ok, %{state | record: record}}
    end
  rescue
    ArgumentError -> {:error, :closed_journal}
  end

  defp provisioning(false, true), do: :ok
  defp provisioning(true, false), do: :ok
  defp provisioning(true, true), do: {:error, :journal_exists}
  defp provisioning(false, false), do: {:error, :journal_missing}
  defp provisioning(_, _), do: {:error, :invalid_initialization}

  defp claim_journal(journal) do
    if :global.set_lock({{__MODULE__, :journal, journal}, self()}, [node()], 0),
      do: :ok,
      else: {:error, :journal_owned}
  end

  defp load(table, instance, true) do
    if :dets.info(table, :size) == 0 do
      {:ok,
       %{
         version: 1,
         instance_id: instance,
         phase: :open,
         generation: 0,
         sequence: 0,
         pending: [],
         operation: nil
       }}
    else
      {:error, :invalid_journal}
    end
  end

  defp load(table, instance, false) do
    case :dets.lookup(table, :state) do
      [{:state, %{instance_id: ^instance} = record}] ->
        if valid_record?(record) and :dets.info(table, :size) == 1,
          do: {:ok, record},
          else: {:error, :invalid_journal}

      _ ->
        {:error, :invalid_journal}
    end
  end

  defp valid_record?(record) do
    Map.keys(record) |> Enum.sort() ==
      Enum.sort([:version, :instance_id, :phase, :generation, :sequence, :pending, :operation]) and
      record.version == 1 and record.phase in @phases and
      is_integer(record.generation) and record.generation > 0 and
      is_integer(record.sequence) and record.sequence > 0 and
      is_list(record.pending) and length(record.pending) <= @max_writers and
      Enum.all?(record.pending, &valid_id?/1) and
      Enum.uniq(record.pending) == record.pending and
      (is_nil(record.operation) or valid_id?(record.operation)) and
      (record.phase != :open or is_nil(record.operation)) and
      (record.phase not in [:closing, :held] or valid_id?(record.operation)) and
      (record.phase != :held or record.pending == [])
  end

  defp valid_id?(value), do: is_binary(value) and byte_size(value) in 1..200
  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
