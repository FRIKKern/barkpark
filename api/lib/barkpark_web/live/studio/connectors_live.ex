defmodule BarkparkWeb.Studio.ConnectorsLive do
  @moduledoc """
  **Connectors** — the catalog, and THE CONNECT LOOP (Connectors D47–D55).

  Mounted at `/w/:ws/p/:proj/studio/connectors` in `live_session
  :scoped_admin_studio`. It closes the one loop nobody closed: until this shipped,
  minting a workspace-bound chat token and sealing it into
  `chat_bridge.connector_installs.chat_token_ref` was a HAND operation, so "click
  Connect and your team is talking to your agent in two minutes" was a claim, not
  a product.

  ## The loop

      Connect → paste a token → the bridge VALIDATES it (Telegram getMe, Discord
      /users/@me) and hands back the install_key + the bot's real name → the
      operator CONFIRMS that bot → Barkpark MINTS a chat token labelled
      `connector:<provider>:<install_key>` → POST /connect ships the credential +
      the token over LOOPBACK → the bridge seals both and MOUNTS the adapter live
      (no restart) → the card flips to Connected.

  A FAILED `/connect` REVOKES the just-minted token. A token minted for an install
  that does not exist is a live workspace credential with no owner — leaking one
  is worse than failing.

  ## THE GATE DELTA (D49) — read this before touching a handler

  The mount gate is NOT the mint gate. `LiveAuth(:admin)` checks the token's
  GLOBAL `permissions` array; the HTTP mint (`ChatTokenController`, `:scoped_admin`)
  checks per-workspace MEMBERSHIP. A token with global `admin` and no membership
  row in this workspace MOUNTS this page and is a flat 403 on the endpoint. So
  every state-changing handler here re-gates on
  `Tenancy.Auth.workspace_admin?/2`, fail-closed, accepting BOTH principal kinds
  (`%ApiToken{}` from the token path, `%User{}` from the account-session path) —
  otherwise an in-process mint would be a privilege escalation relative to the
  endpoint it delegates to.

  ## Honest states, always

    * No `CONNECTORS_CONNECT_SECRET` on this instance ⇒ the catalog renders
      READ-ONLY with a banner. Not a crash, not a hidden page, not a dead button.
    * The bridge unreachable ⇒ the operator is told the bridge is not answering.
      There is no code path anywhere in this module that renders "Connected"
      without an install row read back out of the database.
    * A provider we cannot honestly connect (Slack's OAuth is not wired; Teams
      needs your org's Azure admin; WhatsApp needs Meta App Review; iMessage needs
      a Mac you own) shows its gate as prose and NO button.

  Zero installs exist anywhere today. Nothing here seeds one.
  """

  use BarkparkWeb, :live_view

  require Logger

  alias Barkpark.Auth
  alias Barkpark.Connectors
  alias Barkpark.Connectors.Catalog
  alias Barkpark.Connectors.ConnectTicket
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Connectors",
       providers: Catalog.providers(),
       installs: %{},
       loaded?: false,
       connect_configured?: Connectors.connect_configured?(),
       # A scope switch from here re-opens Connectors under the new scope.
       scope_subpath: "/connectors",
       dialog: nil,
       disconnecting: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    # The install read is a real cross-schema query; the disconnected render is
    # discarded and this page is admin-gated (no crawler consumes the dead HTML),
    # so load once, on connect. Until then the cards render "Loading…", never a
    # confident "Not connected" the read might contradict.
    if connected?(socket) do
      {:noreply, load_installs(socket)}
    else
      {:noreply, socket}
    end
  end

  # ── Connect ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_connect", %{"provider" => provider}, socket) do
    with {:ok, _ws, _principal} <- authorize(socket),
         true <- socket.assigns.connect_configured?,
         %{connectable?: true} = card <- Catalog.provider(provider) do
      {:noreply,
       assign(socket, :dialog, %{
         provider: card.id,
         step: :paste,
         credential: "",
         candidate: nil,
         error: nil
       })}
    else
      {:error, :forbidden} -> {:noreply, deny(socket)}
      _ -> {:noreply, put_flash(socket, :error, "That provider cannot be connected here.")}
    end
  end

  def handle_event("close_dialog", _params, socket) do
    {:noreply, assign(socket, :dialog, nil)}
  end

  # STEP 1 — VALIDATE. Writes nothing, anywhere. Its only job is to learn the
  # install_key (so the token can be LABELLED before it is minted, D51) and to
  # show the operator the bot the credential actually belongs to.
  def handle_event("validate_credential", %{"credential" => credential}, socket) do
    credential = String.trim(credential || "")

    with {:ok, ws, _principal} <- authorize(socket),
         %{provider: provider} <- socket.assigns.dialog,
         :ok <- present(credential),
         {:ok, ticket} <- ticket(ws, provider) do
      case Connectors.bridge().validate(ticket, credential) do
        {:ok, %{install_key: key, display_name: name}} ->
          {:noreply,
           assign(socket, :dialog, %{
             provider: provider,
             step: :confirm,
             credential: credential,
             candidate: %{install_key: key, display_name: name},
             error: nil
           })}

        {:error, reason} ->
          {:noreply, dialog_error(socket, bridge_message(reason))}
      end
    else
      {:error, :forbidden} ->
        {:noreply, deny(socket)}

      {:error, :blank} ->
        {:noreply, dialog_error(socket, "Paste the token first.")}

      {:error, :not_configured} ->
        {:noreply, dialog_error(socket, not_configured_message())}

      {:error, ticket_err} when is_atom(ticket_err) ->
        {:noreply, dialog_error(socket, "Could not sign a connect ticket (#{ticket_err}).")}

      _ ->
        {:noreply, assign(socket, :dialog, nil)}
    end
  end

  # STEP 2 — CONNECT. Mint, ship, verify, or REVOKE.
  def handle_event("confirm_connect", _params, socket) do
    with {:ok, ws, _principal} <- authorize(socket),
         %{provider: provider, credential: credential, candidate: %{install_key: key}} <-
           socket.assigns.dialog,
         {:ok, ticket} <- ticket(ws, provider) do
      {:noreply, do_connect(socket, ws, provider, key, credential, ticket)}
    else
      {:error, :forbidden} -> {:noreply, deny(socket)}
      {:error, :not_configured} -> {:noreply, dialog_error(socket, not_configured_message())}
      _ -> {:noreply, assign(socket, :dialog, nil)}
    end
  end

  # ── Disconnect ─────────────────────────────────────────────────────────────

  def handle_event("open_disconnect", %{"provider" => provider}, socket) do
    case {authorize(socket), Map.get(socket.assigns.installs, provider)} do
      {{:ok, _ws, _principal}, %{} = install} ->
        {:noreply, assign(socket, :disconnecting, install)}

      {{:error, :forbidden}, _} ->
        {:noreply, deny(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_disconnect", _params, socket) do
    {:noreply, assign(socket, :disconnecting, nil)}
  end

  def handle_event("confirm_disconnect", _params, socket) do
    with {:ok, ws, _principal} <- authorize(socket),
         %{provider: provider, install_key: key} <- socket.assigns.disconnecting,
         {:ok, ticket} <- ticket(ws, provider) do
      case Connectors.bridge().disconnect(ticket, key) do
        {:ok, _} ->
          # ORDER MATTERS. The install is gone from the bridge (unmounted +
          # deleted) BEFORE the token dies, so there is no window where a mounted
          # adapter holds a revoked credential and 401s on every message. Revoke
          # is idempotent, so a crash between the two leaves a token that
          # authenticates nothing — recoverable. The reverse order would leave a
          # live adapter that cannot talk.
          revoked = revoke_install_tokens(ws.id, provider, key)

          {:noreply,
           socket
           |> assign(:disconnecting, nil)
           |> load_installs()
           |> put_flash(
             :info,
             "Disconnected #{provider_name(provider)}. #{revoked} token#{plural(revoked)} revoked."
           )}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:disconnecting, nil)
           |> put_flash(:error, "Could not disconnect: #{bridge_message(reason)}")}
      end
    else
      {:error, :forbidden} ->
        {:noreply, deny(socket)}

      {:error, :not_configured} ->
        {:noreply,
         socket
         |> assign(disconnecting: nil)
         |> put_flash(:error, not_configured_message())}

      _ ->
        {:noreply, assign(socket, disconnecting: nil)}
    end
  end

  # Never crash on a stale/unknown event from an old tab.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── The connect transaction ────────────────────────────────────────────────

  defp do_connect(socket, ws, provider, install_key, credential, ticket) do
    label = Catalog.token_label(provider, install_key)

    case Auth.create_chat_token(label, @dataset, ws.id) do
      {:ok, raw, token} ->
        # `raw` lives in THIS function and nowhere else: not in the socket, not in
        # a log line, not in the flash. It goes over loopback to the bridge, which
        # seals it into chat_token_ref, and then it is unrecoverable by design.
        case Connectors.bridge().connect(ticket, credential, raw) do
          {:ok, %{install_key: ^install_key}} ->
            socket
            |> assign(:dialog, nil)
            |> load_installs()
            |> put_flash(:info, "#{provider_name(provider)} connected.")

          {:ok, %{install_key: other}} ->
            # The bridge wrote a DIFFERENT install than the one we labelled the
            # token for — the label would not match, so disconnect could never
            # revoke it. Refuse the whole thing rather than leave an orphan.
            Auth.revoke_token(token)

            dialog_error(
              socket,
              "The bridge installed #{other}, not #{install_key}. Nothing was connected."
            )

          {:error, reason} ->
            # REVOKE. A minted-but-unattached chat token is a live workspace
            # credential nobody owns.
            Auth.revoke_token(token)
            dialog_error(socket, bridge_message(reason))
        end

      {:error, reason} ->
        Logger.warning("connectors: chat-token mint failed for #{provider}: #{inspect(reason)}")
        dialog_error(socket, "Could not mint a workspace chat token.")
    end
  end

  defp revoke_install_tokens(ws_id, provider, install_key) do
    ws_id
    |> Auth.live_tokens_by_label(Catalog.token_label(provider, install_key))
    |> Enum.reduce(0, fn token, acc ->
      case Auth.revoke_token(token) do
        {:ok, _} -> acc + 1
        _ -> acc
      end
    end)
  end

  # ── Gate + helpers ─────────────────────────────────────────────────────────

  # D49. Fail-closed, both principal kinds. Called by EVERY state-changing
  # handler — including the two that only open a dialog, so the UI never offers
  # an action the confirm step will refuse.
  defp authorize(socket) do
    ws = socket.assigns[:current_workspace]
    principal = socket.assigns[:api_token] || socket.assigns[:current_user]

    if is_map(ws) and not is_nil(principal) and TenancyAuth.workspace_admin?(principal, ws.id) do
      {:ok, ws, principal}
    else
      {:error, :forbidden}
    end
  end

  defp deny(socket) do
    socket
    |> assign(dialog: nil, disconnecting: nil)
    |> put_flash(
      :error,
      "You need to be an owner or admin of this workspace to change its connectors."
    )
  end

  defp ticket(ws, provider), do: ConnectTicket.sign(ws.id, provider)

  defp present(""), do: {:error, :blank}
  defp present(credential) when is_binary(credential), do: :ok
  defp present(_), do: {:error, :blank}

  defp load_installs(socket) do
    socket
    |> assign(:installs, Catalog.installs_by_provider(socket.assigns[:current_workspace]))
    |> assign(:loaded?, true)
  end

  defp dialog_error(socket, message) do
    case socket.assigns.dialog do
      %{} = dialog -> assign(socket, :dialog, %{dialog | error: message})
      _ -> put_flash(socket, :error, message)
    end
  end

  defp bridge_message(:not_configured), do: not_configured_message()

  defp bridge_message(:unreachable),
    do:
      "The connectors bridge is not answering on this instance. Nothing was connected — " <>
        "check that barkpark-connectors is running."

  defp bridge_message({:refused, reason}) when is_binary(reason), do: reason
  defp bridge_message({:http, status}), do: "The bridge returned HTTP #{status}."
  defp bridge_message(other), do: "The bridge failed: #{inspect(other)}"

  defp not_configured_message,
    do:
      "Connect is not configured on this instance (no CONNECTORS_CONNECT_SECRET). " <>
        "The catalog is read-only."

  defp provider_name(id) do
    case Catalog.provider(id) do
      %{name: name} -> name
      _ -> id
    end
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp connected_at(%{created_at: %DateTime{} = at}),
    do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp connected_at(_), do: "—"

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="connectors-live"
      style="max-width: 960px; margin: 32px auto; padding: 0 24px; font-family: var(--font);"
    >
      <h1 class="h1" style="margin-bottom: 4px;">Connectors</h1>
      <p style="color: var(--fg-muted); margin-top: 0;">
        Talk to your agent from the places your team already is. Each connector belongs to
        <strong :if={@current_workspace}>{@current_workspace.name}</strong>
        <span :if={!@current_workspace}>this workspace</span>
        — its credentials never leave it.
      </p>

      <div
        :if={!@connect_configured?}
        data-test-id="connectors-readonly-banner"
        class="card"
        style="border: 1px solid var(--border); border-left: 3px solid var(--warning, #b7791f); border-radius: 8px; padding: 12px 16px; margin: 16px 0; background: var(--bg-card);"
      >
        <strong>Connect is not configured on this instance.</strong>
        <p class="text-sm" style="color: var(--fg-muted); margin: 4px 0 0;">
          No <code>CONNECTORS_CONNECT_SECRET</code>
          is set, so Barkpark cannot authorize a connect against the bridge. The catalog below is
          read-only. A deploy generates the secret once — see
          <code>docs/ops/connectors-deploy.md</code>.
        </p>
      </div>

      <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(380px, 1fr)); gap: 16px; margin-top: 24px;">
        <.provider_card
          :for={provider <- @providers}
          provider={provider}
          install={Map.get(@installs, provider.id)}
          loaded?={@loaded?}
          connect_configured?={@connect_configured?}
        />
      </div>

      <.connect_dialog :if={@dialog} dialog={@dialog} />

      <div
        :if={@disconnecting}
        id="connectors-disconnect-modal"
        role="dialog"
        aria-modal="true"
        data-test-id="connectors-disconnect-modal"
        style="position: fixed; inset: 0; background: rgba(0,0,0,0.4); display: flex; align-items: center; justify-content: center; z-index: 1000;"
      >
        <div
          class="card"
          style="background: var(--bg-card); color: var(--fg); padding: 24px; min-width: 420px; max-width: 560px; border-radius: 10px; display: flex; flex-direction: column; gap: 12px;"
        >
          <h2 class="h3" style="margin: 0;">
            Disconnect {provider_name(@disconnecting.provider)}?
          </h2>
          <p class="text-sm" style="color: var(--fg-muted); margin: 0;">
            The bridge unmounts <code>{@disconnecting.install_key}</code>
            and deletes the install, and Barkpark revokes the chat token it was using. Messages sent
            to it will stop reaching your agent immediately. You can reconnect by pasting the token
            again.
          </p>
          <div style="display: flex; gap: 8px; justify-content: flex-end;">
            <button type="button" class="btn" phx-click="cancel_disconnect">Cancel</button>
            <button
              type="button"
              class="btn btn-destructive"
              phx-click="confirm_disconnect"
              phx-disable-with="Disconnecting…"
              data-test-id="connectors-confirm-disconnect"
            >
              Disconnect
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :provider, :map, required: true
  attr :install, :map, default: nil
  attr :loaded?, :boolean, default: false
  attr :connect_configured?, :boolean, default: false

  defp provider_card(assigns) do
    ~H"""
    <div
      class="card"
      data-test-id={"connector-card-#{@provider.id}"}
      style="border: 1px solid var(--border); border-radius: 10px; padding: 16px; background: var(--bg-card); display: flex; flex-direction: column; gap: 10px;"
    >
      <div style="display: flex; align-items: baseline; justify-content: space-between; gap: 8px;">
        <h2 class="h3" style="margin: 0;">{@provider.name}</h2>
        <span
          data-test-id={"connector-status-#{@provider.id}"}
          class="text-sm"
          style={"border-radius: 999px; padding: .1rem .6rem; border: 1px solid var(--border); color: #{status_color(@install, @loaded?)};"}
        >
          {status_label(@install, @loaded?)}
        </span>
      </div>

      <p class="text-sm" style="margin: 0;">{@provider.blurb}</p>

      <p class="text-sm" style="margin: 0; color: var(--fg-muted);">
        <strong>What it takes:</strong> {@provider.effort}
      </p>

      <div
        :if={@install}
        data-test-id={"connector-install-#{@provider.id}"}
        class="text-sm"
        style="border-top: 1px solid var(--border); padding-top: 8px; color: var(--fg-muted);"
      >
        <div>
          Install <code>{@install.install_key}</code>
        </div>
        <div>Connected {connected_at(@install)}</div>
      </div>

      <p
        :if={@provider.gate}
        data-test-id={"connector-gate-#{@provider.id}"}
        class="text-sm"
        style="margin: 0; color: var(--fg-muted); border-left: 2px solid var(--border); padding-left: 10px;"
      >
        {@provider.gate}
      </p>

      <div style="display: flex; gap: 8px; margin-top: auto; padding-top: 4px;">
        <button
          :if={@provider.connectable? and is_nil(@install) and @connect_configured?}
          type="button"
          class="btn btn-primary"
          phx-click="open_connect"
          phx-value-provider={@provider.id}
          data-test-id={"connector-connect-#{@provider.id}"}
        >
          Connect
        </button>

        <button
          :if={@install}
          type="button"
          class="btn btn-destructive"
          phx-click="open_disconnect"
          phx-value-provider={@provider.id}
          data-test-id={"connector-disconnect-#{@provider.id}"}
        >
          Disconnect
        </button>

        <a
          :if={@provider.help_url}
          href={@provider.help_url}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-sm"
        >
          How to get a token
        </a>
      </div>
    </div>
    """
  end

  attr :dialog, :map, required: true

  defp connect_dialog(assigns) do
    assigns = assign(assigns, :card, Catalog.provider(assigns.dialog.provider))

    ~H"""
    <div
      id="connectors-connect-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="connectors-connect-title"
      data-test-id="connectors-connect-modal"
      style="position: fixed; inset: 0; background: rgba(0,0,0,0.4); display: flex; align-items: center; justify-content: center; z-index: 1000;"
    >
      <div
        class="card"
        style="background: var(--bg-card); color: var(--fg); padding: 24px; min-width: 480px; max-width: 620px; border-radius: 10px; display: flex; flex-direction: column; gap: 12px;"
      >
        <h2 id="connectors-connect-title" class="h3" style="margin: 0;">
          Connect {@card.name}
        </h2>

        <p
          :if={@dialog.error}
          data-test-id="connectors-dialog-error"
          class="text-sm"
          style="margin: 0; color: var(--danger, #c53030); border-left: 2px solid var(--danger, #c53030); padding-left: 10px;"
        >
          {@dialog.error}
        </p>

        <%= if @dialog.step == :paste do %>
          <form phx-submit="validate_credential" style="display: flex; flex-direction: column; gap: 10px;">
            <label class="text-sm" for="connector-credential">{@card.credential_label}</label>
            <input
              id="connector-credential"
              type="password"
              name="credential"
              value={@dialog.credential}
              autocomplete="off"
              spellcheck="false"
              phx-debounce="blur"
              data-test-id="connectors-credential-input"
              style="padding: 8px; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); color: var(--fg); font-family: var(--font-mono, monospace);"
            />
            <p :if={@card.credential_hint} class="text-sm" style="margin: 0; color: var(--fg-muted);">
              {@card.credential_hint}
            </p>
            <p class="text-sm" style="margin: 0; color: var(--fg-muted);">
              Barkpark checks the token with {@card.name} before storing anything. It is sealed on
              this box and never leaves it.
            </p>
            <div style="display: flex; gap: 8px; justify-content: flex-end;">
              <button type="button" class="btn" phx-click="close_dialog">Cancel</button>
              <button
                type="submit"
                class="btn btn-primary"
                phx-disable-with="Checking with the provider…"
                data-test-id="connectors-validate-submit"
              >
                Check token
              </button>
            </div>
          </form>
        <% else %>
          <div data-test-id="connectors-confirm-step" style="display: flex; flex-direction: column; gap: 10px;">
            <p class="text-sm" style="margin: 0;">
              That token belongs to
              <strong data-test-id="connectors-candidate-name">{@dialog.candidate.display_name}</strong>
              (<code>{@dialog.candidate.install_key}</code>). Connecting mints a chat token for this
              workspace, hands it to the bridge, and mounts the bot — no restart.
            </p>
            <div style="display: flex; gap: 8px; justify-content: flex-end;">
              <button type="button" class="btn" phx-click="close_dialog">Cancel</button>
              <button
                type="button"
                class="btn btn-primary"
                phx-click="confirm_connect"
                phx-disable-with="Connecting…"
                data-test-id="connectors-confirm-connect"
              >
                Yes, connect it
              </button>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp status_label(%{}, _loaded?), do: "Connected"
  defp status_label(nil, true), do: "Not connected"
  defp status_label(nil, false), do: "Loading…"

  defp status_color(%{}, _loaded?), do: "var(--success, #2f855a)"
  defp status_color(nil, _loaded?), do: "var(--fg-muted)"
end
