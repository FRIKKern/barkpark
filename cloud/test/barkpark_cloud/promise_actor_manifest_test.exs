defmodule BarkparkCloud.PromiseActorManifestTest do
  @moduledoc """
  cch-w55-s4 — THE PROMISE-ACTOR REGISTER.

  The console renders sentences about a FUTURE ACT: "your instances are paused
  after the grace period", "your plan stays active until the end of the billing
  period", "your trial ends on …". Each such sentence is a promise that
  something WILL happen on a day nobody is watching. This register pins, per
  promise, the only three things that can make one true:

    * CLOCK  — does anything reach that day at all?
    * ACTOR  — does something RUN on it?
    * EFFECT — can that actor produce the effect the copy names?

  Key: `{reason, transition}`. The PAIR is load-bearing: one reason (`trial`)
  contributes a DISCHARGED row and an UNSUPPORTED row, so this register proves
  it DISCRIMINATES rather than merely agreeing with itself. A register keyed on
  the bare reason would be false on its own fixture, and there is an arm below
  that asserts exactly that.

  ── HOW EACH COLUMN IS READ ────────────────────────────────────────────────

  Every verdict is resolved BY RUNNING on this booted BEAM. Nothing here is
  transcribed prose.

    * CLOCK is one of FIVE verdicts, and every one of them is RUN
      (cch-w56-s2, charter D649–D652). `:synchronous` used to be a sixth — a
      nullary clause returning a fixed sentence — and it is DELETED, not
      renamed: it took no subject, read no config, touched no DB, so no state
      could make it return `{:error, _}`. Swapping the clock labels between a
      genuinely-absent row and a genuinely in-band row left the suite 6/6
      green, which is this epic's own thesis violated by this epic's own
      instrument. The replacements:

        `:crontab_absent`            — the crontab equality read PLUS a
          REQUIRED `%{pattern, roots}` search whose hit count must be ZERO. On
          its own, "I looked at the crontab and it is not there" is
          indistinguishable from "I failed to look anywhere else"; the search
          is what makes the difference. Any hit reds, naming the hit.
        `:crontab_row`               — the configured row, by equality.
        `{:external_only, …, search}` — the mirror obligation: a local negative
          RUN, plus a declared zero-hit search proving there is no in-tree
          arming artefact either. Without it, `:external_only` becomes the
          dumping ground for "I didn't look".
        `{:in_band, subject}`        — RUNS the named guard with BOTH controls.
          The positive control is mandatory and is the non-obvious half: an
          in-band resolver that only checks the expired case PASSES when the
          lookup is broken in every direction. Each `:in_band` payload names a
          `file:symbol` the resolver actually calls.
        `{:external_armed_here, path, arming_literal, cadence}` — the promise
          is kept by a non-BEAM process, but this tree ARMS it. The arming
          literal is asserted by equality against the pinned EXACT file, and
          `cadence` is either `{:cadence, "<literal>"}` or `:no_cadence_in_tree`
          — the resolver checks WHICHEVER IS DECLARED, so an invented interval
          reds AND a lazily-declared `:no_cadence_in_tree` on a cadence-bearing
          file reds. That second direction matters because the taxonomy pin at
          the bottom of this file folds tuples with `elem(_, 0)` and CANNOT SEE
          ARITY: a row downgraded to an arming-only payload walks straight
          through the pin. The resolver, not the pin, closes that hole.

      An `:external_armed_here` path must ALSO be declared in `CLOUD_PATHS`
      (`scripts/cloud-path-escape-check.sh`), as an EXACT FILE and never a
      directory (D270 — measured over 60 days: 145 newly-dispatching commits
      for `.github/workflows/**`, 76 for `deploy/**`, 8 for the Caddy file),
      or a PR editing the pinned file never dispatches this suite and the row
      publishes green having never run. And the read must be a SINGLE `"../…"`
      string literal: the escape census greps `"\.\./[^"]*"`, so a path spliced
      through `Path.join/1` over a bare ".." segment is invisible to it. An arm
      below that asserts this file contains no such splice.

    * CLOCK's crontab half is read off
      `Application.get_env(:barkpark_cloud, Oban)[:plugins]`
      — the crontab the application is CONFIGURED with — never off the text of
      `config/config.exs`. The full read is compared by EQUALITY against
      `@scheduled_crontab` pinned in this file. Equality, not a
      `/Billing|Dunning|Grace/` name heuristic: a real enforcement worker named
      `ArrearsWorker` walks straight through a heuristic, and the register would
      stay green claiming ABSENT while the clock had in fact arrived. Under
      equality, ANY added row reds here naming the row verbatim — which works
      even when the named module does not exist, because a crontab entry is
      just a term in config.

    * ACTOR on the DISCHARGED row is the REAL producer, run
      (`perform_job(TrialExpiryWorker, %{})` under Oban `:manual`) with an
      observer pre-armed on an EFFECT ROW — a `ProvisionJob` with
      `kind: "deprovision"`. A cron probe MAY NOT be labelled ACTOR (charter
      D635): "a crontab row names this module and the module loads" survives a
      `perform/1` gutted to a bare `:ok`. Measured in this epic —
      `AutoupdateRolloutWorker.perform/1` neutered to `:ok` left
      `sold_capability_manifest_test.exs` at 6/6 green while the
      effect-observing worker test went 9/11. So a cron row is CLOCK evidence
      and only CLOCK evidence; ACTOR always costs a run.

    * ACTOR on an ABSENCE row is not "unverified" — it is resolved too. The
      `billing_past_due` promise's only enforcement branch is reached from a
      single call site, and the same delivery that could fire it re-anchors the
      grace window forward, so the arm DRIVES that path and observes that no
      box is ever suspended by it.

    * EFFECT asserts what a suspension actually IS: one `Repo.update_all` in
      `suspend_team_barkparks/2` touching exactly four columns, observed as the
      set of fields that change on a real row. The only `poweroff` anywhere in
      `cloud/lib` is an uncalled catalog entry in `registry/hetzner_catalog.ex`
      — asserted by reading the tree, not described here.

  ── SCOPE. Quote this register's green for exactly this much ───────────────

    1. A green certifies, per row: "this promised act HAS / HAS NOT a clock, a
       scheduled actor, and a producible effect." It NEVER certifies that the
       billing system is correct, that the copy is well worded, or that the
       effect is the right one to have.
    2. An `:absent` clock verdict is only as strong as the crontab equality pin
       above it. It says "no configured schedule reaches this day", not "no
       code anywhere could ever run".
    3. A `:flag_only` effect verdict is a statement about the CONTROL PLANE: a
       row's flags flip and the dashboard and agent gate honour them. Whether
       any machine is physically stopped is out of its reach — the same
       boundary `Registry.delete_barkpark/1` documents.
    4. RETRACTED, cch-w56-bl. This item used to read "a promise the console
       makes that has no row is simply unexamined; this register cannot see
       it", and that is no longer true: `__future_act_dump.mjs` censuses the
       shipped `app.js` for DEFERRED-ACT sentences and the ADD arm below reds
       on any one no row claims. What remains true, and is now the whole of
       this item: the census's reach is the closed deadline vocabulary in that
       script, so copy about an IMMEDIATE act ("The instance will restart.")
       is still outside this register — deliberately, because such a sentence
       has no day for a clock to reach — and so is every promise made outside
       `cloud/priv/static/app.js`. The ~14 future-act promises in
       `internal/cli` are operator-facing and no app.js census can see them.

  ── WHAT THIS INSTRUMENT STILL CANNOT DO ───────────────────────────────────

  IT HAS AN ADD DIRECTION NOW (cch-w56-bl), and the paragraph that used to
  stand here — "it has NO ADD DIRECTION … nothing in this file notices a new
  promise appearing in cloud/priv/static/app.js" — is retracted. Widening it
  was a copy census's job, and the census exists:
  `priv/static/__preview__/__future_act_dump.mjs` is SPAWNED by this file with
  `System.cmd/3` and a non-zero exit reds the suite. Every deferred-act
  sentence it emits must be claimed by `@promised_sentences`, whose every value
  is a `@register` key; a new promise in the console reds here by its own text.

  The DELETE direction is the half that is only possible because
  `@promised_sentences` is pinned in THIS file. The ADD arm iterates what the
  census emits, so a census that emitted NOTHING would pass it at zero
  iterations — vacuously green over a console full of promises (the D564 shape
  `sold_capability_manifest_test.exs:261` was measured on). The DELETE arm
  iterates the pin instead and reds when a pinned sentence stops being emitted,
  so an emptied census, a broken lexer and a deleted promise all lose.

  WHAT IT STILL CANNOT DO. The census keys on a CLOSED VOCABULARY of deadline
  constructions (`VOCABULARY` in the dump). A promise phrased outside that list
  is not seen — the vocabulary is the honest boundary of the ADD direction, and
  widening it is a deliberate act that reds this file until the new sentences
  are claimed. It also reads ONE file: `cloud/priv/static/app.js`. Operator
  copy in `internal/cli` is invisible to it by construction.

  It also does not own the TLS claim end to end. The `custom_domain` row below
  proves the EXTERNAL half — that this tree arms Caddy's on-demand ACME, and
  that no renewal cadence lives in-tree because renewal is an internal of
  Caddy's own binary. The in-BEAM half is
  `sold_capability_manifest_test.exs`'s `{:route, :tls_ask_gate}` row, which
  dispatches `/v1/tls/ask` with a 404→200 discriminator and proves the ask gate
  is actually armed in this application. Neither row subsumes the other and
  neither is duplicated here: read them together or you have half the claim.
  """

  # async: true — every DB touch is inside the SQL sandbox, the config reads are
  # pure, and Oban runs in :manual mode (config/test.exs) so perform_job/2 runs
  # the worker synchronously inside this test's own transaction.
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, Billing, DeviceAuth, Registry, Repo}
  alias BarkparkCloud.Accounts.{Team, TeamInvitation, UserToken}
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.DeviceAuth.Request, as: DeviceAuthRequest
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}
  alias BarkparkCloud.Workers.{AutoupdateRolloutWorker, TrialExpiryWorker}

  @password "correct horse battery staple"

  # THE CRONTAB, PINNED HERE AND COMPARED BY EQUALITY. Declared by neither the
  # console nor the config: that is the only reason an ABSENT clock verdict can
  # lose. Nineteen rows today (dr-bl-rate-notice added the deploy failure RATE notice).
  @scheduled_crontab [
    {"* * * * *", BarkparkCloud.Workers.StaleProvisionJobReaper},
    {"* * * * *", BarkparkCloud.Workers.DeviceAuthReaper},
    {"* * * * *", BarkparkCloud.Workers.OAuthStateReaper},
    {"* * * * *", BarkparkCloud.Workers.SseTicketReaper},
    {"* * * * *", BarkparkCloud.Workers.OAuthExchangeReaper},
    {"* * * * *", BarkparkCloud.Workers.StaleDeploymentReaper},
    {"* * * * *", BarkparkCloud.Workers.StaleWarmClaimReaper},
    {"* * * * *", BarkparkCloud.Health.StalenessWorker},
    {"0 * * * *", BarkparkCloud.Workers.TrialExpiryWorker},
    {"17 * * * *", BarkparkCloud.Workers.UpdateStatusWorker},
    {"*/5 * * * *", BarkparkCloud.Workers.AutoupdateRolloutWorker},
    {"7,22,37,52 * * * *", BarkparkCloud.Workers.UsageSamplerWorker},
    {"30 3 * * *", BarkparkCloud.Workers.AgentRetentionWorker},
    {"45 3 * * *", BarkparkCloud.Workers.ArchiveRetentionWorker},
    {"0 6 * * *", BarkparkCloud.Workers.DailyDigestWorker},
    {"10 7 * * *", BarkparkCloud.Workers.TokenExpiryWarningWorker},
    {"41 * * * *", BarkparkCloud.Sites.TemplateFreshnessWorker},
    # dr-w11 (17 -> 18 rows): the hourly content-publish webhook reconcile. It is
    # UNRELATED to every `:crontab_absent` verdict in this register — it registers
    # a box endpoint, it touches no promise clock — so it is pinned here in the
    # same commit that adds it, per the classification rule in `crontab_agrees/0`.
    {"53 * * * *", BarkparkCloud.Workers.ContentWebhookReconciler},
    # dr-bl-rate-notice (18 -> 19 rows): the hourly deploy failure RATE notice.
    # UNRELATED to every `:crontab_absent` verdict in this register — it reads the
    # deploy ledger and mails a rate; it touches no promise clock — so it is
    # pinned here in the same commit that adds it, per `crontab_agrees/0`.
    {"27 * * * *", BarkparkCloud.Workers.DeployRateAlertWorker}
  ]

  # THE REGISTER. Each key is a promise the console makes about a future act;
  # each value names how its three columns are RESOLVED (not what they are —
  # the resolvers below decide that by running).
  @register %{
    # The grace-period promise. The only branch that could keep it
    # (`maybe_enforce/1`) has ONE call site, inside `mark_past_due/2`, reachable
    # only from the Stripe `invoice.payment_failed` arm — and that same call
    # re-anchors the grace window to now+3d when the webhook passes no attrs,
    # which it never does. The one event that could fire the branch is the one
    # that pushes it out of reach.
    # The ABSENT clock now costs a SEARCH as well as the crontab read: Oban is
    # the only scheduler in this plane, so a non-Oban arming (a send_after, a
    # :timer interval, a Quantum job) is exactly the thing a crontab-only read
    # would miss while still saying "absent".
    {"billing_past_due", :suspend_on_grace_elapse} => %{
      clock:
        {:crontab_absent,
         %{
           pattern:
             "Process\\.send_after|:timer\\.(send_after|send_interval|apply_interval)" <>
               "|Quantum\\.|Crontab\\.",
           roots: ["../../lib"],
           why: "no NON-Oban timer arms this day anywhere in cloud/lib"
         }},
      actor: {:unreachable, :grace_reanchors_on_every_delivery},
      effect: {:flag_only, :suspend_update_all}
    },

    # Immediate self-serve cancel. A REAL non-admin write path: POST
    # /v1/billing/cancel with at_period_end: false → request_cancel/2 →
    # cancel_subscription/1, gated by team ownership + password only.
    {"billing_lapsed", :cancel_immediate} => %{
      clock: {:in_band, :cancel_immediate_suspends},
      actor: {:synchronous_call, :request_cancel_immediate},
      effect: {:flag_only, :suspend_update_all}
    },

    # "Your plan stays active until the end of the billing period." Nothing in
    # this plane reaches that boundary: no crontab row, nothing local reads
    # `cancel_at_period_end` to decide entitlement, and for a paid plan the
    # named boundary has NO STORED VALUE at all. The mirror obligation: a
    # declared zero-hit search proving no CONFIGURED artefact in this tree names
    # the boundary either, so "external only" is a finding and not a shrug.
    {"billing_lapsed", :cancel_at_period_end} => %{
      clock:
        {:external_only, :stripe,
         %{
           pattern: "cancel_at_period_end|current_period_end",
           roots: ["../../config"],
           why: "no configured artefact in cloud/config names the boundary this copy promises"
         }},
      actor: :none_local,
      effect: {:unread, :cancel_at_period_end}
    },

    # The downgrade ceiling. In-band off the plan transition, no clock.
    {"quota_exceeded", :downgrade_suspend} => %{
      clock: {:in_band, :reconcile_completes_in_band},
      actor: {:synchronous_call, :reconcile_plan_limit},
      effect: {:flag_only, :suspend_update_all}
    },

    # "Invitations expire after 7 days" (app.js:19564) / "expires in 7 days"
    # (:19734). The deadline is enforced by ONE predicate — `i.expires_at >
    # ^now` in `Accounts.get_live_invitation/1` (accounts.ex:1210), reachable
    # UNAUTHENTICATED via GET /v1/invitations/:token — and by the same predicate
    # in `accept_invitation/2`. Delete either and the console's sentence is
    # enforced by nothing, on a path with no login in front of it.
    {"team_invitation", :expire_after_seven_days} => %{
      clock: {:in_band, :invitation_expiry},
      actor: {:in_band_guard, :invitation_accept},
      effect: {:refused, :no_membership_from_expired_invite}
    },

    # "It expires in an hour" (app.js:4958). `@reset_validity_minutes 60` at
    # accounts.ex:103; the predicate lives inside `reset_password_by_token/2`'s
    # FOR UPDATE txn (accounts.ex:1408). The EFFECT is the half worth asserting:
    # a refused reset must leave the OLD password still authenticating and the
    # attempted new one dead.
    {"password_reset", :expire_after_one_hour} => %{
      clock: {:in_band, :reset_expiry},
      actor: {:in_band_guard, :reset_by_token},
      effect: {:refused, :expired_reset_keeps_old_password}
    },

    # "Custom domains with automatic TLS" (app.js:14361, planFeatures). The
    # renewing actor is Caddy's own binary — not this BEAM — but THIS TREE arms
    # it: the rendered Caddyfile carries `on_demand_tls { ask <AskGateURL> }`.
    # There is deliberately NO cadence: Caddy renews at ~2/3 of certificate
    # lifetime as an internal of its own scheduler, and no interval for it
    # exists anywhere in this repo. `:no_cadence_in_tree` is therefore a CHECKED
    # claim, not a shrug — the resolver reds if the file carries a
    # cadence-shaped token after all. The in-BEAM half of this claim lives in
    # sold_capability_manifest_test.exs's {:route, :tls_ask_gate} row.
    {"custom_domain", :auto_tls_renewal} => %{
      clock:
        {:external_armed_here, "../../../internal/caddyfile/caddyfile.go", "on_demand_tls {",
         :no_cadence_in_tree},
      actor: :none_local,
      effect: {:absent, :local_cert_renewal}
    },

    # THE POSITIVE CONTROL — DISCHARGED. Hourly clock, real producer run, and
    # the effect it names is observed on an effect row.
    {"trial", :expire_teardown} => %{
      clock: {:crontab_row, TrialExpiryWorker, "0 * * * *"},
      actor: {:producer_run, :teardown_enqueued},
      effect: {:produced, :deprovision_job}
    },

    # THE SPLIT CONTROL — UNSUPPORTED, and it shares the `trial` reason with the
    # row above. Same clock, same actor, DIFFERENT effect: the console's
    # "you'll drop to the free plan" has no writer anywhere — the worker never
    # touches the Subscription row's plan.
    {"trial", :land_on_free} => %{
      clock: {:crontab_row, TrialExpiryWorker, "0 * * * *"},
      actor: {:producer_run, :teardown_enqueued},
      effect: {:absent, :free_plan_write}
    },

    # ── THE THREE ROWS THE ADD DIRECTION FOUND (cch-w56-bl) ─────────────────
    #
    # Not authored from a reading of the console: the census emitted their
    # sentences, nothing in @register claimed them, and the ADD arm reds until
    # a row exists. That is the direction working the first time it ran.

    # "We'll remind you 3 days and 1 day before the trial ends." (the trial-reminder
    # copy in cloud/priv/static/app.js, plus its alerts-unknown variant — a built
    # asset, so cited by sentence, not by line). A SECOND promise on the same
    # `trial` reason, and it is not the teardown: the act promised is a piece of
    # MAIL, on a day before the one the teardown row pins. Its effect is the
    # per-team notice STAMP, which is the whole budget for that warning — an
    # `UPDATE … WHERE <stamp> IS NULL` that can never match twice — so the
    # effect resolver runs the producer TWICE and the second run must send
    # nothing.
    {"trial", :remind_before_expiry} => %{
      clock: {:crontab_row, TrialExpiryWorker, "0 * * * *"},
      actor: {:producer_run, :reminder_claimed},
      effect: {:produced, :trial_notice_stamp}
    },

    # "New releases won't roll out to any instance until you resume."
    # (app.js:10658) and the confirm-modal's "No instance in any team advances
    # to a new release until you resume." (:11405). A NEGATIVE promise — the
    # act is that nothing happens — which is exactly the shape a register that
    # only reads its own rows never gets asked about. The ACTOR resolver's
    # non-vacuity control is the load-bearing half: it asserts
    # `next_autoupdate_candidate/0` really returns the fixture box BEFORE the
    # halted run, so "nothing advanced" is a measurement and not an empty
    # candidate set answering trivially.
    {"autoupdate_halted", :no_advance_until_resume} => %{
      clock: {:crontab_row, AutoupdateRolloutWorker, "*/5 * * * *"},
      actor: {:producer_run, :halt_blocks_advance},
      effect: {:absent, :no_trigger_stamped}
    },

    # "expires in 4m 30s" on /activate (the activation-expiry copy in the built
    # cloud/priv/static/app.js — cited by sentence, not line — both the
    # with-minutes and the sub-minute arm). The device-activation code's TTL. Its clock is
    # IN-BAND, not the per-minute `DeviceAuthReaper` cron: that worker is
    # hygiene by its own moduledoc ("Correctness never depends on it running")
    # and every DeviceAuth query carries `expires_at > now`, so labelling the
    # cron row as this promise's clock would credit the wrong mechanism —
    # exactly the D635 error in the CLOCK column.
    {"device_activation", :code_expiry} => %{
      clock: {:in_band, :device_code_expiry},
      actor: {:in_band_guard, :device_approve},
      effect: {:refused, :expired_device_code_mints_nothing}
    }
  }

  # ── THE SENTENCE INDEX: the ADD direction's other half ────────────────────
  #
  # Written HERE, declared by neither side, for the same reason
  # `sold_capability_manifest_test.exs`'s `@sold` is (D564): it is the only
  # reason the DELETE direction can lose. Key = the sentence EXACTLY as
  # `__future_act_dump.mjs` emits it (HTML stripped, entities resolved, `…`
  # standing for an interpolated value); value = the `@register` key that
  # carries its CLOCK/ACTOR/EFFECT verdict.
  #
  # A sentence appears here ONLY if a row genuinely covers it. There is no
  # "unexamined" escape value on purpose — an allowlist of promises this file
  # has decided not to look at would grow one entry at a time until the eighth
  # is waved through by the seven above it, and the ADD arm would stop
  # discriminating. The cost is real: a new deferred promise reds this file
  # until somebody resolves its three columns. That cost IS the direction.
  @promised_sentences %{
    "Cancelling keeps your plan until the end of the current billing period." =>
      {"billing_lapsed", :cancel_at_period_end},
    "Your plan stays active until the end of the current billing period." =>
      {"billing_lapsed", :cancel_at_period_end},
    "Your access continues until the end of the current billing period." =>
      {"billing_lapsed", :cancel_at_period_end},
    "When the trial ends, the instance is torn down." => {"trial", :expire_teardown},
    "Yours when the trial ends" => {"trial", :expire_teardown},
    "We'll remind you … before the trial ends." => {"trial", :remind_before_expiry},
    "If your team's alerts are on, we'll remind you … before the trial ends." =>
      {"trial", :remind_before_expiry},
    "Invitation links are emailed, work once, and expire after 7 days." =>
      {"team_invitation", :expire_after_seven_days},
    "You can also share this link — it works once and expires in 7 days:" =>
      {"team_invitation", :expire_after_seven_days},
    "It expires in an hour." => {"password_reset", :expire_after_one_hour},
    "New releases won't roll out to any instance until you resume." =>
      {"autoupdate_halted", :no_advance_until_resume},
    "No instance in any team advances to a new release until you resume." =>
      {"autoupdate_halted", :no_advance_until_resume},
    "expires in …m …s" => {"device_activation", :code_expiry},
    "expires in …s" => {"device_activation", :code_expiry}
  }

  ## ── The client half: the deferred-act census, read BY RUNNING ──────────

  # Spawn `__future_act_dump.mjs` and return its rows. There is NO regex and no
  # `File.read!` over app.js in this file: the census is a program with its own
  # self-test, and this side's only job is to refuse anything short of a clean
  # exit 0 with parseable JSON.
  #
  # THE PATH IS A SINGLE "../…" LITERAL, deliberately — `scripts/cloud-path-
  # escape-check.sh` greps `"\.\./[^"]*"`, and a path spliced through
  # `Path.join/1` over a bare ".." segment is invisible to it (there is an arm
  # below asserting this file contains no such splice). This one resolves
  # INSIDE cloud/, so it is not an escape and needs no CLOUD_PATHS entry; the
  # `cloud/**` pattern already dispatches this suite on it.
  defp console_deferred_acts! do
    node = System.find_executable("node")

    # A guard that cannot run must RED, never skip.
    assert node,
           "node is not on PATH — the future-act census cannot read the console's promises, and " <>
             "an unread console must never pass as a console that promises nothing"

    script = Path.expand("../../priv/static/__preview__/__future_act_dump.mjs", __DIR__)

    assert File.exists?(script),
           "the future-act census script is missing at #{script} — the ADD direction has no input"

    {out, status} = System.cmd(node, [script], stderr_to_stdout: true)

    assert status == 0,
           "the future-act census failed (exit #{status}) — exit 2 is an unreadable app.js, " <>
             "exit 3 is the lexer losing its own fixture, exit 4 is a lexer that desynchronised " <>
             "and found no literals at all. NONE of them is 'the console promises nothing'. " <>
             "The census said: #{out}"

    Jason.decode!(out)
  end

  ## ── Fixtures ───────────────────────────────────────────────────────────

  defp team_and_owner do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "promise-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {team, user}
  end

  defp team_with_owner, do: team_and_owner() |> elem(0)

  # Move a deadline into the past WITHOUT touching the guard: the row is real,
  # only the clock has passed. This is the negative control every :in_band
  # deadline resolver runs.
  defp expire_invitation!(%TeamInvitation{id: id}) do
    {1, _} =
      Repo.update_all(from(i in TeamInvitation, where: i.id == ^id),
        set: [
          expires_at:
            DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:microsecond)
        ]
      )

    :ok
  end

  defp expire_reset_tokens!(user_id) do
    {n, _} =
      Repo.update_all(
        from(t in UserToken, where: t.user_id == ^user_id and t.context == "reset"),
        set: [
          expires_at:
            DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:microsecond)
        ]
      )

    n
  end

  defp live_reset_token(user_id) do
    Repo.one(
      from(t in UserToken,
        where: t.user_id == ^user_id and t.context == "reset" and is_nil(t.revoked_at),
        order_by: [desc: t.inserted_at],
        limit: 1
      )
    )
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  # A box that satisfies EVERY clause of `Registry.next_autoupdate_candidate/0`
  # (registry.ex:5176) — host present, unsuspended, `behind`, autoupdate on and
  # unpaused, unpinned, not already in flight, arming not "unarmed". Written to
  # the row rather than through `refresh_update_status/1`, which would POST to
  # the box. The resolver that uses it asserts the query really returns it, so
  # a clause added to that query reds here instead of quietly emptying the
  # candidate set and making "nothing advanced" true for the wrong reason.
  defp behind_candidate!(team) do
    bp = barkpark_fixture(team)
    {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.10"})

    Repo.get!(Barkpark, bp.id)
    |> Ecto.Changeset.change(%{
      update_state: "behind",
      autoupdate_enabled: true,
      autoupdate_paused: false,
      pinned_release: nil,
      autoupdate_triggered_at: nil,
      # OLDER THAN EVERY EARLIER FIXTURE, monotonically. The candidate query
      # orders `asc: update_checked_at`, and the ACTOR and EFFECT columns of
      # this row each build their own box inside the SAME test process — with a
      # shared `utc_now()` the second one is never the pick and its control
      # reds as vacuous for a reason that has nothing to do with the halt.
      #
      # `:monotonic` IS LOAD-BEARING. `System.unique_integer([:positive])` is
      # unique but UNORDERED, so the second box's offset can be the smaller
      # one; measured, that passed alone and failed one run in two under the
      # whole `test/barkpark_cloud` directory — a load-dependent red in a
      # control whose entire job is to prove the measurement was not vacuous.
      update_checked_at:
        DateTime.utc_now()
        |> DateTime.add(-System.unique_integer([:positive, :monotonic]), :second)
        |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  # Move every live device-activation request's deadline into the past WITHOUT
  # touching the guard — the rows stay real, only the clock has passed. Same
  # shape as `expire_invitation!/1` and `expire_reset_tokens!/1` above: the
  # negative control every `:in_band` deadline resolver runs.
  defp expire_device_requests! do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)
    {count, _} = Repo.update_all(DeviceAuthRequest, set: [expires_at: past])
    count
  end

  # A lapsed request and a live one, in that order, so the live control is
  # created AFTER the expiry sweep and survives it.
  defp lapsed_and_live_device_codes! do
    {:ok, dead} = DeviceAuth.start(%{client_name: "promise-register"})
    expired = expire_device_requests!()
    {:ok, live} = DeviceAuth.start(%{client_name: "promise-register"})
    {dead, live, expired}
  end

  defp trial_sub(team, offset_seconds) do
    ends =
      DateTime.utc_now()
      |> DateTime.add(offset_seconds, :second)
      |> DateTime.truncate(:microsecond)

    {:ok, sub} =
      %Subscription{}
      |> Subscription.changeset(%{
        team_id: team.id,
        plan: "trial",
        status: "active",
        current_period_end: ends
      })
      |> Repo.insert()

    sub
  end

  defp reload_bp(%Barkpark{id: id}), do: Repo.get!(Barkpark, id)

  defp deprovision_jobs(bp_id) do
    Repo.all(from(j in ProvisionJob, where: j.barkpark_id == ^bp_id and j.kind == "deprovision"))
  end

  ## ── CLOCK ──────────────────────────────────────────────────────────────

  # The crontab the APPLICATION is configured with, read off this booted BEAM.
  defp configured_crontab do
    plugins = Application.get_env(:barkpark_cloud, Oban)[:plugins] || []

    Enum.find_value(plugins, [], fn
      {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
      _ -> nil
    end)
    |> Enum.map(fn
      {schedule, worker} -> {schedule, worker}
      {schedule, worker, _opts} -> {schedule, worker}
    end)
  end

  # EQUALITY, not a name heuristic. Returns the sorted read so a red can print
  # the exact rows that appeared or vanished.
  defp crontab_agrees do
    read = Enum.sort(configured_crontab())
    pinned = Enum.sort(@scheduled_crontab)

    added = read -- pinned
    removed = pinned -- read

    cond do
      added != [] ->
        {:error,
         "the configured crontab gained #{inspect(added)}. Every ABSENT clock verdict in this " <>
           "register is only true while the crontab is exactly what it pins. Classify the new " <>
           "row: if it is the actor a promise here was missing, move that row's verdict; if it " <>
           "is unrelated, add it to @scheduled_crontab in the same commit."}

      removed != [] ->
        {:error,
         "the configured crontab lost #{inspect(removed)} — a scheduled actor this register " <>
           "counted on is gone"}

      true ->
        {:ok, "crontab equality holds over #{length(read)} rows"}
    end
  end

  # THE REQUIRED ZERO-HIT SEARCH. `:crontab_absent` and `:external_only` both
  # claim "nothing here reaches that day"; on the crontab read alone that is
  # indistinguishable from "I failed to look anywhere else". Every such row
  # declares a `%{pattern, roots}` whose hit count must be ZERO, run over the
  # working tree, and any hit reds NAMING the hit. A search that reads no files
  # at all also reds — an empty corpus proves nothing.
  defp zero_hit_search(%{pattern: pattern, roots: roots, why: why}) do
    re = Regex.compile!(pattern)

    files =
      Enum.flat_map(roots, fn root ->
        dir = Path.expand(root, __DIR__)
        Path.wildcard(Path.join(dir, "**/*.{ex,exs}")) |> Enum.map(&{root, dir, &1})
      end)

    hits =
      Enum.flat_map(files, fn {root, dir, path} ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> Regex.match?(re, line) end)
        |> Enum.map(fn {line, n} ->
          {Path.join(root, Path.relative_to(path, dir)), n, String.trim(line)}
        end)
      end)

    cond do
      files == [] ->
        {:error,
         "the required zero-hit search read NO FILES under #{inspect(roots)} — a search over an " <>
           "empty corpus is exactly the 'I failed to look' verdict this obligation exists to stop"}

      hits != [] ->
        {:error,
         "the required zero-hit search (#{why}) HIT #{length(hits)} line(s): " <>
           "#{inspect(Enum.take(hits, 3))} — the absence this row records is no longer true, so " <>
           "re-derive the verdict rather than widening the pattern"}

      true ->
        {:ok,
         "the required zero-hit search over #{length(files)} file(s) in #{inspect(roots)} found " <>
           "nothing (#{why})"}
    end
  end

  defp resolve_clock({:crontab_absent, search}) do
    with {:ok, detail} <- crontab_agrees(),
         {:ok, searched} <- zero_hit_search(search) do
      {:ok, "ABSENT — #{detail}, and none of them reaches this promise; #{searched}"}
    end
  end

  # THE FIFTH CLOCK. The promise is kept by a process that is not this BEAM, but
  # THIS TREE arms it. Both halves are checked against the pinned file's bytes:
  # the arming literal by equality, and whichever cadence shape was declared.
  # `:no_cadence_in_tree` is not a way of declaring less — the resolver asserts
  # the file carries ZERO cadence-shaped tokens, so a lazily-downgraded row reds.
  @cadence_tokens "OnCalendar|OnUnitActiveSec|cron:|time\\.(Second|Minute|Hour|Duration)|[0-9]+d\\b"

  defp resolve_clock({:external_armed_here, rel, arming, cadence}) do
    path = Path.expand(rel, __DIR__)

    case File.read(path) do
      {:error, reason} ->
        {:error,
         "the pinned arming file #{rel} could not be read (#{inspect(reason)}) — an " <>
           ":external_armed_here verdict rests entirely on that file's bytes, and it must also be " <>
           "declared in CLOUD_PATHS or a PR moving it never runs this suite"}

      {:ok, body} ->
        found = cadence_hits(body)

        cond do
          not String.contains?(body, arming) ->
            {:error,
             "#{rel} no longer contains the arming literal #{inspect(arming)} — nothing in this " <>
               "tree arms the external clock this promise rests on"}

          true ->
            resolve_cadence(rel, arming, cadence, found)
        end
    end
  end

  defp resolve_clock({:crontab_row, worker, schedule}) do
    read = configured_crontab()

    cond do
      {schedule, worker} not in read ->
        {:error,
         "no crontab row schedules #{inspect(worker)} at #{inspect(schedule)} — the configured " <>
           "rows are #{inspect(read)}"}

      not Code.ensure_loaded?(worker) ->
        {:error, "#{inspect(worker)} is scheduled but the module does not load"}

      true ->
        {:ok, "PRESENT — #{inspect(worker)} at #{schedule}"}
    end
  end

  defp resolve_clock({:external_only, :stripe, search}) do
    # Three things must hold for "external only": no local schedule reaches the
    # boundary (the equality read), no in-tree artefact names it either (the
    # MIRROR OBLIGATION — without it this verdict is the dumping ground for "I
    # didn't look"), AND nothing local honours the flag when the day comes. The
    # last is a RUN, not a reading.
    with {:ok, detail} <- crontab_agrees(),
         {:ok, searched} <- zero_hit_search(search) do
      detail = "#{detail}; #{searched}"
      team = team_with_owner()
      {:ok, sub} = Billing.subscribe(team, "supporter")
      {:ok, sub} = sub |> Subscription.changeset(%{cancel_at_period_end: true}) |> Repo.update()

      cond do
        not Billing.entitled?(team) ->
          {:error,
           "entitled?/1 DID honour cancel_at_period_end — this promise has a local reader after " <>
             "all, so the clock verdict must be re-derived"}

        not is_nil(sub.current_period_end) ->
          {:error,
           "the paid plan now stores a period end (#{inspect(sub.current_period_end)}) — the " <>
             "boundary this copy names has a value, so re-derive this row"}

        true ->
          {:ok,
           "EXTERNAL-ONLY — #{detail}; entitled?/1 stays true with cancel_at_period_end set, " <>
             "and a paid plan stores no current_period_end for the boundary to fall on"}
      end
    end
  end

  ## ── CLOCK: the IN-BAND verdicts ────────────────────────────────────────
  #
  # `:synchronous` used to live here as `defp resolve_clock(:synchronous), do:
  # {:ok, "N/A — …"}` — a nullary constant that no state could make fail. It is
  # DELETED, with no fallback clause: a surviving nullary clause is what a
  # builder reaches for at 5pm. Every clause below RUNS the guard the row names,
  # with BOTH CONTROLS. The positive control is the load-bearing half: a
  # resolver that only checks the expired case passes with flying colours when
  # the lookup is broken in every direction and no invitation link ever worked.

  # "Invitations expire after 7 days" — Accounts.get_live_invitation/1,
  # accounts.ex:1205, predicate `i.expires_at > ^now` at :1210.
  defp resolve_clock({:in_band, :invitation_expiry}) do
    {team, owner} = team_and_owner()
    n = System.unique_integer([:positive])
    email = "invitee-#{n}@example.com"

    {:ok, %{invitation: inv, token: raw}} = Accounts.invite_member(team, email, "member", owner)
    window_days = DateTime.diff(inv.expires_at, DateTime.utc_now()) / 86_400

    cond do
      # POSITIVE CONTROL — a LIVE invitation must be ADMITTED.
      is_nil(Accounts.get_live_invitation(raw)) ->
        {:error,
         "IN-BAND GUARD DEAD ON THE POSITIVE ARM: accounts.ex:1205 refused a LIVE invitation " <>
           "(expires_at #{inspect(inv.expires_at)}, #{Float.round(window_days, 2)} days out). An " <>
           "expired-only check would call this row green while the console's invite link never " <>
           "worked at all"}

      window_days < 6.9 or window_days > 7.05 ->
        {:error,
         "the invitation window is #{Float.round(window_days, 2)} days, not the '7 days' the " <>
           "console promises (app.js:19564) — accounts.ex:98 @invite_validity_days has moved and " <>
           "the copy has not"}

      true ->
        :ok = expire_invitation!(inv)

        case Accounts.get_live_invitation(raw) do
          nil ->
            {:ok,
             "IN-BAND — accounts.ex:1205 admitted the live invitation " <>
               "(#{Float.round(window_days, 2)}d window, the console's '7 days') and refused the " <>
               "same token the moment expires_at moved into the past"}

          %TeamInvitation{expires_at: at} ->
            {:error,
             "IN-BAND GUARD GONE: accounts.ex:1210 admitted an invitation whose expires_at is " <>
               "#{inspect(at)} — the console's '7 days' is now enforced by NOTHING, on a route " <>
               "(GET /v1/invitations/:token) with no login in front of it"}
        end
    end
  end

  # "It expires in an hour" — Accounts.reset_password_by_token/2,
  # accounts.ex:1397, predicate at :1408 inside a FOR UPDATE txn.
  defp resolve_clock({:in_band, :reset_expiry}) do
    {_team, user} = team_and_owner()

    {:ok, {_user, live_raw}} = Accounts.request_password_reset(user.email)
    token = live_reset_token(user.id)
    window_minutes = DateTime.diff(token.expires_at, DateTime.utc_now()) / 60

    cond do
      window_minutes < 59 or window_minutes > 60.5 ->
        {:error,
         "the reset window is #{Float.round(window_minutes, 2)} minutes, not the hour the console " <>
           "promises ('It expires in an hour', app.js:4958) — accounts.ex:103 " <>
           "@reset_validity_minutes has moved and the copy has not"}

      # POSITIVE CONTROL — a LIVE link must WORK.
      not match?({:ok, _}, Accounts.reset_password_by_token(live_raw, "a live control password")) ->
        {:error,
         "IN-BAND GUARD DEAD ON THE POSITIVE ARM: accounts.ex:1397 refused a LIVE reset link " <>
           "(#{Float.round(window_minutes, 2)} minutes out). An expired-only check would call this " <>
           "row green while every reset email in production was already dead on arrival"}

      true ->
        {:ok, {_user, dead_raw}} = Accounts.request_password_reset(user.email)
        expired = expire_reset_tokens!(user.id)
        true = expired >= 1

        case Accounts.reset_password_by_token(dead_raw, "a password the clock should refuse") do
          {:error, :invalid_token} ->
            {:ok,
             "IN-BAND — accounts.ex:1397 consumed a live link inside its hour " <>
               "(#{Float.round(window_minutes, 2)} min window) and refused the same shape once " <>
               "expires_at was in the past"}

          other ->
            {:error,
             "IN-BAND GUARD GONE: accounts.ex:1408 answered #{inspect(other)} to an EXPIRED reset " <>
               "link — the console's 'It expires in an hour' (app.js:4958) is enforced by NOTHING"}
        end
    end
  end

  # The in-band CANCEL. Here the two controls are BEFORE and AFTER: the box is
  # live before the request and suspended by the request itself, with no day in
  # between. A resolver that only looked at the end state would pass on a box
  # that had been suspended all along.
  defp resolve_clock({:in_band, :cancel_immediate_suspends}) do
    team = team_with_owner()
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    bp = barkpark_fixture(team)

    before = reload_bp(bp)

    cond do
      before.suspended ->
        {:error,
         "the before-control failed: the box was ALREADY suspended before the cancel request, so " <>
           "an in-band verdict here would be measuring nothing"}

      true ->
        {:ok, _} = Billing.request_cancel(team, false)
        later = reload_bp(bp)

        cond do
          not later.suspended ->
            {:error,
             "the cancel request returned but the box is still live — this promise is NOT kept " <>
               "in-band, so it needs a clock this register does not record"}

          is_nil(later.suspended_at) ->
            {:error, "the box is suspended but carries no suspended_at — re-derive this row"}

          DateTime.diff(DateTime.utc_now(), later.suspended_at) > 60 ->
            {:error,
             "the suspension is stamped #{inspect(later.suspended_at)}, more than a minute before " <>
               "now — that is not the request that just ran"}

          true ->
            {:ok,
             "IN-BAND — the box was live before POST /v1/billing/cancel and suspended at " <>
               "#{inspect(later.suspended_at)} by the request itself; no scheduled day involved"}
        end
    end
  end

  # The in-band DOWNGRADE ceiling, same before/after controls.
  # THE DEVICE-CODE DEADLINE, both controls. The positive one is the non-obvious
  # half and the whole reason this is not a one-liner: a resolver that only
  # checked the expired case PASSES when `inspect/1` is broken in every
  # direction (a typo'd hash, a dropped table, an always-`{:error, _}` clause)
  # — it would be proving that the lookup fails, not that the deadline is
  # enforced. Both codes go through the SAME call.
  defp resolve_clock({:in_band, :device_code_expiry}) do
    {dead, live, expired} = lapsed_and_live_device_codes!()

    case {DeviceAuth.inspect(live.user_code), DeviceAuth.inspect(dead.user_code)} do
      {{:ok, _row}, {:error, :expired_or_invalid}} ->
        {:ok,
         "IN-BAND — DeviceAuth.inspect/1 (device_auth.ex:148) filters `r.expires_at > ^now`: it " <>
           "answered the LIVE code and refused the lapsed one (#{expired} row(s) aged out). " <>
           "The per-minute DeviceAuthReaper cron is hygiene by its own moduledoc and is NOT " <>
           "what keeps this promise"}

      {{:error, why}, _} ->
        {:error,
         "the POSITIVE control failed: a freshly started device code was already refused " <>
           "(#{inspect(why)}), so a refusal of the expired one proves nothing about the deadline"}

      {_, other} ->
        {:error, "an EXPIRED device code was still resolvable: #{inspect(other)}"}
    end
  end

  defp resolve_clock({:in_band, :reconcile_completes_in_band}) do
    team = team_with_owner()
    {:ok, sub} = Billing.subscribe(team, "support_plus")
    boxes = for _ <- 1..4, do: barkpark_fixture(team)
    {:ok, _} = sub |> Subscription.changeset(%{plan: "supporter"}) |> Repo.update()

    suspended_now = fn -> Enum.count(boxes, &reload_bp(&1).suspended) end
    before = suspended_now.()

    cond do
      before != 0 ->
        {:error,
         "the before-control failed: #{before} of 4 boxes were suspended by the plan write alone, " <>
           "so this row cannot tell an in-band act from a pre-existing state"}

      true ->
        _ = Billing.reconcile_plan_limit(team)
        later = suspended_now.()

        if later == 1 do
          {:ok,
           "IN-BAND — 0 of 4 boxes were suspended after the plan write, 1 after the call that " <>
             "the plan transition makes; the ceiling is enforced by the request, not by a clock"}
        else
          {:error,
           "reconcile_plan_limit/1 left #{later} of 4 boxes suspended against a 3-box plan — the " <>
             "in-band verdict for this row must be re-derived"}
        end
    end
  end

  defp resolve_cadence(rel, arming, :no_cadence_in_tree, []) do
    {:ok,
     "EXTERNAL, ARMED HERE — #{rel} carries #{inspect(arming)} and ZERO cadence-shaped tokens; " <>
       "the renewing interval is an internal of the external binary, not a fact of this repo"}
  end

  defp resolve_cadence(rel, _arming, :no_cadence_in_tree, found) do
    {:error,
     "this row declares :no_cadence_in_tree, but #{rel} carries #{length(found)} cadence-shaped " <>
       "token(s): #{inspect(Enum.take(found, 3))}. Declare {:cadence, \"<literal>\"} and let the " <>
       "resolver check it — the taxonomy pin folds tuples with elem/2 and cannot see arity, so " <>
       "this downgrade is invisible to everything except this clause"}
  end

  defp resolve_cadence(rel, arming, {:cadence, literal}, found) do
    body = File.read!(Path.expand(rel, __DIR__))

    cond do
      not String.contains?(body, literal) ->
        {:error,
         "this row declares the cadence #{inspect(literal)}, which is NOT in #{rel} — an " <>
           "invented interval is exactly the lore an :external_armed_here row must not carry"}

      found == [] ->
        {:error,
         "this row declares a cadence but #{rel} carries no cadence-shaped token at all — either " <>
           "the literal is not a cadence or the discriminator has stopped matching"}

      true ->
        {:ok,
         "EXTERNAL, ARMED HERE — #{rel} carries #{inspect(arming)} and the declared cadence " <>
           "#{inspect(literal)} (#{length(found)} cadence-shaped line(s))"}
    end
  end

  defp cadence_hits(body) do
    re = Regex.compile!(@cadence_tokens)

    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> Regex.match?(re, line) end)
    |> Enum.map(fn {line, n} -> {n, String.trim(line)} end)
  end

  ## ── ACTOR ──────────────────────────────────────────────────────────────

  # The DISCHARGED row's actor: the REAL producer, run, with an observer
  # pre-armed on an effect row. A cron probe would not do — see the moduledoc.
  defp resolve_actor({:producer_run, :teardown_enqueued}) do
    team = team_with_owner()
    _sub = trial_sub(team, -3600)
    bp = barkpark_fixture(team)

    # Observer pre-armed: the effect row does not exist yet.
    assert deprovision_jobs(bp.id) == [],
           "the observer was not pre-armed — a deprovision job already existed before the run"

    case perform_job(TrialExpiryWorker, %{}) do
      {:ok, %{expired: expired, teardowns: teardowns}} when expired >= 1 and teardowns >= 1 ->
        case deprovision_jobs(bp.id) do
          [%ProvisionJob{kind: "deprovision"} = job] ->
            {:ok,
             "RAN — perform_job(TrialExpiryWorker) reported expired=#{expired} " <>
               "teardowns=#{teardowns} and the observer caught ProvisionJob #{job.id} " <>
               "(kind: \"deprovision\") on box #{bp.id}"}

          other ->
            {:error,
             "the producer ran but the observer caught no single deprovision row: #{inspect(other)}"}
        end

      other ->
        {:error, "perform_job(TrialExpiryWorker, %{}) returned #{inspect(other)}"}
    end
  end

  # The grace-elapse promise's actor, resolved by DRIVING the only path that
  # reaches it. mark_past_due/2 with no attrs is exactly what the
  # invoice.payment_failed webhook does; it re-anchors grace to now+3d before
  # maybe_enforce/1 looks at it, so the branch can never be true on that path.
  defp resolve_actor({:unreachable, :grace_reanchors_on_every_delivery}) do
    team = team_with_owner()
    {:ok, sub} = Billing.subscribe(team, "supporter")
    bp = barkpark_fixture(team)

    # First delivery, then a redelivery — the only shape this path takes.
    {:ok, _} = Billing.mark_past_due(sub)
    sub = Repo.get!(Subscription, sub.id)
    {:ok, _} = Billing.mark_past_due(sub)
    sub = Repo.get!(Subscription, sub.id)

    cond do
      reload_bp(bp).suspended ->
        {:error,
         "a bare mark_past_due/2 DID suspend the box — the grace branch is reachable after all, " <>
           "so this row's ACTOR verdict must be re-derived"}

      # cch-w57-bl RE-POINTED these three arms from `current_period_end` to
      # `grace_ends_at`. They assert the SAME property — the attr-less path
      # anchors a FUTURE grace window, which is why maybe_enforce/1's suspend is
      # unreachable — off the column that now actually carries the dunning
      # anchor. Leaving them on `current_period_end` would have turned the
      # verdict's whole basis into a read of a column mark_past_due/2 no longer
      # writes: the FIRST arm would fire on every run and the row would report a
      # missing anchor that is in fact present, one column over.
      is_nil(sub.grace_ends_at) ->
        {:error, "the grace anchor was not written at all — re-derive this row"}

      DateTime.compare(sub.grace_ends_at, DateTime.utc_now()) != :gt ->
        {:error,
         "the grace anchor landed in the PAST (#{inspect(sub.grace_ends_at)}) — the " <>
           "re-anchor this verdict rests on is gone"}

      # The SPLIT itself, pinned here rather than in a new row: the dunning path
      # must leave `current_period_end` — the TRIAL expiry — untouched. A future
      # re-merge of the two clocks reds this arm.
      not is_nil(sub.current_period_end) ->
        {:error,
         "mark_past_due/2 wrote current_period_end (#{inspect(sub.current_period_end)}) — the " <>
           "dunning anchor is back on the trial-expiry column, so cch-w57-bl's split is gone"}

      true ->
        {:ok,
         "UNREACHABLE — two deliveries of the only event that reaches maybe_enforce/1 left the " <>
           "box live and pushed grace_ends_at forward to #{inspect(sub.grace_ends_at)}, with " <>
           "current_period_end still nil"}
    end
  end

  defp resolve_actor({:synchronous_call, :request_cancel_immediate}) do
    team = team_with_owner()
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    bp = barkpark_fixture(team)

    case Billing.request_cancel(team, false) do
      {:ok, %Subscription{status: "canceled"}} ->
        if reload_bp(bp).suspended_reason == "billing_lapsed" do
          {:ok,
           "RAN — request_cancel(team, false) canceled the sub and suspended the box in-band"}
        else
          {:error, "request_cancel(team, false) canceled the sub but suspended nothing"}
        end

      other ->
        {:error, "request_cancel(team, false) returned #{inspect(other)}"}
    end
  end

  defp resolve_actor({:synchronous_call, :reconcile_plan_limit}) do
    team = team_with_owner()
    {:ok, sub} = Billing.subscribe(team, "support_plus")
    for _ <- 1..4, do: barkpark_fixture(team)

    {:ok, _} = sub |> Subscription.changeset(%{plan: "supporter"}) |> Repo.update()

    case Billing.reconcile_plan_limit(team) do
      %{suspended: 1, restored: 0} ->
        quota =
          Registry.list_barkparks(team) |> Enum.filter(&(&1.suspended_reason == "quota_exceeded"))

        if length(quota) == 1 do
          {:ok,
           "RAN — reconcile_plan_limit/1 suspended 1 box as quota_exceeded against a 3-box plan"}
        else
          {:error, "reconcile reported 1 suspend but #{length(quota)} rows carry quota_exceeded"}
        end

      other ->
        {:error,
         "reconcile_plan_limit/1 returned #{inspect(other)} against 4 boxes on a 3-box plan"}
    end
  end

  # THE IN-BAND ACTOR. For a deadline promise the actor is the request that
  # arrives after the day has passed — so it is resolved by making that request,
  # both before the deadline (it must WORK) and after it (it must be refused).
  defp resolve_actor({:in_band_guard, :invitation_accept}) do
    n = System.unique_integer([:positive])
    email = "invitee-#{n}@example.com"
    {:ok, invitee} = Accounts.register_user(%{email: email, password: @password})

    {live_team, live_owner} = team_and_owner()
    {:ok, %{token: live_raw}} = Accounts.invite_member(live_team, email, "member", live_owner)

    {dead_team, dead_owner} = team_and_owner()

    {:ok, %{invitation: dead_inv, token: dead_raw}} =
      Accounts.invite_member(dead_team, email, "member", dead_owner)

    :ok = expire_invitation!(dead_inv)

    case {Accounts.accept_invitation(live_raw, invitee),
          Accounts.accept_invitation(dead_raw, invitee)} do
      {{:ok, _membership}, {:error, :invalid_token}} ->
        {:ok,
         "RAN — accept_invitation/2 admitted the live invitation on team #{live_team.slug} and " <>
           "refused the expired one on #{dead_team.slug} with :invalid_token"}

      {{:ok, _}, other} ->
        {:error,
         "accept_invitation/2 answered #{inspect(other)} to an EXPIRED invitation — the deadline " <>
           "is enforced on the lookup page but not on the accept path"}

      {other, _} ->
        {:error,
         "the positive control failed: accept_invitation/2 answered #{inspect(other)} to a LIVE " <>
           "invitation, so the negative arm below proves nothing"}
    end
  end

  defp resolve_actor({:in_band_guard, :reset_by_token}) do
    {_team, user} = team_and_owner()
    {:ok, {_user, raw}} = Accounts.request_password_reset(user.email)
    new_password = "the reset actor ran here"

    case Accounts.reset_password_by_token(raw, new_password) do
      {:ok, _updated} ->
        # Single-use: the same link replayed must be refused, or "expired"
        # would be the only thing standing between a leaked link and an
        # account.
        case Accounts.reset_password_by_token(raw, "a replay of the same link") do
          {:error, :invalid_token} ->
            if Accounts.get_user_by_email_and_password(user.email, new_password) do
              {:ok,
               "RAN — reset_password_by_token/2 consumed a live link (the new password now " <>
                 "authenticates) and refused the replay of that same link"}
            else
              {:error,
               "reset_password_by_token/2 returned {:ok, _} but the new password does not " <>
                 "authenticate — the act the console promises did not happen"}
            end

          other ->
            {:error, "the consumed reset link was accepted a SECOND time: #{inspect(other)}"}
        end

      other ->
        {:error,
         "the positive control failed: reset_password_by_token/2 answered #{inspect(other)} to a " <>
           "LIVE link"}
    end
  end

  # NOT "unverified" — resolved by the same equality read that backs the clock,
  # plus the absence of any local reader (proven in the clock arm above).
  # THE REMINDER PRODUCER, run. A trial 12 h from its boundary is inside the
  # worker's one-day threshold, so a real `perform_job/2` must report
  # `noticed_1d: 1`. The observer is pre-armed: the team's 1-day stamp must be
  # nil BEFORE the run, or a stamp found afterwards would prove nothing.
  defp resolve_actor({:producer_run, :reminder_claimed}) do
    {team, _user} = team_and_owner()
    _sub = trial_sub(team, 12 * 3600)

    assert is_nil(Repo.get!(Team, team.id).trial_notice_1d_sent_at),
           "the observer was not pre-armed — the 1-day notice stamp was already claimed"

    case perform_job(TrialExpiryWorker, %{}) do
      {:ok, %{noticed_1d: noticed}} when noticed >= 1 ->
        {:ok,
         "RAN — perform_job(TrialExpiryWorker) reported noticed_1d=#{noticed} for a trial 12 h " <>
           "from its boundary; the reminder is produced by the same hourly worker the teardown " <>
           "rows pin, on an earlier day"}

      other ->
        {:error,
         "the reminder producer sent nothing for a trial inside the 1-day window: " <>
           "#{inspect(other)}"}
    end
  end

  # THE HALT, run — a NEGATIVE promise, so the non-vacuity control carries the
  # weight. `next_autoupdate_candidate/0` must return the fixture box BEFORE
  # the halted tick; without that assertion an empty candidate set would make
  # "nothing advanced" true for a reason that has nothing to do with the halt.
  #
  # No un-halted control, deliberately and by measurement: the advance step
  # calls `Registry.trigger_self_update/1`, which POSTs to the box's host. The
  # fixture host is TEST-NET-3 and unroutable, so an un-halted arm would hang
  # on a socket rather than measure anything. The halted branch returns before
  # any network call, which is exactly why this arm is hermetic.
  defp resolve_actor({:producer_run, :halt_blocks_advance}) do
    team = team_with_owner()
    bp = behind_candidate!(team)

    case Registry.next_autoupdate_candidate() do
      %Barkpark{id: id} when id == bp.id ->
        :ok

      other ->
        flunk(
          "the candidate control is VACUOUS: next_autoupdate_candidate/0 returned #{inspect(other)}, not the fixture box #{bp.id} — 'nothing advanced' would be true with no halt at all"
        )
    end

    {:ok, _settings} = Registry.set_autoupdate_halted(true)
    assert Registry.autoupdate_halted?(), "the kill switch did not persist"

    case perform_job(AutoupdateRolloutWorker, %{}) do
      :ok ->
        {:ok,
         "RAN — perform_job(AutoupdateRolloutWorker) ticked with box #{bp.id} standing as the " <>
           "next candidate and the fleet halted; the worker settles and returns without " <>
           "reaching advance/0"}

      other ->
        {:error, "perform_job(AutoupdateRolloutWorker, %{}) returned #{inspect(other)}"}
    end
  end

  # THE DEVICE-APPROVE GUARD, both controls, through the one call a browser
  # makes. `approve/2` is the only write that can turn a pending request into a
  # mintable one, so it is where the deadline has to hold.
  defp resolve_actor({:in_band_guard, :device_approve}) do
    {_team, user} = team_and_owner()
    {dead, live, _expired} = lapsed_and_live_device_codes!()

    case {DeviceAuth.approve(live.user_code, user.id),
          DeviceAuth.approve(dead.user_code, user.id)} do
      {:ok, {:error, :expired_or_invalid}} ->
        {:ok,
         "IN-BAND GUARD — DeviceAuth.approve/2 (device_auth.ex:176) approved the LIVE code and " <>
           "refused the lapsed one; the same predicate that gates inspect/1 gates the write"}

      {other, _} when other != :ok ->
        {:error,
         "the POSITIVE control failed: approving a LIVE device code returned #{inspect(other)}, " <>
           "so refusing the expired one proves nothing"}

      {_, other} ->
        {:error, "an EXPIRED device code was APPROVED: #{inspect(other)}"}
    end
  end

  defp resolve_actor(:none_local) do
    with {:ok, detail} <- crontab_agrees() do
      {:ok, "NONE LOCAL — #{detail}; no scheduled worker and no in-band caller reaches this act"}
    end
  end

  ## ── EFFECT ─────────────────────────────────────────────────────────────

  # What a suspension IS: the set of columns that change on a real row, plus the
  # tree fact that nothing in cloud/lib powers a machine off.
  defp resolve_effect({:flag_only, :suspend_update_all}) do
    team = team_with_owner()
    bp = barkpark_fixture(team)

    before = Map.from_struct(reload_bp(bp))
    {:ok, 1} = Registry.suspend_team_barkparks(team, "billing_lapsed")
    later = Map.from_struct(reload_bp(bp))

    changed =
      before
      |> Enum.filter(fn {k, v} -> Map.fetch!(later, k) != v end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    with :ok <- assert_flag_only_columns(changed),
         {:ok, poweroff} <- poweroff_is_an_uncalled_catalog_entry() do
      {:ok, "FLAG-ONLY — one update_all changed exactly #{inspect(changed)}; #{poweroff}"}
    end
  end

  defp resolve_effect({:absent, :free_plan_write}) do
    team = team_with_owner()
    sub = trial_sub(team, -3600)
    _bp = barkpark_fixture(team)

    {:ok, _} = perform_job(TrialExpiryWorker, %{})
    after_run = Repo.get!(Subscription, sub.id)

    if after_run.plan == "free" do
      {:error,
       "the trial row DID land on \"free\" — the console's promise is kept after all, so this " <>
         "row's EFFECT verdict must be re-derived"}
    else
      {:ok,
       "ABSENT — after the expiry run the subscription still reads plan=#{inspect(after_run.plan)} " <>
         "status=#{inspect(after_run.status)}; nothing writes the free plan the copy names"}
    end
  end

  # THE REFUSAL'S EFFECT. A guard that returns an error tuple and still writes
  # is not a guard, so these arms observe the WORLD after the refusal, not the
  # return value.
  defp resolve_effect({:refused, :no_membership_from_expired_invite}) do
    n = System.unique_integer([:positive])
    email = "invitee-#{n}@example.com"
    {:ok, invitee} = Accounts.register_user(%{email: email, password: @password})
    {team, owner} = team_and_owner()

    {:ok, %{invitation: inv, token: raw}} = Accounts.invite_member(team, email, "member", owner)
    :ok = expire_invitation!(inv)

    _ = Accounts.accept_invitation(raw, invitee)

    case Accounts.get_membership(team, invitee) do
      nil ->
        {:ok,
         "REFUSED — after an expired invite was presented, #{email} holds NO membership on " <>
           "#{team.slug}; the refusal is a state, not just a return value"}

      membership ->
        {:error,
         "an EXPIRED invitation still produced a membership (#{inspect(membership.role)} on " <>
           "#{team.slug}) — the guard returns an error and writes anyway"}
    end
  end

  defp resolve_effect({:refused, :expired_reset_keeps_old_password}) do
    {_team, user} = team_and_owner()
    {:ok, {_user, raw}} = Accounts.request_password_reset(user.email)
    1 = expire_reset_tokens!(user.id)
    attempted = "the password an expired link tried to set"

    _ = Accounts.reset_password_by_token(raw, attempted)

    cond do
      is_nil(Accounts.get_user_by_email_and_password(user.email, @password)) ->
        {:error,
         "an EXPIRED reset link left the OLD password unusable — the refusal damaged the account " <>
           "it was protecting"}

      not is_nil(Accounts.get_user_by_email_and_password(user.email, attempted)) ->
        {:error,
         "an EXPIRED reset link CHANGED the password anyway — the console's 'It expires in an " <>
           "hour' is enforced by nothing that matters"}

      true ->
        {:ok,
         "REFUSED — after an expired reset link the old password still authenticates and the " <>
           "password the link tried to set does not"}
    end
  end

  # The Caddy row's effect: the renewal is NOT this plane's to produce. Read the
  # tree rather than describing it — if cert-minting ever moves in-house, this
  # row's whole external verdict has to be re-derived.
  defp resolve_effect({:absent, :local_cert_renewal}) do
    search = %{
      pattern: "certmagic|renew_cert|obtain_cert|cert_renew",
      roots: ["../../lib"],
      why: "nothing in cloud/lib mints or renews a certificate"
    }

    case zero_hit_search(search) do
      {:ok, detail} ->
        {:ok,
         "ABSENT LOCALLY — #{detail}; the renewal this copy promises is produced by Caddy's own " <>
           "binary, and this plane only arms it"}

      err ->
        err
    end
  end

  defp resolve_effect({:unread, :cancel_at_period_end}) do
    team = team_with_owner()
    {:ok, sub} = Billing.subscribe(team, "supporter")
    {:ok, _} = sub |> Subscription.changeset(%{cancel_at_period_end: true}) |> Repo.update()

    if Billing.entitled?(team) do
      {:ok, "UNREAD — entitled?/1 answers true on status \"active\" regardless of the flag"}
    else
      {:error, "entitled?/1 honoured cancel_at_period_end — re-derive this row"}
    end
  end

  defp resolve_effect({:produced, :deprovision_job}) do
    team = team_with_owner()
    _sub = trial_sub(team, -3600)
    bp = barkpark_fixture(team)

    {:ok, _} = perform_job(TrialExpiryWorker, %{})

    case deprovision_jobs(bp.id) do
      [%ProvisionJob{kind: "deprovision", status: status}] ->
        {:ok,
         "PRODUCED — one deprovision ProvisionJob (status #{inspect(status)}) on box #{bp.id}"}

      other ->
        {:error, "the named effect was not produced: #{inspect(other)}"}
    end
  end

  # THE NOTICE STAMP IS THE EFFECT. The console promises MAIL, and this plane
  # cannot observe an inbox — what it CAN observe is the write that makes the
  # send happen at most once: `claim_notice/3`'s `UPDATE … WHERE <stamp> IS
  # NULL`. So the resolver runs the producer TWICE. The first run must stamp;
  # the second must send NOTHING. Without the second run this would pass on a
  # worker that re-sent the same reminder every hour forever — which is a
  # different promise from the one the copy makes.
  defp resolve_effect({:produced, :trial_notice_stamp}) do
    {team, _user} = team_and_owner()
    _sub = trial_sub(team, 12 * 3600)

    {:ok, %{noticed_1d: first}} = perform_job(TrialExpiryWorker, %{})
    stamped = Repo.get!(Team, team.id).trial_notice_1d_sent_at
    {:ok, %{noticed_1d: second}} = perform_job(TrialExpiryWorker, %{})
    still = Repo.get!(Team, team.id).trial_notice_1d_sent_at

    cond do
      first < 1 or is_nil(stamped) ->
        {:error,
         "the first run produced no 1-day notice (noticed_1d=#{first}, stamp=#{inspect(stamped)})"}

      second > 0 ->
        {:error,
         "a SECOND hourly run sent the same reminder again (noticed_1d=#{second}) — the notice " <>
           "budget is not claimed, and the console's one-off promise is not what this plane does"}

      still != stamped ->
        {:error,
         "the second run rewrote the notice stamp: #{inspect(stamped)} -> #{inspect(still)}"}

      true ->
        {:ok,
         "PRODUCED — one run claimed trial_notice_1d_sent_at (#{inspect(stamped)}) and the next " <>
           "hourly run sent nothing (noticed_1d=#{second}), so the reminder is produced exactly once"}
    end
  end

  # THE ABSENCE THE COPY PROMISES. "won't roll out … until you resume" is kept
  # by NOT writing: no `autoupdate_triggered_at`, nothing in flight. The
  # candidate control is re-asserted here rather than inherited from the ACTOR
  # column — the two columns resolve independently, and an effect that trusted
  # another resolver's fixture would be reading a claim, not a row.
  defp resolve_effect({:absent, :no_trigger_stamped}) do
    team = team_with_owner()
    bp = behind_candidate!(team)

    assert %Barkpark{id: id} = Registry.next_autoupdate_candidate()

    assert id == bp.id,
           "the candidate control is VACUOUS — the fixture box is not what the rollout would pick"

    {:ok, _settings} = Registry.set_autoupdate_halted(true)
    :ok = perform_job(AutoupdateRolloutWorker, %{})

    after_run = reload_bp(bp)

    cond do
      not is_nil(after_run.autoupdate_triggered_at) ->
        {:error,
         "the halted tick STAMPED box #{bp.id} in flight at " <>
           "#{inspect(after_run.autoupdate_triggered_at)} — the console's \"until you resume\" " <>
           "is not what this plane does"}

      Registry.autoupdate_in_flight() != [] ->
        {:error,
         "the halted tick left #{length(Registry.autoupdate_in_flight())} box(es) in flight"}

      true ->
        {:ok,
         "ABSENT — with the fleet halted and box #{bp.id} standing as the next candidate, the " <>
           "tick stamped no autoupdate_triggered_at and left nothing in flight"}
    end
  end

  # A lapsed activation code MINTS NOTHING. `poll/1` is the only path from a
  # device code to a token, so the refusal has to hold there and not only at
  # approve/2 — and the LIVE control (`{:pending}`, not a token and not a
  # refusal) is what proves the poll query still works at all.
  defp resolve_effect({:refused, :expired_device_code_mints_nothing}) do
    {_team, user} = team_and_owner()
    {dead, live, _expired} = lapsed_and_live_device_codes!()

    {:error, :expired_or_invalid} = DeviceAuth.approve(dead.user_code, user.id)

    case {DeviceAuth.poll(live.device_code), DeviceAuth.poll(dead.device_code)} do
      {{:pending}, {:error, :expired_or_invalid}} ->
        {:ok,
         "REFUSED — polling the LIVE code answers {:pending} while the lapsed one is refused: " <>
           "the expired request is unapprovable AND unmintable, so no token exists to be issued"}

      {other, _} when other != {:pending} ->
        {:error,
         "the POSITIVE control failed: polling a LIVE pending device code returned " <>
           "#{inspect(other)}, so refusing the expired one proves nothing"}

      {_, other} ->
        {:error, "polling an EXPIRED device code returned #{inspect(other)}, not a refusal"}
    end
  end

  # The four columns a suspend writes. Named here so a fifth column (or a lost
  # one) reds with the diff rather than passing as "some flags moved".
  @suspend_columns [:suspended, :suspended_at, :suspended_reason, :updated_at]

  defp assert_flag_only_columns(changed) do
    if changed == @suspend_columns do
      :ok
    else
      {:error,
       "a suspend changed #{inspect(changed)}, not #{inspect(@suspend_columns)} — this register " <>
         "calls the effect FLAG-ONLY on the strength of exactly those four columns"}
    end
  end

  # Read the tree, do not describe it: the only `poweroff` in cloud/lib is a
  # catalog entry, and nothing calls the verb.
  defp poweroff_is_an_uncalled_catalog_entry do
    # A SINGLE "../…" literal, deliberately: the escape census greps
    # `"\.\./[^"]*"`, and a path spliced through Path.join/1 over a bare ".."
    # produces the literal ".." and is invisible to it. There is an arm below
    # asserting this file contains no such splice.
    lib = Path.expand("../../lib", __DIR__)

    hits =
      Path.wildcard(Path.join(lib, "**/*.ex"))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> String.contains?(line, "poweroff") end)
        |> Enum.map(fn {line, n} -> {Path.relative_to(path, lib), n, String.trim(line)} end)
      end)

    catalog_only? =
      hits != [] and
        Enum.all?(hits, fn {rel, _n, line} ->
          rel == "barkpark_cloud/registry/hetzner_catalog.ex" and
            (String.starts_with?(line, "verb:") or String.starts_with?(line, "path:"))
        end)

    if catalog_only? do
      {:ok,
       "the only poweroff in cloud/lib is the uncalled hetzner_catalog entry " <>
         "(#{length(hits)} lines, all in registry/hetzner_catalog.ex)"}
    else
      {:error,
       "poweroff now appears outside the hetzner catalog entry: #{inspect(hits)} — an effect " <>
         "stronger than a flag may exist, so every FLAG-ONLY verdict here must be re-derived"}
    end
  end

  ## ── The register's arms ────────────────────────────────────────────────

  defp resolve_row(%{clock: clock, actor: actor, effect: effect}) do
    %{clock: resolve_clock(clock), actor: resolve_actor(actor), effect: resolve_effect(effect)}
  end

  test "CLOCK: the configured crontab is exactly what this register pins, by EQUALITY" do
    # This is the arm every ABSENT verdict rests on. It is an equality, not a
    # /Billing|Dunning|Grace/ heuristic: an enforcement worker named e.g.
    # ArrearsWorker slips past a heuristic and the register would keep claiming
    # ABSENT while the clock had arrived.
    assert {:ok, detail} = crontab_agrees()
    # dr-w11: 17 -> 18 (ContentWebhookReconciler).
    # dr-bl-rate-notice: 18 -> 19 (DeployRateAlertWorker).
    assert detail =~ "19 rows"
    assert length(configured_crontab()) == length(@scheduled_crontab)
  end

  test "every row's CLOCK, ACTOR and EFFECT resolve as this register records them" do
    for {{reason, transition}, spec} <- @register do
      for {column, result} <- resolve_row(spec) do
        case result do
          {:ok, _detail} ->
            :ok

          {:error, why} ->
            flunk(
              "#{reason}/#{transition}: the #{column} column does not resolve as recorded: #{why}"
            )
        end
      end
    end
  end

  test "the PAIR key is load-bearing: the two `trial` rows resolve to genuinely different triples" do
    # If both trial rows resolved the same way, a register keyed on the bare
    # reason would have done — and this file would be agreeing with itself
    # rather than discriminating.
    discharged = resolve_row(@register[{"trial", :expire_teardown}])
    unsupported = resolve_row(@register[{"trial", :land_on_free}])

    {:ok, d_clock} = discharged.clock
    {:ok, u_clock} = unsupported.clock
    assert d_clock == u_clock, "the split control must share a clock, or the pair proves nothing"

    {:ok, d_effect} = discharged.effect
    {:ok, u_effect} = unsupported.effect

    assert d_effect =~ "PRODUCED"
    assert u_effect =~ "ABSENT"

    refute d_effect == u_effect,
           "the two trial rows resolved identically — the (reason, transition) key is doing no " <>
             "work and a state key would have sufficed"
  end

  test "EFFECT: a suspension is four columns and nothing in cloud/lib powers a box off" do
    # Stated as its own test so the property is visible without reading
    # resolve_effect/1.
    assert {:ok, detail} = resolve_effect({:flag_only, :suspend_update_all})
    assert detail =~ "[:suspended, :suspended_at, :suspended_reason, :updated_at]"
    assert detail =~ "uncalled hetzner_catalog entry"
  end

  test "ACTOR: the discharged row is backed by the real producer, not by its cron row" do
    # A cron probe proves the module is scheduled and loads. It survives a
    # perform/1 gutted to :ok (measured in this epic on
    # AutoupdateRolloutWorker). So the DISCHARGED verdict costs a run whose
    # observer sits on an effect row.
    assert {:ok, detail} = resolve_actor({:producer_run, :teardown_enqueued})
    assert detail =~ "perform_job(TrialExpiryWorker)"
    assert detail =~ "kind: \"deprovision\""
  end

  test "every repo-root read in this file is a single \"../…\" literal the escape census can see" do
    # scripts/cloud-path-escape-check.sh greps `"\.\./[^"]*"` and requires every
    # resolved repo-root read to be declared in CLOUD_PATHS. A read spliced as
    # segment produces the literal ".." — which
    # that grep does not match — so an :external_armed_here row written that way
    # would publish green on PRs that never ran it. The split idiom IS live in
    # this tree (billing_client_mirror_test.exs:70), so this is a real hole and
    # this file closes it for itself.
    source = File.read!(__ENV__.file)

    refute Regex.match?(~r/Path\.join\(\[[^\]]*"\.\."/, source),
           "this file builds a path by splicing \"..\" through Path.join/1 — the escape census " <>
             "cannot see that read, so the file it points at need never be declared in " <>
             "CLOUD_PATHS. Write it as a single \"../…\" string literal."

    assert String.contains?(source, "\"../../../internal/caddyfile/caddyfile.go\""),
           "the Caddy arming read is no longer a single literal — the census would stop seeing it"
  end

  test "ADD: every deferred-act sentence the console ships is claimed by a register row" do
    rows = console_deferred_acts!()

    for row <- rows do
      sentence = Map.fetch!(row, "sentence")
      lines = Map.fetch!(row, "lines")

      key =
        Map.get(@promised_sentences, sentence) ||
          flunk(
            "the console promises #{inspect(sentence)} (app.js:" <>
              "#{Enum.join(lines, ", :")}) and NOTHING in this register claims it. A deferred " <>
              "act with no row is not 'verified absent' and not 'verified present' — it is " <>
              "UNEXAMINED. Either add a row resolving its CLOCK, ACTOR and EFFECT and index the " <>
              "sentence in @promised_sentences, or stop promising it."
          )

      assert Map.has_key?(@register, key),
             "@promised_sentences maps #{inspect(sentence)} to #{inspect(key)}, which is not a " <>
               "row of @register — the index points at a promise nobody resolves"
    end
  end

  test "DELETE: every indexed sentence is still shipped — an emptied census reds as a stale pin" do
    # WHY THIS TEST EXISTS AT ALL. The ADD test above iterates what the census
    # EMITS, so a census returning [] passes it at ZERO ITERATIONS — vacuously
    # green while the console's promises go unread. This is the other
    # direction, and it is only possible because @promised_sentences is pinned
    # in this file rather than derived from the census. Same shape, same
    # reason, as sold_capability_manifest_test.exs:261 (charter D564).
    rows = console_deferred_acts!()
    shipped = MapSet.new(rows, &Map.fetch!(&1, "sentence"))

    assert map_size(@promised_sentences) > 0,
           "the sentence index is EMPTY — an empty index claims nothing and can red at nothing"

    refute Enum.empty?(rows),
           "the census emitted NO deferred-act sentence at all while this file pins " <>
             "#{map_size(@promised_sentences)}. Either every promise was deleted from the " <>
             "console in one commit, or the census stopped seeing them — and the two must not " <>
             "read alike."

    for {sentence, key} <- @promised_sentences do
      assert MapSet.member?(shipped, sentence),
             "@promised_sentences pins #{inspect(sentence)} (row #{inspect(key)}) but the " <>
               "console no longer ships it. The census emits: " <>
               "#{inspect(Enum.sort(MapSet.to_list(shipped)))}. If the copy was deleted on " <>
               "purpose, delete its index entry in the same commit — and check whether its " <>
               "@register row still has a promise to be about."
    end
  end

  test "META: the register actually iterated every row and exercised every resolver kind" do
    # Without this, gutting a resolver to `{:ok, "fine"}` — or emptying
    # @register — would leave a green suite that compared nothing.
    resolved = for {key, spec} <- @register, do: {key, resolve_row(spec)}

    assert length(resolved) == map_size(@register)

    assert map_size(@register) == 12,
           "the register seeded 9 rows and the cch-w56-bl ADD direction found 3 more; it now " <>
             "holds #{map_size(@register)}"

    # THE CONVERSE IS DELIBERATELY NOT ASSERTED. Five rows here are claimed by
    # no indexed sentence — billing_past_due, cancel_immediate,
    # quota_exceeded, custom_domain and trial/land_on_free — because the copy
    # they are about is not phrased as a DEADLINE ("your instances are
    # suspended", "Custom domains with automatic TLS"). Requiring every row to
    # carry a census sentence would force those five to be deleted or their
    # copy to be re-written to suit the instrument, which is the instrument
    # choosing the population again. The census widens what this register can
    # SEE; it does not become the only reason a row may exist.

    reasons = @register |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

    assert reasons == [
             "autoupdate_halted",
             "billing_lapsed",
             "billing_past_due",
             "custom_domain",
             "device_activation",
             "password_reset",
             "quota_exceeded",
             "team_invitation",
             "trial"
           ]

    kind = fn
      tuple when is_tuple(tuple) -> elem(tuple, 0)
      atom when is_atom(atom) -> atom
    end

    clock_kinds =
      @register |> Map.values() |> Enum.map(&kind.(&1.clock)) |> Enum.uniq() |> Enum.sort()

    actor_kinds =
      @register |> Map.values() |> Enum.map(&kind.(&1.actor)) |> Enum.uniq() |> Enum.sort()

    effect_kinds =
      @register |> Map.values() |> Enum.map(&kind.(&1.effect)) |> Enum.uniq() |> Enum.sort()

    # NOTE the blind spot this pin has and the resolvers close: `kind` folds a
    # tuple with elem/2, so payload ARITY IS INVISIBLE here. A row downgraded
    # from {:external_armed_here, path, literal, cadence} to an arming-only
    # payload walks straight through this line — resolve_cadence/4 is what reds.
    assert clock_kinds == [
             :crontab_absent,
             :crontab_row,
             :external_armed_here,
             :external_only,
             :in_band
           ]

    assert actor_kinds == [
             :in_band_guard,
             :none_local,
             :producer_run,
             :synchronous_call,
             :unreachable
           ]

    assert effect_kinds == [:absent, :flag_only, :produced, :refused, :unread]

    refute :synchronous in clock_kinds,
           "the nullary :synchronous clock is back — it took no subject, read no config and " <>
             "touched no DB, so no state could make it fail"

    # And every resolution reported a non-empty detail — a resolver that
    # returns {:ok, ""} is a resolver that measured nothing.
    for {key, columns} <- resolved, {column, {:ok, detail}} <- columns do
      assert is_binary(detail) and detail != "",
             "#{inspect(key)}'s #{column} resolved with no detail to report"
    end
  end
end
