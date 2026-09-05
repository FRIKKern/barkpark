defmodule BarkparkWeb.QuizHostLive do
  @moduledoc """
  P1 host/projector surface (the big-screen half of the split-surface client).
  `/quiz/host/:pin` ensures the room, shows the question, the live player count,
  and animated per-choice tally bars that move as answers land — read-only, no
  input. Subscribes to the room events topic so every `{:tally, t}` /
  `{:player_joined|left, _}` broadcast re-renders without polling.

  This is the surface P5's crowd heatmap will eventually replace the bars with
  (`/papers/hyperquiz-realtime-protocol`); for P1 it's the individual-tally view.
  """
  use Phoenix.LiveView

  alias Barkpark.Quiz

  @impl true
  def mount(%{"pin" => pin} = params, _session, socket) do
    if connected?(socket) do
      # `Quiz.ensure_room/1` is specced `{:ok, pid()} | {:error, term()}` and
      # returns `{:error, :max_children}` BY DESIGN once `Quiz.RoomSupervisor`
      # is at its 10_000-room memory-DoS backstop (plugins/quiz.ex). A hard
      # `{:ok, _pid} =` match turned that bounded, expected refusal into a
      # MatchError on an ANONYMOUS route (`auth: :public_root`), so the client
      # reconnect-looped with no explanation exactly when the node was already
      # under pressure. Branch it, the way `QuizPlayLive.mount/3` and
      # `QuizChannel.join/3` already branch the same refusal.
      case Quiz.ensure_room(pin) do
        {:ok, _pid} -> mount_room(pin, params, socket)
        {:error, reason} -> {:ok, assign(unavailable_assigns(socket, pin), error: reason)}
      end
    else
      {:ok, unavailable_assigns(socket, pin)}
    end
  end

  # The connected mount once the room is live.
  defp mount_room(pin, params, socket) do
    # Bind an optional `?quiz=<id>` so a Studio publish of that quiz reaches
    # this live room in under a second (charter Vision + Decision M). This is
    # the first production call site of `bind_quiz/3`. The default dataset
    # ("production") is deliberate; the id rides the doc_id string column, so
    # NO UUID guard — a guard would reject valid non-UUID ids. `bind_quiz`
    # always returns `:ok`: it silently no-ops on a garbage/unpublished id
    # (the room keeps its default question) and is idempotent across refresh,
    # so there is no error branch to render.
    case params["quiz"] do
      qid when is_binary(qid) and qid != "" -> Quiz.bind_quiz(pin, qid)
      _ -> :ok
    end

    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    state = Quiz.state(pin)

    {:ok,
     assign(socket,
       pin: pin,
       question: state.question,
       tally: state.tally,
       player_count: state.player_count,
       error: nil
     )}
  end

  # The pre-connect skeleton AND the base for the capacity-refusal state.
  defp unavailable_assigns(socket, pin) do
    assign(socket, pin: pin, question: nil, tally: %{}, player_count: 0, error: nil)
  end

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
        <% @error -> %>
          <p class="q-status" role="status">
            This room could not be opened — the quiz service is at room capacity.
            Nothing is lost: reopen
            <a href={"/quiz/host/#{@pin}"}>/quiz/host/{@pin}</a>
            in a moment and the room starts as soon as one frees up.
          </p>
        <% @question -> %>
          <h1 class="q-question">{@question.prompt}</h1>
          <img :if={@question[:image]} src={@question[:image]} alt="" class="q-image" />
          <div class="q-meta">{@total} answers in</div>

          <div class="q-bar-row" :for={{choice, idx} <- Enum.with_index(@question.choices)}>
            <div class="q-bar-label">
              <span>{choice.label}</span>
              <span class="q-count">{Map.get(@tally, choice.id, 0)}</span>
            </div>
            <div class="q-bar-track">
              <div class={"q-bar-fill c#{rem(idx, 4)}"} style={"width: #{pct(Map.get(@tally, choice.id, 0), @total)}%"}></div>
            </div>
          </div>
        <% true -> %>
          <p class="q-status">Opening the room…</p>
      <% end %>
    </div>
    """
  end

  defp pct(_count, 0), do: 0
  defp pct(count, total), do: round(count / total * 100)
end
