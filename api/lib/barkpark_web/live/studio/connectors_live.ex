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
    * Slack connects over OAUTH (Add to Slack), not the paste modal (D62). The
      card renders an external `<a>` carrying a signed connect ticket as `state`;
      Studio first stages the workspace-bound chat token over LOOPBACK (D63) so
      the public callback can join it. If the instance has no Slack app configured
      (no client id / public URL) the card shows an honest note, never a broken
      button.
    * A provider we cannot honestly connect (Teams needs your org's Azure admin;
      WhatsApp needs Meta App Review; iMessage needs a Mac you own) shows its gate
      as prose and NO button.

  Zero installs exist anywhere today. Nothing here seeds one.
  """

  use BarkparkWeb, :live_view

  import BarkparkWeb.Studio.PageScroll

  require Logger

  alias Barkpark.Auth
  alias Barkpark.Connectors
  alias Barkpark.Connectors.Catalog
  alias Barkpark.Connectors.ConnectTicket
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  # How often the OAuth-return poll re-reads installs while a connect is in-flight
  # (D179). Bounded: it only reschedules while a staged link is showing and the
  # install has not landed, so it stops on its own once the card is Connected.
  @oauth_poll_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Connectors",
       providers: Catalog.providers(),
       tool_providers: Catalog.tool_providers(),
       installs: %{},
       loaded?: false,
       connect_configured?: Connectors.connect_configured?(),
       # A scope switch from here re-opens Connectors under the new scope.
       scope_subpath: "/connectors",
       dialog: nil,
       disconnecting: nil,
       # The OAuth surface, keyed by provider id (D102): each oauth-mode provider
       # (Slack channel, Linear tool) gets `%{add_url, gate, cta_label}` on reload —
       # either a ready authorize link or an honest note about why there is none.
       # A per-provider MAP, never page-global scalars: Slack's URL must not
       # broadcast into Linear's card (the D85 landmine).
       oauth: %{}
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    # The install read is a real cross-schema query; the disconnected render is
    # discarded and this page is admin-gated (no crawler consumes the dead HTML),
    # so load once, on connect. Until then the cards render "Loading…", never a
    # confident "Not connected" the read might contradict.
    if connected?(socket) do
      {:noreply, socket |> reload() |> schedule_oauth_poll()}
    else
      {:noreply, socket}
    end
  end

  # ── OAuth return poll (D179) ─────────────────────────────────────────────────

  # The OAuth return is a redirect in ANOTHER tab: the public callback lands the
  # install, but THIS view — the one that launched the flow — never re-reads, so
  # its card sits on the Add-to-Slack link while the connection is already live. A
  # bounded server poll closes that. It re-reads ONLY the installs (load_installs,
  # never reload): reload re-runs prepare_oauth, and Slack's oauth entry REVOKES +
  # re-mints its staged chat token on every build — doing that mid-flight would
  # kill the very token the pending callback is about to join. The install read is
  # all the card needs: once installs is non-empty the status chip flips to
  # Connected and the add-to-slack link's `@installs == []` guard hides it.
  @impl true
  def handle_info(:oauth_poll_tick, socket) do
    socket = load_installs(socket)
    {:noreply, schedule_oauth_poll(socket)}
  end

  # Never crash on a stale message from an old timer/tab.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Schedule the next poll ONLY while a staged OAuth connect is genuinely
  # in-flight — bounded by construction. Stops the moment the install lands (or if
  # no oauth link is showing at all), so a Connected card holds no timers.
  defp schedule_oauth_poll(socket) do
    if connected?(socket) and oauth_pending?(socket) do
      Process.send_after(self(), :oauth_poll_tick, @oauth_poll_ms)
    end

    socket
  end

  # True while at least one OAuth provider is showing a staged connect link
  # (add_url) AND has no install yet — the window in which a callback in another
  # tab can land an install this view has not read. Workspace-scoped by
  # construction: `installs` is `Catalog.installs_by_provider(current_workspace)`,
  # so a poll can never reflect another tenant's install.
  defp oauth_pending?(socket) do
    installs = socket.assigns.installs

    Enum.any?(socket.assigns.oauth, fn {provider_id, entry} ->
      not is_nil(entry.add_url) and Map.get(installs, provider_id, []) == []
    end)
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

  def handle_event("open_disconnect", %{"provider" => provider, "install_key" => key}, socket) do
    # Key by (provider, install_key), NEVER bare provider: a workspace can hold
    # two installs of one provider (two Telegram bots), so the bare-provider
    # lookup would always open the FIRST and leave the second undisconnectable.
    install =
      socket.assigns.installs
      |> Map.get(provider, [])
      |> Enum.find(&(&1.install_key == key))

    case {authorize(socket), install} do
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
           |> reload()
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

  # A CHANNEL connect mints a workspace chat token and ships it; a TOOL connect
  # (github/linear — D101) mints NOTHING and passes `nil` — the bridge seals only
  # the pasted credential, `chat_token_ref` stays NULL. Dispatch on the provider's
  # direction so the tool arm never orphans a minted credential.
  defp do_connect(socket, ws, provider, install_key, credential, ticket) do
    case Catalog.direction(provider) do
      :tool -> connect_tool(socket, provider, install_key, credential, ticket)
      :channel -> connect_channel(socket, ws, provider, install_key, credential, ticket)
    end
  end

  # THE TOOL ARM (D101). No `Auth.create_chat_token`, so no revoke arms — nothing
  # was minted to leak. Same 3-branch result handling as the channel arm: the
  # happy path, the wrong-key mismatch (refuse, but nothing to revoke), and the
  # bridge error.
  defp connect_tool(socket, provider, install_key, credential, ticket) do
    case Connectors.bridge().connect(ticket, credential, nil) do
      {:ok, %{install_key: ^install_key}} ->
        socket
        |> assign(:dialog, nil)
        |> reload()
        |> put_flash(:info, "#{provider_name(provider)} connected.")

      {:ok, %{install_key: other}} ->
        dialog_error(
          socket,
          "The bridge installed #{other}, not #{install_key}. Nothing was connected."
        )

      {:error, reason} ->
        dialog_error(socket, bridge_message(reason))
    end
  end

  defp connect_channel(socket, ws, provider, install_key, credential, ticket) do
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
            |> reload()
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
    # The install's own labelled token — and, for Slack, ALSO the OAuth-minted
    # `connector:slack:oauth` label as a DEFENSIVE net (D179). The Add-to-Slack
    # flow mints its chat token BEFORE the install key is known (the OAuth callback
    # learns team_id only after the redirect), so it starts life labelled
    # `connector:slack:oauth`. `reconcile_slack_oauth_label/1` relabels it to
    # `connector:slack:<install_key>` on the reload after the callback, so by
    # disconnect time the token normally already carries the install_key label and
    # the primary path revokes it there. The oauth label stays in this set only to
    # catch the pre-reconcile window (a disconnect racing the very first reload) —
    # a no-op once the relabel has run.
    install_token_labels(provider, install_key)
    |> Enum.flat_map(&Auth.live_tokens_by_label(ws_id, &1))
    |> Enum.reduce(0, fn token, acc ->
      case Auth.revoke_token(token) do
        {:ok, _} -> acc + 1
        _ -> acc
      end
    end)
  end

  defp install_token_labels("slack", install_key) do
    [Catalog.token_label("slack", install_key), slack_oauth_label()]
  end

  defp install_token_labels(provider, install_key) do
    [Catalog.token_label(provider, install_key)]
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

  # Read the installs, THEN prepare the OAuth surface (which depends on whether an
  # install already exists per provider). Called on connect and after any
  # connect/disconnect that changes what is installed.
  defp reload(socket) do
    socket
    |> load_installs()
    |> reconcile_slack_oauth_label()
    |> prepare_oauth()
  end

  # Close the D48 filed limitation (see `install_token_labels/2`). The Add-to-Slack
  # flow (D62/D63) mints its chat token as `connector:slack:oauth` BEFORE the
  # callback knows the team_id. Once an install has landed we DO know the
  # install_key, so relabel that OAuth token to the canonical
  # `connector:slack:<install_key>` — after this, Slack DISCONNECT revokes by the
  # same single install_key label as every other provider. A relabel, never a
  # revoke: the live install keeps its credential. Idempotent + workspace-scoped
  # (`live_tokens_by_label` is ws-bound); a no-op when no oauth-labelled token
  # remains (already reconciled) or no Slack install exists yet (pre-callback).
  # Best-effort to the head install: a workspace holds at most one pending OAuth
  # token, so the common single-install case is exact; the dual-label revoke in
  # `install_token_labels/2` remains as a defensive net for the pre-reconcile
  # window.
  defp reconcile_slack_oauth_label(socket) do
    with %{id: ws_id} <- socket.assigns[:current_workspace],
         [%{install_key: key} | _] <- Map.get(socket.assigns.installs, "slack", []) do
      canonical = Catalog.token_label("slack", key)

      ws_id
      |> Auth.live_tokens_by_label(slack_oauth_label())
      |> Enum.each(&Auth.relabel_token(&1, canonical))
    end

    socket
  end

  # THE OAUTH SURFACE (D62/D102). Build the per-provider `oauth` map — one entry
  # per oauth-mode provider (Slack channel, Linear tool). A per-provider MAP, never
  # page-global scalars: Slack's URL must never render on Linear's card (the D85
  # landmine). An entry is `%{add_url, gate, cta_label}`; a provider with nothing
  # to offer (already connected / not an admin / no connect seam) is simply absent
  # from the map, and its card renders neither link nor gate.
  defp prepare_oauth(socket) do
    oauth =
      (Catalog.providers() ++ Catalog.tool_providers())
      |> Enum.filter(&(&1.connect_mode == :oauth))
      |> Enum.reduce(%{}, fn provider, acc ->
        case oauth_entry(socket, provider) do
          nil -> acc
          entry -> Map.put(acc, provider.id, entry)
        end
      end)

    assign(socket, :oauth, oauth)
  end

  # Decide, honestly, which state a single oauth provider's card is in. The two
  # "no button, no gate" cases (already connected / not an admin or no connect
  # seam) return nil; a configured provider returns a ready link; an unconfigured
  # one returns an honest note. Provider-specific computation lives in
  # `build_oauth_entry/2`.
  defp oauth_entry(socket, provider) do
    cond do
      # An install exists: the card shows Disconnect, not the connect link.
      Map.has_key?(socket.assigns.installs, provider.id) ->
        nil

      # A non-admin (mounts the page, cannot change connectors — D49) or an
      # instance with no connect seam: no link, and the read-only banner already
      # explains the latter.
      match?({:error, :forbidden}, authorize(socket)) or not socket.assigns.connect_configured? ->
        nil

      true ->
        build_oauth_entry(socket, provider)
    end
  end

  # SLACK = oauth-with-staging (D62/D63). Mint a workspace-bound chat token, STAGE
  # it over loopback under a fresh connect ticket's nonce, and hand back the
  # Add-to-Slack URL carrying that ticket as `state`. The mint+stage+revoke LADDER
  # is byte-identical to the original `stage_slack_oauth`; only the return shape
  # changed (an entry map, not socket assigns). The raw token rides the loopback
  # stage, NEVER the URL.
  defp build_oauth_entry(socket, %{id: "slack"} = provider) do
    case Catalog.slack_oauth_config() do
      nil ->
        oauth_gate(
          provider,
          "Add to Slack is not configured on this instance — it needs a Slack app " <>
            "(a client id from api.slack.com and a public callback URL). See " <>
            "docs/ops/slack-app.md."
        )

      cfg ->
        {:ok, ws, _principal} = authorize(socket)

        # Any prior unclicked OAuth token for this workspace is stale on this path
        # (no Slack install exists), so revoke it before minting a fresh one — at
        # most one unattached credential at a time, never a growing pile.
        revoke_slack_oauth_tokens(ws.id)

        with {:ok, ticket} <- ConnectTicket.sign(ws.id, "slack"),
             {:ok, raw, token} <- Auth.create_chat_token(slack_oauth_label(), @dataset, ws.id) do
          case Connectors.bridge().stage_pending(ticket, raw) do
            {:ok, _} ->
              oauth_link(provider, Catalog.slack_authorize_url(ticket, cfg))

            {:error, reason} ->
              # Never leave a minted-but-unstaged token live — a chat token with no
              # pending row is a workspace credential nobody owns.
              Auth.revoke_token(token)

              oauth_gate(
                provider,
                "Add to Slack is unavailable right now: #{bridge_message(reason)}"
              )
          end
        else
          {:error, reason} ->
            Logger.warning("connectors: could not prepare Add to Slack: #{inspect(reason)}")
            oauth_gate(provider, "Could not prepare Add to Slack.")
        end
    end
  end

  # LINEAR = oauth-URL-only (D78/D103: "the write IS the connect"). NO
  # `create_chat_token`, NO `stage_pending`, NO revoke — a tool install lands
  # `chat_token_ref` NULL bridge-side, so there is nothing to mint or stage ahead
  # of the redirect. Just sign a ticket and build the authorize URL. When the
  # instance has no Linear OAuth app configured (the honest state at merge — no env
  # plumbing exists), render the not-configured note.
  defp build_oauth_entry(socket, %{id: "linear"} = provider) do
    case Catalog.linear_oauth_config() do
      nil ->
        oauth_gate(
          provider,
          "Connect Linear is not configured on this instance — it needs a Linear OAuth app " <>
            "(a client id from linear.app/settings/api and a public callback URL). See " <>
            "docs/ops/linear-app.md."
        )

      cfg ->
        {:ok, ws, _principal} = authorize(socket)

        case ConnectTicket.sign(ws.id, "linear") do
          {:ok, ticket} ->
            oauth_link(provider, Catalog.linear_authorize_url(ticket, cfg))

          {:error, reason} ->
            Logger.warning("connectors: could not prepare Connect Linear: #{inspect(reason)}")
            oauth_gate(provider, "Could not prepare Connect Linear.")
        end
    end
  end

  defp oauth_link(provider, url),
    do: %{add_url: url, gate: nil, cta_label: oauth_cta_label(provider)}

  defp oauth_gate(provider, note),
    do: %{add_url: nil, gate: note, cta_label: oauth_cta_label(provider)}

  # The connect CTA text, provider-derived — "Add to Slack" / "Connect Linear" —
  # so the hardcoded anchor never reads "Add to Slack" on Linear's card.
  defp oauth_cta_label(%{id: "slack"}), do: "Add to Slack"
  defp oauth_cta_label(%{name: name}), do: "Connect #{name}"

  defp slack_oauth_label, do: Catalog.token_label("slack", "oauth")

  defp revoke_slack_oauth_tokens(ws_id) do
    ws_id
    |> Auth.live_tokens_by_label(slack_oauth_label())
    |> Enum.each(&Auth.revoke_token/1)
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
    <%!-- studio-shell child contract (BarkparkWeb.Studio.PageScroll): the
          shell is height:100vh + overflow:hidden, so a bare centred column
          here is CLIPPED and its tail is unreachable by any input. This
          wrapper fills the shell and owns the scroll; the centred column
          below is unchanged, so the reading measure is too. --%>
    <.studio_page_scroll>
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
        style="border: 1px solid var(--border); border-left: 3px solid var(--warn); border-radius: 8px; padding: 12px 16px; margin: 16px 0; background: var(--bg-card);"
      >
        <strong>Connect is not configured on this instance.</strong>
        <p class="text-sm" style="color: var(--fg-muted); margin: 4px 0 0;">
          No <code>CONNECTORS_CONNECT_SECRET</code>
          is set, so Barkpark cannot authorize a connect against the bridge. The catalog below is
          read-only. A deploy generates the secret once — see
          <code>docs/ops/connectors-deploy.md</code>.
        </p>
      </div>

      <section data-test-id="connectors-section-channels">
        <h2 class="h2" style="margin: 32px 0 4px;">Channels</h2>
        <p class="text-sm" style="color: var(--fg-muted); margin: 0 0 8px;">
          Places your team already talks — connect one and messages reach your agent there.
        </p>
        <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(380px, 1fr)); gap: 16px; margin-top: 8px;">
          <.provider_card
            :for={provider <- @providers}
            provider={provider}
            installs={Map.get(@installs, provider.id, [])}
            loaded?={@loaded?}
            connect_configured?={@connect_configured?}
            oauth={Map.get(@oauth, provider.id)}
          />
        </div>
      </section>

      <section data-test-id="connectors-section-tools">
        <h2 class="h2" style="margin: 32px 0 4px;">Tools</h2>
        <p class="text-sm" style="color: var(--fg-muted); margin: 0 0 8px;">
          Services your agent can ACT on — connect one and it can open pull requests, file
          issues, and more on your behalf.
        </p>
        <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(380px, 1fr)); gap: 16px; margin-top: 8px;">
          <.provider_card
            :for={provider <- @tool_providers}
            provider={provider}
            installs={Map.get(@installs, provider.id, [])}
            loaded?={@loaded?}
            connect_configured?={@connect_configured?}
            oauth={Map.get(@oauth, provider.id)}
          />
        </div>
      </section>

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
    </.studio_page_scroll>
    """
  end

  attr :provider, :map, required: true
  # EVERY install for this provider in this workspace (D161) — a list, one row per
  # install. `[]` means none connected. A provider is never collapsed to a single
  # install: the second one must be visible AND disconnectable.
  attr :installs, :list, default: []
  attr :loaded?, :boolean, default: false
  attr :connect_configured?, :boolean, default: false
  # The oauth entry for THIS provider (or nil): %{add_url, gate, cta_label}.
  attr :oauth, :map, default: nil

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
          style={"border-radius: 999px; padding: .1rem .6rem; border: 1px solid var(--border); color: #{status_color(@installs, @loaded?)};"}
        >
          {status_label(@installs, @loaded?)}
        </span>
      </div>

      <p class="text-sm" style="margin: 0;">{@provider.blurb}</p>

      <p class="text-sm" style="margin: 0; color: var(--fg-muted);">
        <strong>What it takes:</strong> {@provider.effort}
      </p>

      <div
        :for={install <- @installs}
        data-test-id={"connector-install-#{@provider.id}"}
        class="text-sm"
        style="border-top: 1px solid var(--border); padding-top: 8px; color: var(--fg-muted);"
      >
        <div>
          Install <code>{install.install_key}</code>
        </div>
        <div>Connected {connected_at(install)}</div>
        <.webhook_endpoint_row provider_id={@provider.id} install_key={install.install_key} />
      </div>

      <p
        :if={@provider.gate}
        data-test-id={"connector-gate-#{@provider.id}"}
        class="text-sm"
        style="margin: 0; color: var(--fg-muted); border-left: 2px solid var(--border); padding-left: 10px;"
      >
        {@provider.gate}
      </p>

      <p
        :if={
          @provider.connect_mode == :oauth and @loaded? and @installs == [] and
            not is_nil(@oauth) and not is_nil(@oauth.gate)
        }
        data-test-id={"connector-oauth-gate-#{@provider.id}"}
        class="text-sm"
        style="margin: 0; color: var(--fg-muted); border-left: 2px solid var(--border); padding-left: 10px;"
      >
        {@oauth.gate}
      </p>

      <div style="display: flex; gap: 8px; margin-top: auto; padding-top: 4px;">
        <%!-- `@loaded?` is not decoration: until the install read lands we do not
        KNOW that this provider is unconnected, and a Connect button offered beside
        a "Loading…" chip is the UI asserting something it has not read yet. --%>
        <button
          :if={@provider.connectable? and @loaded? and @installs == [] and @connect_configured?}
          type="button"
          class="btn btn-primary"
          phx-click="open_connect"
          phx-value-provider={@provider.id}
          data-test-id={"connector-connect-#{@provider.id}"}
        >
          Connect
        </button>

        <%!-- OAuth providers (Slack channel, Linear tool) connect over an external
        link, NOT phx-click into the paste flow. The href carries a signed connect
        ticket as `state`. For Slack the pending chat token was already staged over
        loopback (D62/D63); for Linear the write IS the connect (D78) — no staging.
        target=_blank makes the callback page's "close this tab and return to
        Studio" copy literally true. --%>
        <a
          :if={
            @provider.connect_mode == :oauth and @loaded? and @installs == [] and
              @connect_configured? and not is_nil(@oauth) and not is_nil(@oauth.add_url)
          }
          href={@oauth.add_url}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-primary"
          data-test-id={"connector-add-to-slack-#{@provider.id}"}
        >
          {@oauth.cta_label}
        </a>

        <button
          :for={install <- @installs}
          type="button"
          class="btn btn-destructive"
          phx-click="open_disconnect"
          phx-value-provider={@provider.id}
          phx-value-install_key={install.install_key}
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

  # THE WEBHOOK / INTERACTIONS URL (D260). A copyable, DISPLAY-ONLY mirror of the
  # ops runbooks: Phoenix mounts no route — the Node bridge serves this URL behind
  # Caddy (D34/D39). Rendered per install because a PATH-keyed provider's URL
  # carries the install_key. A provider with no inbound webhook (telegram polling,
  # imessage, the github/linear tools) has no spec and renders nothing.
  #
  # When the public base is not configured (`Catalog.webhook_endpoint` returns a
  # nil `:url`) the row is HONEST — "endpoint unavailable" — never a localhost or
  # loopback guess an operator would paste into a vendor portal and watch fail.
  #
  # The copy button reuses `CSP.copy_data_url_onclick/0` with `data-url={url}`: that
  # exact handler hash is CSP-allowlisted (browser_csp_test.exs). A hand-rolled
  # inline onclick with the URL interpolated into the JS would be silently blocked.
  attr :provider_id, :string, required: true
  attr :install_key, :string, required: true

  defp webhook_endpoint_row(assigns) do
    assigns =
      assign(
        assigns,
        :endpoint,
        Catalog.webhook_endpoint(assigns.provider_id, assigns.install_key)
      )

    ~H"""
    <div
      :if={@endpoint}
      data-test-id={"connector-webhook-#{@provider_id}"}
      style="margin-top: 8px;"
    >
      <div class="text-sm" style="color: var(--fg-muted); font-weight: 600;">
        {@endpoint.label}
      </div>

      <div
        :if={@endpoint.url}
        style="display: flex; gap: 8px; align-items: center; margin-top: 2px;"
      >
        <code
          data-test-id={"connector-webhook-url-#{@provider_id}"}
          style="flex: 1; min-width: 0; overflow-wrap: anywhere; word-break: break-all; padding: 4px 6px; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); color: var(--fg);"
        >{@endpoint.url}</code>
        <button
          type="button"
          class="btn btn-sm"
          data-url={@endpoint.url}
          onclick={BarkparkWeb.CSP.copy_data_url_onclick()}
          data-test-id={"connector-webhook-copy-#{@provider_id}"}
          title="Copy webhook URL"
        >
          Copy
        </button>
      </div>

      <div
        :if={is_nil(@endpoint.url)}
        data-test-id={"connector-webhook-unavailable-#{@provider_id}"}
        class="text-sm"
        style="margin-top: 2px; color: var(--fg-muted);"
      >
        Endpoint unavailable — public base not configured.
      </div>

      <p :if={@endpoint.help} class="text-sm" style="margin: 4px 0 0; color: var(--fg-muted);">
        {@endpoint.help}
      </p>
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
          style="margin: 0; color: var(--danger); border-left: 2px solid var(--danger); padding-left: 10px;"
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

  defp status_label([_ | _], _loaded?), do: "Connected"
  defp status_label([], true), do: "Not connected"
  defp status_label([], false), do: "Loading…"

  defp status_color([_ | _], _loaded?), do: "var(--ok)"
  defp status_color([], _loaded?), do: "var(--fg-muted)"
end
