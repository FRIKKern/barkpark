defmodule Barkpark.ChatHosts do
  @moduledoc "Workspace-scoped registration and fenced dispatch for local Chat hosts."

  @behaviour Barkpark.StudioChat.Runtime.HostDirectory

  import Ecto.Query

  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease, RegisteredHost, Security, Transport}
  alias Barkpark.ChatHosts.EventText
  alias Barkpark.Repo
  alias Barkpark.StudioChat.{BotFolder, TurnAttachments}

  @enrollment_ttl 10 * 60
  @credential_ttl 30 * 24 * 60 * 60
  @lease_ttl 60
  @expired_turn_grace 90
  # The server ends an expired turn only when its lease was CREATED
  # (`inserted_at`) at or after this instant (UTC), set past the merge of
  # task-1e98bcc0f1c64067 (#26199). A lease created before it, including every
  # row stuck before this code shipped, is left exactly as it is. Tests move it through the
  # `:chat_host_expired_turn_floor` app env; never edit it to reach old rows.
  @expired_turn_floor ~U[2026-11-14 12:00:00Z]
  @online_window 90
  # Live hosts (see live_count/1) one workspace may hold. Each has its own
  # :host_write_per_minute bucket, so this bounds a workspace's host writes.
  # People run one or two machines each; 10 leaves room for a small team.
  # Set with `config :barkpark, :chat_host_live_limit` (task-4abf105be723796a).
  @default_live_limit 10

  def issue_enrollment(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    secret = Security.mint_secret()
    now = DateTime.utc_now()
    limit = live_limit()

    params = %{
      workspace_id: workspace_id,
      name: value(attrs, :name),
      enrollment_hash: Security.hash_secret(secret),
      enrollment_expires_at: DateTime.add(now, @enrollment_ttl),
      approved_roots: value(attrs, :approved_roots, []),
      protocol_version: value(attrs, :protocol_version, 1),
      capabilities: value(attrs, :capabilities, %{})
    }

    # An early answer for the owner. `enroll/2` checks again under the lock,
    # because tokens issued while there was room could all complete.
    if live_count(workspace_id) >= limit do
      {:error, {:host_limit_reached, limit}}
    else
      case %RegisteredHost{} |> RegisteredHost.enrollment_changeset(params) |> Repo.insert() do
        {:ok, host} -> {:ok, %{host: public_host(host), enrollment_token: secret}}
        error -> error
      end
    end
  end

  def enroll(enrollment_token, attrs \\ %{})
      when is_binary(enrollment_token) and is_map(attrs) do
    now = DateTime.utc_now()
    hash = Security.hash_secret(enrollment_token)

    Repo.transaction(fn ->
      host =
        RegisteredHost
        |> where([h], h.enrollment_hash == ^hash)
        |> where([h], is_nil(h.enrolled_at) and is_nil(h.revoked_at))
        |> lock("FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(host) ->
          Repo.rollback(:invalid_enrollment)

        DateTime.compare(host.enrollment_expires_at, now) != :gt ->
          Repo.rollback(:expired_enrollment)

        true ->
          claim_live_slot(host.workspace_id)
          complete_enrollment(host, attrs, now)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # Two enrolments in one workspace queue on this lock until the first
  # commits, so the second counts the first. A refusal rolls back and leaves
  # the token unused until it expires. Hosts already enrolled are never
  # touched, so a workspace over the cap keeps them all.
  defp claim_live_slot(workspace_id) do
    lock_live_slots(workspace_id)
    limit = live_limit()

    if live_count(workspace_id) >= limit, do: Repo.rollback({:host_limit_reached, limit})
  end

  defp lock_live_slots(workspace_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["chat_host_live:" <> workspace_id])
  end

  # Live means it can still write: enrolled, not revoked, credential unexpired.
  # An expired credential never comes back (authenticate/1 and
  # rotate_credential/1 both refuse it), so freeing its slot is final.
  defp live_count(workspace_id) do
    now = DateTime.utc_now()

    RegisteredHost
    |> where([h], h.workspace_id == ^workspace_id)
    |> where([h], not is_nil(h.enrolled_at) and is_nil(h.revoked_at))
    |> where([h], h.credential_expires_at > ^now)
    |> Repo.aggregate(:count)
  end

  defp live_limit do
    case Application.get_env(:barkpark, :chat_host_live_limit, @default_live_limit) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_live_limit
    end
  end

  defp complete_enrollment(host, attrs, now) do
    credential = Security.mint_secret()

    params = %{
      enrolled_at: now,
      credential_hash: Security.hash_secret(credential),
      credential_version: 1,
      credential_expires_at: DateTime.add(now, @credential_ttl),
      approved_roots: host.approved_roots,
      protocol_version: value(attrs, :protocol_version, host.protocol_version),
      capabilities: value(attrs, :capabilities, host.capabilities),
      last_seen_at: now
    }

    case host |> RegisteredHost.enrollment_complete_changeset(params) |> Repo.update() do
      {:ok, enrolled} -> %{host: public_host(enrolled), credential: credential}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  def authenticate(credential) when is_binary(credential) do
    now = DateTime.utc_now()
    hash = Security.hash_secret(credential)

    RegisteredHost
    |> where([h], h.credential_hash == ^hash)
    |> where([h], is_nil(h.revoked_at) and not is_nil(h.enrolled_at))
    |> where([h], h.credential_expires_at > ^now)
    |> Repo.one()
    |> case do
      nil -> {:error, :invalid_credential}
      host -> {:ok, host}
    end
  end

  def rotate_credential(%RegisteredHost{} = host) do
    credential = Security.mint_secret()

    Repo.transaction(fn ->
      current =
        RegisteredHost
        |> where([h], h.id == ^host.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      # The same order as enrol: this host's own row, then the workspace key,
      # and the clock read only after both. Holding the key, nothing waits on
      # a row, so no cycle forms, and a rotation stuck behind a row lock never
      # stalls the workspace's enrolments. The key orders this expiry check
      # against claim_live_slot/1's count: an enrolment that saw this host
      # expired is committed before `now` is read here.
      if current, do: lock_live_slots(current.workspace_id)
      now = DateTime.utc_now()

      cond do
        is_nil(current) or not is_nil(current.revoked_at) ->
          Repo.rollback(:invalid_credential)

        # Authenticated just before the expiry, rotating just after: refused,
        # so an expired host, which holds no live slot, cannot come back.
        DateTime.compare(current.credential_expires_at, now) != :gt ->
          Repo.rollback(:invalid_credential)

        current.credential_hash != host.credential_hash or
            current.credential_version != host.credential_version ->
          Repo.rollback(:stale_credential)

        true ->
          attrs = %{
            credential_hash: Security.hash_secret(credential),
            credential_version: current.credential_version + 1,
            credential_expires_at: DateTime.add(now, @credential_ttl)
          }

          case current |> RegisteredHost.rotate_changeset(attrs) |> Repo.update() do
            {:ok, rotated} -> %{host: public_host(rotated), credential: credential}
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def heartbeat(%RegisteredHost{} = host, attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    params = %{
      protocol_version: value(attrs, :protocol_version, host.protocol_version),
      capabilities: value(attrs, :capabilities, host.capabilities),
      last_seen_at: now
    }

    host
    |> RegisteredHost.heartbeat_changeset(params)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        from(l in ExecutionLease,
          where:
            l.host_id == ^host.id and is_nil(l.revoked_at) and
              l.status in ["leased", "running", "disconnected"]
        )
        |> Repo.update_all(set: [expires_at: DateTime.add(now, @lease_ttl), updated_at: now])

        {:ok, public_host(updated)}

      error ->
        error
    end
  end

  def list_hosts(workspace_id) when is_binary(workspace_id) do
    RegisteredHost
    |> where([h], h.workspace_id == ^workspace_id and is_nil(h.revoked_at))
    |> order_by([h], asc: h.name)
    |> Repo.all()
    |> Enum.map(&public_host/1)
  end

  # A registered host is ALWAYS workspace-owned (enrollment requires a binary
  # `workspace_id`), so a nil workspace or host id can never match one. Guard
  # both to a binary before the query: a `:global`-scoped chat session carries
  # `owner_workspace_id == nil` (charter D82), and that nil used to reach the
  # `h.workspace_id == ^nil` comparison, which Ecto REFUSES ("comparing … with
  # nil is forbidden as it is unsafe") — crashing `resolve/2` and 500-ing every
  # registered-host send. Fail closed instead: no scope ⇒ no host (host_not_found).
  # A host id is typed by a caller (the DELETE path, the Studio revoke button), so
  # one that is not a UUID is no host too, not a CastError (task-34f964e9d66f48e4).
  def get_host(workspace_id, host_id) when is_binary(workspace_id) and is_binary(host_id) do
    with {:ok, workspace_id} <- Ecto.UUID.cast(workspace_id),
         {:ok, host_id} <- Ecto.UUID.cast(host_id) do
      RegisteredHost
      |> where([h], h.workspace_id == ^workspace_id and h.id == ^host_id)
      |> Repo.one()
    else
      :error -> nil
    end
  end

  def get_host(_workspace_id, _host_id), do: nil

  @impl true
  def resolve(workspace_id, host_id) do
    case get_host(workspace_id, host_id) do
      %RegisteredHost{revoked_at: nil, enrolled_at: enrolled_at} = host
      when not is_nil(enrolled_at) ->
        if online?(host), do: {:ok, public_host(host)}, else: {:error, :host_offline}

      _ ->
        {:error, :host_not_found}
    end
  end

  def revoke(workspace_id, host_id) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      case get_host(workspace_id, host_id) do
        nil ->
          Repo.rollback(:not_found)

        host ->
          with {:ok, revoked} <- host |> RegisteredHost.revoke_changeset(now) |> Repo.update() do
            from(l in ExecutionLease,
              where: l.host_id == ^host.id and is_nil(l.revoked_at)
            )
            |> Repo.update_all(set: [revoked_at: now, status: "cancelled", updated_at: now])

            Transport.revoke(host.id)
            broadcast_revoke(host.id)
            public_host(revoked)
          else
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  def lease_and_enqueue(host, command, opts) do
    host_id = value(host, :id)
    workspace_id = value(host, :workspace_id)
    now = DateTime.utc_now()
    key = command.idempotency_key || Ecto.UUID.generate()

    attrs = %{
      host_id: host_id,
      workspace_id: workspace_id,
      session_id: command.session_id,
      provider: command.provider,
      command_key: key,
      expires_at: DateTime.add(now, Keyword.get(opts, :lease_ttl, @lease_ttl))
    }

    result =
      case %ExecutionLease{} |> ExecutionLease.changeset(attrs) |> Repo.insert() do
        {:ok, lease} ->
          {:ok, lease}

        {:error, changeset} ->
          if constraint_error?(changeset),
            do: {:ok, Repo.get_by!(ExecutionLease, host_id: host_id, command_key: key)},
            else: {:error, changeset}
      end

    with {:ok, lease} <- result,
         :ok <- enqueue(lease, command) do
      {:ok, %{lease_id: lease.id, epoch: lease.epoch, command_key: lease.command_key}}
    end
  end

  # `Transport.enqueue/3` is a GenServer.call: a timeout exits AFTER the lease
  # row exists, and the call can still land in the queue later. The lease is
  # ended first, so no host runs a command its caller is told was not sent
  # (task-583b6031c13b28ac). When it cannot be ended the exit goes on: the
  # outcome is unknown, and the crash answer does not claim either way.
  defp enqueue(lease, command) do
    Transport.enqueue(lease.host_id, lease.id, command)
  catch
    :exit, reason ->
      case end_server_turn(where(ExecutionLease, [l], l.id == ^lease.id), :host_queue_unavailable) do
        :ok -> {:error, :host_queue_unavailable}
        :error -> exit(reason)
      end
  end

  @doc """
  Ends the `send_turn` lease leased under `command_key` for `session_id` when
  the server cannot stand behind the send: the user's row could not be stored
  (task-583b6031c13b28ac). The server writes the turn's close itself, as for an
  expired or unservable lease, so no host is handed it again.

  Only a lease no host has started is ended: still `leased`, with no event
  taken. A host that took the command but has posted nothing has its first
  event refused (a cursor conflict), and stops.

  `:ok` when the lease is ended now. `:error` when it is not: no such lease, a
  host already posted an event for it (some of the turn ran), it already
  closed, or the write failed. Never raises.
  """
  @spec withdraw_turn(String.t(), String.t()) :: :ok | :error
  def withdraw_turn(session_id, command_key)
      when is_binary(session_id) and is_binary(command_key) do
    ExecutionLease
    |> where([l], l.session_id == ^session_id and l.command_key == ^command_key)
    |> end_server_turn(:turn_not_stored)
  end

  # One transaction under the lease row lock, then the same settle as every
  # server close. Only a lease no host has started is ended: `leased`, with no
  # event taken (cursor 0). A host that has posted an event ran some of the
  # turn, so the caller must not be told it was not sent. The guard sits in
  # the locking read, so a host event committing first makes the row miss it
  # (Postgres re-checks the WHERE on the locked row), and one arriving after
  # the close takes a cursor conflict. A fault anywhere before the commit is
  # `:error`; after it the lease is ended, so a failed settle still answers
  # `:ok`.
  defp end_server_turn(lease_query, reason) do
    Repo.transaction(fn ->
      lease_query
      |> where([l], is_nil(l.revoked_at) and l.status == "leased" and l.last_cursor == 0)
      |> lock("FOR UPDATE")
      |> Repo.one()
      |> case do
        nil ->
          Repo.rollback(reason)

        lease ->
          lease
          |> end_turn(reason, "server:#{reason}", withdrawn_message(reason))
          |> ended_or_rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ended, execution_event, lease}} ->
        settle_withdrawn(execution_event, lease)

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # The session half first: the lease row is `completed`, so `next_commands/1`
  # never hands it out even while it is still in the queue. Then the queue,
  # which may be the thing that just failed.
  defp settle_withdrawn(execution_event, lease) do
    settle_session(execution_event, lease)
    Transport.complete(lease.id)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp withdrawn_message(:turn_not_stored),
    do: "The message could not be stored, so this turn was not sent. Send it again."

  defp withdrawn_message(:host_queue_unavailable),
    do: "The chat host's queue did not take this turn, so it was not sent. Send it again."

  @doc """
  The commands `host` is handed on its poll: every live lease it holds.

  Each command is checked again against the host's capabilities as stored now
  (task-fb73a4f2ed75231f): the dispatch path's `TurnAttachments.admit/3` and
  `BotFolder.admit/3` ran when the lease was made, and a heartbeat since then
  may have dropped what the turn needs (an older host binary would run a bot
  in the shared root, or drop a file). Such a lease is never handed out. The
  server ends its turn with the dispatch path's refusal as the reason, so the
  session leaves `working`, and the command leaves the queue.
  """
  def next_commands(%RegisteredHost{} = host) do
    host.id
    |> Transport.commands()
    |> Enum.flat_map(fn {lease_id, command} ->
      case Repo.get(ExecutionLease, lease_id) do
        %ExecutionLease{revoked_at: nil, status: status} = lease
        when status not in ["completed", "cancelled"] ->
          case servable(host, lease, command) do
            :ok ->
              [
                %{
                  lease_id: lease.id,
                  epoch: lease.epoch,
                  last_cursor: lease.last_cursor,
                  command: command_to_map(command)
                }
              ]

            {:error, refusal} ->
              end_unservable_turn(lease.id, refusal)
              []
          end

        _ ->
          []
      end
    end)
  end

  # The same checks, in the same order, as `Runtime.dispatch/4` for a
  # registered host.
  defp servable(host, lease, command) do
    with :ok <- TurnAttachments.admit(host, lease.provider, command) do
      BotFolder.admit(host, lease.provider, command)
    end
  end

  defp end_unservable_turn(lease_id, {reason, _provider} = refusal) do
    Repo.transaction(fn ->
      ExecutionLease
      |> where([l], l.id == ^lease_id and is_nil(l.revoked_at))
      |> lock("FOR UPDATE")
      |> Repo.one()
      |> case do
        nil ->
          Repo.rollback(refusal)

        lease ->
          lease
          |> end_turn(reason, "server:#{reason}", unservable_message(reason))
          |> ended_or_rollback(refusal)
      end
    end)
    |> case do
      {:ok, {:ended, execution_event, lease}} -> settle_ended_turn(execution_event, lease)
      _ -> Transport.complete(lease_id)
    end
  end

  defp unservable_message(:host_cannot_use_bot_folder),
    do:
      "The chat host no longer runs a bot in its own folder, so this turn was not sent. Update barkpark-chat-host."

  defp unservable_message(:host_cannot_receive_attachments),
    do:
      "The chat host no longer receives this turn's attachments, so it was not sent. Update barkpark-chat-host, or send the words alone."

  def accept_event(%RegisteredHost{} = host, attrs) when is_map(attrs) do
    lease_id = value(attrs, :lease_id)
    epoch = value(attrs, :epoch)
    cursor = value(attrs, :cursor)
    key = value(attrs, :idempotency_key)

    # U+0000 becomes U+FFFD in every string the event carries, after the status
    # label rules (which fold it to a space), so jsonb can store it and the host
    # keeps publishing (EventText, task-6497a4925af9b22f).
    with {:ok, event} <- normalize_status_event(value(attrs, :event, %{})) do
      accept_fenced_event(host, lease_id, epoch, cursor, key, EventText.replace_nul(event))
    end
  end

  # `lease_id` comes from the host's request body: one that is not a UUID (or is
  # missing) matches no lease, so it is the fence's `:lease_not_found`.
  defp accept_fenced_event(host, lease_id, epoch, cursor, key, event) do
    case Ecto.UUID.cast(lease_id) do
      {:ok, lease_id} -> accept_cast_event(host, lease_id, epoch, cursor, key, event)
      :error -> {:error, :lease_not_found}
    end
  end

  defp accept_cast_event(host, lease_id, epoch, cursor, key, event) do
    Repo.transaction(fn ->
      lease = ExecutionLease |> where([l], l.id == ^lease_id) |> lock("FOR UPDATE") |> Repo.one()

      case validate_fence(lease, host, epoch) do
        :ok ->
          if takes_new_event?(lease, cursor),
            do: reconcile_event(lease, cursor, key, event),
            else: Repo.rollback(:stale_fence)

        # The host's close comes after its lease expired. The fence still
        # refuses it, and the host takes that 409 as final and never sends the
        # close again (internal/chathost/runner.go), so the server ends the
        # turn here or nothing ever will (task-1e98bcc0f1c64067).
        {:error, :lease_expired} ->
          if status_for(event) == "completed" and created_since_floor?(lease),
            do: end_expired_turn(lease, :lease_expired),
            else: Repo.rollback(:lease_expired)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:accepted, execution_event, lease}} ->
        project_event(execution_event, lease)
        {:ok, :accepted}

      {:ok, {:ended, execution_event, lease}} ->
        settle_ended_turn(execution_event, lease)
        {:error, :lease_expired}

      other ->
        other
    end
  end

  # A `status` event is the host's 2-4 word label for the running turn
  # (task-a9983f9aeffb5430), shown on a client's working line. It is checked
  # before the fence, so a refusal takes no cursor and the host's next event
  # lands where the label would have: the label must be text; whitespace runs
  # fold to one space and it is cut to @status_label_max characters. Only
  # `kind` and `label` are kept, so what is stored and streamed is exactly that,
  # and a retry of the same label normalizes to the same payload (a duplicate,
  # not a cursor_conflict). It is never a message row and never moves the
  # session's status (the Recorder's catch-all leaves both alone).
  @status_label_max 60

  defp normalize_status_event(%{} = event) do
    if value(event, :kind) == "status",
      do: normalize_status_label(value(event, :label)),
      else: {:ok, event}
  end

  defp normalize_status_event(event), do: {:ok, event}

  defp normalize_status_label(label) when is_binary(label) do
    label =
      if String.valid?(label),
        do:
          label
          |> String.replace(~r/[\s\p{C}]+/u, " ")
          |> String.trim()
          |> cut_status_label()
          |> String.trim_trailing(),
        else: ""

    if label == "",
      do: {:error, :invalid_status_label},
      else: {:ok, %{"kind" => "status", "label" => label}}
  end

  defp normalize_status_label(_label), do: {:error, :invalid_status_label}

  # Whole graphemes while the label stays within @status_label_max codepoints,
  # so combining marks cannot carry a "short" label past 4 * @status_label_max
  # bytes (the Go host counts the same codepoints).
  defp cut_status_label(label) do
    label
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, count} ->
      count = count + length(String.codepoints(grapheme))

      if count > @status_label_max,
        do: {:halt, {kept, count}},
        else: {:cont, {[grapheme | kept], count}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  @doc """
  A turn's status label posted OUT of the cursor sequence
  (`POST /v1/chat-host/leases/:lease_id/status`, task-768e7dc4449cc7b9), so a
  label in flight never holds the turn's next event.

  The fence is `live_lease_for_host/2` (this host's live lease, in its
  workspace, on a session it executes) plus the lease's integer `epoch`; every
  miss is the one `{:error, :stale_fence}`. The label is checked by the same
  rules as a `status` event. Nothing is written: no ExecutionEvent row, no
  cursor, no lease or session change, so it cannot reach the expired-lease
  close or the run-once rule. The Recorder streams it as the same runtime
  `:status` event the cursor path does, once per turn, only while the turn is
  open and has no text yet. Answers `{:ok, :streamed}`, or `{:ok, :dropped}`
  when the turn is not open, already has text or already streamed a label, or
  when the session has no Recorder or it did not answer within 2 s.
  """
  def accept_status(%RegisteredHost{} = host, lease_id, attrs) when is_map(attrs) do
    epoch = value(attrs, :epoch)

    with %ExecutionLease{epoch: ^epoch} = lease when is_integer(epoch) <-
           live_lease_for_host(host, lease_id),
         {:ok, event} <- normalize_status_label(value(attrs, :label)) do
      {:ok, stream_status(lease, event)}
    else
      {:error, :invalid_status_label} = refused -> refused
      _miss -> {:error, :stale_fence}
    end
  end

  defp stream_status(lease, event) do
    status = %Barkpark.StudioChat.Runtime.Event{
      provider: lease.provider,
      session_id: lease.session_id,
      kind: :status,
      native: event
    }

    case Barkpark.StudioChat.Recorder.whereis(lease.session_id) do
      pid when is_pid(pid) -> GenServer.call(pid, {:offer_status, status}, 2_000)
      nil -> :dropped
    end
  catch
    :exit, _ -> :dropped
  end

  @doc """
  Ends every turn whose host went silent: a `leased`/`running` lease that
  expired more than #{@expired_turn_grace}s ago (no heartbeat for
  #{@lease_ttl + @expired_turn_grace}s). A host that dies for good never sends
  its close, so without this the session stays `working` forever. The grace
  lets a host back from a short gap keep its turn: its next heartbeat renews
  the lease. Each lease is re-read under `FOR UPDATE`, so a heartbeat or a
  second BEAM sweeping at the same time ends nothing twice. Returns how many
  turns it ended.

  It never touches older rows: the lease's session must be `working`, and the
  lease must have been created (`inserted_at`, which nothing updates) at or
  after `floor`, the fixed instant this code shipped (`@expired_turn_floor`).
  A lease created before the floor is left exactly as it is, even when a
  heartbeat carried its `expires_at` past the floor. One created after it is
  ended however long the server was down.
  """
  def end_expired_turns(now \\ DateTime.utc_now(), floor \\ expired_turn_floor()) do
    cutoff = DateTime.add(now, -@expired_turn_grace)

    from(l in ExecutionLease,
      join: s in Barkpark.StudioChat.Session,
      on: s.id == l.session_id,
      where: s.status == "working",
      where: l.status in ["leased", "running"],
      where: is_nil(l.revoked_at) and l.expires_at < ^cutoff and l.inserted_at >= ^floor,
      select: l.id
    )
    |> Repo.all()
    |> Enum.count(&end_expired_turn_by_id(&1, cutoff, floor))
  end

  defp end_expired_turn_by_id(lease_id, cutoff, floor) do
    Repo.transaction(fn ->
      ExecutionLease
      |> where([l], l.id == ^lease_id and is_nil(l.revoked_at))
      |> where([l], l.expires_at < ^cutoff and l.inserted_at >= ^floor)
      |> lock("FOR UPDATE")
      |> Repo.one()
      |> case do
        nil -> :noop
        lease -> end_expired_turn(lease, :host_silent)
      end
    end)
    |> case do
      {:ok, {:ended, execution_event, lease}} ->
        settle_ended_turn(execution_event, lease)
        true

      _ ->
        false
    end
  end

  # Runs inside the transaction that holds the lease row lock. The server
  # writes the close itself, at the next cursor, so it rides the same durable
  # path as a host's close: the lease is `completed` (no heartbeat renews it,
  # no poll lists it again) and the recorder ends the turn on projection or
  # on its replay. A lease that already closed ends nothing.
  defp end_expired_turn(lease, reason) do
    lease
    |> end_turn(
      reason,
      "server:lease_expired",
      "The chat host's lease expired before this turn closed."
    )
    |> ended_or_rollback(:lease_expired)
  end

  defp ended_or_rollback({:ended, _execution_event, _lease} = ended, _reason), do: ended
  defp ended_or_rollback(:not_ended, reason), do: Repo.rollback(reason)

  # The server's own close of a `leased`/`running` lease, written at the next
  # cursor inside the caller's transaction, under its row lock. `:not_ended`
  # (a lease already closed, or a write that failed) asks the caller to roll
  # back.
  defp end_turn(%ExecutionLease{status: status} = lease, reason, key, message)
       when status in ["leased", "running"] do
    cursor = lease.last_cursor + 1

    event = %{
      "kind" => "terminal",
      "terminal_state" => "failed",
      "origin" => "server",
      "reason" => Atom.to_string(reason),
      "error" => %{"message" => message}
    }

    with {:ok, execution_event} <- persist_event(lease, cursor, key, event),
         :ok <- persist_cursor(lease, cursor, event) do
      {:ended, execution_event, lease}
    else
      _ -> :not_ended
    end
  end

  defp end_turn(_lease, _reason, _key, _message), do: :not_ended

  # On when the lease was CREATED: a heartbeat renews `expires_at` on every
  # live lease, so a lease from before deploy can carry its expiry past the
  # floor, while `inserted_at` never moves.
  defp created_since_floor?(%ExecutionLease{inserted_at: inserted_at}),
    do: DateTime.compare(inserted_at, expired_turn_floor()) != :lt

  defp expired_turn_floor,
    do: Application.get_env(:barkpark, :chat_host_expired_turn_floor, @expired_turn_floor)

  # After commit. The session row leaves `working` even when no recorder is
  # running to project the close. Only a `working` row moves: an `active` or
  # `exited` session has no open turn to close, so its status stays and the
  # close is marked projected instead of sent, because the recorder would mark
  # any session it gets an error for `exited`. When another live lease holds
  # the session, its status stays and the close is not sent either: a
  # Runtime.Event carries no lease id, so the recorder would end whatever turn
  # it has open (the newer lease's) and mark the session `exited`. The live
  # lease's own close ends the recorder's turn (task-d8685be32b21e31b).
  defp settle_ended_turn(execution_event, lease) do
    Transport.complete(lease.id)
    settle_session(execution_event, lease)
  end

  defp settle_session(execution_event, lease) do
    if is_nil(live_report_fence(lease.session_id)) and
         match?({1, _}, exit_if_working(lease.session_id)),
       do: project_event(execution_event, lease),
       else: mark_projected(execution_event.id)
  end

  defp exit_if_working(session_id) do
    now = DateTime.utc_now()

    from(s in Barkpark.StudioChat.Session, where: s.id == ^session_id and s.status == "working")
    |> Repo.update_all(set: [status: "exited", last_active_at: now, updated_at: now])
  end

  # A closed lease takes no new event (task-77353697aed3ffa4). The fence alone
  # passed one: a closed lease's `expires_at` is still up to @lease_ttl s
  # ahead, and the Recorder cannot tell leases apart, so a stray close from a
  # lease the server withdrew ended the session's NEWER turn. The refusal is
  # `:stale_fence` (409, final for the host); nothing is written or projected.
  # A cursor at or below `last_cursor` still reaches `reconcile_event/4`, so a
  # retry of a taken event stays a duplicate. (A codex `error` that will retry
  # leaves the lease running, `status_for/1`, so it takes the turn's events.)
  # Two closing kinds still take the next event: `error` (one that will not
  # retry is followed by the host's terminal when the app-server exits, "exited
  # before turn completion", internal/chathost/local_handler.go) and
  # `control_completed` (a Stop's ack, followed by the turn's own close). Only
  # a `completed` lease pays the read. Even those are refused once the session
  # has a newer lease (task-1eefeeb52ed19e73): a person can send again in that
  # gap, and the Recorder would end the newer turn. (After a Claude result the
  # host sends no terminal: `runClaude` returns nil once it saw one.)
  @continuing_kinds ["error", "control_completed"]
  defp takes_new_event?(%ExecutionLease{status: "cancelled", last_cursor: current}, cursor)
       when is_integer(cursor) and cursor > current,
       do: false

  defp takes_new_event?(
         %ExecutionLease{status: "completed", last_cursor: current} = lease,
         cursor
       )
       when is_integer(cursor) and cursor > current do
    last_kind =
      ExecutionEvent
      |> where([e], e.lease_id == ^lease.id and e.cursor == ^current)
      |> select([e], e.kind)
      |> Repo.one()

    last_kind in @continuing_kinds and not newer_lease?(lease)
  end

  defp takes_new_event?(_lease, _cursor), do: true

  # On the (workspace_id, session_id) index.
  defp newer_lease?(%ExecutionLease{} = lease) do
    ExecutionLease
    |> where([l], l.workspace_id == ^lease.workspace_id and l.session_id == ^lease.session_id)
    |> where([l], l.inserted_at > ^lease.inserted_at)
    |> Repo.exists?()
  end

  defp reconcile_event(%ExecutionLease{last_cursor: current} = lease, cursor, key, event)
       when cursor == current + 1 do
    with {:ok, execution_event} <- persist_event(lease, cursor, key, event),
         :ok <- persist_cursor(lease, cursor, event) do
      if status_for(event) == "completed", do: Transport.complete(lease.id)
      {:accepted, execution_event, lease}
    else
      :duplicate -> :duplicate
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reconcile_event(%ExecutionLease{last_cursor: current} = lease, cursor, key, event)
       when cursor <= current do
    case Repo.get_by(ExecutionEvent, lease_id: lease.id, cursor: cursor) do
      %ExecutionEvent{idempotency_key: ^key, payload: ^event} -> :duplicate
      %ExecutionEvent{} -> Repo.rollback(:cursor_conflict)
      nil -> Repo.rollback(:cursor_history_lost)
    end
  end

  defp reconcile_event(%ExecutionLease{}, _cursor, _key, _event),
    do: Repo.rollback(:cursor_gap)

  defp persist_cursor(lease, cursor, event) do
    lease
    |> Ecto.Changeset.change(last_cursor: cursor, status: status_for(event))
    |> Repo.update()
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp persist_event(lease, cursor, key, event) do
    attrs = %{
      lease_id: lease.id,
      host_id: lease.host_id,
      workspace_id: lease.workspace_id,
      cursor: cursor,
      idempotency_key: key,
      kind: value(event, :kind, "event"),
      payload: event
    }

    case %ExecutionEvent{} |> ExecutionEvent.changeset(attrs) |> Repo.insert() do
      {:ok, execution_event} ->
        {:ok, execution_event}

      {:error, changeset} ->
        case Repo.get_by(ExecutionEvent, lease_id: lease.id, cursor: cursor) do
          %ExecutionEvent{idempotency_key: ^key, payload: ^event} -> :duplicate
          %ExecutionEvent{} -> {:error, :cursor_conflict}
          nil -> {:error, changeset}
        end
    end
  end

  @doc """
  Authoritative external state report for one session (herd-s6, charter
  D78h–D80h): the registered host that holds the session's live execution-lease
  fence writes the herd four-state directly — while that fence lives, the
  reporter is the SOLE truth source (the Recorder's derivation is suspended for
  both the DB column and the fleet wire; see `Recorder.note_reported_state/3`).

  ## Fence = literal `chat_execution_leases` reuse (D79h)

  No new table, no migration. Several leases can exist per session (one per
  dispatched command), so the fence row follows the selection rule: the LATEST
  non-revoked, unexpired lease with status `leased`/`running` for the session.
  It is locked `FOR UPDATE` and validated exactly like `accept_event/2`
  (`validate_fence/3`): wrong host or wrong/stale epoch → `:stale_fence`;
  expired → `:lease_expired` (both 409 at the route); no lease at all →
  `:lease_not_found`. The lease `epoch` is compared but VESTIGIAL — nothing in
  chat_hosts ever bumps it (it is always the insert default `1` today); we
  deliberately do NOT build a bump path, we only refuse a mismatch.

  On success the write funnels through the D80h choke point
  (`StudioChat.set_agent_state/4`, source `:reported` — for `"blocked"` the
  live fence itself is the in-WHERE corroboration, satisfied by construction
  inside this same transaction), then AFTER commit the reported truth is
  broadcast on the activity topic as `{:chat_reported_state, session_id, frame}`
  (the FleetHub projects it onto the fleet wire) and the session's live
  Recorder — if any — is told to suspend its derivation until hand-back.
  """
  def report_state(%RegisteredHost{} = host, session_id, agent_state, epoch)
      when is_binary(session_id) and agent_state in ["working", "blocked", "idle", "unknown"] do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      lease = report_fence_lease(session_id, now)

      with :ok <- validate_fence(lease, host, epoch) do
        case Barkpark.StudioChat.set_agent_state(session_id, agent_state, :reported, now) do
          {1, _} -> %{lease: lease, ts: now}
          {0, _} -> Repo.rollback(:session_not_found)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %{lease: lease, ts: ts}} ->
        broadcast_reported_state(session_id, agent_state, ts)
        notify_recorder_of_report(session_id, agent_state, lease.expires_at)

        {:ok,
         %{
           session_id: session_id,
           agent_state: agent_state,
           lease_id: lease.id,
           epoch: lease.epoch,
           expires_at: lease.expires_at
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The correlated live-fence EXISTS predicate (herd-s6): execution leases that
  currently fence the parent query's session — the parent binding MUST be named
  `:session`. One owner for the predicate: `StudioChat.set_agent_state/4` uses
  it as the `:reported`-blocked corroboration and the agent-state sweep uses
  its negation, so "live fence" can never mean two different things.
  """
  def live_fence_subquery(now) do
    from(l in ExecutionLease,
      where: l.session_id == parent_as(:session).id,
      where: l.status in ["leased", "running"],
      where: is_nil(l.revoked_at) and l.expires_at > ^now
    )
  end

  @doc """
  The live lease `host` holds under the raw, caller-supplied `lease_id`, or nil.

  This is the fence for the host-scoped attachment read
  (`/papers/chat-host-attachments-plan`): the host names the lease it is
  serving, never a session, and the session is taken from the row this returns.
  A lease answers only when every term holds:

    * `lease_id` casts to a UUID (raw input never reaches the query uncast);
    * it is THIS host's lease (`host_id`), stamped with this host's workspace;
    * it is live: status `leased` or `running`, unrevoked and unexpired, the
      same terms as `live_fence_subquery/1`;
    * its session exists and is owned by this host's workspace. The lease row's
      `workspace_id` is a copy written at lease time; the session's owner is
      the tenancy truth, so both must agree;
    * its session is a `registered_host` session whose `execution_host_id` is
      this host. The lease row's `host_id` is also a copy; the session names
      its executor, so a lease on a managed session or on a session another
      host executes opens nothing, whoever minted it.

  Every miss is the same nil, so a caller cannot tell another host's lease from
  an ended one or from an id that never existed.
  """
  def live_lease_for_host(host, lease_id, now \\ DateTime.utc_now())

  def live_lease_for_host(%RegisteredHost{id: host_id, workspace_id: workspace_id}, lease_id, now)
      when is_binary(host_id) and is_binary(workspace_id) do
    case Ecto.UUID.cast(lease_id) do
      {:ok, lease_id} ->
        from(l in ExecutionLease,
          join: s in Barkpark.StudioChat.Session,
          on: s.id == l.session_id,
          where: l.id == ^lease_id,
          where: l.host_id == ^host_id and l.workspace_id == ^workspace_id,
          where: s.owner_workspace_id == ^workspace_id,
          where: s.execution_target == "registered_host" and s.execution_host_id == ^host_id,
          where: l.status in ["leased", "running"],
          where: is_nil(l.revoked_at) and l.expires_at > ^now
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  def live_lease_for_host(_host, _lease_id, _now), do: nil

  @doc """
  The session's current live report fence, or nil (herd-s6). The Recorder's
  hand-back check calls this when its fence timer fires: a still-live lease
  (the host heartbeat extends `expires_at`) re-arms the suspension; nil means
  the reporter is gone — authority hands back explicitly.
  """
  def live_report_fence(session_id, now \\ DateTime.utc_now()) when is_binary(session_id) do
    ExecutionLease
    |> where([l], l.session_id == ^session_id)
    |> where([l], l.status in ["leased", "running"])
    |> where([l], is_nil(l.revoked_at) and l.expires_at > ^now)
    |> order_by([l], desc: l.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  WHO IS EXECUTING THIS SESSION, as two independently-measured names — the read
  behind the Studio chat context band (`Barkpark.StudioChat.ContextIdentity`).

  A projection, not a decision: it reports both truths and judges neither.

    * `:lease_host` — the host holding the session's LIVE execution lease, via
      the ONE canonical fence selector (`live_report_fence/2`), so "who runs
      this session" can never mean something different here than it means to
      the report gate. `nil` when no host does — the server itself runs it.
    * `:reporting_host` — the host that sent the session's most recent
      execution event, across ALL of its leases. Normally the same host; when
      it is not, a lease TRANSFERRED and the band says so.

  Both are host NAMES (never ids, never credentials): the band is chrome, and
  a name is the only part of a registered host that is safe to paint.
  """
  def session_execution_identity(session_id) when is_binary(session_id) do
    %{
      lease_host: host_name(lease_host_id(session_id)),
      reporting_host: host_name(latest_reporting_host_id(session_id))
    }
  end

  defp lease_host_id(session_id) do
    case live_report_fence(session_id) do
      %ExecutionLease{host_id: host_id} -> host_id
      _ -> nil
    end
  end

  # Ordered by `inserted_at` and NOT by `cursor`: cursor is per-LEASE, so a
  # cross-lease `order_by: cursor` would rank a transferred host's first event
  # (cursor 1) behind the old host's tenth and report the transfer backwards.
  defp latest_reporting_host_id(session_id) do
    from(e in ExecutionEvent,
      join: l in ExecutionLease,
      on: l.id == e.lease_id,
      where: l.session_id == ^session_id,
      order_by: [desc: e.inserted_at, desc: e.cursor],
      limit: 1,
      select: e.host_id
    )
    |> Repo.one()
  end

  defp host_name(nil), do: nil

  defp host_name(host_id) do
    case Repo.get(RegisteredHost, host_id) do
      %RegisteredHost{name: name} -> name
      _ -> nil
    end
  end

  # D79h selection rule, plus honest deny grammar: prefer the LATEST live lease
  # (non-revoked, unexpired, leased/running); when none exists, fall back to the
  # latest leased/running row regardless of expiry/revocation so
  # `validate_fence/3` can distinguish `:lease_expired` from `:stale_fence`
  # instead of collapsing every failure into `:lease_not_found`. The session id
  # is the route's `:id`: one that is not a UUID has no lease.
  defp report_fence_lease(session_id, now) do
    case Ecto.UUID.cast(session_id) do
      {:ok, session_id} -> report_fence_lease_cast(session_id, now)
      :error -> nil
    end
  end

  defp report_fence_lease_cast(session_id, now) do
    base =
      ExecutionLease
      |> where([l], l.session_id == ^session_id)
      |> where([l], l.status in ["leased", "running"])
      |> order_by([l], desc: l.inserted_at)
      |> limit(1)
      |> lock("FOR UPDATE")

    live =
      base
      |> where([l], is_nil(l.revoked_at) and l.expires_at > ^now)
      |> Repo.one()

    live || Repo.one(base)
  end

  # Reported truth on the fleet wire (herd-s6): the Recorder is suspended while
  # the fence lives, and FleetHub hears only the activity topic — so the
  # reporter's write must speak there itself, as its OWN frame kind (the
  # four-state rides literally; reverse-mapping through the wave-5 activity
  # vocabulary would distort "unknown" through the :offline prior rule).
  defp broadcast_reported_state(session_id, agent_state, ts) do
    owner_ws =
      case Barkpark.StudioChat.get_session(session_id) do
        %{owner_workspace_id: ws} -> ws
        _ -> nil
      end

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Barkpark.StudioChat.Recorder.activity_topic(),
      {:chat_reported_state, session_id,
       %{agent_state: agent_state, ts: ts, owner_workspace_id: owner_ws}}
    )
  catch
    :exit, _ -> :ok
  end

  defp notify_recorder_of_report(session_id, agent_state, expires_at) do
    Barkpark.StudioChat.Recorder.note_reported_state(session_id, agent_state, expires_at)
  catch
    :exit, _ -> :ok
  end

  defp validate_fence(nil, _host, _epoch), do: {:error, :lease_not_found}

  defp validate_fence(%ExecutionLease{} = lease, host, epoch) do
    now = DateTime.utc_now()

    cond do
      lease.host_id != host.id -> {:error, :stale_fence}
      lease.epoch != epoch -> {:error, :stale_fence}
      not is_nil(lease.revoked_at) -> {:error, :stale_fence}
      DateTime.compare(lease.expires_at, now) != :gt -> {:error, :lease_expired}
      true -> :ok
    end
  end

  # A codex error that will retry is not the turn's end, for the lease as for
  # the Recorder (task-7d3afdffa1fd4473): the lease stays running, so the
  # heartbeat renews it, the expiry sweep ends it if the host dies, and the
  # turn's own close after a Stop is taken.
  defp status_for(%{"kind" => "error"} = event) do
    retrying = %Barkpark.StudioChat.Runtime.Event{kind: :error, error: event["error"]}

    if Barkpark.StudioChat.Runtime.Event.retrying_error?(retrying),
      do: "running",
      else: "completed"
  end

  defp status_for(%{"kind" => kind})
       when kind in [
              "terminal",
              "completed",
              "turn_completed",
              "control_completed",
              "process_failed",
              "protocol_error"
            ],
       do: "completed"

  defp status_for(%{kind: kind})
       when kind in [
              :terminal,
              :completed,
              :turn_completed,
              :control_completed,
              :error,
              :process_failed,
              :protocol_error
            ],
       do: "completed"

  defp status_for(_), do: "running"

  defp command_to_map(%_{} = command), do: Map.from_struct(command)
  defp command_to_map(command), do: command

  defp constraint_error?(changeset),
    do:
      Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
        opts[:constraint] == :unique
      end)

  defp online?(%RegisteredHost{last_seen_at: nil}), do: false

  defp online?(%RegisteredHost{last_seen_at: seen}) do
    DateTime.compare(seen, DateTime.add(DateTime.utc_now(), -@online_window)) == :gt
  end

  defp public_host(host) do
    %{
      id: host.id,
      workspace_id: host.workspace_id,
      name: host.name,
      enrolled: not is_nil(host.enrolled_at),
      revoked: not is_nil(host.revoked_at),
      approved_roots: host.approved_roots,
      protocol_version: host.protocol_version,
      capabilities: host.capabilities,
      credential_version: host.credential_version,
      credential_expires_at: host.credential_expires_at,
      last_seen_at: host.last_seen_at,
      online: online?(host)
    }
  end

  defp broadcast_revoke(host_id) do
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      "chat_host:#{host_id}",
      {:chat_host_revoked, host_id}
    )
  catch
    :exit, _ -> :ok
  end

  defp broadcast_event(lease, cursor, key, event) do
    kind = value(event, :kind, "event")

    native =
      cond do
        is_binary(value(event, :delta)) ->
          Map.put(event, "params", %{"delta" => value(event, :delta)})

        is_map(value(event, :item)) ->
          Map.put(event, "params", %{"item" => value(event, :item)})

        true ->
          event
      end

    normalized = %Barkpark.StudioChat.Runtime.Event{
      provider: lease.provider,
      session_id: lease.session_id,
      provider_session_id: value(event, :provider_session_id),
      turn_id: value(event, :turn_id),
      item_id: value(event, :item_id),
      sequence: cursor,
      idempotency_key: key,
      durability: :durable,
      kind: normalize_host_kind(kind, event),
      approval_id: value(event, :approval_id),
      terminal_state: normalize_terminal_state(value(event, :terminal_state)),
      error: value(event, :error),
      native: native
    }

    normalized
  catch
    :exit, _ -> nil
  end

  @doc false
  def replay_unprojected(session_id) when is_binary(session_id) do
    ExecutionEvent
    |> join(:inner, [e], l in ExecutionLease, on: l.id == e.lease_id)
    |> where([e, l], l.session_id == ^session_id and is_nil(e.projected_at))
    |> order_by([e, l], asc: e.inserted_at, asc: e.cursor)
    |> select([e, l], {e, l})
    |> Repo.all()
    |> Enum.map(fn {event, lease} ->
      normalized = broadcast_event(lease, event.cursor, event.idempotency_key, event.payload)
      {event.id, normalized}
    end)
  end

  @doc false
  def mark_projected(event_id) when is_binary(event_id) do
    ExecutionEvent
    |> where([e], e.id == ^event_id and is_nil(e.projected_at))
    |> Repo.update_all(set: [projected_at: DateTime.utc_now()])

    :ok
  end

  defp project_event(%ExecutionEvent{projected_at: projected_at}, _lease)
       when not is_nil(projected_at),
       do: :ok

  defp project_event(%ExecutionEvent{} = execution_event, %ExecutionLease{} = lease) do
    normalized =
      broadcast_event(
        lease,
        execution_event.cursor,
        execution_event.idempotency_key,
        execution_event.payload
      )

    case {normalized, Barkpark.StudioChat.Recorder.whereis(lease.session_id)} do
      {%Barkpark.StudioChat.Runtime.Event{} = event, recorder} when is_pid(recorder) ->
        case GenServer.call(recorder, {:project_runtime_event, event}) do
          :ok ->
            execution_event
            |> Ecto.Changeset.change(projected_at: DateTime.utc_now())
            |> Repo.update()
            |> case do
              {:ok, _} -> :ok
              _ -> :retry
            end

          _ ->
            :retry
        end

      _ ->
        :retry
    end
  catch
    :exit, _ -> :retry
  end

  defp normalize_host_kind("session_started", _event), do: :session_started
  defp normalize_host_kind("turn_started", _event), do: :turn_started
  defp normalize_host_kind("text_delta", _event), do: :text_delta
  defp normalize_host_kind("approval_requested", _event), do: :approval_requested
  defp normalize_host_kind("turn_completed", _event), do: :turn_completed
  defp normalize_host_kind("control_completed", _event), do: :control_completed
  defp normalize_host_kind("item_started", _event), do: :item_started
  defp normalize_host_kind("item_completed", _event), do: :item_completed
  defp normalize_host_kind("error", _event), do: :error
  defp normalize_host_kind("status", _event), do: :status

  defp normalize_host_kind("terminal", event) do
    case value(event, :terminal_state) do
      state when state in ["completed", "interrupted", "cancelled"] -> :turn_completed
      _ -> :error
    end
  end

  defp normalize_host_kind(kind, _event), do: kind

  defp normalize_terminal_state("completed"), do: :completed
  defp normalize_terminal_state("interrupted"), do: :interrupted
  defp normalize_terminal_state("cancelled"), do: :interrupted
  defp normalize_terminal_state("failed"), do: :failed
  defp normalize_terminal_state(state), do: state

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
