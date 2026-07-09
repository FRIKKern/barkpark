defmodule Barkpark.StudioChat.Message do
  @moduledoc """
  One remembered message in a Studio Claude chat session (epic
  studio-claude-chat, wave 1). We persist the SOURCE markdown, never rendered
  HTML — the improving paper engine re-renders on read (charter D7). Persisted
  on message COMPLETION, never per streaming delta.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(user assistant tool)

  @foreign_key_type :binary_id
  schema "chat_messages" do
    belongs_to :session, Barkpark.StudioChat.Session, type: :binary_id
    field :seq, :integer
    field :role, :string
    field :source_markdown, :string, default: ""
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:session_id, :seq, :role, :source_markdown, :metadata])
    |> validate_required([:session_id, :seq, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:session_id, :seq], name: :chat_messages_session_id_seq_index)
  end
end
