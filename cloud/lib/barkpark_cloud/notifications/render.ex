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

  ## The deployment failure names WHICH deployment (wave 15 S4)

  `deployment_failed` used to render a site name and a cause and nothing else, on
  both rails — so a team that got three alerts in an hour could not tell three
  attempts at one push from three different pushes, and had no handle to look
  anything up with. `deployment_identity/1` is the shared formatter both rails
  render, so the identity line is byte-identical in the inbox and in Slack.

  ## The trial teardown is a NAMED arm (cch-w32-s1)

  `trial_expiring` is dispatched hourly in production and, as of charter D359,
  fans to chat through `Notifications.@chat_always_send`. Without a named arm it
  would fall to the catch-all below and ship "Event: trial_expiring for acme."
  at `:info` — which Discord renders GREEN — for a message whose subject is an
  instance being torn down. It renders at `:warning`. NOTE THE LIMIT so nobody
  over-claims it: Pushover escalates priority only on `:error`, so `:warning`
  raises no Pushover priority; what it buys is the Discord/severity colour and
  an honest classification.

  ## The teardown ITSELF is a second, later arm (cch-w52-bl)

  `trial_expiring` is the ADVANCE notice — T-3 and T-1 days, future tense. The
  teardown that follows it dispatched NOTHING: `TrialExpiryWorker` enqueued a
  deprovision for every box a team owned and the only artefact was a
  `{"deprovision","pending"}` job row. A team that missed both advance notices
  learned its instances were gone at the outage. `trial_expired` is that missing
  fact, and it is a DIFFERENT fact from "expiring": it is past tense, it NAMES
  the instances that were torn down (`teardown_clause/1`, shared with the alert
  email so the two rails cannot disagree about which instances a team lost), and
  it prescribes the one action left. Reusing `trial_expiring` at day 0 would have
  mailed future-tense copy about something that had already happened.
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
        {"Deployment failed",
         "A deployment for #{site} failed.#{identity(payload)}#{cause(payload)}", :error}

      "agent_unreachable" ->
        {"Site unreachable", "#{site} stopped responding to health checks.", :warning}

      "agent_reachable" ->
        {"Site reachable again", "#{site} is responding to health checks again.", :info}

      "subscription_past_due" ->
        {"Subscription past due",
         "Your subscription is past due — hosted instances may be suspended.", :warning}

      "trial_expiring" ->
        {"Trial ending",
         "Your free trial ends #{trial_window(payload)} — #{site} is torn down " <>
           "automatically when it ends.", :warning}

      "trial_expired" ->
        {"Trial ended",
         "Your free trial has ended and #{teardown_clause(payload)}. " <>
           "Subscribe to a paid plan to run Barkpark again.", :warning}

      "test" ->
        if muted?(payload) do
          {"Test notification",
           "This is a test from Barkpark Cloud. The channel works — but alerts are " <>
             "currently OFF for this team, so no real notification will be delivered " <>
             "until they are switched back on.", :warning}
        else
          {"Test notification",
           "This is a test from Barkpark Cloud. If you can read this, the channel works.", :info}
        end

      other ->
        {"Barkpark Cloud", "Event: #{other} for #{site}.", :info}
    end
  end

  @doc """
  WHICH deployment this alert is about, as ONE line — `""` when the payload
  carries no identity at all (wave 15 S4, charter D248).

  It lives here, and the alert email calls it, so the inbox and the chat channels
  can never disagree about the deployment they are naming — the same "one story,
  two envelopes" property `render/2` itself exists for.

  Every part is a real `deployments` column carried by the producer
  (`Registry.dispatch_deployment_failed/3`) under its own name: the id (which
  `GET /v1/sites/:id/deployments/:dep_id` answers), the nullable `stage`, and ONE
  code identity — `git_ref` / `content_rev` / `build_id`. THERE IS NO DURATION
  AND NO LINK: `deployments` has no started_at/finished_at to subtract, and the
  notifications layer has no console base URL to link to. The id is the handle.

  The payload reaching a chat shaper is the Oban args map, so every key is read
  under both a string and an atom.
  """
  @spec deployment_identity(map()) :: String.t()
  def deployment_identity(payload) when is_map(payload) do
    [
      {"Deployment", field(payload, :deployment_id)},
      {"stage", field(payload, :stage)},
      {"git_ref", field(payload, :git_ref)},
      {"content_rev", field(payload, :content_rev)},
      {"build_id", field(payload, :build_id)}
    ]
    |> Enum.filter(fn {_label, value} -> is_binary(value) and value != "" end)
    |> Enum.map_join(" · ", fn {label, value} -> "#{label} #{value}" end)
  end

  @doc """
  WHAT the trial teardown destroyed, as ONE clause — `"acme has been torn down"`,
  `"acme and beta have been torn down"` (cch-w52-bl).

  It lives here, and the alert email calls it, for exactly the reason
  `deployment_identity/1` does: the inbox and the chat channels must not disagree
  about which instances a team lost. The names come from the producer
  (`TrialExpiryWorker`), which reads them off the box list it is tearing down —
  `Registry.succeed_deprovision_job/1` DELETES the barkpark row, so this is the
  last moment the names exist at all.

  A payload with no usable names degrades to "your Barkpark instances have been
  torn down" rather than rendering an empty subject. The payload reaching a chat
  shaper is the Oban args map, so the key is read under both a string and an atom.
  """
  @spec teardown_clause(map()) :: String.t()
  def teardown_clause(payload) when is_map(payload) do
    case instance_names(payload) do
      [] -> "your Barkpark instances have been torn down"
      [one] -> "#{one} has been torn down"
      many -> "#{join_names(many)} have been torn down"
    end
  end

  defp instance_names(payload) do
    (Map.get(payload, "instances") || Map.get(payload, :instances) || [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp join_names(names) do
    {rest, [last]} = Enum.split(names, -1)
    "#{Enum.join(rest, ", ")} and #{last}"
  end

  # The identity as its own paragraph, or nothing — a payload without one keeps
  # the bare lead sentence rather than growing a dangling blank line.
  defp identity(payload) do
    case deployment_identity(payload) do
      "" -> ""
      line -> "\n\n#{line}"
    end
  end

  defp field(payload, key) do
    Map.get(payload, Atom.to_string(key)) || Map.get(payload, key)
  end

  # cch-w32-s1 — the trial window, BUILT FROM THE INTEGER, never from `:detail`.
  #
  # `TrialExpiryWorker` used to supply both a `days` integer and a first-party
  # `detail` sentence, and this arm read only the integer. As of cch-w42-s6 it
  # supplies the FACTS ONLY (`%{days:, name:}`) — the sentence moved into the two
  # recipient-aware `EventEmail` render arms, because a body authored per-TEAM
  # could never soften an owner-only imperative for a member. This arm is
  # unchanged, and that is the point: it never depended on the string. Had it
  # done so, `detail` would have had to travel
  # through `cause/1`, i.e. `FailureCopy.humanize/1` = `classify() |> scrub()` —
  # a FAILURE taxonomy plus a credential redactor. There is nothing to classify
  # in control-plane-authored prose and nothing to scrub in an integer, and a
  # future `@scrub_rules` pattern would then silently rewrite customer copy.
  # (Measured: `humanize/1` is a no-op on that sentence today, so this is design
  # hygiene, not a live bug.) The payload is the Oban args map, so the key is
  # read under both a string and an atom; a missing/odd value degrades to "soon"
  # rather than rendering "in  days".
  defp trial_window(payload) do
    case Map.get(payload, "days") || Map.get(payload, :days) do
      1 -> "in 1 day"
      d when is_integer(d) and d > 1 -> "in #{d} days"
      _ -> "soon"
    end
  end

  # cch-w32-s1 — did the test fan out from a MUTED team? `send_test_chat/2` is a
  # transport probe and fires regardless of `alerts_enabled`, which is right; it
  # sets this flag so the message itself can say so, instead of the one button
  # whose job is to answer "will I be told?" answering an unqualified yes.
  defp muted?(payload) do
    Map.get(payload, "alerts_muted") == true or Map.get(payload, :alerts_muted) == true
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
