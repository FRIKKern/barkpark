defmodule Barkpark.Quiz.Room do
  @moduledoc """
  Per-room in-memory GenServer for the hyperinteractive quiz (P1 walking
  skeleton — see `/papers/hyperquiz-architecture`). Owns ONE live room's state
  — players, the current question, and the per-choice answer tallies — and
  serializes every mutation through its mailbox.

  ## Lifecycle

  Started LAZILY by `ensure/1` — the ONLY starter, reached solely from the
  host mount (`QuizHostLive`), so joins can never spawn a ghost room for a
  typo'd pin. `restart: :temporary` — a crashed room is gone; the next host
  visit starts a fresh one (state is ephemeral by design). The room self-stops after
  an idle window with NO interaction — a short window while empty
  (`@empty_idle_ms`) so abandoned/never-populated rooms don't linger, a long
  one once it has players (`@idle_stop_ms`). `hibernate_after` releases its heap
  between bursts. The idle timer is generation-tokened so a stale `:idle_stop`
  already in the mailbox can't stop a freshly-active room.

  Join/read/leave paths (`join/3`, `leave/2`, `tally/1`, `state/1`,
  `submit_answer/3`) resolve via `whereis/1` and NEVER start a room — only
  `ensure/1` does — so a disconnect, a stray read, or a bogus-pin join can't
  start (or resurrect) a room as a zombie.

  CORE + plugin-independent. State is in-memory and authoritative while the room
  lives; nothing persists per-tick (per `/papers/hyperquiz-scaling`). Live
  updates fan out over `Phoenix.PubSub` on `topic/1` (distinct from the channel
  topic) so the Channel/LiveView subscribe without polling. Roster broadcasts
  carry the AUTHORITATIVE `player_count` so subscribers assign it directly
  rather than accumulating deltas.

  Backstops (P1-level; full anti-abuse/rate-limiting is P6, `/papers/hyperquiz-risks`):
  a per-room player cap (`@max_players`) and a global room cap
  (`max_children` on `Barkpark.Quiz.RoomSupervisor`).
  """
  use GenServer, restart: :temporary

  require Logger

  alias Phoenix.PubSub
  alias Barkpark.Quiz.{CursorFrame, Heatmap}

  @registry Barkpark.Quiz.RoomRegistry
  @supervisor Barkpark.Quiz.RoomSupervisor
  @pubsub Barkpark.PubSub

  @call_timeout 5_000
  @hibernate_after :timer.seconds(15)
  @idle_stop_ms :timer.minutes(60)
  @empty_idle_ms :timer.minutes(2)
  @max_players 2_000

  # P2 cursor fan-out: aggregate per-player cursor positions and broadcast ONE
  # batched, delta-encoded CursorFrame per tick (~15Hz) — O(N) not O(N²). The
  # tick is internal (does NOT reset the idle timer); only player actions do.
  @cursor_tick_ms 66

  # Above this many live cursors, the tick switches from individual frames to a
  # single fixed-size heatmap (dec-scale: ~2000 hybrid). Per-room overridable.
  @heatmap_threshold 300

  # P1 carries one hardcoded question; P3 loads it from Barkpark content
  # (`/papers/hyperquiz-content-model`). Choice ids are stable strings.
  @default_question %{
    id: "q1",
    prompt: "What powers Barkpark's realtime layer?",
    answer: "a",
    choices: [
      %{id: "a", label: "Phoenix Channels + PubSub"},
      %{id: "b", label: "Carrier pigeons"},
      %{id: "c", label: "Polling every 5 seconds"},
      %{id: "d", label: "Pure willpower"}
    ]
  }

  @type pin :: String.t()
  @type player_id :: String.t()
  @type tally :: %{optional(String.t()) => non_neg_integer()}

  # ── Public lifecycle ───────────────────────────────────────────────────────

  @doc false
  def start_link(pin) when is_binary(pin) do
    GenServer.start_link(__MODULE__, pin,
      name: {:via, Registry, {@registry, pin}},
      hibernate_after: @hibernate_after
    )
  end

  @doc "The live room pid for `pin`, or `nil`."
  @spec whereis(pin()) :: pid() | nil
  def whereis(pin) do
    case Registry.lookup(@registry, pin) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Resolve-or-start the room for `pin`. The ONLY path that starts a room."
  @spec ensure(pin()) :: {:ok, pid()} | {:error, term()}
  def ensure(pin) when is_binary(pin) do
    case Registry.lookup(@registry, pin) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, pin}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, :max_children} -> {:error, :max_children}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Stop a live room (normal shutdown). No-op when none is registered."
  @spec stop(pin()) :: :ok
  def stop(pin) do
    case whereis(pin) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Add (or refresh) a player in a LIVE room. Never starts one — the host mount
  is the sole room creator, so a typo'd/scanned pin can't spawn a ghost room
  that looks like a working quiz. Returns `{:ok, snapshot}`,
  `{:error, :no_room}` when nobody is hosting `pin`, or `{:error, :room_full}`
  past the per-room cap.
  """
  @spec join(pin(), player_id(), String.t()) ::
          {:ok, map()} | {:error, :no_room | :room_full | term()}
  def join(pin, player_id, name),
    do: call_existing(pin, {:join, player_id, name}, {:error, :no_room})

  @doc "Remove a player and drop their answer. No-op (never starts a room) when none lives."
  @spec leave(pin(), player_id()) :: :ok
  def leave(pin, player_id), do: call_existing(pin, {:leave, player_id}, :ok)

  @doc """
  Record a player's answer (last write wins). `{:error, :no_room}` when the room
  isn't live, `{:error, :not_joined}` / `{:error, :invalid_choice}` otherwise.
  """
  @spec submit_answer(pin(), player_id(), String.t()) ::
          {:ok, tally()} | {:error, :no_room | :not_joined | :invalid_choice | :wrong_phase}
  def submit_answer(pin, player_id, choice_id),
    do: call_existing(pin, {:submit, player_id, choice_id}, {:error, :no_room})

  @doc "Current per-choice answer counts (empty map when the room isn't live)."
  @spec tally(pin()) :: tally()
  def tally(pin), do: call_existing(pin, :tally, %{})

  @doc "Public room snapshot (an empty snapshot when the room isn't live)."
  @spec state(pin()) :: map()
  def state(pin), do: call_existing(pin, :state, empty_snapshot(pin))

  @doc """
  Start (or restart) the question phase — clears answers, opens answering, and
  arms a server-authoritative countdown. `time_limit` is seconds (fractional ok);
  `nil` uses the question's `time_limit` (default 20). On expiry the room
  auto-transitions to `:reveal`.
  """
  @spec start_question(pin(), number() | nil) :: :ok
  def start_question(pin, time_limit \\ nil),
    do: call_existing(pin, {:start_question, time_limit}, :ok)

  @doc """
  Reveal phase — answers locked. Broadcasts the final tally + scores on the
  shared events topic (`topic/1`), and the correct answer on the HOST-ONLY
  topic (`host_topic/1`) so it never reaches a player socket.
  """
  @spec reveal(pin()) :: :ok
  def reveal(pin), do: call_existing(pin, :reveal, :ok)

  @doc "Leaderboard phase — broadcasts the scores."
  @spec leaderboard(pin()) :: :ok
  def leaderboard(pin), do: call_existing(pin, :leaderboard, :ok)

  @doc "End the game."
  @spec end_game(pin()) :: :ok
  def end_game(pin), do: call_existing(pin, :end_game, :ok)

  @doc "Return to the lobby."
  @spec to_lobby(pin()) :: :ok
  def to_lobby(pin), do: call_existing(pin, :to_lobby, :ok)

  @doc """
  Replace the live question (live-edit / swap). Prunes any answers whose choice
  no longer exists, then broadcasts {:question_updated, question} on the events
  topic — players see the change without dropping. No-op when the room isn't live.
  """
  @spec apply_question(pin(), map()) :: :ok
  def apply_question(pin, question), do: call_existing(pin, {:apply_question, question}, :ok)

  @doc """
  The PubSub topic a room broadcasts live updates on. Deliberately distinct
  from the Phoenix channel topic (`quiz:room:<pin>`) so a channel can subscribe
  to room events without colliding with its own channel-topic subscription.
  """
  @spec topic(pin()) :: String.t()
  def topic(pin), do: "quiz:events:" <> pin

  @doc "The PubSub topic batched cursor frames broadcast on (distinct from `topic/1`)."
  @spec cursor_topic(pin()) :: String.t()
  def cursor_topic(pin), do: "quiz:cursors:" <> pin

  @doc "The PubSub topic aggregate heatmap frames broadcast on (above the crossover)."
  @spec heat_topic(pin()) :: String.t()
  def heat_topic(pin), do: "quiz:heat:" <> pin

  @doc """
  The HOST-ONLY topic (distinct from `topic/1`) carrying terms a player must
  never receive — currently `{:reveal_answer, answer}` at `:reveal`.

  `topic/1` is shared: the projector AND every anonymous player phone subscribe
  to it, with no per-role filtering. So the correct answer cannot ride it — see
  `do_reveal/1`. Subscribe to this topic ONLY from a projector/host surface;
  subscribing a player socket to it re-opens the leak this split closes.
  """
  @spec host_topic(pin()) :: String.t()
  def host_topic(pin), do: "quiz:host:" <> pin

  @doc "Override the individual→heatmap crossover threshold (mainly for tests)."
  @spec set_heatmap_threshold(pin(), non_neg_integer()) :: :ok
  def set_heatmap_threshold(pin, n), do: call_existing(pin, {:set_heatmap_threshold, n}, :ok)

  @doc "The P1 hardcoded fallback question (served when no quiz content is selected)."
  @spec default_question() :: map()
  def default_question, do: @default_question

  @doc """
  Report a player's cursor position (normalized `0.0..1.0`). Fire-and-forget
  cast — high-frequency; the position is quantized and folded into the next
  ~15Hz batched frame. No-op when the room isn't live or the player hasn't
  joined (so a stray move never starts a room).
  """
  @spec move(pin(), player_id(), number(), number()) :: :ok
  def move(pin, player_id, x, y) when is_number(x) and is_number(y) do
    case whereis(pin) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:move, player_id, x, y})
    end
  end

  @doc """
  Signal which choice a player is hovering (pre-commit), or `nil` to clear.
  Fire-and-forget; the room re-broadcasts per-choice hover counts on change
  (the "37 people hovering B" feature). No-op when the room/player is absent.
  """
  @spec hover(pin(), player_id(), String.t() | nil) :: :ok
  def hover(pin, player_id, choice_id) do
    case whereis(pin) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:hover, player_id, choice_id})
    end
  end

  # Resolve via whereis ONLY — never starts a room (no resurrection).
  defp call_existing(pin, msg, default) do
    case whereis(pin) do
      nil -> default
      pid -> GenServer.call(pid, msg, @call_timeout)
    end
  end

  defp empty_snapshot(pin),
    do: %{pin: pin, question: nil, players: [], player_count: 0, tally: %{}}

  defp safe_stop(pid) do
    GenServer.stop(pid, :normal, @call_timeout)
  catch
    :exit, _ -> :ok
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(pin) do
    state = %{
      pin: pin,
      players: %{},
      question: @default_question,
      # Default :question keeps the P1/P2 join→answer→tally flow working with no
      # explicit start; lobby/reveal/leaderboard/ended are opt-in transitions.
      phase: :question,
      scores: %{},
      streaks: %{},
      answers: %{},
      answer_times: %{},
      hovers: %{},
      slots: %{},
      cursors: %{},
      last_sent: %{},
      idle_gen: 0,
      idle_timer: nil,
      q_timer_gen: 0,
      deadline: nil,
      round_secs: nil,
      heatmap_threshold: @heatmap_threshold
    }

    Process.send_after(self(), :cursor_tick, @cursor_tick_ms)
    {:ok, arm_idle(state)}
  end

  @impl true
  def handle_call({:join, player_id, name}, _from, state) do
    new? = not Map.has_key?(state.players, player_id)

    cond do
      new? and map_size(state.players) >= @max_players ->
        {:reply, {:error, :room_full}, arm_idle(state)}

      not new? ->
        # Idempotent re-join — the SAME browser's cursor socket re-joining after
        # its LiveView already joined (or any reconnect). Preserve the existing
        # record/slot/count and DON'T rebroadcast, so one human is one player.
        {:reply, {:ok, public(state)}, arm_idle(state)}

      true ->
        # Genuinely-new player: assign a cursor slot (the CursorFrame idx).
        state = assign_slot(state, player_id)
        slot = Map.get(state.slots, player_id)
        player = %{id: player_id, name: name, slot: slot, joined_at: System.system_time(:second)}
        state = put_in(state.players[player_id], player)
        broadcast(state, {:player_joined, player, map_size(state.players)})
        {:reply, {:ok, public(state)}, arm_idle(state)}
    end
  end

  def handle_call({:leave, player_id}, _from, state) do
    existed? = Map.has_key?(state.players, player_id)
    idx = Map.get(state.slots, player_id)

    state =
      state
      |> update_in([:players], &Map.delete(&1, player_id))
      |> update_in([:answers], &Map.delete(&1, player_id))
      |> update_in([:hovers], &Map.delete(&1, player_id))
      |> update_in([:slots], &Map.delete(&1, player_id))
      |> update_in([:cursors], &Map.delete(&1, idx))
      |> update_in([:last_sent], &Map.delete(&1, idx))

    # Carry the cursor SLOT (idx) so subscribers can evict the departed dot —
    # the binary cursor protocol only sends changed slots, never removals.
    if existed?, do: broadcast(state, {:player_left, player_id, idx, map_size(state.players)})
    {:reply, :ok, arm_idle(state)}
  end

  def handle_call({:submit, player_id, choice_id}, _from, state) do
    cond do
      state.phase != :question ->
        {:reply, {:error, :wrong_phase}, state}

      not Map.has_key?(state.players, player_id) ->
        {:reply, {:error, :not_joined}, state}

      not valid_choice?(state.question, choice_id) ->
        {:reply, {:error, :invalid_choice}, state}

      true ->
        state =
          state
          |> put_in([:answers, player_id], choice_id)
          |> put_in([:answer_times, player_id], System.monotonic_time(:millisecond))

        t = compute_tally(state)
        broadcast(state, {:tally, t})
        {:reply, {:ok, t}, arm_idle(state)}
    end
  end

  def handle_call(:tally, _from, state), do: {:reply, compute_tally(state), arm_idle(state)}
  def handle_call(:state, _from, state), do: {:reply, public(state), arm_idle(state)}

  # ── Phase transitions (host-driven); each broadcasts {:phase, phase, payload}.
  def handle_call({:start_question, time_limit}, _from, state) do
    secs = time_limit || Map.get(state.question, :time_limit, 20)
    ms = round(secs * 1000)
    gen = state.q_timer_gen + 1
    Process.send_after(self(), {:question_expired, gen}, ms)
    deadline = System.monotonic_time(:millisecond) + ms

    state = %{
      state
      | phase: :question,
        answers: %{},
        answer_times: %{},
        q_timer_gen: gen,
        deadline: deadline,
        round_secs: secs
    }

    broadcast(
      state,
      {:phase, :question,
       %{question: public_question(state.question), tally: compute_tally(state), time_limit: secs}}
    )

    {:reply, :ok, arm_idle(state)}
  end

  def handle_call(:reveal, _from, state) do
    # Bump the timer generation so any armed auto-expiry is now stale.
    {:reply, :ok, arm_idle(do_reveal(%{state | q_timer_gen: state.q_timer_gen + 1}))}
  end

  def handle_call(:leaderboard, _from, state) do
    state = %{state | phase: :leaderboard}
    broadcast(state, {:phase, :leaderboard, %{scores: leaderboard_list(state)}})
    {:reply, :ok, arm_idle(state)}
  end

  def handle_call(:end_game, _from, state) do
    state = %{state | phase: :ended}
    broadcast(state, {:phase, :ended, %{scores: leaderboard_list(state)}})
    {:reply, :ok, arm_idle(state)}
  end

  def handle_call(:to_lobby, _from, state) do
    state = %{state | phase: :lobby}
    broadcast(state, {:phase, :lobby, %{}})
    {:reply, :ok, arm_idle(state)}
  end

  def handle_call({:apply_question, question}, _from, state) do
    # Reject a malformed question outright — storing one without a choices LIST
    # would crash the next compute_tally/hover_counts/public on this room.
    if is_map(question) and is_list(Map.get(question, :choices)) do
      valid = MapSet.new(question.choices, & &1.id)

      answers =
        state.answers |> Enum.filter(fn {_p, c} -> MapSet.member?(valid, c) end) |> Map.new()

      state = %{state | question: question, answers: answers}
      broadcast(state, {:question_updated, public_question(question)})
      {:reply, :ok, arm_idle(state)}
    else
      {:reply, {:error, :invalid_question}, state}
    end
  end

  def handle_call({:set_heatmap_threshold, n}, _from, state),
    do: {:reply, :ok, %{state | heatmap_threshold: n}}

  @impl true
  def handle_cast({:move, player_id, x, y}, state) do
    case Map.get(state.slots, player_id) do
      nil ->
        {:noreply, state}

      idx ->
        qpos = {CursorFrame.quantize(x), CursorFrame.quantize(y)}
        {:noreply, arm_idle(put_in(state.cursors[idx], qpos))}
    end
  end

  def handle_cast({:hover, player_id, choice_id}, state) do
    prev = Map.get(state.hovers, player_id)

    cond do
      not Map.has_key?(state.players, player_id) ->
        {:noreply, state}

      # No-op (and NO broadcast) when the hover is unchanged — otherwise a chatty
      # client amplifies one frame into O(N) PubSub pushes every message.
      choice_id == prev ->
        {:noreply, arm_idle(state)}

      is_nil(choice_id) ->
        state = update_in(state.hovers, &Map.delete(&1, player_id))
        broadcast(state, {:hover_counts, hover_counts(state)})
        {:noreply, arm_idle(state)}

      valid_choice?(state.question, choice_id) ->
        state = put_in(state.hovers[player_id], choice_id)
        broadcast(state, {:hover_counts, hover_counts(state)})
        {:noreply, arm_idle(state)}

      true ->
        {:noreply, state}
    end
  end

  # ~15Hz cursor tick: broadcast ONE delta-encoded frame iff anything moved
  # since the last frame. Internal — does NOT reset the idle timer.
  @impl true
  def handle_info(:cursor_tick, state) do
    :telemetry.execute([:barkpark, :quiz, :tick], %{cursors: map_size(state.cursors)}, %{
      pin: state.pin
    })

    delta = CursorFrame.delta(state.last_sent, state.cursors)

    state =
      if map_size(delta) > 0 do
        if map_size(state.cursors) > state.heatmap_threshold do
          # Above the crossover (`/papers/hyperquiz-scaling`): one fixed-size
          # aggregate heatmap (O(1)) instead of N individual cursors (O(N²)).
          PubSub.broadcast(
            @pubsub,
            heat_topic(state.pin),
            {:quiz_heat, state.pin, Heatmap.encode(state.cursors)}
          )
        else
          PubSub.broadcast(
            @pubsub,
            cursor_topic(state.pin),
            {:quiz_cursors, state.pin, CursorFrame.encode(delta)}
          )
        end

        %{state | last_sent: state.cursors}
      else
        state
      end

    Process.send_after(self(), :cursor_tick, @cursor_tick_ms)
    {:noreply, state}
  end

  # Server-authoritative countdown: only the current generation fires, and only
  # while still in :question (a manual reveal/new question bumped the gen).
  def handle_info({:question_expired, gen}, %{q_timer_gen: gen, phase: :question} = state),
    do: {:noreply, arm_idle(do_reveal(state))}

  def handle_info({:question_expired, _stale}, state), do: {:noreply, state}

  # Generation-tokened idle stop: only the most recently armed timer can fire.
  def handle_info({:idle_stop, gen}, %{idle_gen: gen} = state), do: {:stop, :normal, state}
  def handle_info({:idle_stop, _stale}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ── helpers ────────────────────────────────────────────────────────────────

  defp valid_choice?(%{choices: choices}, choice_id),
    do: Enum.any?(choices, &(&1.id == choice_id))

  defp compute_tally(state) do
    base = Map.new(state.question.choices, &{&1.id, 0})

    Enum.reduce(state.answers, base, fn {_player_id, choice_id}, acc ->
      Map.update(acc, choice_id, 1, &(&1 + 1))
    end)
  end

  defp public(state) do
    %{
      pin: state.pin,
      question: public_question(state.question),
      players: Map.values(state.players),
      player_count: map_size(state.players),
      cursor_count: map_size(state.cursors),
      phase: state.phase,
      seconds_remaining: seconds_remaining(state),
      tally: compute_tally(state),
      hover_counts: hover_counts(state),
      scores: leaderboard_list(state)
    }
  end

  # Transition to :reveal + broadcast tally/scores on the SHARED events topic,
  # and the answer on the HOST-ONLY topic. Shared by manual reveal and the
  # countdown auto-expiry.
  #
  # The split is the security boundary (task-ae30cd243c2a943d). `topic/1` is
  # subscribed by both roles with NO per-role filtering — the projector
  # (`QuizChannel`'s `observe: true` join, `QuizHostLive.mount/3`) and every
  # anonymous player phone (`QuizChannel`'s player join, `QuizPlayLive.mount/3`)
  # are on the same topic. An `:answer` in this payload is therefore one
  # `handle_info` clause away from every player socket, defeating the same
  # property that makes the `quiz` document type PRIVATE
  # (`Barkpark.Quiz.Content.schema/0`: the doc stores the correct answer inline).
  # The phone is supposed to learn the answer from the projector, not the wire.
  defp do_reveal(state) do
    # Score once, only when transitioning out of :question (a re-reveal won't
    # double-count; the timer expiry is already :question-guarded).
    state = if state.phase == :question, do: score_round(state), else: state
    state = %{state | phase: :reveal}

    # Player-safe: tally + scores render the whole reveal EXCEPT which choice
    # was right. Deliberately no `:answer` key at all (not `nil`) — an explicit
    # nil would still be a slot a future edit could refill.
    broadcast(
      state,
      {:phase, :reveal, %{tally: compute_tally(state), scores: leaderboard_list(state)}}
    )

    # Host-only: the projector legitimately needs the answer to mark the correct
    # bar at reveal. Nothing a player join subscribes to carries this term.
    broadcast_host(state, {:reveal_answer, Map.get(state.question, :answer)})

    state
  end

  # Award speed-based points to correct answers; bump their streak, reset others'.
  defp score_round(state) do
    correct = Map.get(state.question, :answer)

    {scores, streaks} =
      Enum.reduce(state.players, {state.scores, state.streaks}, fn {pid, _p}, {sc, st} ->
        if not is_nil(correct) and Map.get(state.answers, pid) == correct do
          pts = points(state, pid)
          {Map.update(sc, pid, pts, &(&1 + pts)), Map.update(st, pid, 1, &(&1 + 1))}
        else
          {sc, Map.put(st, pid, 0)}
        end
      end)

    %{state | scores: scores, streaks: streaks}
  end

  # 1000 × fraction of the time still on the clock when they answered; a flat
  # 1000 when there's no countdown (no deadline / no recorded answer time).
  defp points(state, pid) do
    # Use the duration the countdown was ACTUALLY armed with (start_question's
    # arg), not the question's nominal time_limit — they can differ, which would
    # otherwise make the speed fraction wrong.
    t = state.round_secs || Map.get(state.question, :time_limit, 20)

    case {state.deadline, Map.get(state.answer_times, pid)} do
      {d, at} when is_integer(d) and is_integer(at) and is_number(t) and t > 0 ->
        remaining = max(0, d - at) / 1000
        round(1000 * min(1.0, remaining / t))

      _ ->
        1000
    end
  end

  defp seconds_remaining(%{phase: :question, deadline: d}) when is_integer(d),
    do: max(0, d - System.monotonic_time(:millisecond)) / 1000

  defp seconds_remaining(_), do: 0

  # Scores as a leaderboard list, highest first. Empty until P3 scoring populates
  # state.scores.
  defp leaderboard_list(state) do
    state.scores
    |> Enum.map(fn {pid, score} ->
      player = Map.get(state.players, pid) || %{}

      %{
        id: pid,
        name: Map.get(player, :name, pid),
        score: score,
        streak: Map.get(state.streaks, pid, 0)
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp hover_counts(state) do
    base = Map.new(state.question.choices, &{&1.id, 0})

    Enum.reduce(state.hovers, base, fn {_player_id, choice_id}, acc ->
      Map.update(acc, choice_id, 1, &(&1 + 1))
    end)
  end

  # Assign the LOWEST free cursor slot (the CursorFrame idx) to a new player,
  # recycling slots freed on leave. With @max_players ≤ 2000 the idx therefore
  # always stays well under the u16 (<<idx::16>>) wire limit, so a long-lived
  # high-churn room can never wrap two live players onto one slot.
  defp assign_slot(state, player_id) do
    used = state.slots |> Map.values() |> MapSet.new()
    slot = Stream.iterate(0, &(&1 + 1)) |> Enum.find(&(not MapSet.member?(used, &1)))
    %{state | slots: Map.put(state.slots, player_id, slot)}
  end

  # The player-facing view of a question — WITHOUT the correct answer. Stops the
  # answer leaking via snapshots / phase / question_updated broadcasts (a public
  # quiz would otherwise be cheatable).
  #
  # This covers every question-shaped term. The answer is NOT disclosed to
  # players at :reveal either: it rides `host_topic/1` as `{:reveal_answer, a}`,
  # never the shared events topic. See `do_reveal/1`.
  defp public_question(nil), do: nil
  defp public_question(question), do: Map.delete(question, :answer)

  defp broadcast(state, msg),
    do: PubSub.broadcast(@pubsub, topic(state.pin), {:quiz, state.pin, msg})

  # Same envelope shape as `broadcast/2`, different topic — so a host surface
  # pattern-matches `{:quiz, pin, term}` uniformly across both subscriptions.
  defp broadcast_host(state, msg),
    do: PubSub.broadcast(@pubsub, host_topic(state.pin), {:quiz, state.pin, msg})

  # Cancel the prior idle timer before arming a new one — otherwise every
  # high-frequency mutation (move/hover) would leave a 60-min timer in the BEAM
  # timer wheel, accumulating unboundedly. The generation token stays as a
  # secondary guard against an :idle_stop already delivered to the mailbox.
  defp arm_idle(state) do
    if is_reference(state.idle_timer), do: Process.cancel_timer(state.idle_timer)
    gen = state.idle_gen + 1
    ms = if map_size(state.players) == 0, do: @empty_idle_ms, else: @idle_stop_ms
    ref = Process.send_after(self(), {:idle_stop, gen}, ms)
    %{state | idle_gen: gen, idle_timer: ref}
  end
end
