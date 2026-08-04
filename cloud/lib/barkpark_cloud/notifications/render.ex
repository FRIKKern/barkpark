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

  ## The failure events carry their CAUSE (wave 29)

  `dispatch_event/3` builds the alert email and enqueues the chat jobs from the
  SAME payload, but only the email arm ever read `:detail`. So charter D310
  (`provision_failed`) and D333 / wave 28 S6 (`deployment_failed`) both landed on
  the email arm alone, and one failure told the same person two stories in the
  same minute: the inbox got the cause, Slack got "A deployment for acme failed."
  and nothing else. Both failure events now render `FailureCopy.humanize/1` as a
  second paragraph.

  THE CAUSE ONLY — NEVER THE RAW CAPTURE. The alert email keeps the honest
  provider bytes below the class because a person forwarding it to support needs
  them; chat does NOT get that treatment. `enqueue_chat/3` already persists the
  raw payload into `oban_jobs.args` unscrubbed (`notifications.ex` `json_safe/1`
  passes binaries through), and that is a STORAGE problem — putting the same
  bytes in the rendered body would make it an EGRESS problem across five
  third-party hosts. `humanize/1` is `classify() |> scrub()`, so every path here
  is scrubbed: a classified reason renders its literal class copy, and an
  unclassified one renders the scrubbed reason, which is exactly the boundary the
  email's own `detail/1` has applied since wave 13 S2. `event_email.ex`'s comment
  that "`Render.render/2` never reads it" described the pre-wave-29 tree; the
  scrub boundary it protects is upheld here, not crossed.
  """

  alias BarkparkCloud.FailureCopy

  # The smallest envelope any shaper has to fit is Pushover's 1024-character
  # `message` (Discord embed descriptions take 4096, Slack sections 3000,
  # Telegram messages 4096, the generic webhook is unbounded JSON). The lead
  # sentences here are all well under 100 characters, so capping the cause well
  # below the remaining headroom keeps every channel well-formed even when an
  # unclassified reason arrives as a multi-line provider aggregate.
  @cause_limit 600
  @ellipsis "…"

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
        {"Provisioning failed", "Provisioning failed for #{site}.#{cause(payload)}", :error}

      "provision_succeeded" ->
        {"Provisioning succeeded", "#{site} finished provisioning and is live.", :info}

      "deployment_failed" ->
        {"Deployment failed", "A deployment for #{site} failed.#{cause(payload)}", :error}

      "agent_unreachable" ->
        {"Site unreachable", "#{site} stopped responding to health checks.", :warning}

      "agent_reachable" ->
        {"Site reachable again", "#{site} is responding to health checks again.", :info}

      "subscription_past_due" ->
        {"Subscription past due",
         "Your subscription is past due — hosted instances may be suspended.", :warning}

      "test" ->
        {"Test notification",
         "This is a test from Barkpark Cloud. If you can read this, the channel works.", :info}

      other ->
        {"Barkpark Cloud", "Event: #{other} for #{site}.", :info}
    end
  end

  # The failure's HUMAN cause as its own paragraph, or "" when the trigger site
  # sent no detail (the health-check and staleness producers pass a name only).
  #
  # `humanize/1` and not `scrub/1`: the reader of a chat alert is the same person
  # the dashboard already tells "The build didn't finish after several attempts
  # and was stopped", and there is no forwarding-to-support role on this channel
  # that the raw capture would serve. The payload reaching here is the Oban args
  # map, so the key is read under both a string and an atom.
  defp cause(payload) do
    case Map.get(payload, "detail") || Map.get(payload, :detail) do
      d when is_binary(d) and d != "" -> "\n\n#{clamp(FailureCopy.humanize(d))}"
      _ -> ""
    end
  end

  # Keep the body inside the smallest channel envelope. An unclassified reason
  # passes through as itself, and the provision path's fallback-ladder aggregate
  # folds every candidate's failure into one string — truncation is honest here
  # (the console and the alert email both hold the full capture) and a silently
  # rejected Pushover POST is not.
  defp clamp(text) when is_binary(text) do
    if String.length(text) > @cause_limit do
      String.slice(text, 0, @cause_limit - 1) <> @ellipsis
    else
      text
    end
  end

  # The thing the event is about — a site/instance slug/name when the payload
  # carries one, else a generic word so the line still reads.
  defp subject(payload) do
    payload["site"] || payload[:site] || payload["slug"] || payload[:slug] ||
      payload["name"] || payload[:name] || "your account"
  end
end
