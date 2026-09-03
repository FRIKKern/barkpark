defmodule BarkparkCloud.Notifications.EventEmail do
  @moduledoc """
  Builds the per-event ALERT email body — the email-only collapse of Coolify's
  `EmailChannel.php` `toMail()`. One subject + body per event; the to-address is
  a team member, the from-address is the team's configured `from_address` (or the
  platform default).

  The dispatcher (`Notifications.dispatch_event/3`) builds one of these per
  recipient and delivers it over the team's transport.

  ## The recipient carries a ROLE (cch-w42-s6, charter D475/D332)

  Two events prescribed a remedy only the team OWNER can perform —
  `subscription_past_due` said "Update your billing" and `trial_expiring` said
  "Upgrade to keep your instance running" — and both were mailed to EVERY member,
  because `Accounts.list_team_member_emails/1` has no role predicate. Both
  imperatives route to `require_current_team_owner` doors (`POST
  /v1/billing/checkout`, `POST /v1/billing/portal`), whose 403 for a member AND
  for a non-owner admin is already pinned by run. The console had already written
  the honest sentence — "Only the team owner can manage billing." — so the two
  surfaces disagreed about the same person.

  THE FIX IS ROLE-AWARE COPY, NEVER A NARROWER AUDIENCE. `trial_expiring` is on
  `Notifications.@always_send` precisely because its reach must be maximal, and
  the TRUE half of both sentences (suspension, automatic teardown) is what a
  member most needs. Filtering would trade one lie for a withhold. So the
  audience is untouched and only the sentence changes: an owner keeps the
  imperative, everyone else gets the consequence plus who can act.

  THE SPLIT IS OWNER vs NOT-OWNER, not this epic's usual `owner|admin` band: the
  gate is `Authz.team_owner?` via `require_current_team_owner`, which refuses a
  non-owner admin too. And it FAILS CLOSED — an unknown, absent or bare-string
  recipient is NOT an owner, so a caller that forgets the role gets the honest
  copy rather than an instruction the server will refuse.
  """
  import Swoosh.Email

  alias BarkparkCloud.FailureCopy
  alias BarkparkCloud.Mailer
  alias BarkparkCloud.Notifications.EmailSettings
  alias BarkparkCloud.Notifications.Render

  # Separates the human cause from the raw provider capture below it, so a reader
  # who only wants the answer can stop at the first paragraph and a reader
  # forwarding this to support still has the honest bytes.
  @capture_heading "What the provider reported:"

  @typedoc """
  Who this email is for. A bare address is still accepted — every caller that has
  no role in hand keeps working — and reads as NOT an owner. A map carries the
  recipient's team role alongside the address, which is how `dispatch_event/3`
  supplies it; the arity of `build/4` is unchanged, so the merged event
  vocabulary census keeps driving the same public function.
  """
  @type recipient ::
          String.t() | %{required(:email) => String.t(), optional(:role) => String.t() | nil}

  @doc """
  Build the `%Swoosh.Email{}` for `event` going to `recipient`, with the team's
  `settings` supplying the From and `payload` supplying event detail (e.g. the
  Barkpark name). Unknown events fall back to a generic subject so a new emit
  site never crashes the dispatcher.

  `recipient` may carry the reader's team role (see `t:recipient/0`); the two
  billing events render an owner-only imperative ONLY to an owner.
  """
  @spec build(EmailSettings.t(), atom(), map(), recipient()) :: Swoosh.Email.t()
  def build(%EmailSettings{} = settings, event, payload, recipient) do
    {address, role} = address_and_role(recipient)
    {subject, body} = render(event, payload, owner?(role))

    new()
    |> to(address)
    |> from(from_for(settings))
    |> subject(subject)
    |> text_body(body)
  end

  defp address_and_role(%{email: address} = recipient),
    do: {address, Map.get(recipient, :role)}

  defp address_and_role(address), do: {address, nil}

  # OWNER vs NOT-OWNER, mirroring `Authz.team_owner?` — the predicate behind the
  # `require_current_team_owner` doors these two remedies point at. An admin is
  # NOT an owner here, and neither is a nil/unknown role: unknown fails closed to
  # the copy that prescribes nothing.
  defp owner?("owner"), do: true
  defp owner?(:owner), do: true
  defp owner?(_role), do: false

  # The From a team's alert email carries: its configured from_address/from_name
  # when set, else the platform default. Keeps a team's mail recognizably theirs.
  defp from_for(%EmailSettings{from_address: addr, from_name: name})
       when is_binary(addr) and addr != "" do
    {name || "Barkpark Cloud", addr}
  end

  defp from_for(_settings), do: Mailer.from()

  # Subject + plain-text body per event. `payload` is a free map from the trigger
  # site; we read a couple of common keys (`:name`, `:detail`) defensively.
  # `owner?` is the reader's authority over the team — only the two billing
  # events read it; every other arm ignores it.
  defp render(:provision_succeeded, payload, _owner?),
    do: {"Your Barkpark is live", "#{name(payload)} finished provisioning and is now live."}

  defp render(:provision_failed, payload, _owner?),
    do:
      {"Your Barkpark failed to provision",
       "#{name(payload)} failed to provision.#{cause_then_capture(payload)}"}

  # wave 28 S6: `deployment_failed` renders through `cause_then_capture/1`, NOT
  # `detail/1`. Its `:detail` is the deployment's `failure_reason` — reaper prose
  # like "exceeded max deploy claim attempts (stale builder lease)" — which
  # `detail/1` would scrub and ship raw. The dashboard classifies the same string;
  # the inbox now tells the same person the same story, with the honest capture
  # kept below the class exactly as D310 ruled for `provision_failed`.
  # wave 15 S4 (charter D248): the identity line goes ABOVE the cause, because a
  # reader with three of these open needs to know WHICH deployment before they
  # care why. `Render.deployment_identity/1` is the single formatter both rails
  # use, so the inbox and Slack name the same deployment the same way.
  defp render(:deployment_failed, payload, _owner?),
    do:
      {"Deployment failed",
       "A deployment for #{name(payload)} failed." <>
         "#{identity(payload)}#{cause_then_capture(payload)}"}

  # cch-w29-bl — the auto-deploy PREBUILT refusal reaches the inbox.
  #
  # THE REMEDY IS NOT RE-TYPED HERE, and that is the whole point of the arm. The
  # sentence a person must act on ("Ship new bytes with `bp cloud site deploy
  # <site> --prebuilt <dir>`.") has exactly ONE owner —
  # `Sites.AutoDeployWorker.refusal_detail/0`, the same string the worker writes
  # into the deployment row's `detail` and `failure_reason`, which is what the
  # console renders. It rides the dispatch payload as `:detail` and lands here
  # through `detail/1`, so the inbox and the console cannot drift: a second copy
  # of the remedy is a second thing to forget to update.
  #
  # `detail/1` and not `cause_then_capture/1`: this string is CONTROL-PLANE
  # PROSE, not a provider capture, so there is no class to lead with — running it
  # through `FailureCopy.humanize/1` would hand a failure taxonomy a sentence
  # that has nothing to classify. `detail/1`'s `strip_ansi |> scrub` still runs
  # (charter D354's order), which is a no-op on a constant the control plane
  # authored and is kept rather than bypassed so this path cannot become the one
  # unscrubbed reader of `:detail` in the email channel.
  defp render(:deployment_refused, payload, _owner?),
    do:
      {"Deployment refused",
       "A content publish for #{name(payload)} did not deploy — it was refused." <>
         "#{identity(payload)}#{detail(payload)}"}

  defp render(:agent_reachable, payload, _owner?),
    do: {"Your Barkpark is reachable again", "#{name(payload)} is reporting healthy again."}

  defp render(:agent_unreachable, payload, _owner?),
    do:
      {"Your Barkpark is unreachable",
       "#{name(payload)} stopped reporting and may be down.#{detail(payload)}"}

  # The remedy — the billing portal — is behind `require_current_team_owner`. The
  # consequence is everyone's business, so it is what the non-owner arm leads
  # with, and the console's own sentence is reused verbatim rather than inventing
  # a third phrasing for the same fact.
  defp render(:subscription_past_due, _payload, true),
    do:
      {"Your Barkpark Cloud subscription is past due",
       "A payment failed and your subscription is past due. Update your billing to avoid interruption."}

  defp render(:subscription_past_due, _payload, false),
    do:
      {"Your Barkpark Cloud subscription is past due",
       "A payment failed and your subscription is past due — hosted instances may be suspended. " <>
         "Only the team owner can manage billing."}

  # cch-w42-s6: the trial body is composed HERE, from the `:days` INTEGER, and no
  # longer arrives pre-written as `:detail` from `TrialExpiryWorker.notify/3`.
  # That string was authored per-TEAM, before any recipient existed, so a
  # role-aware builder could not reach it — a slice that only changed `build/4`
  # would have fixed past-due and left this one still prescribing an upgrade to
  # people the checkout door refuses. `Render.render/2` set the precedent (it has
  # built the window from the integer since cch-w32-s1); this is the email half.
  defp render(:trial_expiring, payload, true),
    do:
      {"Your Barkpark free trial is ending soon",
       "Your Barkpark free trial ends #{trial_window(payload)}. Upgrade to keep your " <>
         "instance running — it's torn down automatically when the trial ends."}

  defp render(:trial_expiring, payload, false),
    do:
      {"Your Barkpark free trial is ending soon",
       "Your Barkpark free trial ends #{trial_window(payload)}. #{name(payload)} is torn down " <>
         "automatically when the trial ends. Only the team owner can upgrade the plan."}

  # cch-w52-bl — the TEARDOWN's own alert, and it is a different fact from the
  # two arms above: `trial_expiring` is the advance notice (future tense, T-3 /
  # T-1), this one fires from the worker's teardown arm and reports what has
  # already been done. It NAMES the instances — `Render.teardown_clause/1` is the
  # single formatter both rails use, so the inbox and Slack name the same
  # instances the same way — because "your trial ended" without the names leaves
  # a team guessing which of its boxes went.
  #
  # The role split is the same one `subscription_past_due` and `trial_expiring`
  # carry, for the same reason: the one action left routes to
  # `POST /v1/billing/checkout`, a `require_current_team_owner` door that refuses
  # a member AND a non-owner admin. The audience is untouched (every member is
  # mailed — the reach of a teardown notice must be maximal); only the sentence
  # changes. There is no "export your data" offer here: the deprovision has been
  # enqueued for every box by the time this is dispatched, so an offer to export
  # would be a promise the control plane cannot keep.
  defp render(:trial_expired, payload, true),
    do:
      {"Your Barkpark free trial has ended",
       "Your Barkpark free trial has ended and #{Render.teardown_clause(payload)}. " <>
         "Subscribe to a paid plan to run Barkpark again."}

  defp render(:trial_expired, payload, false),
    do:
      {"Your Barkpark free trial has ended",
       "Your Barkpark free trial has ended and #{Render.teardown_clause(payload)}. " <>
         "Only the team owner can subscribe to a paid plan."}

  defp render(event, payload, _owner?),
    do: {"Barkpark Cloud notification", "Event: #{event}.#{detail(payload)}"}

  defp name(payload), do: Map.get(payload, :name) || Map.get(payload, "name") || "Your Barkpark"

  # WHICH deployment failed, as its own paragraph — deployment id, stage and one
  # real code identity, all columns, no invented commit field and no computed
  # build duration (`deployments` has neither a start nor a finish timestamp to
  # subtract). There is no link: the notifications layer has no console base URL,
  # and the id is what `GET /v1/sites/:id/deployments/:dep_id` takes.
  defp identity(payload) do
    case Render.deployment_identity(payload) do
      "" -> ""
      line -> "\n\n#{line}"
    end
  end

  # The trial window, BUILT FROM THE INTEGER — the same shape (and the same
  # degraded "soon") `Notifications.Render.trial_window/1` uses, so the two rails
  # can never disagree about how long a team has left.
  defp trial_window(payload) do
    case Map.get(payload, :days) || Map.get(payload, "days") do
      1 -> "in 1 day"
      d when is_integer(d) and d > 1 -> "in #{d} days"
      _ -> "soon"
    end
  end

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
  #
  # deploy-reliability W20 S4 (charter D354): `strip_ansi/1` BEFORE `scrub/1`,
  # never a bare scrub. `failure_copy.ex:184-187` rules that any path rendering a
  # RAW capture without classifying it must be `strip_ansi() |> scrub()`, and
  # states the measurement behind the order: 2000/2000 leaked under
  # `scrub |> strip_ansi`, 0/2000 under `strip_ansi |> scrub`. This IS such a
  # path — it never classifies — and it stripped nothing, so a colourised
  # `\e[31mapi_key=…\e[0m` off the build PTY defeated the scrub's key clause
  # (whose `(?<![A-Za-z0-9])` lookbehind is satisfied by the `m` of `\e[31m`) and
  # shipped the credential to an operator's inbox in cleartext. Only the ORDER
  # changes here: the capture itself is still rendered in full and unreordered.
  defp detail(payload) do
    case Map.get(payload, :detail) || Map.get(payload, "detail") do
      d when is_binary(d) and d != "" ->
        "\n\n#{d |> FailureCopy.strip_ansi() |> FailureCopy.scrub()}"

      _ ->
        ""
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
  #
  # deploy-reliability W20 S4 (charter D354): the capture is
  # `strip_ansi() |> scrub()`, the raw-log order `failure_copy.ex:184-187` rules,
  # not the bare scrub this line shipped — same defect as `detail/1` above.
  #
  # The STRIPPED reason is also what `humanize/1` reads, and that is load-bearing
  # rather than tidiness. `humanize/1` ends `… |> scrub() |> strip_ansi()`, so on
  # its PASS-THROUGH arm (an unclassified reason returns itself from `classify/1`)
  # it scrubs colourised bytes — the very order that leaks. Feeding it a reason
  # with no escapes left in it makes that arm land on exactly `capture`, which
  # keeps the `^capture` equal-arm below firing for an unclassified reason (a
  # colourised one would otherwise fall to the `cause` arm and print the leaky
  # pass-through paragraph ABOVE the clean capture). On a CLASSIFIED reason
  # `classify/1` returns a literal carrying no secret shape, and stripping a
  # capture's escapes before the classifier only removes bytes no clause anchors
  # on. The classified arm's copy is untouched by this slice.
  defp cause_then_capture(payload) do
    case Map.get(payload, :detail) || Map.get(payload, "detail") do
      d when is_binary(d) and d != "" ->
        stripped = FailureCopy.strip_ansi(d)
        capture = FailureCopy.scrub(stripped)

        case FailureCopy.humanize(stripped) do
          ^capture -> "\n\n#{capture}"
          cause -> "\n\n#{cause}\n\n#{@capture_heading}\n\n#{capture}"
        end

      _ ->
        ""
    end
  end
end
