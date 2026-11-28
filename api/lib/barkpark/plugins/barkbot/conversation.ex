defmodule Barkpark.Plugins.Barkbot.Conversation do
  @moduledoc """
  Schema for BarkBot conversations.
  
  A conversation is a persistent chat session with:
  - Message history
  - Associated jobs
  - Workspace isolation
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  
  schema "barkbot_conversations" do
    belongs_to :bot, Barkpark.Plugins.Barkbot.Bot, type: :binary_id
    has_many :messages, Barkpark.Plugins.Barkbot.Message
    has_many :jobs, Barkpark.Plugins.Barkbot.Job
    
    field :title, :string
    field :workspace_id, :binary_id
    field :created_by, :string
    field :last_message_at, :utc_datetime_usec
    
    # Claude Code session tracking (for multi-turn context)
    field :claude_session_id, :string
    field :last_activity_at, :utc_datetime_usec
    
    timestamps(type: :utc_datetime_usec)
  end
  
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:bot_id, :title, :workspace_id, :created_by, :last_message_at, :claude_session_id, :last_activity_at])
    |> validate_required([:bot_id, :workspace_id])
    |> foreign_key_constraint(:bot_id)
  end
end

defmodule Barkpark.Plugins.Barkbot.Message do
  @moduledoc """
  Individual message in a conversation.
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  
  @roles ~w(user assistant system)
  
  schema "barkbot_messages" do
    belongs_to :conversation, Barkpark.Plugins.Barkbot.Conversation, type: :binary_id
    belongs_to :job, Barkpark.Plugins.Barkbot.Job, type: :binary_id
    
    field :role, :string  # "user" | "assistant" | "system"
    field :content, :string
    field :tokens, :integer
    
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
  
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:conversation_id, :job_id, :role, :content, :tokens])
    |> validate_required([:conversation_id, :role, :content])
    |> validate_inclusion(:role, @roles)
    |> foreign_key_constraint(:conversation_id)
  end
end
