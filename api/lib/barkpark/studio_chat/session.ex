defmodule Barkpark.StudioChat.Session do
  @moduledoc """
  A Studio Claude chat SESSION — the index record for one resumable conversation
  (epic studio-claude-chat, charter D6/D8).

  The primary key is the minted claude session UUID (`autogenerate: false`): we
  generate it before the first byte via `--session-id`, and the SAME value is the
  `--resume` key. One identity, no cursor column.

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

    field :last_active_at, :utc_datetime_usec

    # When the admin LAST LOOKED at this session (wave 12, the needs-you strip).
    # Stamped on open, on switch-away, and when a settle is watched on screen —
    # never bumped by the agent (that is `last_active_at`'s job). The pair is the
    # finished-while-away signal: `last_active_at > last_visited_at` on a settled
    # session means something happened after you last looked. Nullable: a
    # pre-migration row reads "never visited" and the strip stays quiet about it.
    field :last_visited_at, :utc_datetime_usec

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
  Changeset for creating a session. `id` is REQUIRED — the caller mints the UUID
  (it doubles as the --resume key). Defaults supply title/title_source/status.
  """
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, @create_fields)
    |> put_legacy_identity_defaults()
    |> maybe_default_last_active()
    |> maybe_default_last_visited()
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
  end

  defp put_legacy_identity_defaults(changeset) do
    changeset =
      changeset
      |> put_default(:provider, "claude")
      |> put_default(:execution_target, "managed")

    case {get_field(changeset, :provider), get_field(changeset, :provider_session_id),
          get_field(changeset, :id)} do
      {"claude", nil, id} when is_binary(id) -> put_change(changeset, :provider_session_id, id)
      _ -> changeset
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

  # A session is created on the FIRST send — while the user is looking at it —
  # so it starts VISITED (wave 12). Copy the (possibly just-defaulted)
  # `last_active_at` value, never a second `utc_now()`: two separate clock reads
  # would make a freshly-created row read `last_active_at > last_visited_at` by
  # microseconds and fake a finished-while-away signal at birth.
  defp maybe_default_last_visited(changeset) do
    case get_field(changeset, :last_visited_at) do
      nil -> put_change(changeset, :last_visited_at, get_field(changeset, :last_active_at))
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
