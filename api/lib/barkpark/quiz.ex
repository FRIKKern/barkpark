defmodule Barkpark.Quiz do
  @moduledoc """
  Hyperinteractive quiz — public context facade (P1 walking skeleton).

  A thin pass-through to per-room GenServers (`Barkpark.Quiz.Room`), each
  owning one live room's in-memory state. Rooms start lazily on first use and
  self-stop when idle; see `Barkpark.Quiz.Room` for the lifecycle and
  `/papers/hyperquiz-architecture` for where this sits in the stack.

  This is the surface later phases build on: the P1 Channel (player join +
  answer submit) and the live-tally broadcast both go through these calls.
  """

  alias Barkpark.Quiz.Room

  @doc "Resolve-or-start the room for `pin`."
  defdelegate ensure_room(pin), to: Room, as: :ensure

  @doc """
  Add (or refresh) a player in a live room; returns `{:ok, snapshot}`, or
  `{:error, :no_room}` when nobody is hosting `pin` (joins never start rooms —
  the host mount is the sole creator).
  """
  defdelegate join(pin, player_id, name), to: Room

  @doc "Remove a player and drop their answer."
  defdelegate leave(pin, player_id), to: Room

  @doc "Record a player's answer (last write wins)."
  defdelegate submit_answer(pin, player_id, choice_id), to: Room

  @doc "Current per-choice answer counts."
  defdelegate tally(pin), to: Room

  @doc "Public room snapshot."
  defdelegate state(pin), to: Room

  @doc "The PubSub topic a room broadcasts live updates on."
  defdelegate room_topic(pin), to: Room, as: :topic

  @doc "Stop a live room (no-op if none)."
  defdelegate stop_room(pin), to: Room, as: :stop

  @doc "Phase transitions (host-driven): start a question, reveal, leaderboard, end, lobby."
  defdelegate start_question(pin, time_limit \\ nil), to: Room
  defdelegate reveal(pin), to: Room
  defdelegate leaderboard(pin), to: Room
  defdelegate end_game(pin), to: Room
  defdelegate to_lobby(pin), to: Room

  @doc "Replace a room's live question (used by the live-edit bridge + swap)."
  defdelegate apply_question(pin, question), to: Room

  @doc "Bind a room to a quiz id so Studio edits to that quiz update it live (P4)."
  defdelegate bind_quiz(pin, quiz_id, dataset \\ "production"),
    to: Barkpark.Quiz.Bridge,
    as: :bind

  @doc "Report a player's normalized `0.0..1.0` cursor position (fire-and-forget)."
  defdelegate move(pin, player_id, x, y), to: Room

  @doc "Signal which choice a player is hovering (pre-commit), or nil to clear."
  defdelegate hover(pin, player_id, choice_id), to: Room

  @doc "Load a quiz question by id (P3 content), or `{:error, :not_found}`."
  defdelegate load_question(quiz_id, dataset \\ "production"), to: Barkpark.Quiz.Content

  @doc """
  The question for a quiz id, falling back to the Room's hardcoded default when
  the quiz isn't found — so a room always has a question to serve.
  """
  @spec question_or_default(String.t(), String.t()) :: map()
  def question_or_default(quiz_id, dataset \\ "production") do
    case Barkpark.Quiz.Content.load_question(quiz_id, dataset) do
      {:ok, question} -> question
      {:error, :not_found} -> Room.default_question()
    end
  end

  @doc "The PubSub topic batched cursor frames broadcast on."
  defdelegate cursor_topic(pin), to: Room

  @doc "The PubSub topic aggregate heatmap frames broadcast on (P5 crowd scale)."
  defdelegate heat_topic(pin), to: Room

  @doc """
  The HOST-ONLY topic carrying `{:reveal_answer, answer}` — terms a player must
  never receive. Subscribe from a projector/host surface only; a player socket
  on this topic re-opens the answer-key leak (`Room.host_topic/1`).
  """
  defdelegate host_topic(pin), to: Room

  @doc "Override a room's individual→heatmap crossover threshold (tests)."
  defdelegate set_heatmap_threshold(pin, n), to: Room

  # Ambiguous characters (0/O, 1/I/L) omitted so a PIN read off a projector
  # never mis-types.
  @pin_alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"

  @doc "Generate a short, human-friendly room PIN."
  @spec new_pin(pos_integer()) :: String.t()
  def new_pin(len \\ 6) when is_integer(len) and len > 0 do
    for _ <- 1..len, into: "", do: <<Enum.random(@pin_alphabet)>>
  end
end
