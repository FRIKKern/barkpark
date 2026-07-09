defmodule Barkpark.StudioChat.Session do
  @moduledoc """
  A remembered Studio Claude chat session (epic studio-claude-chat, wave 1).

  The `:id` is the CLI-minted session UUID — `autogenerate: false` because WE
  mint it (`Ecto.UUID.generate/0`) at the first user send and pin it via
  `--session-id`, so it is the `--resume` key too. No route ever reads this
  table; the LiveView reads `Repo` directly (charter D6).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active working exited)

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "chat_sessions" do
    field :title, :string, default: "New chat"
    field :title_source, :string, default: "default"
    field :cwd, :string
    field :mode, :string, default: "plan"
    field :model, :string
    field :status, :string, default: "active"
    field :last_active_at, :utc_datetime_usec
    field :summary, :string
    field :message_count, :integer, default: 0
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :total_cost_usd, :float, default: 0.0

    has_many :messages, Barkpark.StudioChat.Message,
      foreign_key: :session_id,
      preload_order: [asc: :seq]

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(id title title_source cwd mode model status last_active_at summary
               message_count input_tokens output_tokens total_cost_usd)a

  def changeset(session, attrs) do
    session
    |> cast(attrs, @castable)
    |> validate_required([:id])
    |> validate_inclusion(:status, @statuses)
  end

  @doc "The valid lifecycle statuses (active | working | exited)."
  def statuses, do: @statuses
end
