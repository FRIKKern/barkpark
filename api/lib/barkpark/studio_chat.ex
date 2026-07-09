defmodule Barkpark.StudioChat do
  @moduledoc """
  The **Studio Claude chat** context — the session index + display history behind
  the `/studio/chat` tab (epic studio-claude-chat, charter D6-D8/D13).

  Two tables, `chat_sessions` + `chat_messages`, with **no HTTP route ever**: the
  admin LiveView reads `Repo` directly, so transcripts (cwd, tool inputs, host
  paths) are admin-gated by construction (charter D6 — the doc route is
  disqualified because a private-schema query gate is any-api-token).

  ## Identity + resume (D8)

  A session's primary key is the minted claude session UUID. We generate it
  before the first byte (`--session-id`), and the SAME value is the `--resume`
  key — one identity, no cursor column. `create_session/1` is called on the
  FIRST user send, never on mount (no empty rows).

  ## Display history (D7)

  Each message stores `source_markdown` ONLY (never HTML); re-render on read so
  the improving render engine wins. Written on message COMPLETION, never per
  delta. The CLI owns the real transcript — we never read `~/.claude/projects`.

  ## Denormalisation

  `append_message/2` and `record_result_metrics/2` bump the session's sidebar
  fields (`summary`, `message_count`, usage totals, `last_active_at`) in the same
  transaction / atomic UPDATE, so the sidebar renders without scanning messages.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.StudioChat.{Message, Session}

  # Longest sidebar preview we keep denormalised on the session row.
  @summary_max 140

  # ---------------------------------------------------------------------------
  # sessions
  # ---------------------------------------------------------------------------

  @doc """
  Create a session from `attrs`. `id` (the minted claude session UUID) is
  REQUIRED — the caller mints it so it doubles as the `--resume` key.

  Returns `{:ok, %Session{}}` or `{:error, changeset}`.
  """
  @spec create_session(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def create_session(attrs) do
    %Session{}
    |> Session.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetch a session by id. Returns `nil` for a missing id AND for a non-UUID
  string (UUID-guarded — never a 500).
  """
  @spec get_session(String.t() | nil) :: Session.t() | nil
  def get_session(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Session, uuid)
      :error -> nil
    end
  end

  def get_session(_), do: nil

  @doc """
  Fetch a session and its messages (ordered by `seq`). Returns `nil` if missing.
  """
  @spec get_session_with_messages(String.t() | nil) :: Session.t() | nil
  def get_session_with_messages(id) do
    case get_session(id) do
      nil -> nil
      session -> Repo.preload(session, :messages)
    end
  end

  # A managed sidebar never renders an unbounded list — the recency-desc order
  # keeps live work on top, so 50 is a generous fold with no pagination chrome.
  @sidebar_cap 50

  @doc """
  List sessions for the sidebar, most-recently-active first, capped at
  #{@sidebar_cap}. Selects only the sidebar fields (no message scan).

  Options:

    * `:archived` — `false` (default) lists the active side of the shelf
      (`archived_at IS NULL`, the partial-indexed hot path); `true` lists the
      archived shelf (`archived_at IS NOT NULL`).
  """
  @spec list_sessions(keyword()) :: [Session.t()]
  def list_sessions(opts \\ []) do
    archived? = Keyword.get(opts, :archived, false)

    Session
    |> archived_filter(archived?)
    |> order_by([s], desc: s.last_active_at, desc: s.inserted_at)
    |> limit(^@sidebar_cap)
    |> select([s], %Session{
      id: s.id,
      title: s.title,
      title_source: s.title_source,
      status: s.status,
      summary: s.summary,
      message_count: s.message_count,
      input_tokens: s.input_tokens,
      output_tokens: s.output_tokens,
      total_cost_usd: s.total_cost_usd,
      last_active_at: s.last_active_at,
      archived_at: s.archived_at,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    })
    |> Repo.all()
  end

  defp archived_filter(query, true), do: where(query, [s], not is_nil(s.archived_at))
  defp archived_filter(query, false), do: where(query, [s], is_nil(s.archived_at))

  @doc """
  List a session's messages in `seq` order.
  """
  @spec list_messages(String.t()) :: [Message.t()]
  def list_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.seq)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # lifecycle: archive + delete (wave 2 — the sidebar as a managed resource list)
  # ---------------------------------------------------------------------------

  @doc """
  Permanently delete a session and its messages. The `chat_messages` FK is
  `on_delete: :delete_all`, so one `Repo.delete` cascades — no manual cleanup.
  UUID-guarded: a missing/non-UUID id is a clean `:noop`, never a crash.
  """
  @spec delete_session(String.t()) :: {:ok, Session.t()} | {:error, term()} | :noop
  def delete_session(id) do
    case get_session(id) do
      nil -> :noop
      session -> Repo.delete(session)
    end
  end

  @doc """
  Archive a session — stamp `archived_at` so it drops off the active sidebar and
  onto the archived shelf. Orthogonal to `status`: a working/exited session can
  be archived without touching its liveness. `:noop` if the session is gone.
  """
  @spec archive_session(String.t()) :: {:ok, Session.t()} | {:error, term()} | :noop
  def archive_session(id), do: set_archived_at(id, DateTime.utc_now())

  @doc """
  Unarchive a session — clear `archived_at` so it returns to the active sidebar.
  `:noop` if the session is gone.
  """
  @spec unarchive_session(String.t()) :: {:ok, Session.t()} | {:error, term()} | :noop
  def unarchive_session(id), do: set_archived_at(id, nil)

  defp set_archived_at(id, value) do
    case get_session(id) do
      nil ->
        :noop

      session ->
        session
        |> Ecto.Changeset.change(archived_at: value)
        |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # messages
  # ---------------------------------------------------------------------------

  @doc """
  Append a completed message to a session in ONE transaction: allocate the next
  `seq` (max + 1, per session), insert the row, and bump the session's
  denormalised `message_count`, `summary`, and `last_active_at`.

  `session` may be a `%Session{}` or a session-id string. `attrs` needs at least
  `:role`; `:source_markdown` and `:metadata` are optional. `:seq` is IGNORED —
  always allocated here.

  Returns `{:ok, %Message{}}` or `{:error, reason}`.
  """
  @spec append_message(Session.t() | String.t(), map()) ::
          {:ok, Message.t()} | {:error, term()}
  def append_message(%Session{id: id}, attrs), do: append_message(id, attrs)

  def append_message(session_id, attrs) when is_binary(session_id) do
    attrs = normalize_keys(attrs)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      next_seq = next_seq(session_id)

      message_attrs =
        attrs
        |> Map.put(:session_id, session_id)
        |> Map.put(:seq, next_seq)

      case %Message{} |> Message.changeset(message_attrs) |> Repo.insert() do
        {:ok, message} ->
          bump_on_append(session_id, message, now)
          message

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # Next monotonic seq for a session (1-based). MAX+1; the UNIQUE
  # [session_id, seq] index is the concurrent-append backstop.
  defp next_seq(session_id) do
    seq =
      Message
      |> where([m], m.session_id == ^session_id)
      |> select([m], max(m.seq))
      |> Repo.one()

    (seq || 0) + 1
  end

  # Denormalised sidebar bump: +1 message, refresh last_active_at, and set the
  # preview summary from THIS message's markdown when it carries any. Only the
  # conversation itself (user/assistant) owns the summary — tool/system ephemera
  # bump activity but never clobber the preview.
  @summary_roles ~w(user assistant)
  defp bump_on_append(session_id, %Message{source_markdown: md, role: role}, now) do
    updates = [inc: [message_count: 1], set: [last_active_at: now, updated_at: now]]

    updates =
      case role in @summary_roles && summary_preview(md) do
        preview when is_binary(preview) ->
          Keyword.update!(updates, :set, &Keyword.put(&1, :summary, preview))

        _ ->
          updates
      end

    Session
    |> where([s], s.id == ^session_id)
    |> Repo.update_all(updates)
  end

  defp summary_preview(nil), do: nil

  defp summary_preview(md) when is_binary(md) do
    trimmed =
      md
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      # Strip leading markdown furniture (heading #, blockquote >, bullets) so
      # a reply opening with "## Findings" previews as "Findings".
      |> String.replace(~r/^(\#{1,6}\s+|>\s+|[-*+]\s+|\d+\.\s+)+/, "")

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= @summary_max -> trimmed
      true -> String.slice(trimmed, 0, @summary_max - 1) <> "…"
    end
  end

  # ---------------------------------------------------------------------------
  # status
  # ---------------------------------------------------------------------------

  @doc """
  Set a session's `status` (one of `active|working|exited`) and refresh
  `last_active_at`. Returns `{:ok, session}`, `{:error, changeset}`, or
  `{:error, :not_found}`.
  """
  @spec update_status(String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_status(session_id, status) do
    with %Session{} = session <- get_session(session_id) do
      session
      |> Ecto.Changeset.change(status: status, last_active_at: DateTime.utc_now())
      |> Ecto.Changeset.validate_inclusion(:status, Session.statuses())
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Persist a mid-session permission-mode switch (charter D17). Mirrors
  `update_status/2`: `validate_inclusion` against `Session.modes/0` and refresh
  `last_active_at`, so a reopened session shows the mode you switched to AND the
  next lazy `--resume` spawn's `build_args` carries it. Returns `{:ok, session}`,
  `{:error, changeset}`, or `{:error, :not_found}`.
  """
  @spec set_mode(String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_mode(session_id, mode) do
    with %Session{} = session <- get_session(session_id) do
      session
      |> Ecto.Changeset.change(mode: mode, last_active_at: DateTime.utc_now())
      |> Ecto.Changeset.validate_inclusion(:mode, Session.modes())
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Mark a session `exited` (its port died — crash or clean exit). Next send
  lazy-resumes. `:noop` if the session is gone.
  """
  @spec mark_exited(String.t()) :: {:ok, Session.t()} | {:error, term()} | :noop
  def mark_exited(session_id) do
    case update_status(session_id, "exited") do
      {:error, :not_found} -> :noop
      other -> other
    end
  end

  # ---------------------------------------------------------------------------
  # titles (charter D13 — layered, clobber-guarded)
  # ---------------------------------------------------------------------------

  @doc """
  Human rename. Sets `title` and pins `title_source: "human"` UNCONDITIONALLY —
  a human title is never overwritten by the AI titler. Returns `{:ok, session}`
  or `{:error, :not_found}`.
  """
  @spec rename(String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def rename(session_id, title) do
    with %Session{} = session <- get_session(session_id) do
      session
      |> Ecto.Changeset.change(title: title, title_source: "human")
      |> Ecto.Changeset.validate_required([:title])
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  AI-title write, clobber-guarded: sets `title` + `title_source: "ai"` ONLY while
  `title_source = "default"`. If a human rename (or an earlier AI title) already
  landed, this is a `:noop` — the race is decided in SQL (UPDATE ... WHERE
  title_source = 'default'), so it is safe against a concurrent `rename/2`.

  Returns `{:ok, session}` when it landed, `:noop` when guarded off, or
  `{:error, :blank}` for an empty/blank title.
  """
  @spec maybe_set_ai_title(String.t(), String.t()) ::
          {:ok, Session.t()} | :noop | {:error, :blank}
  def maybe_set_ai_title(session_id, title) do
    clean = if is_binary(title), do: String.trim(title), else: ""

    cond do
      clean == "" ->
        {:error, :blank}

      true ->
        {count, rows} =
          Session
          |> where([s], s.id == ^session_id and s.title_source == "default")
          |> select([s], s)
          |> Repo.update_all(
            set: [title: clean, title_source: "ai", updated_at: DateTime.utc_now()]
          )

        case {count, rows} do
          {1, [session]} -> {:ok, session}
          _ -> :noop
        end
    end
  end

  # ---------------------------------------------------------------------------
  # metrics (charter D3/D7 — accumulate off the result frame, model-agnostic)
  # ---------------------------------------------------------------------------

  @doc """
  Accumulate usage from a claude result frame onto the session's denormalised
  totals, atomically (`UPDATE ... SET x = x + ?`). Model-agnostic: reads token
  counts from a flat map or a nested `usage` sub-map, and cost from
  `total_cost_usd`. Unknown/absent keys count as zero. Also refreshes
  `last_active_at`.

  Accepts string- or atom-keyed maps. Returns `{:ok, session}` or
  `{:error, :not_found}`.
  """
  @spec record_result_metrics(String.t(), map()) ::
          {:ok, Session.t()} | {:error, :not_found}
  def record_result_metrics(session_id, frame) when is_map(frame) do
    frame = normalize_keys(frame)
    usage = normalize_keys(Map.get(frame, :usage, %{}))

    input = num(Map.get(frame, :input_tokens, Map.get(usage, :input_tokens, 0)))
    output = num(Map.get(frame, :output_tokens, Map.get(usage, :output_tokens, 0)))
    cost = fnum(Map.get(frame, :total_cost_usd, Map.get(usage, :total_cost_usd, 0)))

    set = [last_active_at: DateTime.utc_now()]

    # Track the model that actually answered (callers derive it from the
    # result frame's modelUsage keys) so a reopened session can show it.
    set =
      case Map.get(frame, :model) do
        model when is_binary(model) and model != "" -> [{:model, model} | set]
        _ -> set
      end

    {count, rows} =
      Session
      |> where([s], s.id == ^session_id)
      |> select([s], s)
      |> Repo.update_all(
        inc: [input_tokens: input, output_tokens: output, total_cost_usd: cost],
        set: set
      )

    case {count, rows} do
      {1, [session]} -> {:ok, session}
      _ -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  # Accept string- OR atom-keyed maps from callers/JSON frames — normalise the
  # keys we care about to atoms. Only atomises known keys (no atom-exhaustion).
  @known_keys ~w(role source_markdown metadata session_id seq usage input_tokens
                 output_tokens total_cost_usd model)a
  @known_key_strings Enum.map(@known_keys, &Atom.to_string/1)

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key =
        cond do
          is_atom(k) -> k
          is_binary(k) and k in @known_key_strings -> String.to_existing_atom(k)
          true -> k
        end

      {key, v}
    end)
  end

  defp num(n) when is_integer(n), do: n
  defp num(n) when is_float(n), do: trunc(n)
  defp num(_), do: 0

  defp fnum(n) when is_number(n), do: n / 1
  defp fnum(_), do: 0.0
end
