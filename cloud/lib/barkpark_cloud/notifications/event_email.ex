defmodule BarkparkCloud.Notifications.EventEmail do
  @moduledoc """
  Builds the per-event ALERT email body — the email-only collapse of Coolify's
  `EmailChannel.php` `toMail()`. One subject + body per event; the to-address is
  a team member, the from-address is the team's configured `from_address` (or the
  platform default).

  The dispatcher (`Notifications.dispatch_event/3`) builds one of these per
  recipient and delivers it over the team's transport.
  """
  import Swoosh.Email

  alias BarkparkCloud.Mailer
  alias BarkparkCloud.Notifications.EmailSettings

  @doc """
  Build the `%Swoosh.Email{}` for `event` going to `recipient`, with the team's
  `settings` supplying the From and `payload` supplying event detail (e.g. the
  Barkpark name). Unknown events fall back to a generic subject so a new emit
  site never crashes the dispatcher.
  """
  @spec build(EmailSettings.t(), atom(), map(), String.t()) :: Swoosh.Email.t()
  def build(%EmailSettings{} = settings, event, payload, recipient) do
    {subject, body} = render(event, payload)

    new()
    |> to(recipient)
    |> from(from_for(settings))
    |> subject(subject)
    |> text_body(body)
  end

  # The From a team's alert email carries: its configured from_address/from_name
  # when set, else the platform default. Keeps a team's mail recognizably theirs.
  defp from_for(%EmailSettings{from_address: addr, from_name: name})
       when is_binary(addr) and addr != "" do
    {name || "Barkpark Cloud", addr}
  end

  defp from_for(_settings), do: Mailer.from()

  # Subject + plain-text body per event. `payload` is a free map from the trigger
  # site; we read a couple of common keys (`:name`, `:detail`) defensively.
  defp render(:provision_succeeded, payload),
    do: {"Your Barkpark is live", "#{name(payload)} finished provisioning and is now live."}

  defp render(:provision_failed, payload),
    do:
      {"Your Barkpark failed to provision",
       "#{name(payload)} failed to provision.#{detail(payload)}"}

  defp render(:deployment_succeeded, payload),
    do: {"Deployment succeeded", "A deployment for #{name(payload)} succeeded."}

  defp render(:deployment_failed, payload),
    do: {"Deployment failed", "A deployment for #{name(payload)} failed.#{detail(payload)}"}

  defp render(:agent_reachable, payload),
    do: {"Your Barkpark is reachable again", "#{name(payload)} is reporting healthy again."}

  defp render(:agent_unreachable, payload),
    do:
      {"Your Barkpark is unreachable",
       "#{name(payload)} stopped reporting and may be down.#{detail(payload)}"}

  defp render(:subscription_past_due, _payload),
    do:
      {"Your Barkpark Cloud subscription is past due",
       "A payment failed and your subscription is past due. Update your billing to avoid interruption."}

  defp render(:trial_expiring, payload),
    do: {"Your Barkpark free trial is ending soon", "#{detail(payload)}"}

  defp render(:member_invited, payload),
    do: {"A new member joined your team", "#{detail(payload)}"}

  defp render(:token_expiring, payload),
    do: {"An API token is expiring soon", "#{detail(payload)}"}

  defp render(event, payload),
    do: {"Barkpark Cloud notification", "Event: #{event}.#{detail(payload)}"}

  defp name(payload), do: Map.get(payload, :name) || Map.get(payload, "name") || "Your Barkpark"

  defp detail(payload) do
    case Map.get(payload, :detail) || Map.get(payload, "detail") do
      d when is_binary(d) and d != "" -> "\n\n#{d}"
      _ -> ""
    end
  end
end
