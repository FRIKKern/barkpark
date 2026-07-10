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

  ## The needs-you strip (wave 12 — sidebar inbox)

  `needs_you_strip/2` derives the sidebar's cross-session inbox from persisted
  rows (cold-mount correct) plus the transient `studio_chat:activity` overlay
  (live arrive/leave freshness only). "Away" simply means NOT the currently-open
  session — there is no presence system. The **event-kind vocabulary** is the
  strip's contract (S7's email notifications consume these EXACT kinds), in
  strict priority order:

    * `:pending_approval` — a pending ask row with role `"approval"` (a generic
      tool wants permission). Store truth: `pending_approvals > 0` + a pending
      `"approval"` row.
    * `:awaiting_input` — a pending role `"question"` row (AskUserQuestion —
      the agent asked YOU something).
    * `:plan_ready` — a pending role `"plan"` row (ExitPlanMode — a proposed
      plan awaits approval).
    * `:working` — a turn is running (live overlay `:working`, or persisted
      status `"working"` on a cold mount).
    * `:finished_while_away` — the session settled (persisted status `"active"`
      or `"exited"`) and `last_active_at > last_visited_at`: something happened
      after you last looked. Visiting (`mark_visited/1`) clears it.

  The three needs-you kinds map 1:1 onto the `@needs_you_roles` ask roles
  (charter D31); `:finished_while_away` is the new away axis carried by the
  `last_visited_at` column. A session in none of these states has no strip entry.
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
      last_visited_at: s.last_visited_at,
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
      |> Ecto.Changeset.validate_inclusion(:mode, Session.persistable_modes())
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
  MERGE a metadata patch onto a tool row, matched by its metadata `tool_use_id`
  (charter D45 — the agent-lifecycle merge seam). This is how a Task/Agent
  spawn row grows its lifecycle facts: the CLI emits
  `task_started`/`task_progress`/`task_updated`/`task_notification` frames that
  correlate to the spawn by `tool_use_id`, and each stamps `task_id`,
  `task_status`, and the live `task_progress` line onto the row that spawned it.

  UNLIKE `update_tool_input/3`, this MERGES into the existing metadata rather than
  replacing a key — so the spawn's `{description, prompt, subagent_type}` input is
  never clobbered (calling `update_tool_input/3` here would destroy it). `:noop`
  when no row matches — a lifecycle frame for a spawn we never persisted (e.g. it
  arrived before its assistant frame) must not raise.
  """
  @spec merge_tool_metadata(String.t(), String.t(), map()) ::
          {:ok, Message.t()} | {:error, term()} | :noop
  def merge_tool_metadata(session_id, tool_use_id, patch)
      when is_binary(session_id) and is_binary(tool_use_id) and is_map(patch) do
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
        |> Ecto.Changeset.change(metadata: Map.merge(m.metadata || %{}, patch))
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
  Persist the user's picked reasoning-effort tier (nil = CLI default). The exact
  mirror of `set_model_choice/2` (charter D48): choice is intent — it rides the
  next spawn as `--effort`. There is no observed-effort fact, so nothing else
  writes this column.
  """
  def set_effort_choice(session_id, choice) do
    with %Session{} = session <- get_session(session_id) do
      session
      |> Ecto.Changeset.change(effort_choice: choice, last_active_at: DateTime.utc_now())
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  The most-recently-active session's `effort_choice` — the seed for a NEW chat's
  effort picker, so "high" stays sticky across new chats. The exact mirror of
  `recent_model_choice/0`, and a DEDICATED query for the SAME reason: `list_sessions`
  selects sidebar fields and OMITS `effort_choice`, so seeding off a listed row
  reads `nil` forever (the vacuous-green trap). Returns the tier string or `nil`.
  """
  @spec recent_effort_choice() :: String.t() | nil
  def recent_effort_choice do
    Session
    |> where([s], not is_nil(s.effort_choice) and s.effort_choice != "default")
    |> order_by([s], desc: s.last_active_at, desc: s.inserted_at)
    |> limit(1)
    |> select([s], s.effort_choice)
    |> Repo.one()
  end

  @doc """
  True when this session's PERSISTED mode is `bypassPermissions` — the ONLY
  signal that the dangerous `--allow-dangerously-skip-permissions` flag may ride
  its spawn (charter D48). Derived from the stored row, NEVER a live event param:
  bypass reaches the mode column solely through the armed ceremony
  (`ClaudeChat.normalize_mode` fails every untrusted string closed to plan), so a
  persisted `bypassPermissions` is itself the proof of arming. Fail-closed on a
  missing row.
  """
  @spec bypass_armed?(String.t() | nil) :: boolean()
  def bypass_armed?(session_id) do
    match?(%Session{mode: "bypassPermissions"}, get_session(session_id))
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

  # ---------------------------------------------------------------------------
  # agents rail (charter D47 — the mission-control snapshot below the composer)
  # ---------------------------------------------------------------------------

  @doc """
  Persist the agents-rail snapshot (charter D47) — the task_id-keyed map the
  Recorder maintains as background Workflow agents run. SET in place (the whole
  jsonb column), so a reopened session replays its last-known rail. Deliberately
  does NOT bump `last_active_at`: rail churn is background telemetry and must not
  reorder the sidebar (mirrors `set_draft/2`). Returns `{:ok, session}` or
  `{:error, :not_found}`.
  """
  @spec set_rail_snapshot(String.t(), map()) ::
          {:ok, Session.t()} | {:error, :not_found}
  def set_rail_snapshot(session_id, rail) when is_binary(session_id) and is_map(rail) do
    with %Session{} = session <- get_session(session_id) do
      session
      |> Ecto.Changeset.change(rail_snapshot: rail)
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  The token/usage-stripped STRUCTURAL fingerprint of a rail snapshot (charter
  D47) — the ONE shared change-only signature both the Recorder (persist-or-skip)
  and ChatLive (re-render-or-skip) compute, so they never diverge. A structural
  or state change (a row added/removed, a status flip, a phase/agent title,
  model, or state change) yields a different term; a token-only progress tick —
  same tree structure, only `tokens`/`usage` advanced — yields the SAME term, so
  the hot heartbeat becomes render-on-change (D46 value-equality + wave-5
  change-only precedents).
  """
  @spec rail_signature(map()) :: term()
  def rail_signature(rail) when is_map(rail) do
    rail
    |> Enum.map(fn {tid, entry} -> {tid, rail_entry_signature(entry)} end)
    |> Enum.sort()
  end

  def rail_signature(_), do: []

  defp rail_entry_signature(entry) when is_map(entry) do
    %{
      "row" => entry["row"],
      "status" => entry["status"],
      "tree" => strip_workflow(entry["workflow"])
    }
  end

  defp rail_entry_signature(_), do: %{}

  # Keep only the STRUCTURE of a workflow tree — the phase titles, agent labels,
  # phase grouping, models, and states — and drop the token/usage churn that
  # ticks every frame. `phaseIndex` rides the signature (charter D57) so the
  # newly-rendered phase-journey grouping re-signs on a regrouping while a token
  # tick still does not; a phase flip re-renders, a token tick never does.
  defp strip_workflow(nodes) when is_list(nodes), do: Enum.map(nodes, &strip_workflow_node/1)
  defp strip_workflow(_), do: nil

  defp strip_workflow_node(node) when is_map(node),
    do: Map.take(node, ["type", "title", "label", "phaseIndex", "model", "state"])

  defp strip_workflow_node(other), do: other

  @rail_cap 20

  @doc """
  Fold a `background_tasks_changed` SNAPSHOT into the rail (charter D47). The
  frame is a task_id-keyed list with NO tool_use_id: (a) upsert a live "running"
  row for every listed task, STAMPED `"origin" => "background"`; (b) any
  BACKGROUND-origin task_id that VANISHED from the snapshot flips to
  `"completed"` UNLESS already terminal (a `"interrupted"` is never resurrected).
  Entries are NEVER deleted (replay shows the last-known rail), only capped.

  PROVENANCE GATE (charter D62, corrected against the committed fixtures): a
  local_workflow task DOES ride a `background_tasks_changed` snapshot — the
  committed `workflow_progress.ndjson` (and `epic_cycle_*.ndjson`) opens with a
  bg-add listing the workflow task, so workflow entries ARE background-origin and
  their "completed" arrives redundantly (the vanish→completed flip ∪ task_updated
  ∪ task_notification all agree). The true law is narrower: the vanish→completed
  flip fires ONLY for an entry that WAS seen in a bg snapshot (`origin =>
  "background"`) and is now absent — an entry NEVER listed in any bg snapshot can
  never be vanish-completed by an unrelated snapshot. (Watch item, not built
  speculatively: no real capture shows a workflow blinking OUT mid-run; if one
  ever does, gate the flip on "no non-terminal workflow agents".) PURE — the
  Recorder and ChatLive fold identically off this ONE function (D47 shared-fold
  law).
  """
  @spec rail_apply_background(map(), map()) :: map()
  def rail_apply_background(rail, ev) when is_map(rail) and is_map(ev) do
    tasks = if is_list(ev["tasks"]), do: ev["tasks"], else: []
    live_ids = tasks |> Enum.map(& &1["task_id"]) |> Enum.filter(&is_binary/1) |> MapSet.new()

    rail =
      Enum.reduce(tasks, rail, fn task, rail ->
        case task["task_id"] do
          tid when is_binary(tid) ->
            entry =
              rail
              |> rail_entry(tid)
              |> Map.put("row", %{
                "task_type" => task["task_type"],
                "description" => task["description"]
              })
              |> Map.put("origin", "background")
              |> Map.put("status", "running")

            Map.put(rail, tid, entry)

          _ ->
            rail
        end
      end)

    rail
    |> Map.new(fn {tid, entry} ->
      if rail_background_origin?(entry) and not MapSet.member?(live_ids, tid) and
           not rail_terminal?(entry),
         do: {tid, Map.put(entry, "status", "completed")},
         else: {tid, entry}
    end)
    |> cap_rail()
  end

  def rail_apply_background(rail, _ev), do: rail

  # A rail entry only earns the vanish→completed flip when a
  # `background_tasks_changed` snapshot is its provenance — workflow and
  # foreground entries never ride that frame, so their absence is not a signal.
  defp rail_background_origin?(%{"origin" => "background"}), do: true
  defp rail_background_origin?(_), do: false

  @doc """
  Capture a `task_progress` frame's `workflow_progress` phase→agent tree and
  last-known usage into the task_id-keyed rail entry (charter D47). Only touches
  the rail when the frame carries a workflow tree or the task already has an
  entry — a bare heartbeat for an unknown task adds no noise. PURE.
  """
  @spec rail_capture_progress(map(), map()) :: map()
  def rail_capture_progress(rail, ev) when is_map(rail) and is_map(ev) do
    tid = ev["task_id"]
    wf = ev["workflow_progress"]

    cond do
      not is_binary(tid) ->
        rail

      not is_list(wf) and not Map.has_key?(rail, tid) ->
        rail

      true ->
        entry =
          rail
          |> rail_entry(tid)
          |> rail_put_workflow(wf)
          |> rail_put_usage(ev["usage"])

        rail |> Map.put(tid, entry) |> cap_rail()
    end
  end

  def rail_capture_progress(rail, _ev), do: rail

  @doc """
  Stamp a terminal/transition status onto a rail entry — but ONLY when the
  task_id already has one (charter D47). A lifecycle frame for a task the rail
  never listed leaves the map untouched. PURE.
  """
  @spec rail_stamp_status(map(), any(), any()) :: map()
  def rail_stamp_status(rail, tid, status)
      when is_map(rail) and is_binary(tid) and is_binary(status) do
    case Map.get(rail, tid) do
      entry when is_map(entry) -> Map.put(rail, tid, Map.put(entry, "status", status))
      _ -> rail
    end
  end

  def rail_stamp_status(rail, _tid, _status), do: rail

  # Existing entry, or a fresh one seeded "running" with the next insertion seq
  # (the cap prunes oldest-terminal by seq).
  defp rail_entry(rail, tid) do
    case Map.get(rail, tid) do
      entry when is_map(entry) -> entry
      _ -> %{"status" => "running", "seq" => next_rail_seq(rail)}
    end
  end

  defp rail_put_workflow(entry, wf) when is_list(wf), do: Map.put(entry, "workflow", wf)
  defp rail_put_workflow(entry, _), do: entry

  defp rail_put_usage(entry, usage) when is_map(usage), do: Map.put(entry, "usage", usage)
  defp rail_put_usage(entry, _), do: entry

  @doc "True when a rail entry has reached a terminal status (charter D47)."
  @spec rail_terminal?(any()) :: boolean()
  def rail_terminal?(%{"status" => s}), do: s in ["completed", "interrupted"]
  def rail_terminal?(_), do: false

  @doc "A rail entry's insertion seq (0 when absent) — the cap/order key."
  @spec rail_seq(any()) :: integer()
  def rail_seq(entry) when is_map(entry), do: entry["seq"] || 0
  def rail_seq(_), do: 0

  defp next_rail_seq(rail) do
    rail
    |> Map.values()
    |> Enum.reduce(0, fn e, acc -> max(acc, rail_seq(e)) end)
    |> Kernel.+(1)
  end

  # Cap the rail at @rail_cap entries (bloat guard, charter D47), pruning the
  # OLDEST TERMINAL entries first (lowest seq) — a still-running agent is never
  # dropped from the mission-control view.
  defp cap_rail(rail) when map_size(rail) <= @rail_cap, do: rail

  defp cap_rail(rail) do
    drop_ids =
      rail
      |> Enum.filter(fn {_id, e} -> rail_terminal?(e) end)
      |> Enum.sort_by(fn {_id, e} -> rail_seq(e) end)
      |> Enum.take(map_size(rail) - @rail_cap)
      |> Enum.map(&elem(&1, 0))

    Map.drop(rail, drop_ids)
  end

  # ── Wave-11 phase-journey derivation (charter D57–D59) ──────────────────────
  #
  # The agents rail renders an epic-cycle run as a PHASE JOURNEY (mission
  # control), not a flat node list. Every bit of that structure is derived at
  # RENDER time from the same stored flat `workflow` node list + entry `status`
  # the Recorder already persists — `recorder.ex` is untouched and old
  # `rail_snapshot` rows replay for free (charter D57). These are pure public
  # helpers so fixture-fed unit tests drive them directly, and ChatLive's markup
  # (S2) consumes them without duplicating the truth logic.

  # The one owner of the workflow-agent terminal-state SUPERSET (charter D58).
  # `done`/`completed` are SUCCESS terminals; `failed`/`error`/`canceled`/
  # `cancelled`/`aborted` are FAILURE terminals — an `error` node (real: 304
  # nodes across 507 runs, even inside completed workflows) renders ✕ and is
  # NEVER counted as done. `start`/`progress` are the live (breathing) states;
  # a nil/absent state is treated as live (it has not settled).
  @workflow_node_terminal ~w(done completed failed error canceled cancelled aborted)
  @workflow_node_failed ~w(failed error canceled cancelled aborted)

  @doc """
  True when a workflow-agent node (or a bare state string) has reached a terminal
  state (charter D58). The ONE owner of the terminal superset — ChatLive's rail
  render and the journey folds below both consult it, so the "which states
  breathe" truth lives in a single place. Case-insensitive.
  """
  @spec workflow_node_terminal?(any()) :: boolean()
  def workflow_node_terminal?(%{"state" => s}), do: workflow_node_terminal?(s)

  def workflow_node_terminal?(s) when is_binary(s),
    do: String.downcase(s) in @workflow_node_terminal

  def workflow_node_terminal?(_), do: false

  @doc """
  True when a workflow-agent node (or a bare state string) reached a FAILURE
  terminal (✕) — terminal but never a success (charter D58). Public alongside
  `workflow_node_terminal?/1` so the rail's per-agent glyphs and the journey
  counts read the SAME failure set — one owner, no drift.
  """
  @spec workflow_node_failed?(any()) :: boolean()
  def workflow_node_failed?(%{"state" => s}), do: workflow_node_failed?(s)

  def workflow_node_failed?(s) when is_binary(s),
    do: String.downcase(s) in @workflow_node_failed

  def workflow_node_failed?(_), do: false

  @doc """
  Derive the phase JOURNEY of a rail entry (charter D57–D59) — pure, render-time.

  Input is a rail entry: `%{"workflow" => flat_node_list, "status" => ...}` (the
  exact shape the Recorder persists). Returns
  `%{phases: [phase, …], summary: map}` — the wave-11 PINNED contract:

      phase   = %{index, title, status, agents, running, done, failed, total,
                  tokens, model}
      summary = %{phase_total, phases_run, skipped, active: %{index, title} | nil,
                  agents_total, running, done, failed, tokens, entry_status}

  (`model` and `entry_status` are additive extras.) `status` is one of the
  four-state truth table (D58):

    * `:done`       — has agents, all terminal, and it is behind the frontier (a
                      later phase has agents) or the whole cycle completed.
    * `:active`     — the highest-index phase WITH agents while the entry lives
                      (the one that breathes).
    * `:interrupted`— the frontier phase (highest WITH agents) of a dead entry
                      ("died in Explore").
    * `:future`     — an agentless phase while the entry still runs.
    * `:skipped`    — an agentless phase on a COMPLETED entry (Perfect is
                      conditional — an honest cycle reads "6 of 7 phases ·
                      1 skipped", never a fake 7/7).
    * `:unreached`  — an agentless phase on an INTERRUPTED entry.

  Phases are strictly sequential (proven ~15ms handoffs; parallelism is
  intra-phase only), so exactly one phase is `:active`/`:interrupted` at a time.
  Tokens are settle-on-state numbers, never live counters (charter D57): every
  aggregate is summed from the persisted node payloads.
  """
  @spec workflow_journey(map()) :: %{phases: list(map()), summary: map()}
  def workflow_journey(entry) when is_map(entry) do
    nodes = List.wrap(entry["workflow"])
    kind = entry_lifecycle(entry["status"])

    phase_nodes =
      nodes
      |> Enum.filter(&(&1["type"] == "workflow_phase"))
      |> Enum.sort_by(&phase_index/1)

    agents_by_phase =
      nodes
      |> Enum.filter(&(&1["type"] == "workflow_agent"))
      |> Enum.group_by(& &1["phaseIndex"])

    # the frontier = highest phase index that actually has agents (nil if none)
    frontier =
      phase_nodes
      |> Enum.filter(fn p -> Map.get(agents_by_phase, phase_index(p), []) != [] end)
      |> Enum.map(&phase_index/1)
      |> case do
        [] -> nil
        idxs -> Enum.max(idxs)
      end

    phases =
      Enum.map(phase_nodes, fn p ->
        idx = phase_index(p)
        agents = Map.get(agents_by_phase, idx, [])

        %{
          index: idx,
          title: p["title"],
          status: phase_status(agents, idx, frontier, kind),
          agents: agents,
          running: Enum.count(agents, &(not workflow_node_terminal?(&1))),
          done:
            Enum.count(agents, &(workflow_node_terminal?(&1) and not workflow_node_failed?(&1))),
          failed: Enum.count(agents, &workflow_node_failed?/1),
          total: length(agents),
          tokens: sum_node_tokens(agents),
          model: phase_model(agents)
        }
      end)

    %{phases: phases, summary: journey_summary(phases, kind)}
  end

  def workflow_journey(_), do: %{phases: [], summary: empty_journey_summary()}

  # Entry lifecycle from the rail-entry status: "interrupted" is its own dead
  # frontier; any other terminal (completed/done/…) means the cycle finished;
  # everything else (running) is live.
  defp entry_lifecycle("interrupted"), do: :interrupted

  defp entry_lifecycle(s) when is_binary(s) do
    if String.downcase(s) in @workflow_node_terminal, do: :completed, else: :live
  end

  defp entry_lifecycle(_), do: :live

  defp phase_index(%{"index" => i}) when is_integer(i), do: i
  defp phase_index(_), do: 0

  # An agentless phase reads the entry's fate; a phase with agents reads the
  # frontier + lifecycle (D58 four-state truth table).
  defp phase_status([], _idx, _frontier, :live), do: :future
  defp phase_status([], _idx, _frontier, :interrupted), do: :unreached
  defp phase_status([], _idx, _frontier, :completed), do: :skipped

  defp phase_status(_agents, idx, frontier, :interrupted) when idx == frontier, do: :interrupted
  defp phase_status(_agents, _idx, _frontier, :interrupted), do: :done
  defp phase_status(_agents, idx, frontier, :live) when idx == frontier, do: :active
  defp phase_status(_agents, _idx, _frontier, :live), do: :done
  defp phase_status(_agents, _idx, _frontier, :completed), do: :done

  # A phase's model family (charter D57 — per-phase model derives from its
  # agents). The first agent's family; nil when the phase has no agents.
  defp phase_model([agent | _]), do: model_family(agent["model"])
  defp phase_model(_), do: nil

  defp sum_node_tokens(agents) do
    Enum.reduce(agents, 0, fn a, acc ->
      case a["tokens"] do
        n when is_integer(n) -> acc + n
        _ -> acc
      end
    end)
  end

  # The entry-row aggregates (D57) — every number here settles on a state flip;
  # none is a live counter. `active` is the active/interrupted phase (the m in
  # "m/n"); nil on a completed cycle, which collapses to "k of n phases" instead.
  # Key names are the wave-11 PINNED contract (charter) — S2's markup consumes
  # them verbatim; renaming any of them breaks the render.
  defp journey_summary(phases, kind) do
    all_agents = Enum.flat_map(phases, & &1.agents)

    current =
      Enum.find(phases, fn p -> p.status in [:active, :interrupted] end)

    %{
      entry_status: kind,
      phase_total: length(phases),
      phases_run: Enum.count(phases, &(&1.status == :done)),
      skipped: Enum.count(phases, &(&1.status == :skipped)),
      active: current && %{index: current.index, title: current.title},
      agents_total: length(all_agents),
      running: Enum.count(all_agents, &(not workflow_node_terminal?(&1))),
      done:
        Enum.count(all_agents, &(workflow_node_terminal?(&1) and not workflow_node_failed?(&1))),
      failed: Enum.count(all_agents, &workflow_node_failed?/1),
      tokens: sum_node_tokens(all_agents)
    }
  end

  defp empty_journey_summary do
    %{
      entry_status: :live,
      phase_total: 0,
      phases_run: 0,
      skipped: 0,
      active: nil,
      agents_total: 0,
      running: 0,
      done: 0,
      failed: 0,
      tokens: 0
    }
  end

  @doc """
  Split a workflow-agent label into its two rendered parts (charter D59) — a
  GENERIC grammar, never epic-cycle-hardcoded. Split at the FIRST colon iff the
  head is a short slug (`[a-z0-9_-]{1,16}`): `"design:encryption"` →
  `{:pair, "design", "encryption"}`, `"verify:encryption:leak"` →
  `{:pair, "verify", "encryption:leak"}` (the rest keeps its colons). A bare
  role (`"strategist"`) or a head that is not a slug (a raw-prompt fallback) →
  `{:bare, label}` — render raw, CSS-truncate, never invent.
  """
  @spec workflow_label_parts(any()) ::
          {:pair, String.t(), String.t()} | {:bare, String.t()}
  def workflow_label_parts(label) when is_binary(label) do
    case String.split(label, ":", parts: 2) do
      [kind, rest] ->
        if kind =~ ~r/\A[a-z0-9_-]{1,16}\z/, do: {:pair, kind, rest}, else: {:bare, label}

      _ ->
        {:bare, label}
    end
  end

  def workflow_label_parts(other), do: {:bare, to_string(other)}

  @doc """
  Map a model WIRE id to its family name (charter D59). Rail nodes carry raw wire
  ids like `"claude-opus-4-8[1m]"` (which the picker-oriented `model_label/1`
  falls through verbatim — the trap this closes). Prefix map:
  `claude-fable-*` → "Fable", `claude-opus-*` → "Opus", `claude-sonnet-*` →
  "Sonnet", `claude-haiku-*` → "Haiku"; the short picker slugs (fable/opus/
  sonnet/haiku) still resolve; anything unknown returns raw.
  """
  @spec model_family(any()) :: String.t() | nil
  def model_family(nil), do: nil

  def model_family(id) when is_binary(id) do
    down = String.downcase(id)

    cond do
      String.starts_with?(down, "claude-fable") or down == "fable" -> "Fable"
      String.starts_with?(down, "claude-opus") or down == "opus" -> "Opus"
      String.starts_with?(down, "claude-sonnet") or down == "sonnet" -> "Sonnet"
      String.starts_with?(down, "claude-haiku") or down == "haiku" -> "Haiku"
      true -> id
    end
  end

  def model_family(other), do: other

  @doc """
  Abbreviate a token count for the rail (charter D59): `< 1_000` raw ("845");
  `< 10_000` one decimal k ("9.6k"); `< 1_000_000` integer k ("145k"); else one
  decimal M ("1.2M"). Non-integers render "—" (an honest unknown, never a fake 0).
  """
  @spec format_tokens(any()) :: String.t()
  def format_tokens(n) when is_integer(n) and n < 0, do: "—"
  def format_tokens(n) when is_integer(n) and n < 1_000, do: Integer.to_string(n)

  def format_tokens(n) when is_integer(n) and n < 10_000 do
    "#{Float.round(n / 1_000, 1)}k"
  end

  def format_tokens(n) when is_integer(n) and n < 1_000_000 do
    "#{round(n / 1_000)}k"
  end

  def format_tokens(n) when is_integer(n) do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  def format_tokens(_), do: "—"

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

  @doc """
  Force every still-`running` agent task for a session to `interrupted` (charter
  D45/D47) — the death-path teardown flip. When the subprocess exits (crash, idle
  reap, clean exit), an in-flight sub-agent can never report its result, so its
  spawn row must NOT keep claiming "running" forever on reopen. Flips each
  transcript row's `metadata.task_status` from `"running"` to `"interrupted"`
  AND, in the SAME transaction (charter D47), flips every `"running"` entry of
  the session's `rail_snapshot` to `"interrupted"` — a reopened mid-run session
  shows the honest last-known rail, never a fake live spinner. Every OTHER key
  (task_id, the last progress line, the spawn's input, the rail's workflow tree /
  usage) is preserved. Mirrors `cancel_pending_approvals/1`. Returns the number
  of transcript rows interrupted (the rail flip rides along, uncounted).
  """
  @spec interrupt_running_tasks(String.t()) :: non_neg_integer()
  def interrupt_running_tasks(session_id) do
    Repo.transaction(fn ->
      running =
        Message
        |> where([m], m.session_id == ^session_id)
        |> where([m], fragment("?->>'task_status' = 'running'", m.metadata))
        |> Repo.all()

      Enum.each(running, fn message ->
        meta = Map.put(message.metadata || %{}, "task_status", "interrupted")
        message |> Ecto.Changeset.change(metadata: meta) |> Repo.update!()
      end)

      interrupt_rail_entries(session_id)

      length(running)
    end)
    |> case do
      {:ok, count} -> count
      _ -> 0
    end
  end

  # Flip every still-"running" rail entry to "interrupted" (charter D47). Runs
  # inside interrupt_running_tasks/1's transaction — a single update_all writes
  # the mutated jsonb map back, and only when something actually changed.
  defp interrupt_rail_entries(session_id) do
    case get_session(session_id) do
      %Session{rail_snapshot: rail} when is_map(rail) and map_size(rail) > 0 ->
        flipped =
          Map.new(rail, fn
            {tid, %{"status" => "running"} = entry} ->
              {tid, Map.put(entry, "status", "interrupted")}

            {tid, entry} ->
              {tid, entry}
          end)

        if flipped != rail do
          Session
          |> where([s], s.id == ^session_id)
          |> Repo.update_all(set: [rail_snapshot: flipped, updated_at: DateTime.utc_now()])
        end

      _ ->
        :ok
    end
  end

  @doc """
  Merge a patch into a needs-you row's metadata, keyed by `request_id` (charter
  D49 — the plan-paper stamp seam). Reuses `find_approval/2` (already inclusive
  of the `"plan"` role) + `Map.merge` + `Repo.update`, so the row's existing
  metadata (request_id, tool_name, input, approval_status, …) is preserved and
  only the patched keys are added/overwritten.

  Exists because neither prior seam fits a plan row: `merge_tool_metadata/3`
  keys on `tool_use_id` (which plan rows lack), and `update_approval_status/3`
  writes only `approval_status` (and rejects non-terminal writes). `:noop` when
  no row matches — a stamp for a request_id we never persisted must not raise.
  """
  @spec merge_approval_metadata(String.t(), String.t(), map()) ::
          {:ok, Message.t()} | {:error, term()} | :noop
  def merge_approval_metadata(session_id, request_id, patch)
      when is_binary(session_id) and is_binary(request_id) and is_map(patch) do
    case find_approval(session_id, request_id) do
      nil ->
        :noop

      %Message{} = m ->
        m
        |> Ecto.Changeset.change(metadata: Map.merge(m.metadata || %{}, patch))
        |> Repo.update()
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
  # the needs-you strip (wave 12 — sidebar inbox; kinds documented in @moduledoc)
  # ---------------------------------------------------------------------------

  # Strip kinds in STRICT priority order (the moduledoc vocabulary). The order
  # IS the sort: an approval outranks a question outranks a plan outranks a
  # running turn outranks an unseen finish.
  @strip_kinds [:pending_approval, :awaiting_input, :plan_ready, :working, :finished_while_away]

  # Ask role → strip kind (charter D31 roles). Precedence inside one session
  # with SEVERAL pending asks follows @strip_kinds: approval > question > plan.
  @role_strip_kinds [
    {"approval", :pending_approval},
    {"question", :awaiting_input},
    {"plan", :plan_ready}
  ]

  # The persisted statuses that mean "nothing is running": `active` (turn
  # settled — the Recorder flips it on every result frame) and `exited` (the
  # process died). `working` deliberately is NOT here — a mid-turn session is
  # `:working`, never `:finished_while_away`.
  @settled_statuses ~w(active exited)

  @doc """
  The strip-kind vocabulary in strict priority order (wave 12; see the
  moduledoc). S7's notification seam consumes these EXACT atoms.
  """
  @spec strip_kinds() :: [atom()]
  def strip_kinds, do: @strip_kinds

  @doc """
  Stamp `last_visited_at = now` — the admin just looked at this session (opened
  it, switched away from it, or watched it settle on screen). Clears the session
  from the needs-you strip's `:finished_while_away` state. Deliberately does NOT
  bump `last_active_at` (visiting must not reorder the sidebar — the `set_draft/2`
  precedent). Returns `{:ok, session}` or `{:error, :not_found}`.
  """
  @spec mark_visited(String.t() | nil) :: {:ok, Session.t()} | {:error, :not_found}
  def mark_visited(session_id) do
    with %Session{} = session <- get_session(session_id) do
      session
      |> Ecto.Changeset.change(last_visited_at: DateTime.utc_now())
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  The PENDING ask roles per session, for a list of session ids — the store-truth
  ingredient the strip's needs-you kinds derive from on a COLD mount (the
  denormalised `pending_approvals` counter says *that* the agent needs you; the
  pending rows' roles say *how*). One grouped query:
  `%{session_id => ["approval" | "question" | "plan", …]}`; a session with no
  pending ask simply has no key.
  """
  @spec pending_ask_roles([String.t()]) :: %{String.t() => [String.t()]}
  def pending_ask_roles([]), do: %{}

  def pending_ask_roles(session_ids) when is_list(session_ids) do
    Message
    |> where([m], m.session_id in ^session_ids and m.role in ^@needs_you_roles)
    |> where([m], fragment("?->>'approval_status' = 'pending'", m.metadata))
    |> select([m], {m.session_id, m.role})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Derive the needs-you strip (wave 12) — PURE cross-session aggregation over the
  already-loaded sidebar rows. Returns entries
  `%{session: %Session{}, kind: strip_kind, line: String.t() | nil}` sorted by
  kind priority (`strip_kinds/0` order), then recency (most recently active
  first) within a kind.

  Options:

    * `:current_session_id` — the ON-SCREEN session, excluded ("away" = not the
      session you are looking at; there is no presence system).
    * `:pending_roles` — `pending_ask_roles/1`'s map (store truth for the
      needs-you kinds; cold-mount correct).
    * `:activity` — the transient `studio_chat:activity` overlay
      (`%{session_id => %{state: atom, line: String.t() | nil}}`). Live
      freshness ONLY — with an empty overlay (a cold mount) the derivation is
      still correct from persisted rows alone.
  """
  @spec needs_you_strip([Session.t()], keyword()) ::
          [%{session: Session.t(), kind: atom(), line: String.t() | nil}]
  def needs_you_strip(sessions, opts \\ []) when is_list(sessions) do
    current = Keyword.get(opts, :current_session_id)
    pending_roles = Keyword.get(opts, :pending_roles, %{})
    activity = Keyword.get(opts, :activity, %{})

    sessions
    |> Enum.reject(&(&1.id == current))
    |> Enum.flat_map(fn s ->
      act = Map.get(activity, s.id)

      case strip_kind(s, Map.get(pending_roles, s.id, []), act) do
        nil -> []
        kind -> [%{session: s, kind: kind, line: activity_line(act)}]
      end
    end)
    |> Enum.sort_by(fn %{kind: kind, session: s} ->
      {Enum.find_index(@strip_kinds, &(&1 == kind)), -recency_key(s)}
    end)
  end

  @doc """
  One session's strip kind (wave 12) — or nil (no entry). PURE; the per-session
  half of `needs_you_strip/2`, public so the derivation is unit-testable kind by
  kind. Precedence: a pending ask (any needs-you role) beats a running turn
  beats an unseen finish.

  `pending_roles` is this session's pending ask roles (`pending_ask_roles/1`);
  `activity` is its live overlay entry or nil. The overlay only ADDS liveness
  (`:working`/`:needs_you` between store writes) — the persisted row alone
  yields the same kinds on a cold mount.
  """
  @spec strip_kind(Session.t(), [String.t()], map() | nil) :: atom() | nil
  def strip_kind(session, pending_roles, activity) do
    pending = is_integer(session.pending_approvals) and session.pending_approvals > 0

    cond do
      pending or activity_state(activity) == :needs_you ->
        needs_you_kind(pending_roles)

      activity_state(activity) == :working or session.status == "working" ->
        :working

      finished_while_away?(session) ->
        :finished_while_away

      true ->
        nil
    end
  end

  @doc """
  True when a session settled AFTER the admin last looked (wave 12): persisted
  status is a settled one (`active` — the Recorder flips it on every result
  frame — or `exited`) AND `last_active_at > last_visited_at`. STRICT
  comparison + a nil `last_visited_at` reads false: a freshly-created row
  (stamped visited at birth) and a pre-migration row (never stamped) both stay
  honestly quiet — the strip never fakes an unseen finish.
  """
  @spec finished_while_away?(Session.t()) :: boolean()
  def finished_while_away?(%Session{
        status: status,
        last_active_at: %DateTime{} = active,
        last_visited_at: %DateTime{} = visited
      })
      when status in @settled_statuses,
      do: DateTime.compare(active, visited) == :gt

  def finished_while_away?(_), do: false

  # Highest-priority kind among this session's pending ask roles. A needs-you
  # signal with NO known pending row (an overlay :needs_you racing the store
  # read) degrades to the generic :pending_approval — never dropped.
  defp needs_you_kind(roles) do
    Enum.find_value(@role_strip_kinds, :pending_approval, fn {role, kind} ->
      role in roles && kind
    end)
  end

  defp activity_state(%{state: state}), do: state
  defp activity_state(_), do: nil

  defp activity_line(%{line: line}) when is_binary(line), do: line
  defp activity_line(_), do: nil

  # Recency for the within-kind sort: microseconds of last_active_at (fallback
  # inserted_at; 0 when both are absent — sinks to the bottom of its kind).
  defp recency_key(%Session{last_active_at: %DateTime{} = at}),
    do: DateTime.to_unix(at, :microsecond)

  defp recency_key(%Session{inserted_at: %DateTime{} = at}),
    do: DateTime.to_unix(at, :microsecond)

  defp recency_key(_), do: 0

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
