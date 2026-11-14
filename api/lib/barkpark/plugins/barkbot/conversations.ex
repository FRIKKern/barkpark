defmodule Barkpark.Plugins.Barkbot.Conversations do
  @moduledoc """
  Context for managing BarkBot conversations and messages.
  """
  
  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Plugins.Barkbot.{Conversation, Message}
  
  @doc """
  Create a new conversation.
  """
  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end
  
  @doc """
  Get a conversation by ID with messages preloaded.
  """
  def get_conversation(id) do
    case Repo.get(Conversation, id) |> Repo.preload(:messages) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end
  
  @doc """
  List conversations for a bot.
  """
  def list_conversations(filters \\ %{}) do
    Conversation
    |> apply_filters(filters)
    |> order_by([c], desc: c.last_message_at, desc: c.inserted_at)
    |> limit(50)
    |> Repo.all()
  end
  
  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:bot_id, bot_id}, q when not is_nil(bot_id) ->
        where(q, [c], c.bot_id == ^bot_id)
        
      {:workspace_id, workspace_id}, q when not is_nil(workspace_id) ->
        where(q, [c], c.workspace_id == ^workspace_id)
        
      _, q ->
        q
    end)
  end
  
  @doc """
  Add a message to a conversation.
  """
  def add_message(conversation_id, attrs) do
    attrs = Map.put(attrs, :conversation_id, conversation_id)
    
    message =
      %Message{}
      |> Message.changeset(attrs)
      |> Repo.insert!()
    
    # Update conversation's last_message_at
    from(c in Conversation, where: c.id == ^conversation_id)
    |> Repo.update_all(set: [last_message_at: DateTime.utc_now()])
    
    {:ok, message}
  end
  
  @doc """
  Get messages for a conversation.
  """
  def list_messages(conversation_id) do
    Message
    |> where([m], m.conversation_id == ^conversation_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end
end
