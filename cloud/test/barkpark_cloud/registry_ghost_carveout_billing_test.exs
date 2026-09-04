defmodule BarkparkCloud.RegistryGhostCarveoutBillingTest do
  @moduledoc """
  The `:active_subscription` leg of `Registry.claim_leg/2` — the ONE leg of the
  abandoned-ghost carve-out that asks a billing question. This file drives that
  leg from BOTH sides, because the leg has two opposite failure modes and a fix
  for either one can silently create the other:

    * TOO NARROW → a NAME STEAL. A paid, unsuspended row that merely looks idle
      reads as an abandoned ghost and its provisioning FQDN becomes attachable
      by another tenant. This is the shape
      `dr-w24-bl-ghost-carveout-releases-billed-name` describes.
    * TOO WIDE → a PERMANENT HOSTNAME LEAK. A row whose team is NOT paying for
      anything holds its FQDN forever and no owner can ever release it. This is
      the shape the carve-out was BUILT to fix (the June-29 gyldendal squat the
      `provisioning_fqdn_claim/2` doc records).

  ## Why the leg needs `Billing.entitled?/1` and not a raw status read

  `subscriptions.status` is only `active | canceled | past_due`, and it is NOT
  the entitlement answer:

    * Every signup grants a `trial` subscription (`Billing.grant_trial/1`, run
      from BOTH signup paths — `Accounts.birth_oauth_user!/1` and the router's
      password `register/3`) with `plan: "trial", status: "active"`.
    * An EXPIRED trial is not flipped off `active` AT THE MOMENT IT EXPIRES.
      Until cch-w50 nothing flipped it ever: `TrialExpiryWorker` enqueued
      deprovision jobs (`teardown/1`) and wrote no subscription status, so 15 of
      18 live rows sat `active` past their window, the oldest for three weeks.
      It now writes the terminal status (`Billing.expire_trial/2`) — but only
      once the teardown has COMPLETED, on the hourly tick after the boxes are
      gone, so `plan: "trial", status: "active", current_period_end` in the past
      remains a real, reachable shape and every fixture below still reproduces
      it. The leg must therefore keep asking `entitled?/1`, which reads expiry at
      CALL TIME off `current_period_end`, and must never go back to reading
      `status`.
    * `plan: "free"` is the no-charge signup tier and is likewise `active`.

  So `status IN ('active','past_due')` is true, forever, for essentially every
  team that has ever signed up — which swallows the whole carve-out. Note the
  fixtures below have to build that shape BY HAND: `Accounts.create_team/1`
  (what every test fixture in this repo calls) does NOT grant a trial, so the
  suite's teams carry no subscription row at all and never reproduce it.

  `Billing.entitled?/1` is the platform's own answer to "are we still serving
  this team" — the same predicate the managed-launch gate reads — so the leg
  asks IT rather than keeping a second, drifting copy of the rule.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.Usage.Sample

  ## ── Fixtures ─────────────────────────────────────────────────────────────

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # A UNIQUE host per test — this suite shares one database with every other
  # agent's suite, so a fixed hostname would let a neighbour's row answer for
  # ours (and would make a `:free` assertion pass or fail by luck).
  defp unique_host do
    "ghost-#{System.unique_integer([:positive])}.barkpark.cloud"
  end

  # The silence-only ghost shape, and NOTHING else: url squats `host`, the agent
  # never phoned home (`last_seen_at` nil), the row is older than the 7-day
  # abandonment window, no provision job, no admin token, no usage samples.
  # Every non-billing leg is therefore OFF, so whatever `provisioning_fqdn_claim`
  # answers here is the billing leg's answer alone.
  defp silent_ghost(team, host) do
    n = System.unique_integer([:positive])

    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "https://" <> host,
      inserted_at: DateTime.add(DateTime.utc_now(), -30, :day)
    )
    |> Repo.update!()
  end

  # Subscriptions are inserted AFTER the barkpark on purpose: `register_barkpark/2`
  # runs `Billing.barkpark_limit_reached?/1`, whose ceiling is per-plan, so
  # seeding the plan first would change what the fixture is even able to build.
  defp subscription(team, attrs) do
    Repo.insert!(struct!(%Subscription{team_id: team.id}, attrs))
  end

  defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n, :day)
  defp days_ahead(n), do: DateTime.add(DateTime.utc_now(), n, :day)

  # The cited live shape: a long unreachable-sample history that STOPPED. The
  # `:recent_usage_sample` leg is existence-inside-24h only, so samples older
  # than the window leave it OFF — which is exactly what makes the billed row
  # in the steal scenario look abandoned to every leg but the billing one.
  defp stale_unreachable_samples(bp, count) do
    for i <- 1..count do
      Repo.insert!(%Sample{
        barkpark_id: bp.id,
        envelope: %{"meters" => %{}, "reachable" => false, "status" => "unreachable"},
        measured_at: DateTime.add(DateTime.utc_now(), -(2 + i), :day)
      })
    end
  end

  ## ── Direction A: a BILLED row is NEVER released ──────────────────────────
  ##
  ## This is the row's own stated defect. These cases must be green BEFORE and
  ## AFTER any change to the leg — a fix that narrows the billing question must
  ## not narrow it past a customer who is actually paying.

  describe "the billed row keeps its name (the steal direction)" do
    test "a paid, unsuspended row with a long DEAD unreachable history still holds its FQDN" do
      team = team_fixture()
      host = unique_host()
      ghost = silent_ghost(team, host)

      # Unreachable forever, and the sampler gave up days ago: no leg but the
      # billing one can possibly hold this name.
      stale_unreachable_samples(ghost, 40)
      subscription(team, plan: "supporter", status: "active")

      assert {:held, :active_subscription, why} = Registry.provisioning_fqdn_claim(host)
      assert why =~ ghost.id
    end

    test "a `forever` comp holds its name" do
      team = team_fixture()
      host = unique_host()
      silent_ghost(team, host)
      subscription(team, plan: "forever", status: "active")

      assert {:held, :active_subscription, _} = Registry.provisioning_fqdn_claim(host)
    end

    # cch-w57-bl re-pointed the grace anchor from `current_period_end` to
    # `grace_ends_at`. Seeding the OLD column here would leave this case green for
    # the wrong reason — a past_due row with no anchor at all, which the leg now
    # reads as unbilled — so the case would stop testing "inside grace".
    test "a past_due row INSIDE its grace window is a billed customer and holds its name" do
      team = team_fixture()
      host = unique_host()
      silent_ghost(team, host)
      subscription(team, plan: "supporter", status: "past_due", grace_ends_at: days_ahead(3))

      assert {:held, :active_subscription, _} = Registry.provisioning_fqdn_claim(host)
    end

    test "a LIVE trial holds its name" do
      team = team_fixture()
      host = unique_host()
      silent_ghost(team, host)
      subscription(team, plan: "trial", status: "active", current_period_end: days_ahead(7))

      assert {:held, :active_subscription, _} = Registry.provisioning_fqdn_claim(host)
    end
  end

  ## ── Direction B: a genuine, UNBILLED ghost is still releasable ───────────
  ##
  ## A carve-out that releases nothing is not a safe carve-out — it trades a
  ## name steal for a hostname nobody can ever reclaim.

  describe "the unbilled ghost still releases its name (the leak direction)" do
    test "NON-VACUITY CONTROL: the identical fixture with no subscription reads :free" do
      # The whole file's fixture is proved to REACH the predicate here: same
      # rows, same host shape, same 30-day-old silent row — only the
      # subscription differs. If this ever stopped answering `:free` the
      # `:held` assertions above would be passing for some unrelated reason
      # (a filter catching the fixture) rather than because a leg fired.
      team = team_fixture()
      host = unique_host()
      ghost = silent_ghost(team, host)
      stale_unreachable_samples(ghost, 40)

      assert :free == Registry.provisioning_fqdn_claim(host)
    end

    test "an EXPIRED trial does not hold the name" do
      # Nothing flips an expired trial off `active`, so a raw
      # `status IN ('active','past_due')` read holds this name FOREVER — and
      # every signup gets one of these rows.
      team = team_fixture()
      host = unique_host()
      silent_ghost(team, host)
      subscription(team, plan: "trial", status: "active", current_period_end: days_ago(30))

      assert :free == Registry.provisioning_fqdn_claim(host)
    end

    test "a trial with NO period end is malformed, never entitled, and does not hold the name" do
      team = team_fixture()
      host = unique_host()
      silent_ghost(team, host)
      subscription(team, plan: "trial", status: "active", current_period_end: nil)

      assert :free == Registry.provisioning_fqdn_claim(host)
    end

    test "a past_due row PAST its grace window does not hold the name" do
      team = team_fixture()
      host = unique_host()
      silent_ghost(team, host)
      subscription(team, plan: "supporter", status: "past_due", grace_ends_at: days_ago(5))

      assert :free == Registry.provisioning_fqdn_claim(host)
    end

    # INVERTED by cch-w57-bl, and moved here from the steal direction above. It
    # used to read "a past_due row with NO period end is inside grace BY
    # DEFINITION and holds its name" — the old `entitled?/1` returned true on
    # `is_nil(current_period_end)`, which is precisely the hazard that row was
    # filed for: an unpaid team whose anchor is missing was entitled FOREVER and
    # `maybe_enforce/1` no-opped on the same nil, so its boxes never suspended.
    # An unanchored dunning row is now CLOSED, and this leg — which defers to
    # `entitled?/1` rather than keeping a second copy of the rule — follows it.
    test "a past_due row with NO grace anchor does not hold the name" do
      team = team_fixture()
      host = unique_host()
      silent_ghost(team, host)
      subscription(team, plan: "supporter", status: "past_due", grace_ends_at: nil)

      assert :free == Registry.provisioning_fqdn_claim(host)
    end

    test "a canceled subscription does not hold the name" do
      team = team_fixture()
      host = unique_host()
      silent_ghost(team, host)
      subscription(team, plan: "supporter", status: "canceled", canceled_at: days_ago(20))

      assert :free == Registry.provisioning_fqdn_claim(host)
    end
  end

  ## ── The leg IS `Billing.entitled?/1`, including where that is generous ───

  describe "the leg defers to Billing.entitled?/1 and keeps no second copy" do
    # One table, both sides of the question, driven through the real predicate.
    # This is the guard that matters: it fails the moment the leg starts
    # answering the billing question for itself instead of asking the owner.
    @shapes [
      {[plan: "supporter", status: "active"], "a paid, active subscription"},
      {[plan: "forever", status: "active"], "an admin `forever` comp"},
      {[plan: "free", status: "active"], "the no-charge `free` tier"},
      {[plan: "trial", status: "active", current_period_end_days: 7], "a live trial"},
      {[plan: "trial", status: "active", current_period_end_days: -30], "an EXPIRED trial"},
      {[plan: "trial", status: "active"], "a trial with no window"},
      {[plan: "supporter", status: "past_due", grace_ends_at_days: 3], "past_due in grace"},
      {[plan: "supporter", status: "past_due", grace_ends_at_days: -5], "past_due past grace"},
      {[plan: "supporter", status: "past_due"], "past_due with no window"},
      {[plan: "supporter", status: "canceled"], "a canceled subscription"}
    ]

    for {attrs, label} <- @shapes do
      test "#{label}: the leg's answer is exactly Billing.entitled?/1's" do
        attrs = unquote(attrs)
        team = team_fixture()
        host = unique_host()
        silent_ghost(team, host)

        {offset, attrs} = Keyword.pop(attrs, :current_period_end_days)

        attrs =
          if offset,
            do: Keyword.put(attrs, :current_period_end, days_ahead(offset)),
            else: attrs

        # cch-w57-bl: the dunning window is its OWN column. A past_due shape that
        # kept seeding `current_period_end` would still AGREE with entitled?/1 —
        # the table self-validates — but both sides would be answering about an
        # absent anchor, so "in grace" and "past grace" would stop being
        # distinguishable rows.
        {grace_offset, attrs} = Keyword.pop(attrs, :grace_ends_at_days)

        attrs =
          if grace_offset,
            do: Keyword.put(attrs, :grace_ends_at, days_ahead(grace_offset)),
            else: attrs

        subscription(team, attrs)

        entitled = BarkparkCloud.Billing.entitled?(team)
        claim = Registry.provisioning_fqdn_claim(host)

        case claim do
          {:held, :active_subscription, _} ->
            assert entitled,
                   "the leg held the name but Billing.entitled?/1 says the team is NOT " <>
                     "entitled — the leg has grown a second copy of the billing rule"

          :free ->
            refute entitled,
                   "the leg released the name of an ENTITLED team — this is the name " <>
                     "steal dr-w24-bl-ghost-carveout-releases-billed-name describes"

          other ->
            flunk("another leg answered, so this case proves nothing: #{inspect(other)}")
        end
      end
    end

    # The generosity this deferral inherits, stated out loud rather than left as
    # a silent hole: `Billing.entitled?/1` answers TRUE for `plan: "free"` (its
    # `%Subscription{status: "active"}` clause), so a `free`-tier team's silent
    # ghost keeps its FQDN. That is `entitled?`'s call, not this leg's — it is
    # the same predicate the managed-launch gate reads, and narrowing it here
    # would fork the rule again. Unlike `trial`, a `free` row is NOT granted at
    # signup, so this is a much smaller population than the pre-fix behaviour.
    test "REGRESSION PIN: `free` is held only because entitled?/1 says so" do
      team = team_fixture()
      host = unique_host()
      silent_ghost(team, host)
      subscription(team, plan: "free", status: "active")

      assert BarkparkCloud.Billing.entitled?(team),
             "if entitled?/1 ever stops entitling `free`, this leg must follow it " <>
               "automatically — delete this pin, do not re-fork the rule"

      assert {:held, :active_subscription, _} = Registry.provisioning_fqdn_claim(host)
    end
  end

  ## ── The other legs still outrank billing ─────────────────────────────────
  ##
  ## Narrowing the billing question must not let a row the platform is still
  ## TALKING to fall through to `:free`. These pin that the two hard blocks
  ## answer first even when the team is provably not entitled.

  describe "an unbilled row the platform is still dialling keeps its name" do
    test "an expired trial that still holds a decryptable admin token is :admin_credential" do
      team = team_fixture()
      host = unique_host()

      team
      |> silent_ghost(host)
      |> Ecto.Changeset.change(admin_token_encrypted: "ciphertext")
      |> Repo.update!()

      subscription(team, plan: "trial", status: "active", current_period_end: days_ago(30))

      assert {:held, :admin_credential, _} = Registry.provisioning_fqdn_claim(host)
    end

    test "an expired trial the sampler reached inside the window is :recent_usage_sample" do
      team = team_fixture()
      host = unique_host()
      ghost = silent_ghost(team, host)

      Repo.insert!(%Sample{
        barkpark_id: ghost.id,
        envelope: %{"meters" => %{}},
        measured_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      })

      subscription(team, plan: "trial", status: "active", current_period_end: days_ago(30))

      assert {:held, :recent_usage_sample, _} = Registry.provisioning_fqdn_claim(host)
    end

    test "an expired trial whose agent HAS phoned home is :agent_reporting" do
      team = team_fixture()
      host = unique_host()

      team
      |> silent_ghost(host)
      |> Ecto.Changeset.change(last_seen_at: days_ago(60))
      |> Repo.update!()

      subscription(team, plan: "trial", status: "active", current_period_end: days_ago(30))

      assert {:held, :agent_reporting, _} = Registry.provisioning_fqdn_claim(host)
    end
  end
end
