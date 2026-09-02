defmodule Barkpark.ChatHosts do
  @moduledoc "Workspace-scoped registration and fenced dispatch for local Chat hosts."

  @behaviour Barkpark.StudioChat.Runtime.HostDirectory

  import Ecto.Query

  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease, RegisteredHost, Security, Transport}
  alias Barkpark.Repo

  @enrollment_ttl 10 * 60
  @credential_ttl 30 * 24 * 60 * 60
  @lease_ttl 60
  @online_window 90

  def issue_enrollment(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    secret = Security.mint_secret()
    now = DateTime.utc_now()

    params = %{
      workspace_id: workspace_id,
      name: value(attrs, :name),
      enrollment_hash: Security.hash_secret(secret),
      enrollment_expires_at: DateTime.add(now, @enrollment_ttl),
      approved_roots: value(attrs, :approved_roots, []),
      protocol_version: value(attrs, :protocol_version, 1),
      capabilities: value(attrs, :capabilities, %{})
    }

    case %RegisteredHost{} |> RegisteredHost.enrollment_changeset(params) |> Repo.insert() do
      {:ok, host} -> {:ok, %{host: public_host(host), enrollment_token: secret}}
      error -> error
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
          complete_enrollment(host, attrs, now)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
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
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      current =
        RegisteredHost
        |> where([h], h.id == ^host.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(current) or not is_nil(current.revoked_at) ->
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
  def get_host(workspace_id, host_id) when is_binary(workspace_id) and is_binary(host_id) do
    RegisteredHost
    |> where([h], h.workspace_id == ^workspace_id and h.id == ^host_id)
    |> Repo.one()
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
         :ok <- Transport.enqueue(host_id, lease.id, command) do
      {:ok, %{lease_id: lease.id, epoch: lease.epoch, command_key: lease.command_key}}
    end
  end

  def next_commands(%RegisteredHost{} = host) do
    host.id
    |> Transport.commands()
    |> Enum.flat_map(fn {lease_id, command} ->
      case Repo.get(ExecutionLease, lease_id) do
        %ExecutionLease{revoked_at: nil, status: status} = lease
        when status not in ["completed", "cancelled"] ->
          [
            %{
              lease_id: lease.id,
              epoch: lease.epoch,
              last_cursor: lease.last_cursor,
              command: command_to_map(command)
            }
          ]

        _ ->
          []
      end
    end)
  end

  def accept_event(%RegisteredHost{} = host, attrs) when is_map(attrs) do
    lease_id = value(attrs, :lease_id)
    epoch = value(attrs, :epoch)
    cursor = value(attrs, :cursor)
    key = value(attrs, :idempotency_key)
    event = value(attrs, :event, %{})

    Repo.transaction(fn ->
      lease = ExecutionLease |> where([l], l.id == ^lease_id) |> lock("FOR UPDATE") |> Repo.one()

      with :ok <- validate_fence(lease, host, epoch) do
        reconcile_event(lease, cursor, key, event)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:accepted, execution_event, lease}} ->
        project_event(execution_event, lease)
        {:ok, :accepted}

      other ->
        other
    end
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
  # instead of collapsing every failure into `:lease_not_found`.
  defp report_fence_lease(session_id, now) do
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

  defp status_for(%{"kind" => kind})
       when kind in [
              "terminal",
              "completed",
              "turn_completed",
              "control_completed",
              "error",
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
