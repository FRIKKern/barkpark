defmodule BarkparkWeb.Studio.ConnectorsCopy do
  @moduledoc """
  The Connectors page's provider texts, in the viewer's Studio language.

  `Barkpark.Connectors.Catalog` is core and stays English: its blurbs, effort
  notes, credential hints, gates and webhook help are data, read by more than
  this page. Studio owns the translation instead. Each catalog string is marked
  here for extraction, and the page renders it through `translate/1`.

  A catalog string with no marker here renders in English in every language.
  `markers/0` lets a test catch that drift (task-bf92938448ca864d).
  """
  use Gettext, backend: BarkparkWeb.Gettext

  @markers [
    gettext_noop("Talk to your agent in a Telegram DM or group."),
    gettext_noop("About 60 seconds — message @BotFather, create a bot, paste its token."),
    gettext_noop("Bot token"),
    gettext_noop("Looks like 123456789:AA… — BotFather hands it to you once."),
    gettext_noop("Talk to your agent in your Discord server."),
    gettext_noop(
      "About five steps in the Discord developer portal — create an application, add a bot, enable the Message Content intent, invite it to your server, then paste its token."
    ),
    gettext_noop("From Developer Portal → your application → Bot → Reset Token."),
    gettext_noop("Talk to your agent from a Slack channel or DM."),
    gettext_noop(
      "One click — Add to Slack, pick your workspace, and approve the bot. No token to paste."
    ),
    gettext_noop("Talk to your agent from Teams."),
    gettext_noop("Your organisation's Azure admin must consent to the Barkpark bot."),
    gettext_noop(
      "Teams runs on one multi-tenant Azure bot, so there is no token to paste — instead your org's Azure admin has to grant consent. Barkpark cannot do that on your behalf. See docs/ops/teams-azure-bot.md."
    ),
    gettext_noop("Talk to your agent over WhatsApp Business."),
    gettext_noop(
      "Weeks, not minutes — Meta Business verification, a WABA phone number, and App Review for Advanced Access."
    ),
    gettext_noop(
      "WhatsApp needs a Meta app you own (access token, app secret, phone number id, verify token) plus App Review — without it your number can only message about five test recipients. Paste-a-token cannot express that yet."
    ),
    gettext_noop("Talk to your agent from Messages on Apple devices."),
    gettext_noop("Needs a Mac you own, running all the time, with Full Disk Access."),
    gettext_noop(
      "Self-hosted only (CONNECTORS_PROFILE=self-hosted). iMessage has no official adapter: it drives a real Mac with a real Apple ID, one workspace per Mac, and any macOS update can break it. Barkpark Cloud will never run it for you."
    ),
    gettext_noop("Let your agent open pull requests, file issues, and comment on GitHub."),
    gettext_noop(
      "Paste a fine-grained personal access token — GitHub Settings → Developer settings → Fine-grained tokens. Scope it to the repos and permissions you want the agent to have."
    ),
    gettext_noop("Personal access token"),
    gettext_noop("Starts with github_pat_… — GitHub shows it once when you create it."),
    gettext_noop("Let your agent create and update Linear issues from your conversations."),
    gettext_noop(
      "One click — Connect Linear, authorize Barkpark in Linear, and you are done. No token to paste."
    ),
    gettext_noop("Interactions Endpoint URL"),
    gettext_noop(
      "Deploy the route and let Discord PING-validate it BEFORE you Save — the portal refuses an unreachable URL, and a later failing endpoint is silently removed. See connectors/docs/discord-byo-bot.md (deploy the webhook route before you save the URL)."
    ),
    gettext_noop("Event Subscriptions Request URL"),
    gettext_noop(
      "Paste into Event Subscriptions → Request URL — one app-wide URL for every workspace (Slack demuxes the team from the payload). See docs/ops/slack-app.md."
    ),
    gettext_noop("Messaging Endpoint"),
    gettext_noop(
      "One app-wide URL; Teams demuxes tenants from the payload. See docs/ops/teams-azure-bot.md."
    ),
    gettext_noop("Webhook Callback URL"),
    gettext_noop(
      "Paste as the Meta webhook Callback URL (HTTPS only); the phone number id is the install key. See docs/ops/whatsapp-meta.md."
    )
  ]

  @doc "Every catalog string this module has a translation marker for."
  @spec markers() :: [String.t()]
  def markers, do: @markers

  @doc "A catalog string in the viewer's Studio language; nil stays nil."
  @spec translate(String.t() | nil) :: String.t() | nil
  def translate(nil), do: nil
  def translate(text) when is_binary(text), do: Gettext.gettext(BarkparkWeb.Gettext, text)
end
