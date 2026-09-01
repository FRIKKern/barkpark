defmodule Barkpark.StudioChat.QuestionAnswer do
  @moduledoc """
  The ONE owner of AskUserQuestion answer construction — shared by the Studio
  LiveView and the `/v1/chat` transport (charter `bp-chat-tui`, D22/D23/D28;
  `ct-bl-question-updatedinput`).

  ## The named failure mode

  `POST /v1/chat/sessions/:id/approval` accepts allow/deny only, and D22 forbids
  a caller-supplied `updatedInput`. That is exactly right for a tool approval —
  "allow" means "run the ask I already hold" — but an `AskUserQuestion` row is
  not a yes/no: its whole content is WHICH option the human picked. A blanket
  allow answers a question row with no answer in it.

  The engine has always been able to carry the rich answer
  (`ClaudeChat.respond_permission/3` takes `{:allow, updated_map}`;
  `Runtime.remote_decision/1` maps `{:allow, value}`). The gap was the wire, and
  the wire is where the danger is: the naive fix — "let the caller send
  `updatedInput`" — hands an arbitrary map straight to the subprocess.

  ## The contract this module enforces

  A caller never supplies `updatedInput`. It supplies a CONSTRAINED answers map
  (`question string => chosen option label`, or a list of labels for a
  `multiSelect` question). Every key must be a question string the SERVER
  persisted in `metadata.input`, and every value must be an option label the
  SERVER persisted for that question. The `updatedInput` is then rebuilt HERE,
  from the stored ask (`updated_input/2`) — the caller's bytes never become
  process input, they only SELECT among bytes the model itself offered.

  Free-text answers are deliberately NOT on the wire. Studio's form still allows
  one (`build_answers/2` honours a custom field), because a LiveView answer is
  an authenticated human typing into the session's own surface; the HTTP
  transport is the D22 boundary and stays label-only. That asymmetry is the
  point, not an oversight.

  ## Why both builders live here

  `build_answers/2` (Studio's index-keyed form scratch state) and
  `validate_answers/2` (the transport's question-string-keyed wire map) collapse
  onto the SAME normalisation: keyed by the question STRING, a multiSelect value
  is comma-joined, an unanswered question is omitted. Two copies of that rule
  would be two answer dialects reaching one CLI. There is one copy, and it is
  here.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.StudioChat.Message

  # A question row the model authored is small (the CLI renders chips). These are
  # sanity ceilings on the WIRE map, checked before any label comparison, so a
  # pathological body is rejected on shape rather than by exhausting the
  # comparison loop.
  @max_answers 32
  @max_labels_per_answer 32

  @doc """
  Fetch the still-`pending` QUESTION row for `request_id` in `session_id`.

  Deliberately narrower than `StudioChat.update_approval_status/3`'s
  role-agnostic lookup: `/answer` is the question-only route, so an approval or
  plan row with the same request_id is `nil` here and joins the not-found oracle.
  A row already resolved (a double answer) is `nil` too — the second POST cannot
  re-deliver a decision to the runtime.
  """
  @spec fetch_pending_question(String.t(), String.t()) :: Message.t() | nil
  def fetch_pending_question(session_id, request_id)
      when is_binary(session_id) and is_binary(request_id) do
    Message
    |> where([m], m.session_id == ^session_id and m.role == "question")
    |> where([m], fragment("?->>'request_id' = ?", m.metadata, ^request_id))
    |> where([m], fragment("?->>'approval_status' = 'pending'", m.metadata))
    |> order_by([m], desc: m.seq)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Normalize an AskUserQuestion `input` into a render-ready question list. Each
  entry: the prompt string, an optional header, the `multiSelect` flag, and the
  option chips (label + optional description). Tolerant of options given as bare
  strings. The Studio card renders from this; the wire validator compares
  against it — one parse, so "what the human saw" and "what the server accepts"
  cannot drift.
  """
  @spec parse_questions(map() | any()) :: [map()]
  def parse_questions(%{"questions" => qs}) when is_list(qs) do
    Enum.map(qs, fn q ->
      %{
        question: to_string(Map.get(q, "question", "")),
        header: nonempty(Map.get(q, "header")),
        multi: Map.get(q, "multiSelect", false) == true,
        options: parse_options(Map.get(q, "options"))
      }
    end)
  end

  def parse_questions(_), do: []

  @doc "Option chips for one question — `%{label:, description:}`, bare strings tolerated."
  @spec parse_options(any()) :: [map()]
  def parse_options(opts) when is_list(opts) do
    opts
    |> Enum.map(fn
      %{"label" => label} = o ->
        %{label: to_string(label), description: nonempty(Map.get(o, "description"))}

      label when is_binary(label) ->
        %{label: label, description: nil}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  def parse_options(_), do: []

  @doc """
  Rebuild the `updatedInput` the runtime receives: the SERVER-held original ask
  with the validated answers stamped on it. The caller's body never reaches
  here — only the `answers` map `validate_answers/2` already proved is a subset
  of the stored questions and labels.
  """
  @spec updated_input(map(), map()) :: map()
  def updated_input(server_input, answers) when is_map(server_input) and is_map(answers),
    do: Map.put(server_input, "answers", answers)

  def updated_input(_server_input, answers) when is_map(answers), do: %{"answers" => answers}

  @doc """
  Validate a WIRE answers map against the stored ask (the D22 boundary).

  Accepts `%{question_string => label}` or, for a `multiSelect` question,
  `%{question_string => [label, ...]}`. Returns the normalised answers map —
  values are strings, a multi-select is comma-joined exactly as
  `build_answers/2` joins Studio's chips — or `{:error, message}` for the 400.

  Every rejection is a rejection of SHAPE or of MEMBERSHIP; no message ever
  echoes caller bytes back (D23), so an error is safe to serialize verbatim.
  """
  @spec validate_answers(map() | any(), map() | any()) :: {:ok, map()} | {:error, String.t()}
  def validate_answers(server_input, raw) do
    questions = parse_questions(server_input)

    cond do
      questions == [] ->
        {:error, "the stored ask carries no questions"}

      not is_map(raw) ->
        {:error, "answers must be a JSON object"}

      map_size(raw) == 0 ->
        {:error, "answers must not be empty"}

      map_size(raw) > @max_answers ->
        {:error, "answers exceeds #{@max_answers} entries"}

      true ->
        known = MapSet.new(questions, & &1.question)

        if Enum.any?(Map.keys(raw), &(not MapSet.member?(known, &1))) do
          {:error, "answers names a question the stored ask does not carry"}
        else
          collect(questions, raw)
        end
    end
  end

  # Walk the STORED question order (not the caller's key order) so the built map
  # is a deterministic function of the ask. An absent question is omitted — the
  # same "did not answer" semantics Studio's form has.
  defp collect(questions, raw) do
    Enum.reduce_while(questions, {:ok, %{}}, fn q, {:ok, acc} ->
      case Map.fetch(raw, q.question) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case normalize(q, value) do
            {:ok, answer} -> {:cont, {:ok, Map.put(acc, q.question, answer)}}
            {:error, message} -> {:halt, {:error, message}}
          end
      end
    end)
    |> case do
      {:ok, answers} when map_size(answers) == 0 -> {:error, "answers must not be empty"}
      other -> other
    end
  end

  # ONE label. Valid for single- and multi-select alike (picking one of many is
  # still a legal multi answer).
  defp normalize(q, value) when is_binary(value) do
    if value in labels(q) do
      {:ok, value}
    else
      {:error, "answer is not one of the options the stored ask offers"}
    end
  end

  # A LIST of labels — multiSelect only. Comma-joined exactly as Studio joins its
  # chips, so both surfaces put byte-identical text in front of the CLI.
  defp normalize(q, value) when is_list(value) do
    allowed = labels(q)

    cond do
      not q.multi ->
        {:error, "a list answer is only valid for a multiSelect question"}

      value == [] ->
        {:error, "a list answer must not be empty"}

      length(value) > @max_labels_per_answer ->
        {:error, "a list answer exceeds #{@max_labels_per_answer} labels"}

      Enum.any?(value, &(not is_binary(&1))) ->
        {:error, "each answer label must be a string"}

      length(Enum.uniq(value)) != length(value) ->
        {:error, "a list answer must not repeat a label"}

      Enum.any?(value, &(&1 not in allowed)) ->
        {:error, "answer is not one of the options the stored ask offers"}

      true ->
        {:ok, Enum.join(value, ", ")}
    end
  end

  defp normalize(_q, _value),
    do: {:error, "each answer must be a string or a list of strings"}

  defp labels(q), do: Enum.map(q.options, & &1.label)

  @doc """
  Collapse Studio's FORM scratch state into the wire answer map: keyed by the
  question string, a non-empty custom field wins over the chips, a multiSelect is
  comma-joined, an unanswered question is omitted.

  `form` is `%{selections: %{question_index => [label]}, custom: %{question_index => text}}`.
  """
  @spec build_answers([map()], map()) :: map()
  def build_answers(questions, form) do
    questions
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {q, qidx}, acc ->
      case answer_value(q, Map.get(form.selections, qidx, []), Map.get(form.custom, qidx)) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, q.question, value)
      end
    end)
  end

  @doc """
  The value for ONE question: a trimmed non-empty custom answer wins; else a
  multiSelect joins its labels; else the single selected label; else `nil`
  (unanswered).
  """
  @spec answer_value(map(), [String.t()], String.t() | nil) :: String.t() | nil
  def answer_value(q, selections, custom) do
    trimmed = if is_binary(custom), do: String.trim(custom), else: ""

    cond do
      trimmed != "" -> trimmed
      q.multi and selections != [] -> Enum.join(selections, ", ")
      selections != [] -> List.first(selections)
      true -> nil
    end
  end

  defp nonempty(s) when is_binary(s) do
    if String.trim(s) == "", do: nil, else: s
  end

  defp nonempty(_), do: nil
end
