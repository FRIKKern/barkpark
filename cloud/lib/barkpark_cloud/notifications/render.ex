defmodule BarkparkCloud.Notifications.Render do
  @moduledoc """
  Builds the human-facing `{title, body, severity}` for an event once, so every
  chat channel shaper wraps the SAME line in its provider envelope (the
  gap-analysis "identical message, different envelope" property). The analog of
  Coolify's per-event `Notification` classes collapsed into one data-driven table.

  The event vocabulary is main's `EmailSettings.events/0` set (rendered as strings
  by `Notifications.dispatch_event/3` when it folds an email alert out to chat),
  plus the always-send `test` event. `severity` is `:error | :warning | :info` and
  drives, e.g., the Discord embed colour (red for failures, green for successes).
  """

  @doc """
  Return `{title, body, severity}` for `event` + `payload`. Unknown events get a
  generic line rather than crashing — a new event without a render entry still
  delivers something readable.
  """
  @spec render(String.t(), map()) :: {String.t(), String.t(), :error | :warning | :info}
  def render(event, payload) when is_binary(event) and is_map(payload) do
    site = subject(payload)

    case event do
      "provision_failed" ->
        {"Provisioning failed", "Provisioning failed for #{site}.", :error}

      "provision_succeeded" ->
        {"Provisioning succeeded", "#{site} finished provisioning and is live.", :info}

      "deployment_failed" ->
        {"Deployment failed", "A deployment for #{site} failed.", :error}

      "deployment_succeeded" ->
        {"Deployment succeeded", "A deployment for #{site} went live.", :info}

      "agent_unreachable" ->
        {"Site unreachable", "#{site} stopped responding to health checks.", :warning}

      "agent_reachable" ->
        {"Site reachable again", "#{site} is responding to health checks again.", :info}

      "subscription_past_due" ->
        {"Subscription past due",
         "Your subscription is past due — hosted instances may be suspended.", :warning}

      "member_invited" ->
        {"Team member invited", "A new member was invited to #{site}.", :info}

      "token_expiring" ->
        {"API token expiring", "An API token for #{site} is expiring soon.", :warning}

      "test" ->
        {"Test notification",
         "This is a test from Barkpark Cloud. If you can read this, the channel works.", :info}

      other ->
        {"Barkpark Cloud", "Event: #{other} for #{site}.", :info}
    end
  end

  # The thing the event is about — a site/instance slug/name when the payload
  # carries one, else a generic word so the line still reads.
  defp subject(payload) do
    payload["site"] || payload[:site] || payload["slug"] || payload[:slug] ||
      payload["name"] || payload[:name] || "your account"
  end
end
