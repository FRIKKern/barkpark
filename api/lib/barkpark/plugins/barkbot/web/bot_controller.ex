defmodule Barkpark.Plugins.Barkbot.Web.BotController do
  use BarkparkWeb, :controller
  
  alias Barkpark.Plugins.Barkbot.{Bots, Bot, Authorization}
  
  def create(conn, params) do
    # Admin only
    with :ok <- Authorization.require_admin(conn) do
      workspace_id = conn.assigns.current_workspace.id
      
      # Never include api_key in params - handled separately
      bot_params = Map.merge(params, %{
        "workspace_id" => workspace_id,
        "auth_status" => "unknown"
      })
      
      case Bots.create_bot(bot_params, params["api_key"]) do
        {:ok, bot} ->
          conn
          |> put_status(:created)
          |> json(sanitize_bot(bot))
          
        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    else
      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Admin access required"})
    end
  end
  
  def list(conn, _params) do
    workspace_id = conn.assigns.current_workspace.id
    bots = Bots.list_bots(%{workspace_id: workspace_id})
    
    json(conn, %{bots: Enum.map(bots, &sanitize_bot/1)})
  end
  
  def show(conn, %{"bot_id" => bot_id}) do
    workspace_id = conn.assigns.current_workspace.id
    
    with {:ok, bot} <- Bots.get_bot(bot_id),
         :ok <- Authorization.authorize_bot_access(conn, bot) do
      json(conn, sanitize_bot(bot))
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Bot not found"})
        
      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Access denied"})
    end
  end
  
  def update(conn, %{"bot_id" => bot_id} = params) do
    with {:ok, bot} <- Bots.get_bot(bot_id),
         :ok <- Authorization.authorize_bot_access(conn, bot),
         {:ok, updated_bot} <- Bots.update_bot(bot, params) do
      json(conn, sanitize_bot(updated_bot))
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Bot not found"})
        
      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Access denied"})
        
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end
  
  def delete(conn, %{"bot_id" => bot_id}) do
    with {:ok, bot} <- Bots.get_bot(bot_id),
         :ok <- Authorization.authorize_bot_access(conn, bot),
         {:ok, _} <- Bots.delete_bot(bot) do
      send_resp(conn, :no_content, "")
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Bot not found"})
        
      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Access denied"})
    end
  end
  
  # Never return API keys or encrypted secrets
  defp sanitize_bot(bot) do
    bot
    |> Map.from_struct()
    |> Map.drop([:__meta__, :api_key_encrypted, :__struct__])
    |> Map.put(:api_key_set, bot.api_key_encrypted != nil)
  end
  
  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
