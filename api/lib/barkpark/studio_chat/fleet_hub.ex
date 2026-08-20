defmodule Barkpark.StudioChat.FleetHub do
  @moduledoc """
  The herd fleet hub (chat-tui charter D44h/D45h): ONE subscription to
  `Recorder.activity_topic/0` fans the whole herd out onto a single wire, so a
  client watching N sessions holds ONE `GET /v1/chat/events` stream instead of N
  per-session streams.

  ## What it does

  A singleton `GenServer` (a sibling of `Notifier`/`AgentStateSweeper` under
  `StudioChat.Supervisor`) subscribes the wave-5 activity topic and re-projects
  it onto the fleet topic (`fleet_topic/0`) as compact state-change frames:

    * `{:chat_activity, sid, activity}` → the wave-5 `:state` is mapped onto the
      persisted four-state vocabulary (`map_state/2`, byte-faithful to
      `Recorder.map_agent_state/2`) and, ONLY when that four-state actually flips
      (state-change frames only — a line-only "Bash x → Bash y" is NOT a flip),
      a `{:fleet_flip, entry}` is broadcast. Each flip mints a fresh monotonic
      `seq` and rides the ring so it can be replayed on reconnect.
    * `{:chat_heartbeat, sid, ts}` → a `{:fleet_heartbeat, sid, ts, owner_ws}`
      liveness tick — id-less, seq-less, NEVER ringed (charter D45h): it proves
      a long tool call is not a dead BEAM without pretending to be a replayable
      state change.
    * `{:chat_title, sid, title}` → a `{:fleet_title, sid, title, owner_ws}`
      title update (charter D69h) — id-less, seq-less, NEVER ringed, exactly
      like a heartbeat: the async AI title lands once per session and a
      reconnecting client gets the fresh title from its next snapshot for free,
      so pretending it is a replayable state change would buy nothing.
    * `{:chat_workflow, …}` → EXPLICITLY ignored (D44h): the workflow rail rides
      the per-session wire, never the fleet wire.

  ## Boot-epoch fence (D44h)

  The boot `epoch` is `System.system_time(:microsecond)` minted at `init/1` —
  NEVER `:erlang.unique_integer` (which restarts with the BEAM; the sheets
  session already rejected it for the identical fence). A `Last-Event-ID` cursor
  is the opaque `"<epoch>:<seq>"` pair. A FleetHub restart mints a fresh epoch,
  so every prior cursor's epoch mismatches and the caller degrades to a fresh
  scoped snapshot — the ring is an in-memory plain list (cap #{256}), NOT ETS,
  precisely because a restart is exactly when cursors SHOULD invalidate.

  ## Fail-closed scope (D43h — seam 3 of 3)

  The ring stores each entry's `owner_workspace_id` so ring replay filters
  per-entry through `StudioChat.scope_match?/2` — the SAME term twin the live
  seam uses and `StudioChat.scope_sessions/2` mirrors in SQL. `owner_workspace_id`
  is STRIPPED before any client frame (it lives on the entry only for the scope
  gate). Heartbeats carry no owner of their own, so they are scoped by the
  session's LAST-SEEN owner (learned from its activity flips); a session whose
  activity FleetHub never saw fails closed for every workspace scope.
  """

  use GenServer

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder

  @ring_cap 256
  @fleet_topic "studio_chat:fleet"

  @typedoc "A ring entry — a replayable four-state flip. `owner_ws` never leaves this map."
  @type entry :: %{
          seq: non_neg_integer(),
          session_id: binary(),
          agent_state: binary(),
          ts: DateTime.t(),
          owner_ws: binary() | nil
        }

  @doc "The PubSub topic connections subscribe to for live fleet frames."
  @spec fleet_topic() :: String.t()
  def fleet_topic, do: @fleet_topic

  @doc "The ring capacity (charter D44h)."
  @spec ring_cap() :: pos_integer()
  def ring_cap, do: @ring_cap

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Resolve a connect handshake (charter D45h): given the caller's parsed cursor
  (`{epoch, seq}` or `nil` for a fresh connect) and its store `scope`, decide
  whether to REPLAY the missed in-ring flips or degrade to a fresh SCOPED
  snapshot. Returns `{:snapshot | :replay, epoch, boundary_seq, entries}` — the
  controller emits the snapshot (its own DB query) or the scoped replay entries,
  then streams live, dropping any frame with `seq <= boundary_seq` (already
  reflected) so the handoff is gap-free by convergence.
  """
  @spec handshake(GenServer.server(), {integer(), non_neg_integer()} | nil, :global | binary()) ::
          {:snapshot | :replay, integer(), non_neg_integer(), [entry()]}
  def handshake(server \\ __MODULE__, cursor, scope) do
    GenServer.call(server, {:handshake, cursor, scope})
  end

  # ── CITED SAFE — class D, an INCARNATION FENCE: neither pure clock source is
  # correct (clock-semantics wave, 2026-08-19). Read this before re-sourcing
  # `epoch` in either direction.
  #
  # Provenance: swept alongside the class-C bucket-key defect closed by #12628
  # (8598c4efe7) and the atomicity fix #12579 (e45f1377bb). This is neither
  # class A (nothing compares `epoch` to a STORED instant — it is never
  # persisted and never durably compared), nor class B (it measures no elapsed
  # duration), nor class C (it keys no bound; the ring cap is a list length).
  # It is a fourth thing, and naming the class is the point of this note: a
  # future sweep that misfiles it as A or B will "fix" it into a defect.
  #
  # (a) STRUCTURAL — the required property is IDENTITY, not time: the value must
  #     never repeat and must never go backwards ACROSS A RESTART, because it is
  #     the epoch half of the opaque `"<epoch>:<seq>"` Last-Event-ID cursor, and
  #     a restart is exactly when every prior cursor MUST stop validating (the
  #     ring is an in-memory list, so post-restart the entries a cursor names no
  #     longer exist). See the boot-epoch fence section in the moduledoc above.
  #     Neither pure source satisfies that:
  #       * `System.monotonic_time` RESETS at BEAM start — the very event this
  #         token exists to distinguish. A monotonic epoch would collide across
  #         restarts and hand a stale cursor a false match.
  #       * `:erlang.unique_integer` restarts with the BEAM for the same reason,
  #         and the moduledoc above already rejects it here on that ground.
  #     Wall-clock microseconds is the least-wrong source: two incarnations of
  #     the same hub cannot init in the same microsecond, and it survives a
  #     restart by construction.
  #
  # (b) CONSUMER CENSUS — `epoch` is read only by the handshake, which compares
  #     the CLIENT's cursor epoch against the CURRENT one and, on mismatch,
  #     degrades to a fresh scoped snapshot. There is no authorization, expiry,
  #     quota or lease keyed on it; scope enforcement is `StudioChat.scope_match?/2`
  #     per entry (D43h), entirely independent of `epoch`.
  #
  # RESIDUAL, named in the safe direction: a BACKWARD host clock step spanning a
  # restart could in principle mint an epoch a previous incarnation already
  # used. The failure mode is a client accepting a cursor into a ring that no
  # longer holds those entries — a stale-frame/liveness nuisance on an
  # already-authorized socket, resolved by the next snapshot. Not an
  # authorization bypass, and no caller influences the mint.
  #
  # SIBLINGS, so the class is legible across the repo: the identical shape with
  # the identical recorded rationale lives at
  # api/lib/barkpark/plugins/sheets/session.ex (the sheets session's incarnation
  # stamp). The CAUTIONARY twin is `maybe_prebuilt_nonce/2` in
  # cloud/lib/barkpark_cloud/sites/deploy.ex, which a sibling slice of this wave
  # addresses — same "must differ across restarts" requirement, a source that
  # does not meet it.
  #
  # WHAT THIS VERDICT DOES NOT REST ON: the D44h charter decision recorded in
  # the moduledoc. That decision rejected `:erlang.unique_integer`; it never
  # examined a clock step, and a prior recorded decision is not evidence about
  # clock semantics. The grounds above are the identity requirement and a
  # consumer census.
  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

    {:ok,
     %{
       # Boot epoch — µs wall-clock, NOT :erlang.unique_integer (D44h).
       epoch: System.system_time(:microsecond),
       seq: 0,
       ring: [],
       # sid => last-emitted four-state (dedup + the :offline prior).
       states: %{},
       # sid => last-seen owner_workspace_id (heartbeat scope, D43h).
       owners: %{}
     }}
  end

  @impl true
  def handle_info({:chat_activity, sid, activity}, state) do
    owner_ws = Map.get(activity, :owner_workspace_id)
    mapped = map_state(Map.get(activity, :state), Map.get(state.states, sid))
    {:noreply, record_flip(state, sid, mapped, owner_ws)}
  end

  # An external reporter's authoritative write (herd-s6, charter D79h): while
  # its lease fence lives, the Recorder's derivation is suspended on this very
  # topic — so the fleet wire hears the reporter through its own frame kind.
  # The four-state rides LITERALLY (never reverse-mapped through the wave-5
  # activity vocabulary, which would distort "unknown" via the :offline prior
  # rule). Same flips-only ring discipline as a derived transition.
  def handle_info({:chat_reported_state, sid, %{agent_state: mapped} = frame}, state)
      when mapped in ["working", "blocked", "idle", "unknown"] do
    {:noreply, record_flip(state, sid, mapped, Map.get(frame, :owner_workspace_id))}
  end

  def handle_info({:chat_heartbeat, sid, ts}, state) do
    # Id-less, seq-less, NEVER ringed (D45h) — a liveness tick, not a state change.
    # Scoped by the session's last-seen owner (heartbeats carry no owner of their
    # own); an unseen session fails closed for every workspace scope.
    owner_ws = Map.get(state.owners, sid)
    Phoenix.PubSub.broadcast(Barkpark.PubSub, @fleet_topic, {:fleet_heartbeat, sid, ts, owner_ws})
    {:noreply, state}
  end

  def handle_info({:chat_title, sid, title}, state) when is_binary(title) do
    # A title update (D69h): id-less, seq-less, NEVER ringed — heartbeat-shaped,
    # not a state change. A bare {:chat_title} carries no owner of its own, so
    # it is scoped by the session's last-seen owner (the same fail-closed
    # fallback heartbeats use); a session whose activity FleetHub never saw
    # fails closed for every workspace scope.
    owner_ws = Map.get(state.owners, sid)
    Phoenix.PubSub.broadcast(Barkpark.PubSub, @fleet_topic, {:fleet_title, sid, title, owner_ws})
    {:noreply, state}
  end

  # The workflow rail rides the per-session wire, never the fleet wire (D44h).
  def handle_info({:chat_workflow, _sid, _summary}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:handshake, cursor, scope}, _from, state) do
    {:reply, resolve_handshake(cursor, scope, state), state}
  end

  # The shared flips-only ring discipline for BOTH truth sources (derived
  # activity and herd-s6 reported state): dedup against the last-emitted
  # four-state, mint a seq, ring it, broadcast the flip.
  defp record_flip(state, sid, mapped, owner_ws) do
    owners = Map.put(state.owners, sid, owner_ws)

    if mapped == Map.get(state.states, sid) do
      # A line-only change (working → working): NOT a four-state flip, so no wire
      # frame and no seq consumed — "state-change frames only" (design §s2).
      %{state | owners: owners}
    else
      seq = state.seq + 1

      entry = %{
        seq: seq,
        session_id: sid,
        agent_state: mapped,
        ts: DateTime.utc_now(),
        owner_ws: owner_ws
      }

      ring = Enum.take([entry | state.ring], @ring_cap)

      Phoenix.PubSub.broadcast(Barkpark.PubSub, @fleet_topic, {:fleet_flip, entry})

      %{state | seq: seq, ring: ring, states: Map.put(state.states, sid, mapped), owners: owners}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Pure seams (public @doc false — the handshake/mapping logic is asserted here
  # directly, never through the blocking SSE `get/2`; same convention as
  # ChatController's SSE seams).
  # ─────────────────────────────────────────────────────────────────────────

  @doc false
  # Map the wave-5 activity vocabulary onto the persisted four-state column —
  # byte-faithful to `Recorder.map_agent_state/2`. `:offline` depends on the
  # prior four-state: a mid-turn death (prior working/blocked) is "unknown"
  # (possibly wedged); a reaped resting session (any other prior) stays "idle".
  def map_state(:working, _prior), do: "working"
  def map_state(:needs_you, _prior), do: "blocked"
  def map_state(:idle, _prior), do: "idle"
  def map_state(:offline, prior) when prior in ["working", "blocked"], do: "unknown"
  def map_state(:offline, _prior), do: "idle"
  def map_state(_unknown, prior), do: prior

  @doc false
  # The pure handshake decision (D45h). Testable without a live GenServer.
  def resolve_handshake(nil, _scope, state), do: {:snapshot, state.epoch, state.seq, []}

  def resolve_handshake({req_epoch, req_seq}, scope, state) do
    cond do
      # Wrong epoch — a FleetHub restart invalidated the cursor. Degrade (D44h).
      req_epoch != state.epoch ->
        {:snapshot, state.epoch, state.seq, []}

      # The gap is no longer wholly in the ring — degrade, gap-free by
      # convergence, never fake ring durability (D45h).
      not replayable?(state.ring, state.seq, req_seq) ->
        {:snapshot, state.epoch, state.seq, []}

      # In-ring: replay EXACTLY the scoped flips after the cursor (seam 3).
      true ->
        entries =
          state.ring
          |> Enum.filter(&(&1.seq > req_seq and StudioChat.scope_match?(&1.owner_ws, scope)))
          |> Enum.sort_by(& &1.seq)

        {:replay, state.epoch, state.seq, entries}
    end
  end

  @doc false
  # A cursor is replayable iff every flip after it is still in the ring: its seq
  # is not ahead of the hub AND not older than the oldest retained entry.
  def replayable?(_ring, current_seq, req_seq) when req_seq > current_seq, do: false

  def replayable?(ring, current_seq, req_seq) do
    case List.last(ring) do
      # Empty ring: only a caught-up cursor (nothing to replay) is honored.
      nil -> req_seq == current_seq
      %{seq: oldest} -> req_seq >= oldest - 1
    end
  end

  @doc false
  # Parse an opaque `"<epoch>:<seq>"` Last-Event-ID into `{epoch, seq}` — the NEW
  # lenient 2-part parser (the session stream's `last_event_id/1` is
  # Integer.parse-only). Anything malformed (wrong arity, non-integer, negative
  # seq) yields `nil` → a fresh snapshot, never a crash.
  def parse_cursor(value) when is_binary(value) do
    with [epoch_s, seq_s] <- String.split(value, ":", parts: 2),
         {epoch, ""} <- Integer.parse(epoch_s),
         {seq, ""} <- Integer.parse(seq_s),
         true <- seq >= 0 do
      {epoch, seq}
    else
      _ -> nil
    end
  end

  def parse_cursor(_), do: nil
end
