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

  Child admission: a process whose `$callers` ancestor holds admission joins
  that ancestor's root instead of opening a new one, so plugin hooks and
  supervised tasks spawned inside a write are part of the same settlement. The
  root's final settlement is refused with `children_pending` while any such
  child is still admitted. A `:failed` settlement while an operation is closing
  leaves the instance in recovery; while open it is an ordinary failure. Writer
  death while open releases that admission for the same reason: nothing is
  seeking exclusion, and a later hold drains from a fresh start.
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
  def checkout(server),
    do: GenServer.call(server, {:checkout, Process.get(:"$callers", [])})

  @doc """
  Acknowledge that all effects owned by this admission have settled.

  `:failed` records that the write raised or exited: while an operation is
  closing, the instance moves to recovery; while open, it settles normally.
  """
  def checkin(server, ticket, outcome \\ :settled) when outcome in [:settled, :failed],
    do: GenServer.call(server, {:checkin, ticket, outcome})

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

  @doc """
  Explicit recovery: reopen an instance that is `recovery_required` once the
  operator has reconciled its uncertain effects. `generation` must be the
  current one and `pending` the number of unsettled roots the journal carries,
  so the caller proves it read the state it is clearing. Refused while any
  writer is admitted. Advances the generation; every earlier ticket refuses.
  """
  def recover(server, generation, pending),
    do: GenServer.call(server, {:recover, generation, pending})

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

  def handle_call({:checkout, callers}, {owner, _}, state) do
    case Map.get(state.writers, owner) do
      %{tickets: tickets} = writer when state.record.phase in [:open, :closing] ->
        ticket = new_ticket(state)

        {:reply, {:ok, ticket},
         put_in(state.writers[owner], %{writer | tickets: MapSet.put(tickets, ticket)})}

      nil ->
        case inherited_root(callers, state) do
          {:ok, root} when state.record.phase in [:open, :closing] ->
            # The root is already journaled as pending, so a child needs no
            # persistence; it only extends the root's settlement.
            ticket = new_ticket(state)

            {:reply, {:ok, ticket},
             put_in(state.writers[owner], writer(root, ticket, owner, false))}

          :none when state.record.phase == :open and map_size(state.writers) < @max_writers ->
            ticket = new_ticket(state)
            state = put_in(state.writers[owner], writer(elem(ticket, 2), ticket, owner, true))
            state = put_in(state.record.pending, [elem(ticket, 2) | state.record.pending])
            commit(state, {:ok, ticket})

          :none when state.record.phase == :open ->
            {:reply, {:error, :capacity}, state}

          _ ->
            {:reply, {:error, :admission_closed}, state}
        end

      _ ->
        {:reply, {:error, :admission_closed}, state}
    end
  end

  def handle_call({:checkin, ticket, outcome}, {owner, _}, state) do
    case Map.get(state.writers, owner) do
      %{tickets: tickets} = writer ->
        {state, failed_while_closing} = note_outcome(state, outcome)

        cond do
          not MapSet.member?(tickets, ticket) ->
            {:reply, {:error, :invalid_ticket}, state}

          MapSet.size(tickets) > 1 ->
            state =
              put_in(state.writers[owner], %{writer | tickets: MapSet.delete(tickets, ticket)})

            if failed_while_closing, do: commit(state, :ok), else: {:reply, :ok, state}

          writer.root_owner? and root_shared?(state, owner, writer.root) ->
            # Children that inherited this admission are still running; their
            # effects belong to this settlement, so it cannot complete yet.
            if failed_while_closing,
              do: commit(state, {:error, :children_pending}),
              else: {:reply, {:error, :children_pending}, state}

          true ->
            commit(maybe_held(release(state, owner)), :ok)
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

  def handle_call({:recover, generation, pending}, _from, state) do
    cond do
      state.record.phase != :recovery_required ->
        {:reply, {:error, :not_in_recovery}, state}

      generation !== state.record.generation ->
        {:reply, {:error, :stale_generation}, state}

      pending !== length(state.record.pending) ->
        {:reply, {:error, :unreconciled}, state}

      map_size(state.writers) > 0 ->
        {:reply, {:error, :writers_present}, state}

      true ->
        if state.holder, do: Process.demonitor(state.holder.monitor, [:flush])

        record = %{
          state.record
          | phase: :open,
            pending: [],
            operation: nil,
            generation: state.record.generation + 1
        }

        commit(%{state | holder: nil, record: record}, :ok)
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    lost_writer = match?(%{monitor: ^monitor}, Map.get(state.writers, owner))
    lost_holder = match?(%{monitor: ^monitor}, state.holder)

    cond do
      lost_writer and state.record.phase == :open ->
        # No operation is seeking exclusion: a crashed writer is an ordinary
        # failed request. A later hold drains whatever is admitted then.
        persist_or_stop(release(state, owner))

      lost_writer or lost_holder ->
        # Keep pending evidence. Process death says nothing about a blob or child
        # effect that may already have escaped; it is not a successful settlement.
        persist_or_stop(put_in(state.record.phase, :recovery_required))

      true ->
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

  defp new_ticket(state), do: {state.boot, state.record.generation, random_id()}

  defp writer(root, ticket, owner, root_owner?),
    do: %{
      root: root,
      root_owner?: root_owner?,
      tickets: MapSet.new([ticket]),
      monitor: Process.monitor(owner)
    }

  # The nearest `$callers` ancestor that holds admission; its root is inherited.
  defp inherited_root(callers, state) do
    Enum.find_value(callers, :none, fn pid ->
      case Map.get(state.writers, pid) do
        %{root: root} -> {:ok, root}
        _ -> nil
      end
    end)
  end

  defp root_shared?(state, owner, root),
    do: Enum.any?(state.writers, fn {pid, writer} -> pid != owner and writer.root == root end)

  # Remove a writer; its root leaves the journal once no admitted process shares it.
  defp release(state, owner) do
    writer = Map.fetch!(state.writers, owner)
    Process.demonitor(writer.monitor, [:flush])
    state = %{state | writers: Map.delete(state.writers, owner)}

    if root_shared?(state, owner, writer.root),
      do: state,
      else: put_in(state.record.pending, List.delete(state.record.pending, writer.root))
  end

  defp note_outcome(state, :failed) when state.record.phase == :closing,
    do: {put_in(state.record.phase, :recovery_required), true}

  defp note_outcome(state, _outcome), do: {state, false}

  defp persist_or_stop(state) do
    case persist(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, {:journal_unavailable, reason}, state}
    end
  end

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
