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

  @type provider :: %{
          id: String.t(),
          name: String.t(),
          blurb: String.t(),
          effort: String.t(),
          connectable?: boolean(),
          connect_mode: connect_mode(),
          credential_label: String.t() | nil,
          credential_hint: String.t() | nil,
          help_url: String.t() | nil,
          gate: String.t() | nil
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

  @doc "Every provider card, in catalog order (connectable first)."
  @spec providers() :: [provider()]
  def providers, do: @providers

  @doc "One provider card by id, or nil."
  @spec provider(String.t()) :: provider() | nil
  def provider(id) when is_binary(id), do: Enum.find(@providers, &(&1.id == id))
  def provider(_), do: nil

  @doc "True when the bridge declares a paste-mode connect for `id` (D51)."
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
  `installs_for_workspace/1` keyed by provider id — what the LiveView renders
  against. A provider with no install is simply absent from the map.

  Two installs of the SAME provider in one workspace are possible in principle
  (two Telegram bots); the catalog is a one-card-per-provider surface, so it
  shows the OLDEST (the first one connected) and never invents a second card.
  This is a known, filed limitation, not an accident.
  """
  @spec installs_by_provider(Workspace.t() | binary() | nil) :: %{String.t() => map()}
  def installs_by_provider(workspace) do
    workspace
    |> installs_for_workspace()
    |> Enum.reduce(%{}, fn install, acc ->
      Map.put_new(acc, install.provider, install)
    end)
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
