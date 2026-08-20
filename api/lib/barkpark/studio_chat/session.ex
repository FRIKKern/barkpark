defmodule Barkpark.StudioChat.Session do
  @moduledoc """
  A provider-neutral Studio chat SESSION — the index record for one resumable
  conversation (epic studio-claude-chat, charter D6/D8).

  The primary key is Barkpark's public UUID (`autogenerate: false`). Provider,
  execution location, and opaque provider-native resume identity are durable,
  independent fields. Legacy managed-Claude sessions intentionally reuse the
  public UUID as their provider identity.

  Denormalised fields (`summary`, `message_count`, `input_tokens`,
  `output_tokens`, `total_cost_usd`, `last_active_at`) let the sidebar render
  without touching `chat_messages`. They are bumped in the same transaction that
  appends a message / records metrics — see `Barkpark.StudioChat`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  # active   — reopened / idle, no live process
  # working  — a turn is running in the port
  # exited   — the process died (crash or clean exit); next send lazy-resumes
  @statuses ~w(active working exited)
  @title_sources ~w(default ai human)
  @providers ~w(claude codex)
  @execution_targets ~w(managed registered_host)
  # Permission modes the CLI accepts (mirrors BarkparkWeb.Studio.ClaudeChat.modes/0,
  # kept here so the context layer validates a mode without reaching into web).
  # The two constants move TOGETHER (charter D48). `bypassPermissions` is a legal
  # PERSISTED mode — the store validates inclusion so the armed ceremony can write
  # it — but it is reachable only through that ceremony (ClaudeChat.normalize_mode
  # fails every untrusted string closed to plan). The retired `default` is NOT in
  # this list: an existing row keeps spawning it verbatim, but no NEW switch lands
  # it (a legacy-`default` select re-pick normalizes to plan).
  @modes ~w(plan acceptEdits auto dontAsk manual bypassPermissions)

  # The herd-layer semantic axis (chat-tui charter D38/D40): what the AGENT is
  # doing, persisted by the Recorder at its publish_activity seam. Four states
  # ONLY — `needs_you` maps to `blocked`, `done` deliberately does not exist,
  # and a stall is a VIEW-side badge off `agent_state_at`, never a fifth state.
  @agent_states ~w(working blocked idle unknown)

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @foreign_key_type Ecto.UUID

  schema "chat_sessions" do
    field :title, :string, default: "New chat"
    field :title_source, :string, default: "default"

    # The workspace that OWNS this session (Connectors epic wave 1, charter
    # D14/D15). Nullable, no FK: a pre-migration / admin-`:global` session reads
    # NULL and is invisible to any workspace-scoped caller (a NULL never matches
    # an `owner_workspace_id == ^ws` equality — fail-closed by construction).
    # Stamped by `StudioChat.create_session/2` from the caller's scope; the
    # `:global` superuser path stamps NULL. See `Barkpark.StudioChat` store seal.
    field :owner_workspace_id, Ecto.UUID

    # Provider identity and execution location are independent, durable axes.
    # They are create-only: no update changeset casts them. `provider_session_id`
    # is the opaque native resume/thread id and is set once by the runtime seam.
    field :provider, :string, default: "claude"
    field :execution_target, :string, default: "managed"
    field :execution_host_id, Ecto.UUID
    field :provider_session_id, :string

    # The session-scoped Cloud sandbox binding (Connectors wave 14, charter
    # D136/D137/D139). The opaque id of the Vercel Sandbox the :cloud execution
    # profile keeps alive across turns — the durable memory that lets a one-shot
    # sandboxed turn RESUME the same box (interactive stdin stays impossible, so
    # continuity rides the SESSION, not a held subprocess). Unlike write-once
    # `provider_session_id`, it legitimately resets on sandbox expiry (D139): set,
    # overwritten, and cleared through `StudioChat.set_cloud_sandbox_id/2`. NULL
    # on every self-hosted / pre-migration row. NEVER a transcript blob (D136).
    field :cloud_sandbox_id, :string

    field :cwd, :string
    field :mode, :string
    field :model, :string
    field :model_choice, :string
    # The USER'S picked reasoning-effort tier (low/medium/high/xhigh/max), nil =
    # CLI default. Intent-only (charter D48), the exact mirror of `model_choice`:
    # rides the next spawn as `--effort`, seeded sticky across new chats.
    field :effort_choice, :string
    # Sticky composer draft (charter D36c): the unsent words left behind when the
    # user switched away from this session. Nullable; restored on reopen (via the
    # FULL struct — `list_sessions` deliberately omits it), cleared on send.
    field :draft, :string
    field :status, :string, default: "active"

    # The persisted herd state (chat-tui charter D38–D42h): the Recorder's
    # wave-5 activity derivation as cold truth — `working | blocked | idle |
    # unknown`. Written flips-only via `StudioChat.set_agent_state/3` (its own
    # `Repo.update_all`, never inside `append_message`'s transaction); the
    # sidebar pill, the needs-you strip, and the fleet wire all read THIS
    # column so every surface agrees by construction. `agent_state_at` is the
    # liveness stamp: bumped on every flip and at most every 60s while
    # working/blocked (D41h) — `AgentStateSweeper` flips a stale working/
    # blocked row to `unknown` (D42h). Nullable stamp: a pre-migration row has
    # no heartbeat and reads NULL.
    field :agent_state, :string, default: "idle"
    field :agent_state_at, :utc_datetime_usec

    field :last_active_at, :utc_datetime_usec

    # NOTE: the DB still carries the wave-12 visited-stamp column (read
    # tracking, retired by the herd layer — no read receipts). It is deliberately
    # UNMAPPED here so the old slot keeps working under blue/green; the column
    # drop is the follow-up migration (herd-bl-lastvisited-drop).

    # Archive shelf (wave 2): nil = active side of the sidebar, a timestamp =
    # archived. Orthogonal to `status` (liveness) BY DESIGN — see the migration.
    field :archived_at, :utc_datetime_usec

    field :summary, :string
    field :message_count, :integer, default: 0
    # Denormalised count of approvals still awaiting a decision — the sidebar
    # reads it to raise a "needs you" pill (charter D14, slice scc-w2-approvals).
    # Bumped +1 on ask, −1 on resolve, zeroed on cancel-all. Never < 0.
    field :pending_approvals, :integer, default: 0
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :total_cost_usd, :float, default: 0.0

    # Provider-observed runtime facts. Unlike the legacy Claude counters above,
    # these stay nullable: no event means unknown, never a fabricated zero.
    # Codex token usage is a cumulative snapshot and is SET idempotently by
    # RuntimeTelemetry rather than incremented by record_result_metrics/2.
    field :observed_model, :string
    field :observed_effort, :string
    field :observed_input_tokens, :integer
    field :observed_cached_input_tokens, :integer
    field :observed_output_tokens, :integer
    field :observed_reasoning_output_tokens, :integer
    field :observed_total_tokens, :integer
    field :observed_context_window, :integer
    field :runtime_identity, :map
    field :runtime_telemetry_limitations, {:array, :string}

    # Per-turn context snapshot (charter D19) — the LATEST result frame's window
    # occupancy, SET (never inc). Nullable: unknown until the first result, and
    # the header ring renders hollow rather than a fake arc when they are nil.
    field :last_context_tokens, :integer
    field :context_window, :integer

    # Agents-rail mission-control snapshot (charter D47), a task_id-keyed map —
    # see the migration for the shape. SET in place by the Recorder as
    # background Workflow agents run; hydrated on reopen so the rail replays its
    # last-known state (a reopened mid-run session shows "interrupted", never a
    # fake spinner — `StudioChat.interrupt_running_tasks/1` flips it on teardown).
    field :rail_snapshot, :map

    has_many :messages, Barkpark.StudioChat.Message,
      foreign_key: :session_id,
      preload_order: [asc: :seq]

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Legal session statuses."
  def statuses, do: @statuses

  @doc "Legal title sources."
  def title_sources, do: @title_sources

  @doc "Supported provider identities."
  def providers, do: @providers

  @doc "Supported execution locations."
  def execution_targets, do: @execution_targets

  @doc "Legal permission modes OFFERED in the picker (mirrors ClaudeChat.modes/0)."
  def modes, do: @modes

  @doc "The four herd agent states (chat-tui charter D40) — never more."
  def agent_states, do: @agent_states

  # Modes that may be PERSISTED — the offered six PLUS the grandfathered `default`.
  # `default` is not an offered choice, but the CLI still reports it as its own
  # post-plan mode (charter D34), so `set_mode/2` must accept it when observed and
  # an existing row that carries it stays valid (charter D48).
  @persistable_modes @modes ++ ["default"]

  @doc "Modes `set_mode/2` may persist — the offered six plus the legacy `default`."
  def persistable_modes, do: @persistable_modes

  @create_fields ~w(
    id owner_workspace_id provider execution_target execution_host_id provider_session_id
    title title_source cwd mode model status last_active_at summary
  )a

  @doc """
  Changeset for creating a session. `id` is REQUIRED — the caller mints the
  public UUID. Defaults supply the legacy managed-Claude identity plus
  title/title_source/status.
  """
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, @create_fields)
    |> put_legacy_identity_defaults()
    |> maybe_default_last_active()
    |> validate_required([:id])
    |> validate_uuid(:id)
    |> validate_uuid(:execution_host_id)
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:execution_target, @execution_targets)
    |> validate_execution_host()
    |> validate_length(:provider_session_id, min: 1)
    |> check_constraint(:provider, name: :chat_sessions_provider_check)
    |> check_constraint(:execution_target, name: :chat_sessions_execution_target_check)
    |> check_constraint(:execution_host_id, name: :chat_sessions_execution_host_check)
    |> check_constraint(:provider_session_id, name: :chat_sessions_provider_session_id_check)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:title_source, @title_sources)
    |> validate_inclusion(:agent_state, @agent_states)
    |> check_constraint(:agent_state, name: :chat_sessions_agent_state_check)
  end

  defp put_legacy_identity_defaults(changeset) do
    changeset =
      changeset
      |> put_default(:provider, "claude")
      |> put_default(:execution_target, "managed")

    case {get_field(changeset, :provider), get_field(changeset, :execution_target),
          get_field(changeset, :provider_session_id), get_field(changeset, :id)} do
      {"claude", "managed", nil, id} when is_binary(id) ->
        put_change(changeset, :provider_session_id, id)

      _ ->
        changeset
    end
  end

  defp put_default(changeset, field, value) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, value),
      else: changeset
  end

  defp validate_execution_host(changeset) do
    case {get_field(changeset, :execution_target), get_field(changeset, :execution_host_id)} do
      {"managed", nil} ->
        changeset

      {"managed", _host_id} ->
        add_error(changeset, :execution_host_id, "must be empty for managed execution")

      {"registered_host", nil} ->
        add_error(changeset, :execution_host_id, "is required for registered-host execution")

      {"registered_host", _host_id} ->
        changeset

      _ ->
        changeset
    end
  end

  defp maybe_default_last_active(changeset) do
    case get_field(changeset, :last_active_at) do
      nil -> put_change(changeset, :last_active_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  defp validate_uuid(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        case Ecto.UUID.cast(value) do
          {:ok, _} -> changeset
          :error -> add_error(changeset, field, "is not a valid UUID")
        end
    end
  end
end
