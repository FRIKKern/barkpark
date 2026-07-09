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
      pending_approvals: s.pending_approvals,
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

  Its attachment files (charter D25) are removed too — the bytes live in a
  chat-owned dir keyed by the session id and must not outlive the row. Archiving
  keeps files; only a permanent delete purges them. The file purge runs AFTER a
  successful row delete and never raises (a stray FS error can't fail the delete).
  """
  @spec delete_session(String.t()) :: {:ok, Session.t()} | {:error, term()} | :noop
  def delete_session(id) do
    case get_session(id) do
      nil ->
        :noop

      session ->
        case Repo.delete(session) do
          {:ok, _} = ok ->
            delete_session_attachments(session.id)
            ok

          other ->
            other
        end
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

  # A truly-concurrent same-session append is retried this many times before we
  # give up: two tabs (or a takeover racing the old owner) can both read the
  # same MAX(seq) and try to claim seq N — the UNIQUE index rejects the loser,
  # and a fresh transaction re-reads MAX and takes N+1. Three attempts covers
  # any realistic contention on one session (charter D20b).
  @append_retries 3

  # The "needs you" role set (charter D31). A permission ask persists under one
  # of three roles by its tool_name — "approval" (generic tool), "question"
  # (AskUserQuestion), "plan" (ExitPlanMode) — but ALL THREE mean "the agent is
  # waiting on the human", so every seam that gates on a pending ask
  # (`pending_approvals` inc, cancel-all, find-by-request-id) treats them
  # identically. Partial widening would leave the sidebar pill / cancel / replay
  # lying for questions and plans. The denormalised `pending_approvals` counter
  # stays THE one counter and now means "the agent needs you".
  @needs_you_roles ~w(approval question plan)

  @doc """
  Append a completed message to a session in ONE transaction: allocate the next
  `seq` (max + 1, per session), insert the row, and bump the session's
  denormalised `message_count`, `summary`, and `last_active_at`.

  `session` may be a `%Session{}` or a session-id string. `attrs` needs at least
  `:role`; `:source_markdown` and `:metadata` are optional. `:seq` is IGNORED —
  always allocated here.

  ## Concurrent-append discipline (charter D20b)

  `next_seq/1` is a SELECT-max + 1: two writers on the same session can compute
  the same seq and collide on the UNIQUE `[session_id, seq]` index. That is a
  transient, self-healing conflict — the loser retries with a FRESH max and
  wins the next slot. We retry the mapped `chat_messages_session_id_seq_index`
  changeset error up to #{@append_retries} times so a same-session race NEVER
  silently drops a message. Any OTHER error (or exhausted retries) surfaces as
  `{:error, _}` — callers must not discard it.

  Returns `{:ok, %Message{}}` or `{:error, reason}`.
  """
  @spec append_message(Session.t() | String.t(), map()) ::
          {:ok, Message.t()} | {:error, term()}
  def append_message(%Session{id: id}, attrs), do: append_message(id, attrs)

  def append_message(session_id, attrs) when is_binary(session_id) do
    do_append(session_id, normalize_keys(attrs), @append_retries)
  end

  defp do_append(session_id, attrs, attempts) do
    now = DateTime.utc_now()

    result =
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

    case result do
      {:error, %Ecto.Changeset{} = changeset} ->
        if attempts > 1 and seq_conflict?(changeset) do
          do_append(session_id, attrs, attempts - 1)
        else
          {:error, changeset}
        end

      other ->
        other
    end
  end

  # True when the failure is the UNIQUE [session_id, seq] index specifically —
  # the ONLY error we retry (a foreign-key or validation error must surface, not
  # loop). Matched by the mapped constraint NAME so it is robust to which field
  # Ecto pins the error on.
  defp seq_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "chat_messages_session_id_seq_index"
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
    # An appended needs-you row (approval | question | plan) is an ask — always
    # pending at creation — so it raises the denormalised pending counter. The
    # −1 lands when it resolves (`update_approval_status/3`) or is force-canceled
    # (`cancel_pending_approvals/1`).
    inc =
      if role in @needs_you_roles,
        do: [message_count: 1, pending_approvals: 1],
        else: [message_count: 1]

    updates = [inc: inc, set: [last_active_at: now, updated_at: now]]

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
  Attach a tool's output to its persisted tool row (matched by the
  metadata tool_use_id). `:noop` when no row matches — a result for a tool we
  never persisted must not raise.
  """
  def attach_tool_result(session_id, tool_use_id, output)
      when is_binary(session_id) and is_binary(tool_use_id) and is_binary(output) do
    row =
      Repo.one(
        from(m in Message,
          where:
            m.session_id == ^session_id and m.role == "tool" and
              fragment("?->>'tool_use_id' = ?", m.metadata, ^tool_use_id),
          limit: 1
        )
      )

    case row do
      nil ->
        :noop

      %Message{} = m ->
        m
        |> Ecto.Changeset.change(metadata: Map.put(m.metadata || %{}, "output", output))
        |> Repo.update()
    end
  end

  @doc """
  Replace the persisted `input` on a tool/todo row, matched by its metadata
  `tool_use_id` (charter D39). This is the living-checklist collapse: a later
  TodoWrite in the SAME turn updates the turn's first todo row IN PLACE instead
  of appending a fresh row, so replay reconstructs ONE final-state card. Clones
  `attach_tool_result/3` (find by tool_use_id, changeset the metadata, update)
  but writes `metadata.input` rather than `metadata.output`. `:noop` when no row
  matches — an update for a row we never persisted must not raise.
  """
  def update_tool_input(session_id, tool_use_id, input)
      when is_binary(session_id) and is_binary(tool_use_id) do
    row =
      Repo.one(
        from(m in Message,
          where:
            m.session_id == ^session_id and
              fragment("?->>'tool_use_id' = ?", m.metadata, ^tool_use_id),
          limit: 1
        )
      )

    case row do
      nil ->
        :noop

      %Message{} = m ->
        m
        |> Ecto.Changeset.change(metadata: Map.put(m.metadata || %{}, "input", input))
        |> Repo.update()
    end
  end

  @doc """
  True when a tool_use `input` is TodoWrite-shaped (charter D39): a non-empty
  `todos` list where every item is a map carrying a `content` and a `status`.
  Dispatch on SHAPE, never a tool NAME — names are host-binary-dependent (the
  cmux binary lacks TodoWrite entirely, vanilla has it). Tolerant of both the
  modern `{content, status, activeForm}` and legacy `{content, status, priority,
  id}` item shapes.
  """
  @spec todo_shaped?(any()) :: boolean()
  def todo_shaped?(%{"todos" => todos}) when is_list(todos) and todos != [] do
    Enum.all?(todos, fn t -> is_map(t) and is_binary(t["content"]) and is_binary(t["status"]) end)
  end

  def todo_shaped?(_), do: false

  @doc """
  Persist the user's picked model alias (nil = CLI default). Choice is intent
  (rides the next spawn as `--model`); the `model` column stays the observed
  answering model off the result frame.
  """
  def set_model_choice(session_id, choice) do
    with %Session{} = session <- get_session(session_id) do
      session
      |> Ecto.Changeset.change(model_choice: choice, last_active_at: DateTime.utc_now())
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  The most-recently-active session's non-default `model_choice` (charter D36d) —
  the seed for a NEW chat's model picker, so "opus" stays sticky across new
  chats. A DEDICATED query on purpose: `list_sessions` selects sidebar fields and
  OMITS `model_choice`, so seeding off a listed row reads `nil` forever (the
  vacuous-green trap). Returns the alias string or `nil` (no session ever picked
  a non-default model). Ignores archive state — the last intent is the last
  intent regardless of shelf.
  """
  @spec recent_model_choice() :: String.t() | nil
  def recent_model_choice do
    Session
    |> where([s], not is_nil(s.model_choice) and s.model_choice != "default")
    |> order_by([s], desc: s.last_active_at, desc: s.inserted_at)
    |> limit(1)
    |> select([s], s.model_choice)
    |> Repo.one()
  end

  @doc """
  Persist the sticky composer draft (charter D36c). `draft` is the unsent text
  (nil/`""` clears it). Deliberately does NOT bump `last_active_at` — leaving a
  draft must not reorder the sidebar. Restored on reopen from the full session
  struct (`get_session`), NEVER from `list_sessions` (whose select omits it).
  Returns `{:ok, session}` or `{:error, :not_found}`.
  """
  @spec set_draft(String.t(), String.t() | nil) ::
          {:ok, Session.t()} | {:error, :not_found}
  def set_draft(session_id, draft) do
    with %Session{} = session <- get_session(session_id) do
      session
      |> Ecto.Changeset.change(draft: blank_to_nil(draft))
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(draft) when is_binary(draft) do
    case String.trim(draft) do
      "" -> nil
      _ -> draft
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
  # approvals (charter D11/D14 — persisted lifecycle, denormalised pending count)
  # ---------------------------------------------------------------------------

  # An approval message carries its lifecycle in `metadata.approval_status`:
  # "pending" → one of the terminal states below. The row's markdown/tool_name
  # let the reopened terminal-state card render without a live subprocess.
  @approval_terminal ~w(allowed denied canceled)

  @doc """
  Resolve ONE approval to a terminal state (`allowed | denied | canceled`),
  addressed by its `request_id`. Updates the message row's
  `metadata.approval_status` and, if the row was still `pending`, decrements the
  session's denormalised `pending_approvals` (guarded ≥ 0) in the same
  transaction.

  Returns `{:ok, %Message{}}`, `{:error, :not_found}` (no such pending/known
  approval), or `{:error, :bad_status}` for an unknown terminal state.
  """
  @spec update_approval_status(String.t(), String.t(), String.t()) ::
          {:ok, Message.t()} | {:error, :not_found | :bad_status}
  def update_approval_status(_session_id, _request_id, status)
      when status not in @approval_terminal,
      do: {:error, :bad_status}

  def update_approval_status(session_id, request_id, status) do
    Repo.transaction(fn ->
      case find_approval(session_id, request_id) do
        nil ->
          Repo.rollback(:not_found)

        %Message{} = message ->
          was_pending? = approval_pending?(message)
          meta = Map.put(message.metadata || %{}, "approval_status", status)

          {:ok, updated} =
            message |> Ecto.Changeset.change(metadata: meta) |> Repo.update()

          if was_pending?, do: dec_pending(session_id)
          updated
      end
    end)
    |> case do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Force-cancel EVERY still-pending approval for a session — the shared teardown
  path (a port crash / a reopen with no live control channel) can never deliver
  a decision, so a dangling ask is `canceled`, honestly, not left hanging. Flips
  each pending row's `metadata.approval_status` to `"canceled"` and zeroes the
  session's `pending_approvals`. Returns the number of approvals canceled.
  """
  @spec cancel_pending_approvals(String.t()) :: non_neg_integer()
  def cancel_pending_approvals(session_id) do
    Repo.transaction(fn ->
      pending =
        Message
        |> where([m], m.session_id == ^session_id and m.role in ^@needs_you_roles)
        |> where([m], fragment("?->>'approval_status' = 'pending'", m.metadata))
        |> Repo.all()

      Enum.each(pending, fn message ->
        meta = Map.put(message.metadata || %{}, "approval_status", "canceled")
        message |> Ecto.Changeset.change(metadata: meta) |> Repo.update!()
      end)

      Session
      |> where([s], s.id == ^session_id)
      |> Repo.update_all(set: [pending_approvals: 0, updated_at: DateTime.utc_now()])

      length(pending)
    end)
    |> case do
      {:ok, count} -> count
      _ -> 0
    end
  end

  # The needs-you message (approval | question | plan) for a request_id (unique
  # per ask). Newest wins if a request_id were ever reused; never raises on 0/N
  # rows.
  defp find_approval(session_id, request_id) do
    Message
    |> where([m], m.session_id == ^session_id and m.role in ^@needs_you_roles)
    |> where([m], fragment("?->>'request_id' = ?", m.metadata, ^request_id))
    |> order_by([m], desc: m.seq)
    |> limit(1)
    |> Repo.one()
  end

  defp approval_pending?(%Message{metadata: meta}),
    do: Map.get(meta || %{}, "approval_status") == "pending"

  # Guarded decrement — the counter never underflows if a resolve races a
  # cancel-all that already zeroed it.
  defp dec_pending(session_id) do
    Session
    |> where([s], s.id == ^session_id and s.pending_approvals > 0)
    |> Repo.update_all(inc: [pending_approvals: -1], set: [updated_at: DateTime.utc_now()])
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
  totals, atomically. Model-agnostic: reads token counts from a flat map or a
  nested `usage` sub-map, and cost from `total_cost_usd`. Unknown/absent keys
  count as zero. Also refreshes `last_active_at`.

  Two axes are updated in one UPDATE (charter D19):

    * The lifetime totals `input_tokens` / `output_tokens` / `total_cost_usd`
      are `inc:`-summed across turns (cost + usage history).
    * The context-headroom snapshot `last_context_tokens` / `context_window` is
      **SET** (not inc) from THIS frame only — the ring shows how full the window
      is *right now*, not a cumulative sum. `last_context_tokens =
      input + cache_read + cache_creation + output` of this frame; `context_window`
      is the integer the caller extracted from `modelUsage.<model>.contextWindow`.
      A nil/absent `context_window` leaves the prior value untouched (never
      clobbers a known window to unknown — honest headroom).

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

    cache_read =
      num(Map.get(usage, :cache_read_input_tokens, Map.get(frame, :cache_read_input_tokens, 0)))

    cache_creation =
      num(
        Map.get(
          usage,
          :cache_creation_input_tokens,
          Map.get(frame, :cache_creation_input_tokens, 0)
        )
      )

    cost = fnum(Map.get(frame, :total_cost_usd, Map.get(usage, :total_cost_usd, 0)))

    # Snapshot (SET, never inc): the tokens riding in the model's context on THIS
    # turn. SET is what makes the ring HONEST across compaction (charter D27) — the
    # turn AFTER the CLI compacts reports a small window occupancy, so the ring
    # shrinks to the post-compaction reality instead of a stale summed high-water
    # mark. Two known imprecisions we live with (directional gauge, not an
    # accountant) — DO NOT "fix" by changing the sum:
    #   * One-turn mid-compaction inflation: on the exact turn compaction fires,
    #     the frame can report both the pre-compaction read and the post-compaction
    #     context, briefly over-stating occupancy. It self-corrects on the next
    #     turn's frame (which this SET overwrites).
    #   * Multi-round-trip cache_read overcount: a single turn may make several
    #     internal model round-trips, and cache_read_input_tokens can sum across
    #     them — so this figure can exceed the true resident context. It is the
    #     best signal the frame carries; the ring is a headroom cue, not a ledger.
    last_context = input + cache_read + cache_creation + output

    set = [last_active_at: DateTime.utc_now(), last_context_tokens: last_context]

    # Track the model that actually answered (callers derive it from the
    # result frame's modelUsage keys) so a reopened session can show it.
    set =
      case Map.get(frame, :model) do
        model when is_binary(model) and model != "" -> [{:model, model} | set]
        _ -> set
      end

    # Capture the window ONLY when the frame carries it — never clobber a known
    # window to unknown, and never invent one from a hardcoded model→window map.
    set =
      case num_or_nil(Map.get(frame, :context_window)) do
        window when is_integer(window) and window > 0 -> [{:context_window, window} | set]
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
  # attachments (charter D25 — chat-owned file store, NEVER the media plugin)
  # ---------------------------------------------------------------------------
  #
  # Pasted/dropped images ride the turn as base64 content blocks (built at send
  # time), but the BYTES are NOT kept in jsonb (D7 smell) and NEVER routed through
  # the media plugin — `GET /media/files/*` is public and its "private" delivery
  # is any-token (access.ex:114), the exact leak charter D6 disqualified. Bytes
  # live under a chat-owned dir keyed by the session id; the message metadata
  # carries only a lightweight pointer `{path, media_type, sha256, byte_size}`.
  # Replay reads the file SERVER-SIDE inside the admin-gated LiveView and inlines
  # a `data:` URI — no HTTP route over these files, ever.

  @doc """
  The root directory attachment bytes are written under. Configured via
  `config :barkpark, Barkpark.StudioChat, attachments_dir: <dir>` (test env
  points at a tmp dir); falls back to a stable subdir of the OS temp dir so a
  missing config never crashes a send.
  """
  @spec attachments_dir() :: String.t()
  def attachments_dir do
    Application.get_env(:barkpark, __MODULE__, [])
    |> Keyword.get(:attachments_dir) ||
      Path.join(System.tmp_dir!(), "barkpark_studio_chat_attachments")
  end

  @doc """
  Persist one image's bytes under `<attachments_dir>/<session_id>/<sha256>` and
  return a pointer map `%{path, media_type, sha256, byte_size}` for the message
  metadata (`path` is RELATIVE — `<session_id>/<sha256>` — so the store row is
  location-independent). Content-addressed: the same bytes de-dupe to the same
  file. Returns `{:error, reason}` if the write fails (the caller surfaces it
  honestly — never a base64 blob in the DB).
  """
  @spec store_attachment(String.t(), binary(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def store_attachment(session_id, bytes, media_type)
      when is_binary(session_id) and is_binary(bytes) do
    sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    dir = Path.join(attachments_dir(), session_id)
    abs = Path.join(dir, sha)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(abs, bytes) do
      {:ok,
       %{
         path: Path.join(session_id, sha),
         media_type: normalize_media_type(media_type),
         sha256: sha,
         byte_size: byte_size(bytes)
       }}
    end
  end

  @doc """
  Read an attachment's bytes back by its RELATIVE pointer path (as stored in
  message metadata). Returns `{:ok, bytes}` or `{:error, :missing}` — a file
  removed out from under the row (or a traversal-looking path) degrades to an
  honest miss so replay renders a placeholder instead of crashing.
  """
  @spec read_attachment(String.t() | nil) :: {:ok, binary()} | {:error, :missing}
  def read_attachment(rel_path) when is_binary(rel_path) do
    if safe_rel_path?(rel_path) do
      case File.read(Path.join(attachments_dir(), rel_path)) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, _} -> {:error, :missing}
      end
    else
      {:error, :missing}
    end
  end

  def read_attachment(_), do: {:error, :missing}

  @doc """
  Remove a session's entire attachment directory. Called on permanent delete
  (files must not outlive the row) and safe to call for a session that never had
  an attachment (a missing dir is a clean success). Never raises.
  """
  @spec delete_session_attachments(String.t()) :: :ok
  def delete_session_attachments(session_id) when is_binary(session_id) do
    if uuid_like?(session_id) do
      File.rm_rf(Path.join(attachments_dir(), session_id))
    end

    :ok
  rescue
    _ -> :ok
  end

  def delete_session_attachments(_), do: :ok

  # png|jpeg|gif|webp — the accepted set (charter D25). Anything else (or a nil)
  # falls back to png so the base64 block still has a valid media_type; the
  # composer's allow_upload accept-list is the real gate.
  @image_media_types ~w(image/png image/jpeg image/gif image/webp)
  defp normalize_media_type(mt) when mt in @image_media_types, do: mt
  defp normalize_media_type("image/jpg"), do: "image/jpeg"
  defp normalize_media_type(_), do: "image/png"

  # A stored pointer is always "<session-uuid>/<sha256-hex>" — reject anything
  # with a path separator escape or "..", so read_attachment can never be walked
  # outside the attachments root even if metadata were tampered with.
  defp safe_rel_path?(path) do
    parts = Path.split(path)

    length(parts) == 2 and
      Enum.all?(parts, &(&1 != "" and &1 != "." and &1 != ".." and not String.contains?(&1, "/")))
  end

  defp uuid_like?(id), do: match?({:ok, _}, Ecto.UUID.cast(id))

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  # Accept string- OR atom-keyed maps from callers/JSON frames — normalise the
  # keys we care about to atoms. Only atomises known keys (no atom-exhaustion).
  @known_keys ~w(role source_markdown metadata session_id seq usage input_tokens
                 output_tokens total_cost_usd model cache_read_input_tokens
                 cache_creation_input_tokens context_window)a
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

  # Like num/1 but preserves the "absent" signal: nil/garbage → nil (so the
  # window-capture can distinguish "no window in this frame" from a real zero).
  defp num_or_nil(n) when is_integer(n), do: n
  defp num_or_nil(n) when is_float(n), do: trunc(n)
  defp num_or_nil(_), do: nil

  defp fnum(n) when is_number(n), do: n / 1
  defp fnum(_), do: 0.0
end
