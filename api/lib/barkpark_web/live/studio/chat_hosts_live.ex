defmodule BarkparkWeb.Studio.ChatHostsLive do
  use BarkparkWeb, :live_view

  alias Barkpark.ChatHosts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Chat hosts", hosts: [], enrollment: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    hosts =
      if connected?(socket) do
        case socket.assigns[:current_workspace] do
          %{id: workspace_id} -> ChatHosts.list_hosts(workspace_id)
          _ -> []
        end
      else
        []
      end

    {:noreply, assign(socket, hosts: hosts)}
  end

  @impl true
  def handle_event("enroll", %{"host" => params}, socket) do
    case ChatHosts.issue_enrollment(socket.assigns.current_workspace.id, params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(enrollment: result.enrollment_token)
         |> assign(hosts: ChatHosts.list_hosts(socket.assigns.current_workspace.id))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not create enrollment")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    _ = ChatHosts.revoke(socket.assigns.current_workspace.id, id)
    {:noreply, assign(socket, hosts: ChatHosts.list_hosts(socket.assigns.current_workspace.id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl space-y-6 p-6">
      <div>
        <h1 class="text-2xl font-semibold">Registered Chat hosts</h1>
        <p class="text-sm opacity-70">Provider credentials remain on each enrolled machine.</p>
      </div>

      <form phx-submit="enroll" class="flex gap-2">
        <input name="host[name]" required placeholder="Host name" class="input input-bordered" />
        <input name="host[approved_roots][]" required placeholder="/absolute/approved/root" class="input input-bordered flex-1" />
        <button class="btn btn-primary">Create one-time enrollment</button>
      </form>

      <div :if={@enrollment} class="alert alert-warning font-mono break-all">
        One-time enrollment token: <%= @enrollment %>
      </div>

      <div class="space-y-2">
        <div :for={host <- @hosts} class="flex items-center justify-between rounded border p-3">
          <div>
            <div class="font-medium"><%= host.name %></div>
            <div class="text-xs opacity-70">
              <%= if host.online, do: "online", else: "offline" %> · protocol <%= host.protocol_version %> · credential v<%= host.credential_version %>
            </div>
            <div class="text-xs opacity-70"><%= Enum.join(host.approved_roots, ", ") %></div>
            <div
              :for={{provider, readiness} <- Map.get(host.capabilities, "providers", %{})}
              class="text-xs opacity-70"
            >
              <%= provider %>: <%= if readiness["installed"], do: readiness["version"] || "installed", else: "missing" %> · auth <%= readiness["auth_ready"] || "unknown" %>
            </div>
          </div>
          <button phx-click="revoke" phx-value-id={host.id} class="btn btn-error btn-sm">Revoke</button>
        </div>
      </div>
    </div>
    """
  end
end
