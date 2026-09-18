defmodule BarkparkCloud.Notifications.EventVocabularyCensusTest do
  @moduledoc """
  cch-w42-s5 — a CENSUS over the notification event vocabulary: every event this
  control plane can dispatch must have a NAMED arm in both human-facing
  renderers, so an unnamed event can no longer ship green at `:info`.

  ## What goes wrong without it

  `Render.render/2`'s last arm is `other -> {"Barkpark Cloud", "Event: \#{other}
  for \#{site}.", :info}` and `EventEmail`'s final private clause is
  `{"Barkpark Cloud notification", "Event: \#{event}.\#{detail(payload)}"}`.
  `:info` really is GREEN on Discord — `channels/discord.ex` holds
  `@colors %{error: 15_158_332, warning: 16_761_095, info: 3_066_993}`
  (3_066_993 = 0x2ECC71) and looks the colour up with `Map.get(@colors,
  severity, @colors.info)`, so BOTH the fallback severity and the fallback
  colour default to green. A future `backup_failed` would reach a person titled
  "Barkpark Cloud", coloured like a success.

  ## This is LATENT, not live

  All six `EmailSettings.events/0` atoms — and `"test"` — have named arms today.
  Nobody is being told anything wrong. What was missing is that NOTHING drove
  the vocabulary against either renderer: the console's bidirectional census
  (`__app.test.mjs` "cch-w30-s1 census") checks producer <-> offer, not whether a
  dispatched event RENDERS as itself, and `render_test.exs` pins the arms it
  knows about one by one — it stays fully green when a seventh atom appears.

  ## cch-w42-bl closed all three stated limits

  The three limits s5 wrote down are now assertions, not prose.

  ### 1. SEVERITY is guarded (was: "blind to severity")

  `Render.render/2` returning `{"Backup failed", "…", :info}` used to pass — an
  arm EXISTING said nothing about it being CORRECT. "no failure-worded event may
  render `:info`" is now a test, and it is a PREDICATE over the rendered copy
  (`@failure_words`), never a list of which events are failures: a tenth event
  whose copy says "failed" is judged the moment it is added, with nobody editing
  this file.

  ### 2. The POPULATION is derived from disk (was: "four modules unaudited")

  The four modules s5 named — `digest_email.ex`, `transactional.ex`,
  `delivery_reason.ex`, `withhold.ex` — were four names in a sentence, and the
  sentence was a SNAPSHOT. Measured against the tree there are 22 modules under
  `notifications/`, of which this census audited 2 (`render.ex`,
  `event_email.ex`), leaving **20** unaudited, not four. Worse, the audit of the
  four comes back a NOT-FOUND in all four cases: none of them reads the event
  vocabulary at all, so none of them can have an event catch-all to audit. The
  three modules that DO read the vocabulary — `abandonment_policy.ex`,
  `deployment_failed_policy.ex`, `email_settings.ex` — were not among the four
  names.

  So the fix is not to append four names. `@fan_out_verdicts` below is a LEDGER
  of verdicts whose POPULATION is read off the filesystem: every `.ex` under
  `notifications/` must carry a verdict, a module with no verdict reds naming
  itself, and a module whose verdict says "reads no event vocabulary" is CHECKED
  against its own source. The day somebody adds a `deployment_failed` branch to
  `digest_email.ex`, this census reds and asks for the audit. A not-found
  recorded as a tripwire keeps working; a not-found recorded as prose does not.

  ### 3. `trial_expiring` is covered through a PUBLIC accessor

  `Notifications.chat_always_send/0` (added by this row) is the accessor s5 said
  was missing. `settings_view/2` renders the same function, so the console view
  and this census read ONE source and the literal is never re-typed.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.EmailSettings
  alias BarkparkCloud.Notifications.EventEmail
  alias BarkparkCloud.Notifications.Render

  # The two fallback strings, pinned by the third test against a genuinely
  # unknown event. Without that pin, renaming a fallback would make the two
  # censuses match nothing and report clean — vacuously green.
  @render_catch_all_title "Barkpark Cloud"
  @email_catch_all_subject "Barkpark Cloud notification"

  # A name no producer emits. Deliberately ugly so it cannot collide with a real
  # event someone adds later.
  @unknown_event "__census_definitely_unknown_event__"

  @payload %{"site" => "acme", "name" => "acme"}

  # No Repo, no sandbox: `EventEmail.build/4` only reads From fields off the
  # struct, and `Render.render/2` is pure.
  defp settings, do: %EmailSettings{}

  defp render_title(event) when is_binary(event) do
    {title, _body, _severity} = Render.render(event, @payload)
    title
  end

  # `render/2` inside `EventEmail` is `defp` — every clause is private — so the
  # census goes through the PUBLIC `build/4` and reads the built subject.
  defp email_subject(event) when is_atom(event) do
    EventEmail.build(settings(), event, @payload, "someone@example.com").subject
  end

  # ── Severity ───────────────────────────────────────────────────────────────

  # Words that mean SOMETHING WENT WRONG, matched against the rendered
  # `title <> " " <> body`, lowercased, on word boundaries. This is the rule the
  # guard runs; it is deliberately not a list of failure EVENTS, because a list
  # of events is a snapshot that a tenth event silently falls outside of.
  #
  # The boundary is LETTERS, not `\b`. `\b` treats `_` as a word character, so
  # `\bfailed\b` does NOT match inside `backup_failed` — and `backup_failed` is
  # precisely the shape of event this guard exists to catch, because the
  # catch-all's body is literally "Event: backup_failed for acme." A lookaround
  # on `[a-z]` fires there and still refuses the false positives: "unreachable"
  # does not match the `agent_reachable` copy (preceded by "n"), and "fail" as a
  # prefix cannot fire on "failover".
  @failure_words ~w(
    failed failure fails refused unreachable expired expiring suspended
  )

  # Multi-word failure phrases. Same rule, no boundary subtleties.
  @failure_phrases ["past due", "given up", "torn down", "did not deploy", "stopped responding"]

  # An event nobody dispatches, named so the CATCH-ALL renders failure-worded
  # copy: the fallback body is "Event: <event> for <site>." at `:info`, so this
  # name makes the fallback itself a severity violation. It is the guard's
  # permanent control — see the last test.
  @failure_worded_unknown_event "backup_failed"

  defp rendered_copy(event) when is_binary(event) do
    {title, body, severity} = Render.render(event, @payload)
    {String.downcase(title <> " " <> body), severity}
  end

  defp failure_worded?(copy) when is_binary(copy) do
    Enum.any?(@failure_words, &Regex.match?(~r/(?<![a-z])#{&1}(?![a-z])/u, copy)) or
      Enum.any?(@failure_phrases, &String.contains?(copy, &1))
  end

  # Every event that can reach a chat channel: the routed vocabulary PLUS the
  # always-send events, read from the public accessors so neither list is retyped.
  defp all_chat_events, do: Notifications.chat_events() ++ Notifications.chat_always_send()

  # ── The sibling-module population ──────────────────────────────────────────

  @notifications_source Path.expand("../../../lib/barkpark_cloud/notifications", __DIR__)

  # Every `.ex` under `notifications/`, keyed by its path relative to that root.
  # DERIVED, never typed: this is the census's population, and the verdict ledger
  # below is checked against it in BOTH directions.
  defp sibling_modules do
    @notifications_source
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @notifications_source))
    |> Enum.sort()
  end

  # The event tokens to scan a module's source for. `"test"` is excluded on
  # purpose — it is a real member of the vocabulary but it is also an ordinary
  # English word that appears in almost every file, so scanning for it would make
  # every verdict red for nothing. Excluded by PREDICATE, so a future always-send
  # event is scanned for automatically.
  defp scannable_event_tokens do
    all_chat_events()
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "test"))
    |> Enum.sort()
  end

  defp events_named_in(relative_path) do
    source = File.read!(Path.join(@notifications_source, relative_path))

    Enum.filter(scannable_event_tokens(), fn event ->
      Regex.match?(~r/[":]#{Regex.escape(event)}\b/u, source)
    end)
  end

  # THE LEDGER. Values are verdicts, not coverage-by-assertion: `:reads_vocabulary`
  # means the module names event atoms and the census checks the names it uses are
  # real; `:no_vocabulary` means the audit came back NOT-FOUND and the census holds
  # that not-found true by re-measuring the source every run.
  @fan_out_verdicts %{
    # Audited by the two censuses above: these are the two human-facing renderers.
    "render.ex" =>
      {:reads_vocabulary,
       "the chat renderer — audited by the render census + the severity guard above"},
    "event_email.ex" =>
      {:reads_vocabulary, "the email renderer — audited by the subject census above"},
    # Owns the vocabulary; `events/0` is what the censuses iterate.
    "email_settings.ex" => {:reads_vocabulary, "owns @events — the vocabulary itself"},
    # Policy modules scoped to ONE event each. Not renderers: no copy, no severity.
    "abandonment_policy.ex" =>
      {:reads_vocabulary, "splits deployment_abandoned off deployment_failed; no rendered copy"},
    "deployment_failed_policy.ex" =>
      {:reads_vocabulary, "narrows deployment_failed volume; no rendered copy"},
    # ── The four modules cch-w42-s5 named. All four come back NOT-FOUND. ──
    "digest_email.ex" =>
      {:no_vocabulary,
       "fleet roll-up: its catch-alls key on freshness/window shape, never on an event name"},
    "transactional.ex" =>
      {:no_vocabulary,
       "one named function per transactional email; its only catch-all is transport_caveat/1 on a TRANSPORT string"},
    "delivery_reason.ex" =>
      {:no_vocabulary,
       "classifies TRANSPORT failures; classify/1's catch-all is already pinned by delivery_reason_test.exs and label/1 is total over classes/0"},
    "withhold.ex" =>
      {:no_vocabulary,
       "keys on withhold REASONS (@reasons), not events; label/1 has no catch-all at all, so an unlabelled reason crashes rather than ships generic"},
    # ── Everything else under notifications/. ──
    "box_unreachable_episode_alert.ex" =>
      {:no_vocabulary,
       "episode state machine; dispatches through Notifications, never names an event"},
    "channel_config.ex" => {:no_vocabulary, "channel kinds + sealed creds"},
    "delivery.ex" => {:no_vocabulary, "the delivery receipt row"},
    "deploy_rate_alert.ex" => {:no_vocabulary, "rate thresholds"},
    "deploy_rate_alert_state.ex" => {:no_vocabulary, "rate-alert state row"},
    "digest_run.ex" => {:no_vocabulary, "digest run bookkeeping"},
    "receipt_loss.ex" =>
      {:no_vocabulary,
       "receipt-reduction ladder; keys on the refused changeset's fields and a :lost residue, never on an event name"},
    "safe_url.ex" => {:no_vocabulary, "SSRF fence on channel URLs"},
    "site_publish_waiting_alert.ex" =>
      {:no_vocabulary, "publish-wait alert; dispatches through Notifications"},
    "channels/discord.ex" =>
      {:no_vocabulary, "envelope shaper — takes {title, body, severity}, never the event name"},
    "channels/pushover.ex" => {:no_vocabulary, "envelope shaper"},
    "channels/slack.ex" => {:no_vocabulary, "envelope shaper"},
    "channels/telegram.ex" => {:no_vocabulary, "envelope shaper"},
    "channels/webhook.ex" => {:no_vocabulary, "envelope shaper"}
  }

  test "every chat event has a NAMED Render.render/2 arm (the catch-all ships :info = Discord GREEN)" do
    unnamed =
      all_chat_events()
      |> Enum.filter(&(render_title(&1) == @render_catch_all_title))

    assert unnamed == [],
           """
           These dispatchable events have no named Render.render/2 arm and fall to the catch-all:

               #{inspect(unnamed)}

           The catch-all renders {"#{@render_catch_all_title}", "Event: <event> for <site>.", :info},
           and :info is Discord GREEN (channels/discord.ex @colors info: 3_066_993 = 0x2ECC71).
           A failure event landing here reaches a person looking like a success.
           Add a named arm in cloud/lib/barkpark_cloud/notifications/render.ex.
           """
  end

  test "every email event has a NAMED EventEmail subject" do
    unnamed =
      EmailSettings.events()
      |> Enum.filter(&(email_subject(&1) == @email_catch_all_subject))

    assert unnamed == [],
           """
           These events have no named EventEmail clause and fall to the generic subject:

               #{inspect(unnamed)}

           They would arrive in a customer's inbox titled "#{@email_catch_all_subject}"
           with the body "Event: <event>." — the event name, not what happened.
           Add a named `render/2` clause in cloud/lib/barkpark_cloud/notifications/event_email.ex.
           """
  end

  test "the two catch-all literals are still the catch-alls (keeps the censuses above non-vacuous)" do
    assert render_title(@unknown_event) == @render_catch_all_title,
           "Render's fallback title changed; the render census above now matches nothing " <>
             "and would report clean no matter how many events were unnamed."

    assert email_subject(String.to_atom(@unknown_event)) == @email_catch_all_subject,
           "EventEmail's fallback subject changed; the email census above now matches nothing " <>
             "and would report clean no matter how many events were unnamed."
  end

  # ── cch-w42-bl: severity ──────────────────────────────────────────────────

  test "no failure-worded event renders :info (the catch-all's :info is Discord GREEN)" do
    green_failures =
      for event <- all_chat_events(),
          {copy, severity} = rendered_copy(event),
          failure_worded?(copy),
          severity == :info,
          do: {event, severity, copy}

    assert green_failures == [],
           """
           These events render copy that says something WENT WRONG, at :info:

               #{inspect(green_failures, pretty: true)}

           :info is Discord GREEN — channels/discord.ex holds
           @colors %{error: 15_158_332, warning: 16_761_095, info: 3_066_993}
           (3_066_993 = 0x2ECC71) and looks the colour up with
           Map.get(@colors, severity, @colors.info), so the fallback colour is the
           same green. A person reads the colour before the words: a failure
           painted green reads as a success.

           Either the arm in render.ex should be :error / :warning, or the copy
           does not actually describe a failure and the wording should say so.
           """
  end

  test "the always-send events are covered here, through the PUBLIC accessor" do
    always = Notifications.chat_always_send()

    # The residue s5 filed: trial_expiring reached chat and no census saw it,
    # because @chat_always_send had no accessor to read it from.
    assert "trial_expiring" in always,
           "trial_expiring left @chat_always_send — if it now takes a route it belongs in chat_events/0."

    # Not a re-typed literal: the accessor IS the source settings_view/2 renders.
    assert Enum.count(always) >= 1,
           "chat_always_send/0 returned nothing; the loop below would cover nothing."

    for event <- always do
      assert render_title(event) != @render_catch_all_title,
             "#{event} fans to chat with no route and has no named Render arm — " <>
               "it would ship \"Event: #{event} for <site>.\" at :info."
    end
  end

  test "the severity guard can LOSE: a failure-named event falling to the catch-all is caught" do
    # This is the guard's permanent control. The catch-all renders
    # {"Barkpark Cloud", "Event: backup_failed for acme.", :info} — failure-worded
    # AND :info — so if a `backup_failed` event were added to the vocabulary
    # without a render arm, the test above reds. Proving that here means the
    # predicate cannot go quietly vacuous (a reworded @failure_words that stopped
    # matching anything would still pass the test above, on zero events).
    {copy, severity} = rendered_copy(@failure_worded_unknown_event)

    assert severity == :info,
           "Render's catch-all no longer ships :info; re-check what the severity guard is protecting."

    assert failure_worded?(copy),
           """
           The failure-word predicate did not fire on #{inspect(copy)}.

           @failure_words / @failure_phrases no longer match the catch-all's own
           copy for a failure-named event, which means the severity census above
           is passing over ZERO events and proves nothing.
           """
  end

  # ── cch-w42-bl: the sibling-module population ─────────────────────────────

  test "every module under notifications/ carries a fan-out verdict (population read off disk)" do
    on_disk = sibling_modules()
    declared = @fan_out_verdicts |> Map.keys() |> Enum.sort()

    assert on_disk != [],
           "no modules found under #{@notifications_source} — the census is scanning nothing."

    unjudged = on_disk -- declared
    vanished = declared -- on_disk

    assert unjudged == [],
           """
           New sibling modules under notifications/ with no fan-out verdict:

               #{inspect(unjudged)}

           cch-w42-s5 listed four unaudited siblings by name, and that list was a
           SNAPSHOT: measured, there were 20. Add a verdict to @fan_out_verdicts —
           {:reads_vocabulary, why} if the module names event atoms (and say where
           it is audited), {:no_vocabulary, why} if it does not.
           """

    assert vanished == [],
           """
           @fan_out_verdicts judges modules that no longer exist:

               #{inspect(vanished)}

           Drop them, or the ledger is describing a tree that is gone.
           """
  end

  test "each verdict holds against the module's own source" do
    wrong =
      for {path, verdict} <- @fan_out_verdicts,
          named = events_named_in(path),
          mismatch = verdict_mismatch(verdict, named),
          mismatch != nil,
          do: {path, mismatch}

    assert wrong == [],
           """
           Fan-out verdicts that no longer match the source:

               #{inspect(wrong, pretty: true)}

           A {:no_vocabulary, _} module that STARTED naming events has gained a
           branch keyed on the event vocabulary, and nothing audits its catch-all
           — that is exactly the defect cch-w42-s5 filed against four modules that
           turned out not to have it. Audit the new branch, then move the verdict.

           A {:reads_vocabulary, _} module naming an event that is not in the live
           vocabulary has a typo or a dead branch: the event it matches on can
           never arrive.
           """
  end

  defp verdict_mismatch({:no_vocabulary, _why}, []), do: nil

  defp verdict_mismatch({:no_vocabulary, why}, named),
    do: {:expected_no_event_vocabulary, why, named}

  defp verdict_mismatch({:reads_vocabulary, why}, []),
    do: {:expected_to_read_the_vocabulary, why, :names_none}

  defp verdict_mismatch({:reads_vocabulary, _why}, named) do
    vocabulary = scannable_event_tokens()

    case named -- vocabulary do
      [] -> nil
      unknown -> {:names_events_outside_the_vocabulary, unknown}
    end
  end
end
