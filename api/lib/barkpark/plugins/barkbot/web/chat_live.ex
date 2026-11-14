defmodule Barkpark.Plugins.Barkbot.Web.ChatLive do
  @moduledoc """
  BarkBot chat interface - matches Grok Bot layout:
  - Dark charcoal theme
  - Slim left navigation (bot selector)
  - Central chat area with user/assistant bubbles
  - Right panel with activity, library, and computer status
  - Bottom composer
  """
  
  use BarkparkWeb, :live_view
  
  alias Barkpark.Plugins.Barkbot.{Bots, Conversations, Jobs, Runner}
  alias Barkpark.Repo
  
  @impl true
  def mount(_params, _session, socket) do
    workspace_id = socket.assigns.current_workspace.id
    
    # Load bots for this workspace
    bots = Bots.list_bots(%{workspace_id: workspace_id, enabled: true})
    
    # Select first bot or show empty state
    selected_bot = List.first(bots)
    
    # Load recent conversations
    conversations =
      if selected_bot do
        Conversations.list_conversations(%{bot_id: selected_bot.id})
      else
        []
      end
    
    # Get computer info for selected bot
    computer_info = get_computer_info(selected_bot)
    
    {:ok,
     socket
     |> assign(:bots, bots)
     |> assign(:selected_bot, selected_bot)
     |> assign(:conversations, conversations)
     |> assign(:current_conversation, nil)
     |> assign(:messages, [])
     |> assign(:input, "")
     |> assign(:waiting_for_response, false)
     |> assign(:computer_info, computer_info)
     |> assign(:show_settings, false)}
  end
  
  @impl true
  def handle_event("select_bot", %{"bot_id" => bot_id}, socket) do
    bot = Enum.find(socket.assigns.bots, &(&1.id == bot_id))
    conversations = Conversations.list_conversations(%{bot_id: bot_id})
    
    {:noreply,
     socket
     |> assign(:selected_bot, bot)
     |> assign(:conversations, conversations)
     |> assign(:current_conversation, nil)
     |> assign(:messages, [])
     |> assign(:computer_info, get_computer_info(bot))}
  end
  
  @impl true
  def handle_event("new_conversation", _params, socket) do
    bot = socket.assigns.selected_bot
    
    case Conversations.create_conversation(%{
           bot_id: bot.id,
           workspace_id: socket.assigns.current_workspace.id,
           title: "New conversation",
           created_by: socket.assigns.current_user.email
         }) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(:current_conversation, conversation)
         |> assign(:messages, [])
         |> push_navigate(to: ~p"/barkbot/chat/#{conversation.id}")}
         
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create conversation")}
    end
  end
  
  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    if String.trim(message) == "" do
      {:noreply, socket}
    else
      send_message_to_bot(socket, message)
    end
  end
  
  @impl true
  def handle_event("cancel_job", %{"job_id" => job_id}, socket) do
    case Runner.cancel_job(job_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:waiting_for_response, false)
         |> put_flash(:info, "Job cancelled")}
         
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel: #{reason}")}
    end
  end
  
  defp send_message_to_bot(socket, content) do
    bot = socket.assigns.selected_bot
    conversation = socket.assigns.current_conversation
    
    # Create or use existing conversation
    conversation =
      conversation ||
        case Conversations.create_conversation(%{
               bot_id: bot.id,
               workspace_id: socket.assigns.current_workspace.id,
               created_by: socket.assigns.current_user.email
             }) do
          {:ok, conv} -> conv
          _ -> nil
        end
    
    if conversation do
      # Add user message
      {:ok, user_msg} =
        Conversations.add_message(conversation.id, %{
          role: "user",
          content: content
        })
      
      # Create job
      {:ok, job} =
        Jobs.create_job(%{
          bot_id: bot.id,
          conversation_id: conversation.id,
          prompt: content,
          system_prompt: bot.system_prompt,
          max_tokens: bot.max_tokens,
          temperature: bot.temperature,
          timeout_seconds: bot.timeout_seconds,
          workspace_id: socket.assigns.current_workspace.id,
          created_by: socket.assigns.current_user.email
        })
      
      # Update UI
      messages = socket.assigns.messages ++ [user_msg]
      
      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:input, "")
        |> assign(:waiting_for_response, true)
        |> assign(:current_job_id, job.id)
      
      # Execute job asynchronously
      Task.start(fn ->
        Runner.execute_job(job.id)
      end)
      
      # Poll for completion (in production, use PubSub)
      Process.send_after(self(), {:check_job, job.id}, 1000)
      
      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Failed to create conversation")}
    end
  end
  
  @impl true
  def handle_info({:check_job, job_id}, socket) do
    case Jobs.get_job(job_id) do
      {:ok, job} ->
        case job.status do
          "completed" ->
            # Add assistant message
            {:ok, assistant_msg} =
              Conversations.add_message(socket.assigns.current_conversation.id, %{
                role: "assistant",
                content: job.response,
                job_id: job_id,
                tokens: job.tokens_used
              })
            
            messages = socket.assigns.messages ++ [assistant_msg]
            
            {:noreply,
             socket
             |> assign(:messages, messages)
             |> assign(:waiting_for_response, false)}
            
          status when status in ["failed", "cancelled", "timeout"] ->
            {:noreply,
             socket
             |> assign(:waiting_for_response, false)
             |> put_flash(:error, "Job #{status}: #{job.error}")}
            
          _ ->
            # Still running, check again
            Process.send_after(self(), {:check_job, job_id}, 1000)
            {:noreply, socket}
        end
        
      {:error, _} ->
        {:noreply,
         socket
         |> assign(:waiting_for_response, false)
         |> put_flash(:error, "Job not found")}
    end
  end
  
  defp get_computer_info(nil), do: nil
  
  defp get_computer_info(bot) do
    # Require explicit machine assignment - no fallback to localhost
    %{
      hostname: bot.hostname,
      cpu_cores: bot.cpu_cores,
      memory_gb: bot.memory_gb,
      location: bot.location || "Unknown location",
      status: if(bot.enabled, do: "online", else: "offline")
    }
  end
  
  defp get_cpu_cores do
    System.schedulers_online()
  end
  
  defp get_memory_gb do
    case :memsup.get_system_memory_data() do
      data when is_list(data) ->
        total = Keyword.get(data, :total_memory, 0)
        Float.round(total / 1024 / 1024 / 1024, 1)
        
      _ ->
        0
    end
  end
  
  @impl true
  def render(assigns) do
    ~H"""
    <div class="barkbot-container">
      <!-- Left Sidebar - Bot Navigation -->
      <aside class="barkbot-sidebar">
        <div class="sidebar-header">
          <h2>BarkBot</h2>
        </div>
        
        <div class="bot-list">
          <%= for bot <- @bots do %>
            <button
              class={"bot-item #{if @selected_bot && bot.id == @selected_bot.id, do: "active"}"}
              phx-click="select_bot"
              phx-value-bot_id={bot.id}
            >
              <div class="bot-avatar">
                <%= String.first(bot.name) %>
              </div>
              <span class="bot-name"><%= bot.name %></span>
            </button>
          <% end %>
        </div>
        
        <button class="new-bot-btn" phx-click="new_conversation">
          + New Chat
        </button>
      </aside>
      
      <!-- Main Chat Area -->
      <main class="barkbot-main">
        <%= if @selected_bot do %>
          <div class="chat-header">
            <h1><%= @selected_bot.name %></h1>
            <p class="bot-description"><%= @selected_bot.description %></p>
          </div>
          
          <div class="messages-container">
            <%= for message <- @messages do %>
              <div class={"message message-#{message.role}"}>
                <div class="message-avatar">
                  <%= if message.role == "user" do %>
                    <span>You</span>
                  <% else %>
                    <span><%= String.first(@selected_bot.name) %></span>
                  <% end %>
                </div>
                <div class="message-content">
                  <%= message.content %>
                </div>
              </div>
            <% end %>
            
            <%= if @waiting_for_response do %>
              <div class="message message-assistant">
                <div class="message-avatar">
                  <span><%= String.first(@selected_bot.name) %></span>
                </div>
                <div class="message-content">
                  <div class="typing-indicator">
                    <span></span>
                    <span></span>
                    <span></span>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
          
          <div class="composer">
            <form phx-submit="send_message">
              <input
                type="text"
                name="message"
                value={@input}
                placeholder="Message BarkBot..."
                autocomplete="off"
                disabled={@waiting_for_response}
              />
              <button type="submit" disabled={@waiting_for_response}>
                Send
              </button>
            </form>
            
            <%= if @waiting_for_response do %>
              <button
                class="cancel-btn"
                phx-click="cancel_job"
                phx-value-job_id={@current_job_id}
              >
                Cancel
              </button>
            <% end %>
          </div>
        <% else %>
          <div class="empty-state">
            <h2>No BarkBots configured</h2>
            <p>Create a bot to get started</p>
            <.link navigate={~p"/barkbot/bots/new"} class="btn-primary">
              Create BarkBot
            </.link>
          </div>
        <% end %>
      </main>
      
      <!-- Right Panel - Details -->
      <aside class="barkbot-details">
        <div class="details-section">
          <h3>Activity</h3>
          <div class="activity-list">
            <%= if @current_conversation do %>
              <div class="activity-item">
                <span class="activity-icon">💬</span>
                <span>Active conversation</span>
              </div>
            <% end %>
          </div>
        </div>
        
        <div class="details-section">
          <h3>Library</h3>
          <p class="text-muted">Recent conversations</p>
          <div class="conversation-list">
            <%= for conv <- Enum.take(@conversations, 5) do %>
              <div class="conversation-item">
                <%= conv.title %>
              </div>
            <% end %>
          </div>
        </div>
        
        <%= if @computer_info do %>
          <div class="details-section computer-section">
            <h3>Computer</h3>
            <div class="computer-info">
              <div class="computer-status">
                <span class={"status-dot status-#{@computer_info.status}"}></span>
                <span><%= @computer_info.status %></span>
              </div>
              <div class="computer-spec">
                <strong><%= @computer_info.hostname %></strong>
              </div>
              <div class="computer-spec">
                <%= @computer_info.cpu_cores %> vCPU · <%= @computer_info.memory_gb %> GB RAM
              </div>
              <div class="computer-spec text-muted">
                <%= @computer_info.location %>
              </div>
            </div>
          </div>
        <% end %>
        
        <div class="details-section">
          <h3>Suggested</h3>
          <p class="text-muted">Demo features (unavailable in prototype)</p>
          <div class="suggested-list">
            <div class="suggested-item disabled">
              <span>📢</span> Voice chat
            </div>
            <div class="suggested-item disabled">
              <span>🔗</span> Add to Slack
            </div>
            <div class="suggested-item disabled">
              <span>⚡</span> Create a routine
            </div>
          </div>
        </div>
      </aside>
    </div>
    """
  end
end
