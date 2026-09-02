defmodule BarkparkWeb.Studio.ChatHostsLive do
  use BarkparkWeb, :live_view

  alias Barkpark.ChatHosts
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

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
    with {:ok, workspace} <- authorize(socket, :enroll),
         {:ok, result} <- ChatHosts.issue_enrollment(workspace.id, params) do
      {:noreply,
       socket
       |> assign(enrollment: result.enrollment_token)
       |> assign(hosts: ChatHosts.list_hosts(workspace.id))}
    else
      {:error, :forbidden} ->
        {:noreply, deny(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not create enrollment")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case authorize(socket, :revoke) do
      {:ok, workspace} ->
        _ = ChatHosts.revoke(workspace.id, id)
        {:noreply, assign(socket, hosts: ChatHosts.list_hosts(workspace.id))}

      {:error, :forbidden} ->
        {:noreply, deny(socket)}
    end
  end

  defp authorize(socket, action) do
    workspace = socket.assigns[:current_workspace]
    principal = socket.assigns[:api_token] || socket.assigns[:current_user]

    authorized? =
      is_map(workspace) and not is_nil(principal) and
        case action do
          # Both arms ask a NAMED predicate on the Tenancy.Auth chokepoint, and
          # the pair is the whole point: enrolling a machine is an OWNER
          # decision, revoking one is an admin decision. :enroll used to spell
          # its rule as a literal `membership_role(...) == "owner"` — here and
          # again in `ChatHostController.create_enrollment/2` — so the seat rule
          # existed in two places and could diverge under a one-sided loosening
          # (`arpss-w10-bl-chat-hosts-owner-literal-seat-fork`).
          :enroll -> TenancyAuth.workspace_owner?(principal, workspace.id)
          :revoke -> TenancyAuth.workspace_admin?(principal, workspace.id)
        end

    if authorized? do
      {:ok, workspace}
    else
      {:error, :forbidden}
    end
  end

  defp deny(socket) do
    put_flash(
      socket,
      :error,
      "Only the workspace owner can enroll a trusted machine; owners and admins may revoke one."
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl space-y-6 p-6">
      <div>
        <h1 class="text-2xl font-semibold">Registered Chat hosts</h1>
        <p class="text-sm opacity-70">
          Provider credentials remain on each enrolled machine. Enrollment is an explicit
          trusted-machine ceremony: the local coding CLI can read anything its operating-system
          account can read. Approved roots select working directories; they are not a read sandbox.
        </p>
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
