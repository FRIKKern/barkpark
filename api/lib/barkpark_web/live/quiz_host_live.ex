defmodule BarkparkWeb.QuizHostLive do
  @moduledoc """
  P1 host/projector surface (the big-screen half of the split-surface client).
  `/quiz/host/:pin` ensures the room, shows the question, the live player count,
  and animated per-choice tally bars that move as answers land — read-only, no
  input. Subscribes to the room events topic so every `{:tally, t}` /
  `{:player_joined|left, _}` broadcast re-renders without polling.

  Binding a stored quiz (`?quiz=<id>`) needs a Studio host link
  (`Barkpark.Quiz.HostLink`, `&host=<token>`) or a signed-in Studio author
  session (owner ruling #23); without one the room runs the default question.
  `/quiz/host/new` picks a fresh PIN and keeps the query.

  Host controls: the browser session that OWNS the pin (`Quiz.Bridge`, first
  host wins: `bind_as_host/4` with `?quiz=`, `claim_host/2` without) gets a
  toolbar that drives the room's phases: start the question (arms the
  countdown from its `time_limit`), reveal the answer, show scores, end the
  game. Every control re-checks ownership on the server; a second browser on
  the same host URL sees the projector without controls, and only the owner
  subscribes to the host-only answer topic.

  This is the surface P5's crowd heatmap will eventually replace the bars with
  (`/papers/hyperquiz-realtime-protocol`); for P1 it's the individual-tally view.
  """
  use Phoenix.LiveView

  alias Barkpark.Quiz
  alias Barkpark.Quiz.HostLink

  # `/quiz/host/new` is the PIN-less entry the Studio "Host this quiz" link
  # opens: pick a fresh PIN and carry the quiz + host token along, so every
  # click of the same link opens its own room.
  @impl true
  def mount(%{"pin" => "new"} = params, _session, socket) do
    query = params |> Map.take(["quiz", "host"]) |> URI.encode_query()
    to = "/quiz/host/" <> Quiz.new_pin() <> if(query == "", do: "", else: "?" <> query)
    {:ok, redirect(unavailable_assigns(socket, "new"), to: to)}
  end

  def mount(%{"pin" => pin} = params, session, socket) do
    if connected?(socket) do
      # `Quiz.ensure_room/1` is specced `{:ok, pid()} | {:error, term()}` and
      # returns `{:error, :max_children}` BY DESIGN once `Quiz.RoomSupervisor`
      # is at its 10_000-room memory-DoS backstop (plugins/quiz.ex). A hard
      # `{:ok, _pid} =` match turned that bounded, expected refusal into a
      # MatchError on an ANONYMOUS route (`auth: :public_root`), so the client
      # reconnect-looped with no explanation exactly when the node was already
      # under pressure. Branch it, the way `QuizPlayLive.mount/3` and
      # `QuizChannel.join/3` already branch the same refusal.
      #
      # It now also returns `{:error, :spawn_budget}` — the PER-PRINCIPAL brake
      # (`Barkpark.Quiz.SpawnBudget`) that stands in FRONT of that global cap,
      # so one script cannot spend the whole cluster's room allowance. The two
      # refusals render different copy: a budget refusal is about THIS visitor
      # and clears on its own; a capacity refusal is about the service.
      case Quiz.ensure_room(pin, connect_info(socket)) do
        {:ok, _pid} -> mount_room(pin, params, session, socket)
        {:error, reason} -> {:ok, assign(unavailable_assigns(socket, pin), error: reason)}
      end
    else
      {:ok, unavailable_assigns(socket, pin)}
    end
  end

  # The connected mount once the room is live.
  defp mount_room(pin, params, session, socket) do
    host_key = host_key(session)

    # Bind an optional `?quiz=<id>` so a Studio publish of that quiz reaches
    # this live room in under a second (charter Vision + Decision M). This is
    # the first production call site of `bind_quiz/3`. The default dataset
    # ("production") is deliberate; the id rides the doc_id string column, so
    # NO UUID guard — a guard would reject valid non-UUID ids. `bind_quiz`
    # always returns `:ok`: it silently no-ops on a garbage/unpublished id
    # (the room keeps its default question) and is idempotent across refresh,
    # so there is no error branch to render.
    #
    # Owner ruling #23 (task-f5d0ce5677e1c1d0): binding a stored quiz is an
    # authoring act — the host hears every answer and the answer key of a
    # PRIVATE-type document. `?quiz=` binds only with a valid Studio host link
    # for THAT quiz, or a signed-in Studio session that may write the Default
    # workspace. Anyone else still gets a working room on the default question,
    # and is told why the named quiz did not load.
    link_error =
      case params["quiz"] do
        qid when is_binary(qid) and qid != "" ->
          case authorize_bind(params["host"], qid, session) do
            :ok ->
              # Bound as THIS host session: a second browser (a player who read
              # the PIN off the projector) cannot swap a live room's quiz
              # (task-680f88266f783346).
              Quiz.bind_quiz_as_host(pin, qid, host_key)
              nil

            {:error, reason} ->
              Quiz.Bridge.claim_host(pin, host_key)
              reason
          end

        # No quiz: still claim the unowned pin, so the default question can be run.
        _ ->
          Quiz.Bridge.claim_host(pin, host_key)
          nil
      end

    host? = Quiz.Bridge.host?(pin, host_key)

    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    # The answer rides a HOST-ONLY topic (`Room.host_topic/1`); this route is
    # anonymous, so only the owning session may hear it.
    if host?, do: Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.host_topic(pin))

    state = Quiz.state(pin)

    socket =
      assign(socket,
        pin: pin,
        host_key: host_key,
        host?: host?,
        question: state.question,
        tally: state.tally,
        player_count: state.player_count,
        phase: state.phase,
        scores: state.scores,
        answer: nil,
        error: nil,
        link_error: link_error
      )

    {:ok, arm_countdown(socket, state.seconds_remaining)}
  end

  defp authorize_bind(token, quiz_id, session) do
    case HostLink.verify(token, quiz_id) do
      :ok ->
        :ok

      {:error, reason} ->
        if HostLink.signed_in_author?(session), do: :ok, else: {:error, reason}
    end
  end

  # The host browser's identity: a hash of its session CSRF token (per browser
  # session, signed cookie). Absent → nil, which can claim an unowned PIN but
  # never displace a live host.
  defp host_key(%{"_csrf_token" => token}) when is_binary(token) and token != "",
    do: :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)

  defp host_key(_session), do: nil

  # The pre-connect skeleton AND the base for the capacity-refusal state.
  defp unavailable_assigns(socket, pin) do
    assign(socket,
      pin: pin,
      host_key: nil,
      host?: false,
      question: nil,
      tally: %{},
      player_count: 0,
      phase: nil,
      scores: [],
      answer: nil,
      ends_at: nil,
      remaining: nil,
      error: nil,
      link_error: nil
    )
  end

  # Host controls. The buttons render only for the owner, but the event is a
  # public wire message, so ownership is re-checked here on every press.
  @impl true
  def handle_event("host", %{"action" => action}, socket) do
    %{pin: pin, host_key: key} = socket.assigns

    if Quiz.Bridge.host?(pin, key) do
      case action do
        "start" -> Quiz.start_question(pin)
        "reveal" -> Quiz.reveal(pin)
        "scores" -> Quiz.leaderboard(pin)
        "end" -> Quiz.end_game(pin)
        _ -> :ok
      end
    end

    {:noreply, socket}
  end

  # The countdown the projector shows. The room owns the real deadline (its
  # auto-reveal fires on expiry); this is the display of it, ticked once a second.
  defp arm_countdown(socket, secs) when is_number(secs) and secs > 0 do
    ends_at = System.monotonic_time(:millisecond) + round(secs * 1000)
    if connected?(socket), do: Process.send_after(self(), {:countdown, ends_at}, 1000)
    assign(socket, ends_at: ends_at, remaining: ceil(secs))
  end

  defp arm_countdown(socket, _secs), do: assign(socket, ends_at: nil, remaining: nil)

  @impl true
  def handle_info({:quiz, _pin, {:tally, tally}}, socket),
    do: {:noreply, assign(socket, tally: tally)}

  # Roster broadcasts carry the AUTHORITATIVE count — assign it directly rather
  # than accumulating +1/-1 deltas against a separately-read base (which drifts).
  def handle_info({:quiz, _pin, {:player_joined, _player, count}}, socket),
    do: {:noreply, assign(socket, player_count: count)}

  def handle_info({:quiz, _pin, {:player_left, _player_id, _slot, count}}, socket),
    do: {:noreply, assign(socket, player_count: count)}

  # Live-edit (P4): re-render the projector with the swapped question.
  def handle_info({:quiz, _pin, {:question_updated, question}}, socket),
    do: {:noreply, assign(socket, question: question)}

  # Phase transitions, broadcast by the room on the shared events topic.
  def handle_info({:quiz, _pin, {:phase, :question, payload}}, socket) do
    socket =
      assign(socket,
        phase: :question,
        question: payload.question,
        tally: payload.tally,
        answer: nil
      )

    {:noreply, arm_countdown(socket, payload.time_limit)}
  end

  def handle_info({:quiz, _pin, {:phase, :reveal, payload}}, socket) do
    socket = assign(socket, phase: :reveal, tally: payload.tally, scores: payload.scores)
    {:noreply, arm_countdown(socket, nil)}
  end

  def handle_info({:quiz, _pin, {:phase, phase, payload}}, socket)
      when phase in [:leaderboard, :ended, :lobby] do
    scores = Map.get(payload, :scores, socket.assigns.scores)
    {:noreply, arm_countdown(assign(socket, phase: phase, scores: scores), nil)}
  end

  # Host-only topic (subscribed only by the owner): the correct choice id.
  def handle_info({:quiz, _pin, {:reveal_answer, answer}}, socket),
    do: {:noreply, assign(socket, answer: answer)}

  def handle_info({:countdown, ends_at}, %{assigns: %{ends_at: ends_at}} = socket) do
    left = ends_at - System.monotonic_time(:millisecond)

    if left > 0 and socket.assigns.phase == :question do
      Process.send_after(self(), {:countdown, ends_at}, min(1000, left))
      {:noreply, assign(socket, remaining: ceil(left / 1000))}
    else
      {:noreply, assign(socket, remaining: 0)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :total, assigns.tally |> Map.values() |> Enum.sum())

    ~H"""
    <div class="q-shell">
      <canvas class="quiz-cursor-canvas" data-quiz-pin={@pin} data-quiz-role="host"></canvas>
      <p class="q-eyebrow">Hyperquiz · Host</p>
      <p class="q-pin">
        Join at <code>/quiz/play/{@pin}</code> · <span class="q-count">{@player_count} players</span>
      </p>

      <%= cond do %>
        <% @error == :spawn_budget -> %>
          <p class="q-status" role="status">
            You have opened a lot of quiz rooms in the last hour, so this one is
            on hold — that limit is what keeps every other host's rooms working.
            Nothing is lost: your existing rooms are still live, and reopening
            <a href={"/quiz/host/#{@pin}"}>/quiz/host/{@pin}</a>
            a little later starts this one.
          </p>
        <% @error -> %>
          <p class="q-status" role="status">
            This room could not be opened — the quiz service is at room capacity.
            Nothing is lost: reopen
            <a href={"/quiz/host/#{@pin}"}>/quiz/host/{@pin}</a>
            in a moment and the room starts as soon as one frees up.
          </p>
        <% @question -> %>
          <p :if={@link_error} class="q-status" role="status">
            {link_error_copy(@link_error)} This room is running the sample question.
          </p>
          <div :if={@host?} class="q-host-controls" role="toolbar" aria-label="Host controls">
            <button type="button" class="q-host-btn" phx-click="host" phx-value-action="start">
              {if @phase == :question and is_nil(@ends_at), do: "Start question", else: "Restart question"}
            </button>
            <button
              type="button"
              class="q-host-btn"
              phx-click="host"
              phx-value-action="reveal"
              disabled={@phase != :question}
            >
              Reveal answer
            </button>
            <button
              type="button"
              class="q-host-btn"
              phx-click="host"
              phx-value-action="scores"
              disabled={@phase not in [:reveal, :ended]}
            >
              Show scores
            </button>
            <button
              type="button"
              class="q-host-btn"
              phx-click="host"
              phx-value-action="end"
              disabled={@phase == :ended}
            >
              End game
            </button>
          </div>

          <%= if @phase in [:leaderboard, :ended] do %>
            <h1 class="q-question">{if @phase == :ended, do: "Game over", else: "Scores"}</h1>
            <ol :if={@scores != []} class="q-scores">
              <li :for={row <- @scores}>
                <span>{row.name}</span> <span class="q-count">{row.score}</span>
              </li>
            </ol>
            <p :if={@scores == []} class="q-status">No points scored yet.</p>
          <% else %>
            <h1 class="q-question">{@question.prompt}</h1>
            <img :if={@question[:image]} src={@question[:image]} alt="" class="q-image" />
            <div class="q-meta">
              {@total} answers in<span :if={@remaining} class="q-timer" role="timer"> · {@remaining}s left</span><span :if={@phase == :reveal}> · answers locked</span>
            </div>

            <div class="q-bar-row" :for={{choice, idx} <- Enum.with_index(@question.choices)}>
              <div class="q-bar-label">
                <span class={if @answer == choice.id, do: "q-correct"}>
                  {choice.label}{if @answer == choice.id, do: " ✓"}
                </span>
                <span class="q-count">{Map.get(@tally, choice.id, 0)}</span>
              </div>
              <div class="q-bar-track">
                <div class={"q-bar-fill c#{rem(idx, 4)}"} style={"width: #{pct(Map.get(@tally, choice.id, 0), @total)}%"}></div>
              </div>
            </div>

            <ol :if={@phase == :reveal and @scores != []} class="q-scores">
              <li :for={row <- @scores}>
                <span>{row.name}</span> <span class="q-count">{row.score}</span>
              </li>
            </ol>
          <% end %>
        <% true -> %>
          <p class="q-status">Opening the room…</p>
      <% end %>
    </div>
    """
  end

  # THE TRANSPORT CONTEXT THE SPAWN BUDGET BILLS ON.
  #
  # `Phoenix.LiveView.get_connect_info/2` is the public reader, but it only
  # answers for the fixed key set it knows (`:peer_data`, `:x_headers`, `:uri`,
  # …) — it cannot hand over the map ITSELF, and the map itself is what
  # `Barkpark.RateLimiter.scoped_key/2` needs to find a test's per-process
  # bucket scope. Reading `socket.private[:connect_info]` hands the whole
  # source over, and both shapes it can take are ones the limiter already
  # understands: a socket `connect_info` map in production, and (under
  # `Phoenix.LiveViewTest`) the `%Plug.Conn{}` the test mounted with — which is
  # exactly where `ConnCase.scoped_conn/0` stamps that scope. Without it every
  # test in the run would bill ONE `127.0.0.1` bucket and the suite would
  # throttle itself, the failure `ConnCase.refute_rate_limited!/1` exists to
  # name.
  #
  # nil-safe on purpose: `SpawnBudget.principal/1` falls back rather than
  # raising, so a transport that stops carrying connect_info degrades to the
  # shared fallback bucket instead of breaking the door.
  defp connect_info(%{private: private}), do: Map.get(private, :connect_info)

  defp link_error_copy(:expired),
    do: "This host link has expired. Open Host this quiz in Studio again for a new one."

  defp link_error_copy(_missing_or_invalid),
    do: "Only the quiz's authors can host it. Open Host this quiz in Studio to get a host link."

  defp pct(_count, 0), do: 0
  defp pct(count, total), do: round(count / total * 100)
end
