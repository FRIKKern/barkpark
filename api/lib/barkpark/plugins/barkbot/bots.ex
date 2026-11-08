defmodule Barkpark.Plugins.Barkbot.Bots do
  @moduledoc """
  Context for managing BarkBot bot configurations.
  """
  
  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Plugins.Barkbot.Bot
  
  @doc """
  Create a new bot with encrypted API key.
  """
  def create_bot(attrs, api_key) do
    %Bot{}
    |> Bot.create_changeset(attrs, api_key)
    |> Repo.insert()
  end
  
  @doc """
  Get a bot by ID.
  """
  def get_bot(id) do
    case Repo.get(Bot, id) do
      nil -> {:error, :not_found}
      bot -> {:ok, bot}
    end
  end
  
  @doc """
  Get a bot by bot_id slug.
  """
  def get_bot_by_slug(bot_id, workspace_id) do
    Bot
    |> where([b], b.bot_id == ^bot_id and b.workspace_id == ^workspace_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      bot -> {:ok, bot}
    end
  end
  
  @doc """
  List bots, optionally filtered.
  """
  def list_bots(filters \\ %{}) do
    Bot
    |> apply_filters(filters)
    |> order_by([b], asc: b.name)
    |> Repo.all()
  end
  
  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:workspace_id, workspace_id}, q when not is_nil(workspace_id) ->
        where(q, [b], b.workspace_id == ^workspace_id)
        
      {:enabled, enabled}, q when is_boolean(enabled) ->
        where(q, [b], b.enabled == ^enabled)
        
      {:status, status}, q when not is_nil(status) ->
        where(q, [b], b.status == ^status)
        
      _, q ->
        q
    end)
  end
  
  @doc """
  Update a bot.
  """
  def update_bot(bot, attrs) do
    bot
    |> Bot.changeset(attrs)
    |> Repo.update()
  end
  
  @doc """
  Delete a bot.
  """
  def delete_bot(bot) do
    Repo.delete(bot)
  end
  
  @doc """
  Update bot's last active timestamp.
  """
  def touch_bot(bot_id) do
    from(b in Bot, where: b.id == ^bot_id)
    |> Repo.update_all(set: [last_active_at: DateTime.utc_now()])
  end
end
