defmodule BarkparkWeb.QuizPlayLive do
  @moduledoc """
  P1 player surface (the phone half of the split-surface client). A player opens
  `/quiz/play/:pin`, is auto-joined to the room with a generated identity, taps a
  choice, and watches the live tally move as the crowd answers — all over
  LiveView's own WebSocket (no custom JS for P1; the JS canvas client arrives in
  P2 for cursors/heatmap).

  Realtime: on the connected mount we join the room and subscribe to its events
  topic (`Barkpark.Quiz.room_topic/1`); every `{:tally, t}` broadcast re-renders
  the bars. The dead (HTTP) mount renders a "Connecting…" placeholder and never
  touches the room, so a bare GET never spins up a room as a side effect.
  Joining NEVER starts a room either (the host mount is the sole creator —
  ghost-room guard): a typo'd pin gets the quiet honest "nobody is hosting"
  state instead of a silently-spawned empty room that looks like a working quiz.

  `terminate/2` calls `Quiz.leave/2` so a closed tab / navigation / disconnect
  sheds the player from the room's roster (otherwise the players map and the
  host's count would only ever grow). Stable identity across reconnects and
  anti-spoofing are P6 (`/papers/hyperquiz-risks`).
  """
  use Phoenix.LiveView
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Quiz

  @impl true
  def mount(%{"pin" => pin}, _session, socket) do
    put_quiz_locale()

    if connected?(socket) do
      player_id = Ecto.UUID.generate()
      name = gettext("Player") <> "-" <> String.slice(player_id, 0, 4)

      case Quiz.join(pin, player_id, name) do
        {:ok, snapshot} ->
          Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))

          {:ok,
           assign(socket,
             pin: pin,
             player_id: player_id,
             # Signed identity handed to the cursor canvas so its separate
             # /quiz socket joins as the SAME player (no double-count).
             player_token: BarkparkWeb.QuizSocket.sign(player_id),
             name: name,
             question: snapshot.question,
             tally: snapshot.tally,
             picked: nil,
             locked: snapshot.phase != :question,
             error: nil
           )}

        {:error, reason} ->
          {:ok, base_assigns(socket, pin) |> Phoenix.Component.assign(:error, reason)}
      end
    else
      {:ok, base_assigns(socket, pin)}
    end
  end

  defp base_assigns(socket, pin) do
    assign(socket,
      pin: pin,
      player_id: nil,
      player_token: nil,
      question: nil,
      tally: %{},
      picked: nil,
      locked: false,
      error: nil
    )
  end

  @impl true
  def handle_event("answer", %{"choice" => choice_id}, socket) do
    case Quiz.submit_answer(socket.assigns.pin, socket.assigns.player_id, choice_id) do
      {:ok, tally} -> {:noreply, assign(socket, tally: tally, picked: choice_id)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:quiz, _pin, {:tally, tally}}, socket),
    do: {:noreply, assign(socket, tally: tally)}

  # Live-edit (P4): the host changed the quiz in Studio — swap the question
  # under the player without a reconnect; clear their pick for the new question.
  def handle_info({:quiz, _pin, {:question_updated, question}}, socket),
    do: {:noreply, assign(socket, question: question, picked: nil)}

  # The host started (or restarted) the question: answers were cleared, so the
  # phone clears its pick and opens the buttons again.
  def handle_info({:quiz, _pin, {:phase, :question, payload}}, socket),
    do:
      {:noreply,
       assign(socket,
         question: payload.question,
         tally: payload.tally,
         picked: nil,
         locked: false
       )}

  # Reveal, scores, end: the room refuses answers now (`:wrong_phase`), so the
  # phone says so instead of offering buttons that do nothing.
  def handle_info({:quiz, _pin, {:phase, phase, _payload}}, socket)
      when phase in [:reveal, :leaderboard, :ended],
      do: {:noreply, assign(socket, locked: true)}

  # The host removed THIS player (owner ruling #59): stop showing the question
  # and say why. The room already dropped the player and refuses its id.
  def handle_info(
        {:quiz, _pin, {:player_kicked, player_id}},
        %{assigns: %{player_id: player_id}} = socket
      ),
      do: {:noreply, assign(socket, error: :kicked, question: nil, player_id: nil)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns do
      %{player_id: player_id, pin: pin} when is_binary(player_id) -> Quiz.leave(pin, player_id)
      _ -> :ok
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The page's one main landmark (axe landmark-one-main / region). --%>
    <main class="q-shell">
      <canvas
        class="quiz-cursor-canvas"
        data-quiz-pin={@pin}
        data-quiz-role="player"
        data-quiz-player-token={@player_token}
      ></canvas>
      <p class="q-eyebrow">{gettext("Hyperquiz · Player")}</p>
      <p class="q-pin">{gettext("Room")} <code>{@pin}</code></p>

      <%= cond do %>
        <% @error == :no_room -> %>
          <p class="q-status">
            {gettext("Nobody is hosting this room right now — check the pin, or refresh once your host is up.")}
          </p>
        <% @error == :kicked -> %>
          <p class="q-status">{gettext("The host removed you from this room.")}</p>
        <% @error == :room_locked -> %>
          <p class="q-status">
            {gettext("The host has locked this room, so nobody new can join. Ask the host to unlock it.")}
          </p>
        <% @error == :join_rate_limited -> %>
          <p class="q-status">
            {gettext("Lots of players are joining this room right now. Refresh in a few seconds to join.")}
          </p>
        <% @error -> %>
          <p class="q-status">{gettext("This room is unavailable right now. Try again shortly.")}</p>
        <% @question -> %>
          <h1 class="q-question">{@question.prompt}</h1>
          <img :if={@question[:image]} src={@question[:image]} alt="" class="q-image" />
          <div class="q-grid">
            <button
              :for={{choice, idx} <- Enum.with_index(@question.choices)}
              type="button"
              class={"q-choice c#{rem(idx, 4)} #{if @picked == choice.id, do: "is-picked"}"}
              phx-click="answer"
              phx-value-choice={choice.id}
              disabled={@locked}
            >
              {choice.label}
              <span class="q-count"> · {Map.get(@tally, choice.id, 0)}</span>
            </button>
          </div>
          <p :if={@locked} class="q-status">{gettext("Answers are closed — look up at the host screen.")}</p>
          <p :if={@picked != nil and not @locked} class="q-status">
            {gettext("Answer locked in — tap another to change it.")}
          </p>
        <% true -> %>
          <p class="q-status">{gettext("Connecting to the room…")}</p>
      <% end %>
    </main>
    """
  end

  # The page speaks the quiz's workspace language, never the viewer's: this is
  # an anonymous public door. Every quiz a room can bind resolves through
  # `Content.get_public_document/3`, pinned to the seeded Default workspace
  # (`Barkpark.Quiz.Content.load_question/2`), so that workspace IS the quiz's
  # workspace; an unbound room runs the sample question under the same rule.
  defp put_quiz_locale,
    do: BarkparkWeb.StudioLocale.put(Barkpark.Tenancy.get_default_workspace())
end
