defmodule BarkparkWeb.Studio.ChatHostsLive do
  @moduledoc """
  Studio > Chat hosts: register the machines that run this workspace's bot
  turns (/papers/chat-host-enrollment-overhaul T4).

  A one-time code lives only in this LiveView process, under the host it was
  made for, until the machine enrolls or the code expires; the server keeps
  its hash. After a reload the page cannot show it again and offers "Make a
  new code" instead, which replaces it. Only the workspace owner sees the
  register form and the new-code button, and the server checks the seat again
  on every write.
  """
  use BarkparkWeb, :live_view

  import BarkparkWeb.Studio.PageScroll

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.Enrollment
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Components.ConfirmModal
  alias BarkparkWeb.Studio.BoundAdminWrite
  alias BarkparkWeb.Studio.ChatHostsLive.{HostCard, Style}

  # How often an open page re-reads the hosts, so a machine that enrolls or
  # goes offline shows without a reload, and the time left counts down.
  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if Barkpark.Capability.enabled?(:studio_chat) do
      if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

      {:ok,
       assign(socket,
         page_title: "Chat hosts",
         hosts: [],
         revoked: [],
         codes: %{},
         confirm: nil,
         now: DateTime.utc_now(),
         can_enroll: owner?(socket)
       )}
    else
      # Studio Chat is switched off on this instance (`Barkpark.Capability`);
      # its host routes answer 404, so there is nothing to manage here.
      {:ok,
       socket
       |> put_flash(:error, "Studio Chat is not enabled on this instance.")
       |> redirect(to: "/studio")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    case {connected?(socket), socket.assigns[:current_workspace]} do
      {true, %{id: workspace_id}} ->
        hosts = ChatHosts.list_hosts(workspace_id)
        waiting = for h <- hosts, not h.enrolled, into: MapSet.new(), do: h.id

        assign(socket,
          hosts: hosts,
          revoked: Enrollment.recently_revoked(workspace_id),
          codes: Map.filter(socket.assigns.codes, fn {id, _} -> id in waiting end),
          now: DateTime.utc_now()
        )

      _ ->
        assign(socket, now: DateTime.utc_now())
    end
  end

  # Every write follows the dataset-bound admin write rule (`BoundAdminWrite`):
  # a bound admin token is refused in `:enforce` and recorded in `:observe`.
  @impl true
  def handle_event(event, params, socket) when event in ["enroll", "new_code", "revoke"] do
    if BoundAdminWrite.refused?(socket.assigns[:api_token]),
      do: {:noreply, BoundAdminWrite.refuse(socket)},
      else: write(event, params, socket)
  end

  def handle_event("ask_revoke", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm: Enum.find(socket.assigns.hosts, &(&1.id == id)))}
  end

  def handle_event("cancel_revoke", _params, socket), do: {:noreply, assign(socket, confirm: nil)}

  defp write("enroll", %{"host" => params}, socket) do
    with {:ok, workspace} <- authorize(socket, :enroll),
         {:ok, result} <- ChatHosts.issue_enrollment(workspace.id, params) do
      observe(socket, "enroll", workspace)

      {:noreply,
       socket
       |> keep_code(result)
       |> put_flash(
         :info,
         "Made a one-time code for #{result.host.name}. Run the command below on the machine."
       )
       |> load()}
    else
      {:error, :forbidden} ->
        {:noreply, deny(socket)}

      {:error, {:host_limit_reached, limit}} ->
        {:noreply, put_flash(socket, :error, limit_message(limit))}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, enroll_error(socket, params, changeset))}
    end
  end

  defp write("new_code", %{"id" => id}, socket) do
    with {:ok, workspace} <- authorize(socket, :enroll),
         {:ok, result} <- Enrollment.replace_code(workspace.id, id) do
      observe(socket, "new_code", workspace)

      {:noreply,
       socket
       |> keep_code(result)
       |> put_flash(
         :info,
         "Made a new code for #{result.host.name}. The old code no longer works."
       )
       |> load()}
    else
      {:error, :forbidden} ->
        {:noreply, deny(socket)}

      {:error, :already_enrolled} ->
        {:noreply,
         put_flash(socket, :error, "That machine is already enrolled, so it needs no code.")}

      {:error, {:host_limit_reached, limit}} ->
        {:noreply, put_flash(socket, :error, limit_message(limit))}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "That machine is no longer waiting in this workspace.")
         |> load()}
    end
  end

  # The confirm modal's button carries no value, so the id comes from the
  # host the owner asked about; a direct event may still name one.
  defp write("revoke", params, socket) do
    id = params["id"] || (socket.assigns.confirm && socket.assigns.confirm.id)

    case id && authorize(socket, :revoke) do
      nil ->
        {:noreply, assign(socket, confirm: nil)}

      {:ok, workspace} ->
        socket =
          case ChatHosts.revoke(workspace.id, id) do
            {:ok, host} ->
              observe(socket, "revoke", workspace)
              put_flash(socket, :info, revoked_message(host))

            {:error, :not_found} ->
              put_flash(socket, :error, "That machine is not registered in this workspace.")

            {:error, _} ->
              put_flash(socket, :error, "Could not revoke that machine. Try again.")
          end

        {:noreply, socket |> assign(confirm: nil) |> load()}

      {:error, :forbidden} ->
        {:noreply, deny(socket)}
    end
  end

  defp keep_code(socket, %{host: host, enrollment_token: code}) do
    assign(socket, codes: Map.put(socket.assigns.codes, host.id, code))
  end

  defp revoked_message(%{enrolled: true, name: name}),
    do: "Revoked #{name}. It can no longer run turns, and its running turns were cancelled."

  defp revoked_message(%{name: name}), do: "Removed #{name}. Its code no longer works."

  defp limit_message(limit),
    do:
      "This workspace already has #{limit} enrolled machines, the most it can hold. Revoke one to add another."

  # The owner is told what to change: a taken name says whether that machine
  # is waiting or enrolled, and a refused field names the field.
  defp enroll_error(socket, params, changeset) do
    workspace_id = socket.assigns.current_workspace.id

    with true <- Enrollment.name_taken?(changeset),
         {state, _host_id} <- Enrollment.name_conflict(workspace_id, params["name"]) do
      Enrollment.name_taken_message(params["name"], state)
    else
      _ -> field_error(changeset)
    end
  end

  defp field_error(%Ecto.Changeset{errors: [{field, {message, opts}} | _]}) do
    message =
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)

    "Could not register the machine: #{field_label(field)} #{message}."
  end

  defp field_error(_), do: "Could not register the machine. Check the name and the folder."

  defp field_label(:approved_roots), do: "the folder"
  defp field_label(:name), do: "the name"
  defp field_label(field), do: to_string(field)

  defp observe(socket, event, workspace),
    do:
      BoundAdminWrite.observe(
        socket.assigns[:api_token],
        "tokens_write",
        "live ChatHostsLive.#{event}",
        workspace.id
      )

  # Only shapes the page; every write asks `authorize/2` again.
  defp owner?(socket) do
    principal = socket.assigns[:api_token] || socket.assigns[:current_user]

    case socket.assigns[:current_workspace] do
      %{id: workspace_id} when not is_nil(principal) ->
        TenancyAuth.workspace_owner?(principal, workspace_id)

      _ ->
        false
    end
  end

  defp authorize(socket, action) do
    workspace = socket.assigns[:current_workspace]
    principal = socket.assigns[:api_token] || socket.assigns[:current_user]

    authorized? =
      is_map(workspace) and not is_nil(principal) and
        case action do
          # Both arms ask a NAMED predicate on the Tenancy.Auth chokepoint, and
          # the pair is the whole point: enrolling a machine (and making a new
          # code for one) is an OWNER decision, revoking one is an admin
          # decision. :enroll used to spell its rule as a literal
          # `membership_role(...) == "owner"` — here and again in
          # `ChatHostController.create_enrollment/2` — so the seat rule existed
          # in two places and could diverge under a one-sided loosening
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

  # The command a person pastes on the machine: the code on stdin, never in
  # argv, then the server and each approved folder.
  defp command(host, code) do
    roots = Enum.map_join(host.approved_roots, " ", &("--root " <> quote_arg(&1)))

    "printf '%s\\n' #{quote_arg(code)} | barkpark-chat-host enroll --url #{quote_arg(BarkparkWeb.Endpoint.url())} #{roots}"
  end

  defp quote_arg(value) do
    if value =~ ~r/\A[A-Za-z0-9_\-.\/:@=]+\z/,
      do: value,
      else: "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- studio-shell child contract (BarkparkWeb.Studio.PageScroll): the
          shell is height:100vh + overflow:hidden, so this wrapper fills it
          and owns the scroll. --%>
    <.studio_page_scroll>
      <Style.sheet />
      <div class="ch-page">
        <header class="ch-head">
          <p class="ch-eyebrow">Studio Chat</p>
          <h1>Chat hosts</h1>
          <p class="ch-lede">
            A chat host is a machine you trust to run this workspace's bot turns with its own Claude
            or Codex sign-in. It connects out to Barkpark and asks for work; nothing connects in, and
            the provider's keys never leave the machine.
          </p>
        </header>

        <ol class="ch-steps">
          <li>
            <span class="ch-step-n">1</span>
            <div>
              <strong>Name it and pick its folder.</strong>
              The bot works in this folder. It is where turns start, not a sandbox: the coding CLI can
              read anything its account can read.
            </div>
          </li>
          <li>
            <span class="ch-step-n">2</span>
            <div>
              <strong>Run one command on the machine.</strong>
              It needs <code>barkpark-chat-host</code>. The command carries a one-time code that works
              for 10 minutes.
            </div>
          </li>
          <li>
            <span class="ch-step-n">3</span>
            <div>
              <strong>Start it.</strong>
              <code>barkpark-chat-host run</code> keeps it online. This page shows it within seconds.
            </div>
          </li>
        </ol>

        <section :if={@can_enroll} class="ch-card" aria-labelledby="ch-register-title">
          <h2 id="ch-register-title">Register a machine</h2>
          <p class="ch-card-sub">You get the command to run on it right away.</p>
          <form phx-submit="enroll" class="ch-form">
            <div class="ch-field">
              <label for="ch-name">Name</label>
              <input id="ch-name" name="host[name]" required maxlength="120" class="form-input" autocomplete="off" placeholder="build-vm" />
              <p class="ch-hint">How it shows in Studio and in bp.</p>
            </div>
            <div class="ch-field">
              <label for="ch-root">Folder on the machine</label>
              <input id="ch-root" name="host[approved_roots][]" required class="form-input" autocomplete="off" spellcheck="false" placeholder="/home/bot/work" />
              <p class="ch-hint">An absolute path. Turns run here.</p>
            </div>
            <button class="btn btn-primary">Make a code</button>
          </form>
        </section>
        <p :if={not @can_enroll} class="ch-note">
          Only the workspace owner can register a machine. As an admin you can revoke one.
        </p>

        <section class="ch-list" aria-labelledby="ch-list-title">
          <div class="ch-list-head">
            <h2 id="ch-list-title">Machines</h2>
            <span class="ch-count">{online_count(@hosts)} online · {length(@hosts)} registered</span>
          </div>

          <p :if={@hosts == []} class="ch-empty">
            No machines yet. Register one above, and it shows here as soon as it connects.
          </p>

          <div :if={@hosts != []} class="ch-hosts">
            <HostCard.card
              :for={host <- @hosts}
              host={host}
              now={@now}
              code={@codes[host.id]}
              command={@codes[host.id] && command(host, @codes[host.id])}
              can_enroll={@can_enroll}
            />
          </div>
        </section>

        <section :if={@revoked != []} class="ch-revoked" aria-labelledby="ch-revoked-title">
          <h3 id="ch-revoked-title">Recently revoked</h3>
          <ul>
            <li :for={host <- @revoked}>{host.name} · revoked {HostCard.ago(host.revoked_at, @now)}</li>
          </ul>
        </section>

        <p class="ch-foot">
          Each machine checks in every few seconds and shows as offline after
          {HostCard.online_window()} seconds without a word. Revoking a machine stops it at once and
          cancels the turns it is running.
        </p>
      </div>

      <ConfirmModal.confirm_modal
        :if={@confirm}
        id="chat-host-revoke"
        title={if @confirm.enrolled, do: "Revoke #{@confirm.name}?", else: "Remove #{@confirm.name}?"}
        body={
          if @confirm.enrolled,
            do: "It stops running turns now, and the turns it is running are cancelled. To use it again, register it again.",
            else: "Its code stops working. You can register it again later."
        }
        on_cancel="cancel_revoke"
        on_confirm={"revoke"}
        confirm_label={if @confirm.enrolled, do: "Revoke", else: "Remove"}
      />
    </.studio_page_scroll>
    """
  end

  defp online_count(hosts), do: Enum.count(hosts, & &1.online)
end
