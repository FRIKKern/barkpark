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

  alias BarkparkCloud.FailureCopy
  alias BarkparkCloud.Mailer
  alias BarkparkCloud.Notifications.EmailSettings

  # Separates the human cause from the raw provider capture below it, so a reader
  # who only wants the answer can stop at the first paragraph and a reader
  # forwarding this to support still has the honest bytes.
  @capture_heading "What the provider reported:"

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
       "#{name(payload)} failed to provision.#{cause_then_capture(payload)}"}

  # wave 28 S6: `deployment_failed` renders through `cause_then_capture/1`, NOT
  # `detail/1`. Its `:detail` is the deployment's `failure_reason` — reaper prose
  # like "exceeded max deploy claim attempts (stale builder lease)" — which
  # `detail/1` would scrub and ship raw. The dashboard classifies the same string;
  # the inbox now tells the same person the same story, with the honest capture
  # kept below the class exactly as D310 ruled for `provision_failed`.
  defp render(:deployment_failed, payload),
    do:
      {"Deployment failed",
       "A deployment for #{name(payload)} failed.#{cause_then_capture(payload)}"}

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

  defp render(event, payload),
    do: {"Barkpark Cloud notification", "Event: #{event}.#{detail(payload)}"}

  defp name(payload), do: Map.get(payload, :name) || Map.get(payload, "name") || "Your Barkpark"

  # The event's free-text detail, appended as its own paragraph.
  #
  # wave 13 S2: SCRUBBED. For the failure events this string is the RAW reason — a remote ssh/
  # provider capture that can carry a credential the control plane never chose to
  # print — and an email leaves our boundary for good. This is the sole reader of
  # `:detail` in the email channel.
  #
  # WAVE 29 CORRECTION: `Notifications.Render.render/2` DOES read `:detail` now —
  # the chat arm was telling the same person a cause-free story the inbox already
  # explained. It reads it through `FailureCopy.humanize/1` (classify |> scrub)
  # and renders the CLASS ONLY, never the raw capture this line appends, so the
  # boundary the sentence above protects still holds: the verbatim provider bytes
  # remain an email-only courtesy for a reader forwarding them to support.
  defp detail(payload) do
    case Map.get(payload, :detail) || Map.get(payload, "detail") do
      d when is_binary(d) and d != "" -> "\n\n#{FailureCopy.scrub(d)}"
      _ -> ""
    end
  end

  # wave 26 S3 (charter D310), extended to `deployment_failed` by wave 28 S6:
  # the CAUSE first, the raw capture kept below it.
  #
  # The `provision_failed` alert is the one channel that reaches a person away
  # from the console, and it was the only one that never CLASSIFIED. `router.ex`
  # dispatches `%{detail: job.error}` RAW, and `detail/1` above scrubs it and
  # stops there — so a capacity failure the dashboard renders as "Hetzner ran out
  # of server capacity for this size" arrived in the customer's inbox as six
  # lines of `CreateWithFallback` provider jargon. Same event, same minute, two
  # stories.
  #
  # THE RULING IS BOTH, NOT EITHER. `failure_copy.ex:20`/`:41` state that this
  # email deliberately keeps the honest internal reason; that intent is "do not
  # launder the forensic value", and it is PRESERVED here — the scrubbed capture
  # is retained verbatim, in full, unreordered, below the human class. A change
  # that REPLACED or truncated it would contradict :20/:41 and is refused.
  # `:136` of the same module lists this alert email among the surfaces that
  # render the capture "to a PERSON"; leading with the cause is the intent this
  # COMPLETES.
  #
  # `FailureCopy.humanize/1` is `classify() |> scrub()` — classification first,
  # then the very scrub `detail/1` already applies — so routing through it cannot
  # weaken the secret boundary; the class arms return literals, which carry no
  # secret shape.
  #
  # An unclassified reason humanizes to the scrubbed reason itself. Emitting both
  # would print the same paragraph twice, so in that case the capture stands
  # alone exactly as it does today.
  defp cause_then_capture(payload) do
    case Map.get(payload, :detail) || Map.get(payload, "detail") do
      d when is_binary(d) and d != "" ->
        capture = FailureCopy.scrub(d)

        case FailureCopy.humanize(d) do
          ^capture -> "\n\n#{capture}"
          cause -> "\n\n#{cause}\n\n#{@capture_heading}\n\n#{capture}"
        end

      _ ->
        ""
    end
  end
end
