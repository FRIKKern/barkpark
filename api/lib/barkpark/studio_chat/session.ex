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

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @foreign_key_type Ecto.UUID

  schema "chat_sessions" do
    field :title, :string, default: "New chat"
    field :title_source, :string, default: "default"

    field :cwd, :string
    field :mode, :string
    field :model, :string
    field :status, :string, default: "active"

    field :last_active_at, :utc_datetime_usec

    field :summary, :string
    field :message_count, :integer, default: 0
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :total_cost_usd, :float, default: 0.0

    # Per-turn context snapshot (charter D19) — the LATEST result frame's window
    # occupancy, SET (never inc). Nullable: unknown until the first result, and
    # the header ring renders hollow rather than a fake arc when they are nil.
    field :last_context_tokens, :integer
    field :context_window, :integer

    has_many :messages, Barkpark.StudioChat.Message,
      foreign_key: :session_id,
      preload_order: [asc: :seq]

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Legal session statuses."
  def statuses, do: @statuses

  @doc "Legal title sources."
  def title_sources, do: @title_sources

  @create_fields ~w(id title title_source cwd mode model status last_active_at summary)a

  @doc """
  Changeset for creating a session. `id` is REQUIRED — the caller mints the UUID
  (it doubles as the --resume key). Defaults supply title/title_source/status.
  """
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, @create_fields)
    |> maybe_default_last_active()
    |> validate_required([:id])
    |> validate_uuid(:id)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:title_source, @title_sources)
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
