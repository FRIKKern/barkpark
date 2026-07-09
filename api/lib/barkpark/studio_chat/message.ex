defmodule Barkpark.StudioChat.Message do
  @moduledoc """
  One message in a Studio Claude chat session — our DISPLAY history, not the
  transcript (epic studio-claude-chat, charter D7).

  We persist `source_markdown` ONLY (never HTML) and re-render on read so the
  improving render engine wins. `metadata` (jsonb) carries tool inputs, usage,
  and result-frame fields. `seq` is monotonic per session; the UNIQUE
  [session_id, seq] on the table is the append race guard.

  Rows are written on message COMPLETION, never per streaming delta.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "chat_messages" do
    belongs_to :session, Barkpark.StudioChat.Session, type: Ecto.UUID

    field :seq, :integer
    field :role, :string
    field :source_markdown, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(session_id seq role source_markdown metadata)a

  @doc """
  Changeset for a completed message. `session_id`, `seq`, and `role` are
  required; `source_markdown` may be nil for a purely structural row (e.g. a
  tool-result placeholder) whose content lives in `metadata`.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, @fields)
    |> validate_required([:session_id, :seq, :role])
    |> unique_constraint([:session_id, :seq],
      name: :chat_messages_session_id_seq_index,
      message: "sequence already taken for this session"
    )
    |> foreign_key_constraint(:session_id)
  end
end
