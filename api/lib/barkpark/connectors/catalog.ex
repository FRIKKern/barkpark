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
    * `:gate` — the honest, human-readable reason a non-connectable provider is
      not connectable. Rendered on the card in place of the button.
    * `:effort` — the onboarding weight, stated up front.
  """
  @type provider :: %{
          id: String.t(),
          name: String.t(),
          blurb: String.t(),
          effort: String.t(),
          connectable?: boolean(),
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
      credential_label: "Bot token",
      credential_hint: "From Developer Portal → your application → Bot → Reset Token.",
      help_url: "https://discord.com/developers/applications",
      gate: nil
    },
    %{
      id: "slack",
      name: "Slack",
      blurb: "Talk to your agent from a Slack channel or DM.",
      effort: "One click — once Add to Slack is wired.",
      connectable?: false,
      credential_label: nil,
      credential_hint: nil,
      help_url: nil,
      # Say it plainly. The Slack channel SHIPPED (registry entry, webhook seam,
      # per-install token) — what has not shipped is the OAuth "Add to Slack"
      # button that would create the install. Claiming a Connect button here
      # would be the two-minute promise as a lie.
      gate:
        "Add to Slack (OAuth) is not wired yet. The Slack channel itself ships — " <>
          "an install created by the OAuth callback works today — but nothing in Studio " <>
          "can create one, so there is no honest button to show you."
    },
    %{
      id: "teams",
      name: "Microsoft Teams",
      blurb: "Talk to your agent from Teams.",
      effort: "Your organisation's Azure admin must consent to the Barkpark bot.",
      connectable?: false,
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
