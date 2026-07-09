defmodule Barkpark.StudioChat do
  @moduledoc """
  The Studio Claude chat **session index + display history** context (epic
  studio-claude-chat, wave 1, charter D6/D7/D8).

  This is the Barkpark half of the split brain: the CLI owns model memory
  (resumed by `--resume <uuid>`); WE own the durable session index and the
  rendered display history. There is NO HTTP route over these tables — the
  Studio LiveView calls this context and reads `Repo` directly, so the
  transcripts (cwd, tool inputs, host paths) are admin-gated by construction.

  Session rows are created on the FIRST user send (`create_session/1`), never on
  mount. Messages persist on COMPLETION (`append_message/2`), never per streaming
  delta. `append_message/2` also bumps the denormalized sidebar columns
  (`message_count`, `summary`, `last_active_at`) so the sidebar renders without
  loading any message rows.
  """

  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.StudioChat.{Message, Session}

  @summary_len 140

  @doc """
  Create a session row keyed by the caller-minted UUID. Called on the first user
  send with `%{id: uuid, cwd:, mode:, model:}` — never on mount (no empty rows).
  """
  @spec create_session(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def create_session(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:last_active_at, now())
      |> Map.put_new(:status, "active")

    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch one session by its minted UUID, or nil."
  @spec get_session(binary()) :: Session.t() | nil
  def get_session(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Session, uuid)
      :error -> nil
    end
  end

  def get_session(_), do: nil

  @doc """
  Sessions for the sidebar, most-recent first (latest activity, then creation).
  Lean by design — the denormalized columns render the list without touching the
  message rows.
  """
  @spec list_sessions() :: [Session.t()]
  def list_sessions do
    Repo.all(
      from s in Session,
        order_by: [
          desc: coalesce(s.last_active_at, s.inserted_at),
          desc: s.inserted_at
        ]
    )
  end

  @doc "All messages of a session, in seq order — the replay source for reopen."
  @spec list_messages(binary()) :: [Message.t()]
  def list_messages(session_id) when is_binary(session_id) do
    Repo.all(from m in Message, where: m.session_id == ^session_id, order_by: [asc: m.seq])
  end

  @doc """
  Append one COMPLETED message (`%{role:, source_markdown:, metadata:}`) and bump
  the session's denormalized sidebar columns in the same transaction. `seq` is
  assigned monotonically. Returns the inserted message.
  """
  @spec append_message(binary(), map()) :: {:ok, Message.t()} | {:error, term()}
  def append_message(session_id, attrs) when is_binary(session_id) do
    attrs = Map.new(attrs)
    role = to_string(attrs[:role] || attrs["role"] || "assistant")
    source = to_string(attrs[:source_markdown] || attrs["source_markdown"] || "")
    metadata = attrs[:metadata] || attrs["metadata"] || %{}

    Repo.transaction(fn ->
      seq = next_seq(session_id)

      inserted =
        %Message{}
        |> Message.changeset(%{
          session_id: session_id,
          seq: seq,
          role: role,
          source_markdown: source,
          metadata: metadata
        })
        |> Repo.insert()

      case inserted do
        {:ok, message} ->
          bump_session(session_id, role, source)
          message

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Set the session lifecycle status (active | working | exited)."
  @spec update_status(binary(), atom() | binary()) :: {non_neg_integer(), nil}
  def update_status(session_id, status) when is_binary(session_id) do
    Repo.update_all(
      from(s in Session, where: s.id == ^session_id),
      set: [status: to_string(status), updated_at: now()]
    )
  end

  @doc "Mark a session offline after its subprocess exits (crash recovery, D11)."
  @spec mark_exited(binary()) :: {non_neg_integer(), nil}
  def mark_exited(session_id) when is_binary(session_id) do
    update_status(session_id, "exited")
  end

  @doc "A human rename — always wins, and stamps `title_source` so AI can't clobber it."
  @spec rename(binary(), binary()) :: {non_neg_integer(), nil}
  def rename(session_id, title) when is_binary(session_id) and is_binary(title) do
    Repo.update_all(
      from(s in Session, where: s.id == ^session_id),
      set: [title: clip(title, 80), title_source: "human", updated_at: now()]
    )
  end

  @doc """
  Land an AI-generated title — but ONLY while the title is still the default
  (clobber guard, D13). A human rename is never overwritten.
  """
  @spec maybe_set_ai_title(binary(), binary()) :: {non_neg_integer(), nil}
  def maybe_set_ai_title(session_id, title) when is_binary(session_id) and is_binary(title) do
    Repo.update_all(
      from(s in Session, where: s.id == ^session_id and s.title_source == "default"),
      set: [title: clip(title, 80), title_source: "ai", updated_at: now()]
    )
  end

  @doc """
  Fold a result-frame's usage into the session totals (charter D7 metadata).
  Accepts `%{input_tokens:, output_tokens:, total_cost_usd:, model:}` (any nil).
  """
  @spec record_result_metrics(binary(), map()) :: {non_neg_integer(), nil}
  def record_result_metrics(session_id, metrics) when is_binary(session_id) do
    metrics = Map.new(metrics)
    input = int(metrics[:input_tokens])
    output = int(metrics[:output_tokens])
    cost = float(metrics[:total_cost_usd])

    set = [last_active_at: now(), updated_at: now()]
    set = if model = metrics[:model], do: [{:model, to_string(model)} | set], else: set

    Repo.update_all(
      from(s in Session, where: s.id == ^session_id),
      inc: [input_tokens: input, output_tokens: output, total_cost_usd: cost],
      set: set
    )
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp next_seq(session_id) do
    (Repo.one(from m in Message, where: m.session_id == ^session_id, select: max(m.seq)) || -1) + 1
  end

  # Bump the denormalized sidebar columns. Recency + the summary line follow the
  # exchange; tool ephemera bump activity but never own the summary.
  defp bump_session(session_id, role, source) do
    set = [last_active_at: now(), updated_at: now()]

    set =
      if role in ["user", "assistant"] and String.trim(source) != "" do
        [{:summary, summarize(source)} | set]
      else
        set
      end

    Repo.update_all(
      from(s in Session, where: s.id == ^session_id),
      inc: [message_count: 1],
      set: set
    )
  end

  # A clean one-line preview for the sidebar: the first non-empty line with its
  # leading markdown furniture (heading #, blockquote >, list bullets) stripped,
  # so a reply that opens with "## Findings" previews as "Findings".
  defp summarize(text) do
    text
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.replace(~r/^\s*(\#{1,6}\s+|>\s+|[-*+]\s+|\d+\.\s+)/, "")
    |> String.trim()
    |> clip(@summary_len)
  end

  defp clip(nil, _), do: nil

  defp clip(text, len) do
    if String.length(text) > len, do: String.slice(text, 0, len - 1) <> "…", else: text
  end

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0

  defp float(n) when is_number(n), do: n / 1
  defp float(_), do: 0.0

  defp now, do: DateTime.utc_now()
end
