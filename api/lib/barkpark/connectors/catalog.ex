defmodule Barkpark.Connectors.Catalog do
  @moduledoc """
  The Connectors CATALOG — what a workspace CAN connect, and what it HAS
  connected (Connectors D47/D51/D54/D55).

  Two halves:

    * **The providers** (`providers/0`) — six static descriptors, each wearing
      its REAL onboarding weight on its face. This is a product surface, not an
      admin table: an operator must be able to see, before clicking anything,
      that Telegram is a 60-second paste and WhatsApp is weeks of Meta review.

    * **The installs** (`installs_for_workspace/1`) — the cross-schema read of
      `chat_bridge.connector_installs`, scoped to ONE workspace, selecting no
      secret.

  ## Why `connectable?` is declared HERE and not asked of the bridge

  The connect wire (D50/D51) is exactly three routes — `/connect/validate`,
  `/connect`, `/disconnect`. There is deliberately NO catalog endpoint, so
  Studio cannot ask the bridge "which providers have a `connect` member?".
  The flags below therefore MIRROR the bridge's registry (a provider is
  connectable iff its `Connector` declares `connect: { mode: "paste", … }`).

  DRIFT POSTURE (honest): if the bridge later adds `connect` to a provider and
  this list is not updated, the card simply stays non-connectable — a missing
  button, never a broken one. If this list claims connectable for a provider the
  bridge cannot connect, `/connect/validate` returns a typed refusal and the UI
  shows it. Both directions fail visibly and safely; neither fakes a Connected
  state.

  ## Zero installs exist anywhere

  Nothing is seeded. `installs_for_workspace/1` on a fresh workspace returns
  `[]` and the catalog renders every card as "Not connected" — which is the
  truth today.
  """

  import Ecto.Query

  alias Barkpark.Connectors.Install
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Workspace

  @typedoc """
  A provider card.

    * `:connectable?` — the bridge declares a paste-mode `connect` for it.
    * `:connect_mode` — HOW a connectable provider connects. `:paste` opens the
      credential modal (Telegram, Discord). `:oauth` renders an external
      "Add to Slack" link carrying a signed connect ticket (Slack). `nil` means
      catalog-visible but not connectable (Teams/WhatsApp/iMessage show `:gate`).
      `:oauth` and `:connectable?` are DISJOINT: OAuth does not reuse the paste
      handlers, so a Slack card must NOT grow a paste Connect button.
    * `:gate` — the honest, human-readable reason a non-connectable provider is
      not connectable. Rendered on the card in place of the button.
    * `:effort` — the onboarding weight, stated up front.
  """
  @type connect_mode :: :paste | :oauth | nil

  @type direction :: :tool | :channel

  @type provider :: %{
          :id => String.t(),
          :name => String.t(),
          :blurb => String.t(),
          :effort => String.t(),
          :connectable? => boolean(),
          :connect_mode => connect_mode(),
          :credential_label => String.t() | nil,
          :credential_hint => String.t() | nil,
          :help_url => String.t() | nil,
          :gate => String.t() | nil,
          # DIRECTION (D99): tool connectors (github/linear — the OTHER, outbound
          # direction) carry `direction: :tool`. Channel providers omit the key and
          # are `:channel` by default (see `direction/1`).
          optional(:direction) => direction()
        }

  @providers [
    %{
      id: "telegram",
      name: "Telegram",
      blurb: "Talk to your agent in a Telegram DM or group.",
      effort: "About 60 seconds — message @BotFather, create a bot, paste its token.",
      connectable?: true,
      connect_mode: :paste,
      credential_label: "Bot token",
      credential_hint: "Looks like 123456789:AA… — BotFather hands it to you once.",
      help_url: "https://core.telegram.org/bots/features#botfather",
      gate: nil
    },
    %{
      id: "discord",
      name: "Discord",
      blurb: "Talk to your agent in your Discord server.",
      effort:
        "About five steps in the Discord developer portal — create an application, add a bot, " <>
          "enable the Message Content intent, invite it to your server, then paste its token.",
      connectable?: true,
      connect_mode: :paste,
      credential_label: "Bot token",
      credential_hint: "From Developer Portal → your application → Bot → Reset Token.",
      help_url: "https://discord.com/developers/applications",
      gate: nil
    },
    %{
      id: "slack",
      name: "Slack",
      blurb: "Talk to your agent from a Slack channel or DM.",
      effort:
        "One click — Add to Slack, pick your workspace, and approve the bot. No token to paste.",
      # OAuth, not paste: Slack connects by the Add-to-Slack redirect, which does
      # not reuse the paste modal — so `connectable?` (which drives the paste
      # Connect button) stays false while `connect_mode` names the real flow.
      connectable?: false,
      connect_mode: :oauth,
      credential_label: nil,
      credential_hint: nil,
      help_url: "https://api.slack.com/apps",
      # No gate: the OAuth button IS the connect surface now. The card falls back
      # to an honest "needs a Slack app configured" note only when the instance has
      # no Slack client id / public URL (see `connectors_live.ex`) — never a lie
      # about a working button.
      gate: nil
    },
    %{
      id: "teams",
      name: "Microsoft Teams",
      blurb: "Talk to your agent from Teams.",
      effort: "Your organisation's Azure admin must consent to the Barkpark bot.",
      connectable?: false,
      connect_mode: nil,
      credential_label: nil,
      credential_hint: nil,
      help_url: nil,
      gate:
        "Teams runs on one multi-tenant Azure bot, so there is no token to paste — " <>
          "instead your org's Azure admin has to grant consent. Barkpark cannot do that " <>
          "on your behalf. See docs/ops/teams-azure-bot.md."
    },
    %{
      id: "whatsapp",
      name: "WhatsApp",
      blurb: "Talk to your agent over WhatsApp Business.",
      effort:
        "Weeks, not minutes — Meta Business verification, a WABA phone number, " <>
          "and App Review for Advanced Access.",
      connectable?: false,
      connect_mode: nil,
      credential_label: nil,
      credential_hint: nil,
      help_url: nil,
      gate:
        "WhatsApp needs a Meta app you own (access token, app secret, phone number id, " <>
          "verify token) plus App Review — without it your number can only message about " <>
          "five test recipients. Paste-a-token cannot express that yet."
    },
    %{
      id: "imessage",
      name: "iMessage",
      blurb: "Talk to your agent from Messages on Apple devices.",
      effort: "Needs a Mac you own, running all the time, with Full Disk Access.",
      connectable?: false,
      connect_mode: nil,
      credential_label: nil,
      credential_hint: nil,
      help_url: nil,
      gate:
        "Self-hosted only (CONNECTORS_PROFILE=self-hosted). iMessage has no official " <>
          "adapter: it drives a real Mac with a real Apple ID, one workspace per Mac, and " <>
          "any macOS update can break it. Barkpark Cloud will never run it for you."
    }
  ]

  # ── TOOL connectors (the OTHER direction — D99/D69/D77) ─────────────────────
  #
  # These are OUTBOUND connectors: the agent ACTS on the service (opens a GitHub
  # PR, files a Linear issue) rather than a human talking to the agent through a
  # channel. They live in a SEPARATE list, never merged into `@providers`, for
  # two reasons:
  #
  #   * `providers/0` stays the CHANNEL catalog — the two existing `providers()`
  #     test loops and the drift gate's channel extractor both depend on it being
  #     channel-only.
  #   * the connectors drift gate mirrors channel and tool sets INDEPENDENTLY
  #     (variant B): `@tool_providers` is the catalog side of the tool-set check,
  #     scanned by `extract_catalog_tools()` exactly as `@providers` is by
  #     `extract_catalog()`.
  #
  # EXACTLY two entries, no speculative future providers (a wired tool-set gate
  # reds immediately on any catalog-only entry):
  #
  #   * github — `connect_mode: :paste` (a fine-grained PAT is pasted, W7),
  #     `connectable?: true` (it opens the paste modal, reusing the connect loop).
  #   * linear — `connect_mode: :oauth` (authorize→callback, W8), `connectable?:
  #     false` (OAuth does not reuse the paste modal, exactly like Slack).
  @tool_providers [
    %{
      id: "github",
      name: "GitHub",
      blurb: "Let your agent open pull requests, file issues, and comment on GitHub.",
      effort:
        "Paste a fine-grained personal access token — GitHub Settings → Developer settings → " <>
          "Fine-grained tokens. Scope it to the repos and permissions you want the agent to have.",
      connectable?: true,
      connect_mode: :paste,
      direction: :tool,
      credential_label: "Personal access token",
      credential_hint: "Starts with github_pat_… — GitHub shows it once when you create it.",
      help_url: "https://github.com/settings/tokens?type=beta",
      gate: nil
    },
    %{
      id: "linear",
      name: "Linear",
      blurb: "Let your agent create and update Linear issues from your conversations.",
      effort:
        "One click — Connect Linear, authorize Barkpark in Linear, and you are done. " <>
          "No token to paste.",
      # OAuth, not paste (mirrors Slack): Linear connects by the authorize
      # redirect, which does not reuse the paste modal — so `connectable?` (which
      # drives the paste Connect button) stays false while `connect_mode` names the
      # real flow. `:oauth` and `:connectable?` are DISJOINT.
      connectable?: false,
      connect_mode: :oauth,
      direction: :tool,
      credential_label: nil,
      credential_hint: nil,
      help_url: "https://linear.app/settings/api",
      # No gate: the OAuth link IS the connect surface. The card falls back to an
      # honest "needs a Linear OAuth app configured" note only when the instance
      # has no Linear client id / public URL (see `connectors_live.ex`).
      gate: nil
    }
  ]

  @doc "Every CHANNEL provider card, in catalog order (connectable first)."
  @spec providers() :: [provider()]
  def providers, do: @providers

  @doc """
  Every TOOL connector card (the OUTBOUND direction — D99). Disjoint from
  `providers/0`; rendered in its own Studio section.
  """
  @spec tool_providers() :: [provider()]
  def tool_providers, do: @tool_providers

  @doc "One provider card by id — CHANNEL or TOOL — or nil."
  @spec provider(String.t()) :: provider() | nil
  def provider(id) when is_binary(id),
    do: Enum.find(@providers ++ @tool_providers, &(&1.id == id))

  def provider(_), do: nil

  @doc """
  The DIRECTION of a provider id — `:tool` (outbound; github/linear) or
  `:channel` (inbound; everything else). An unknown id is `:channel` (the
  fail-closed default: the connect loop's channel arm mints a chat token, which
  is strictly safer than skipping the mint for something we cannot classify).
  """
  @spec direction(String.t()) :: direction()
  def direction(id) when is_binary(id) do
    case provider(id) do
      %{direction: dir} -> dir
      _ -> :channel
    end
  end

  def direction(_), do: :channel

  @doc "True when the bridge declares a paste-mode connect for `id` (D51). Covers both lists."
  @spec connectable?(String.t()) :: boolean()
  def connectable?(id) do
    case provider(id) do
      %{connectable?: true} -> true
      _ -> false
    end
  end

  # The bot scopes the Add-to-Slack flow requests — the SAME list as the bridge's
  # `connectors/src/oauth/slack-oauth.ts#SLACK_BOT_SCOPES`, kept in lockstep so the
  # authorize URL and the app manifest never drift.
  @slack_scopes ~w(
    app_mentions:read channels:history channels:read chat:write
    groups:history groups:read im:history im:read mpim:history mpim:read
    reactions:read reactions:write users:read
  )

  @slack_authorize_url "https://slack.com/oauth/v2/authorize"

  @doc """
  The Slack Add-to-Slack OAuth config for THIS instance, or `nil` when it is not
  configured (D62).

  Reads the same `Barkpark.Connectors` app config the connect secret lives in.
  `slack_client_id` and `slack_redirect_uri` are set by the operator as part of
  the Slack app human gate (the client id from api.slack.com, the redirect_uri
  byte-matching the app's registered OAuth redirect URL —
  `https://<public>/connectors/oauth/slack/callback`). `nil` ⇒ the Slack card
  shows an honest "needs a Slack app" note, never a broken button.
  """
  @spec slack_oauth_config() ::
          %{client_id: String.t(), redirect_uri: String.t(), scopes: [String.t()]} | nil
  def slack_oauth_config do
    cfg = Application.get_env(:barkpark, Barkpark.Connectors, [])

    with client_id when is_binary(client_id) and client_id != "" <- cfg[:slack_client_id],
         redirect when is_binary(redirect) and redirect != "" <- cfg[:slack_redirect_uri] do
      %{client_id: client_id, redirect_uri: redirect, scopes: @slack_scopes}
    else
      _ -> nil
    end
  end

  @doc """
  The Add-to-Slack authorize URL carrying `state` — a signed connect ticket
  (D62/D65).

  The `state` is minted by `ConnectTicket.sign` and its NONCE joins the
  pending-connect row staged over loopback (D63); the raw chat token NEVER rides
  this URL. `redirect_uri` MUST byte-match the bridge's own — both derive from the
  instance's public base URL + `/connectors/oauth/slack/callback`.
  """
  @spec slack_authorize_url(String.t(), map()) :: String.t()
  def slack_authorize_url(state, %{client_id: cid, redirect_uri: redirect, scopes: scopes})
      when is_binary(state) do
    query =
      URI.encode_query(%{
        "client_id" => cid,
        "scope" => Enum.join(scopes, ","),
        "redirect_uri" => redirect,
        "state" => state
      })

    @slack_authorize_url <> "?" <> query
  end

  # Linear's OAuth `read` scope — enough for the agent to create/update issues
  # via the tool descriptors (D81). Kept minimal on purpose.
  @linear_scopes ~w(read)

  # The AUTHORIZE host — deliberately NOT the token-exchange host. Linear
  # authorizes at linear.app/oauth/authorize and exchanges the code at
  # api.linear.app/oauth/token (the bridge callback's job); do not collapse them.
  @linear_authorize_url "https://linear.app/oauth/authorize"

  @doc """
  The Linear OAuth config for THIS instance, or `nil` when it is not configured
  (mirrors `slack_oauth_config/0`, D103).

  Reads `:linear_client_id` / `:linear_redirect_uri` from the same
  `Barkpark.Connectors` app config the connect secret lives in — set by the
  operator as part of the Linear OAuth app human gate
  (`connectors-linear-live-oauth-gate`). `runtime.exs` plumbs NO oauth client ids
  for ANY provider today, so this is `nil` at merge and the Linear card renders an
  honest not-configured note, never a broken button. It lights up for free once
  the keys are set.
  """
  @spec linear_oauth_config() ::
          %{client_id: String.t(), redirect_uri: String.t(), scopes: [String.t()]} | nil
  def linear_oauth_config do
    cfg = Application.get_env(:barkpark, Barkpark.Connectors, [])

    with client_id when is_binary(client_id) and client_id != "" <- cfg[:linear_client_id],
         redirect when is_binary(redirect) and redirect != "" <- cfg[:linear_redirect_uri] do
      %{client_id: client_id, redirect_uri: redirect, scopes: @linear_scopes}
    else
      _ -> nil
    end
  end

  @doc """
  The Linear authorize URL carrying `state` — a signed connect ticket (D103).

  Mirrors `slack_authorize_url/2` with ONE load-bearing delta: Linear REQUIRES
  `response_type=code` (Slack omits it). `state` is minted by `ConnectTicket.sign`
  and the public callback `/connectors/oauth/linear/callback` verifies it BEFORE
  spending the code; `redirect_uri` MUST byte-match the bridge's own
  (`<public>/connectors/oauth/linear/callback`).
  """
  @spec linear_authorize_url(String.t(), map()) :: String.t()
  def linear_authorize_url(state, %{client_id: cid, redirect_uri: redirect, scopes: scopes})
      when is_binary(state) do
    query =
      URI.encode_query(%{
        "client_id" => cid,
        "response_type" => "code",
        "scope" => Enum.join(scopes, ","),
        "redirect_uri" => redirect,
        "state" => state
      })

    @linear_authorize_url <> "?" <> query
  end

  @doc """
  Every install belonging to `workspace`, newest column set only (D38: no
  `credential_ref`, no `chat_token_ref`).

  THE JOIN (D55). `connector_installs.workspace_id` is Postgres `text`;
  `workspaces.id` is `uuid`. Without `type(ci.workspace_id, Ecto.UUID)` this
  raises `ERROR 42883 operator does not exist: uuid = text`. With it, Ecto emits
  `c0."workspace_id"::uuid = w1."id"` and the join is a plain uuid compare.

  The INNER JOIN is load-bearing, not decoration: it is the tenancy proof. A row
  whose `workspace_id` names a workspace that no longer exists is not this
  workspace's install and is not shown — the row is the bridge's, the truth about
  who owns it is ours.
  """
  @spec installs_for_workspace(Workspace.t() | binary() | nil) :: [map()]
  def installs_for_workspace(%Workspace{id: ws_id}), do: installs_for_workspace(ws_id)

  def installs_for_workspace(ws_id) when is_binary(ws_id) do
    case Repo.uuid_or_nil(ws_id) do
      nil ->
        []

      uuid ->
        Repo.all(
          from(ci in Install,
            join: w in Workspace,
            on: type(ci.workspace_id, Ecto.UUID) == w.id,
            where: w.id == ^uuid,
            order_by: [asc: ci.provider, asc: ci.install_key],
            select: %{
              provider: ci.provider,
              install_key: ci.install_key,
              workspace_id: ci.workspace_id,
              workspace_slug: w.slug,
              created_at: ci.created_at
            }
          )
        )
    end
  end

  def installs_for_workspace(_), do: []

  @doc """
  `installs_for_workspace/1` grouped by provider id — what the LiveView renders
  against. A provider with no install is simply absent from the map; a provider
  with installs maps to a NON-EMPTY LIST of them.

  Two installs of the SAME provider in one workspace are possible (two Telegram
  bots), and the catalog card now shows EVERY one — one row per install, each
  independently disconnectable (D161). The banner-with-links alternative was
  rejected: a hidden second install is an undisconnectable credential, which is a
  security hole, not a cosmetic gap.

  Each provider's list inherits `installs_for_workspace/1`'s ordering —
  `order_by: [asc: provider, asc: install_key]` — so it is install_key-ALPHABETICAL,
  NOT creation order. (The pre-D104 collapse kept the alphabetical survivor and
  MISDESCRIBED it as "the OLDEST"; there was never a `created_at` sort. D104
  corrected the claim; this returns the whole set, so there is no survivor at all.)
  """
  @spec installs_by_provider(Workspace.t() | binary() | nil) :: %{String.t() => [map()]}
  def installs_by_provider(workspace) do
    workspace
    |> installs_for_workspace()
    |> Enum.group_by(& &1.provider)
  end

  # ── The inbound webhook / interactions endpoint (D260) ──────────────────────
  #
  # DRIFT POSTURE (same posture as `connectable?/1`): there is NO catalog endpoint
  # on the bridge, so Studio cannot ASK it "what is your webhook route for X?" —
  # this table MIRRORS the bridge's per-connector `webhook:` blocks. SOURCE OF
  # TRUTH: `connectors/src/connector/types.ts` (`ConnectorWebhook.keySource`) plus
  # each connector's registry entry (`connectors/src/connectors/*.ts`). Keep in
  # lockstep with them; a drift here mis-SHOWS a display string, never breaks a
  # route (Phoenix mounts NONE of these — the Node bridge serves them behind Caddy,
  # D34/D39; this is a copyable convenience mirror of the ops runbooks).
  #
  #   * PATH-keyed (`keySource: "path"`) — the install key IS a path segment, so
  #     the URL is per-install: `{base}{prefix}/webhooks/<provider>/<install_key>`.
  #     discord (install_key = applicationId; the portal field is literally
  #     "Interactions Endpoint URL") and whatsapp (each Meta app points at its own
  #     per-number URL).
  #   * PAYLOAD-keyed (`keySource: "payload"`) — the request_url is APP-WIDE (one
  #     URL for every workspace; the key is dug out of the body), so the URL omits
  #     the install key: `{base}{prefix}/webhooks/<provider>`. slack (team_id) and
  #     teams (tenant id).
  #   * NONE — telegram (polling, no HTTP route), imessage (no HTTP seam at all),
  #     github/linear (TOOL/outbound — the agent acts on them, nothing inbound).
  #     `webhook_endpoint/2` returns nil and the card shows no endpoint row.
  @webhook_specs %{
    "discord" => %{
      key_source: :path,
      label: "Interactions Endpoint URL",
      help:
        "Deploy the route and let Discord PING-validate it BEFORE you Save — the portal " <>
          "refuses an unreachable URL, and a later failing endpoint is silently removed. See " <>
          "connectors/docs/discord-byo-bot.md (deploy the webhook route before you save the URL)."
    },
    "whatsapp" => %{
      key_source: :path,
      label: "Webhook Callback URL",
      help:
        "Paste as the Meta webhook Callback URL (HTTPS only); the phone number id is the " <>
          "install key. See docs/ops/whatsapp-meta.md."
    },
    "slack" => %{
      key_source: :payload,
      label: "Event Subscriptions Request URL",
      help:
        "Paste into Event Subscriptions → Request URL — one app-wide URL for every workspace " <>
          "(Slack demuxes the team from the payload). See docs/ops/slack-app.md."
    },
    "teams" => %{
      key_source: :payload,
      label: "Messaging Endpoint",
      help:
        "One app-wide URL; Teams demuxes tenants from the payload. See " <>
          "docs/ops/teams-azure-bot.md."
    }
  }

  @doc """
  The inbound webhook / interactions endpoint an operator pastes into a provider's
  portal for a given install — or `nil` for a provider that exposes none (D260).

  Returns `%{key_source: :path | :payload, label: String.t(), help: String.t(),
  url: String.t() | nil}`. `:url` is the display string ONLY (Phoenix mounts no
  route — the Node bridge serves it behind Caddy). It is `nil` when the instance's
  PUBLIC base is not configured, and the caller renders the honest
  "endpoint unavailable" state rather than any URL: pasting `Endpoint.url/0` (the
  app's own origin) or the loopback `bridge_url` (127.0.0.1) into a vendor portal
  is a guaranteed verification failure.

  For a PAYLOAD-keyed provider the URL is app-wide and `install_key` is ignored.
  """
  @spec webhook_endpoint(String.t(), String.t()) :: map() | nil
  def webhook_endpoint(provider, install_key)
      when is_binary(provider) and is_binary(install_key) do
    case Map.get(@webhook_specs, provider) do
      nil -> nil
      spec -> Map.put(spec, :url, webhook_url(spec.key_source, provider, install_key))
    end
  end

  def webhook_endpoint(_, _), do: nil

  defp webhook_url(key_source, provider, install_key) do
    case public_base() do
      nil ->
        nil

      base ->
        suffix =
          case key_source do
            :path -> "/webhooks/#{provider}/#{install_key}"
            :payload -> "/webhooks/#{provider}"
          end

        base <> path_prefix() <> suffix
    end
  end

  # THE PUBLIC BASE an operator pastes into a vendor portal — the instance's public
  # origin (`:capabilities_base_url`), which is set ONLY in runtime.exs's prod
  # block. NO DEFAULT on purpose: nil in dev/test/unconfigured ⇒ the honest
  # "endpoint unavailable" render. Deliberately NOT the `"http://localhost:4000"`
  # default other consumers use (capabilities.ex / cycle_fleet_controller.ex): a
  # webhook URL that defaults to localhost is a paste error waiting to happen.
  defp public_base do
    case Application.get_env(:barkpark, :capabilities_base_url) do
      base when is_binary(base) and base != "" -> String.trim_trailing(base, "/")
      _ -> nil
    end
  end

  # The connectors HTTP path prefix (`config :barkpark, Barkpark.Connectors,
  # path_prefix:` — config.exs), default "/connectors". Mirrors the bridge's Caddy
  # route + `webhook-server.ts`'s `{prefix}/webhooks/...` grammar.
  defp path_prefix do
    Application.get_env(:barkpark, Barkpark.Connectors, [])[:path_prefix] || "/connectors"
  end

  @doc """
  The api_token LABEL a connector's per-install chat token carries (D48/D51).

  This is the ONLY thing that makes DISCONNECT able to revoke the token: the
  bridge holds no token id, and `chat_token_ref` is a sealed blob no Elixir will
  ever open. The label is the join key between an install and its credential.
  """
  @spec token_label(String.t(), String.t()) :: String.t()
  def token_label(provider, install_key) when is_binary(provider) and is_binary(install_key),
    do: "connector:#{provider}:#{install_key}"
end
