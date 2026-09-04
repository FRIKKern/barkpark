defmodule BarkparkCloud.BillingLifecycleTest do
  @moduledoc """
  subscription-billing — the lifecycle past `active`: dunning (past_due),
  cancellation, recovery, the suspend/resume teeth, self-serve cancel + portal,
  and the grace-aware entitlement gate. All €0 through StubGateway — no live
  Stripe, no network.
  """
  use BarkparkCloud.DataCase, async: true
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.{Accounts, Billing, Events, Registry, Repo}
  alias BarkparkCloud.Billing.{StripeGateway, StubGateway, Subscription}
  alias BarkparkCloud.Registry.Barkpark

  ## Fixtures

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  # A team with a live `active` subscription on `plan`. Returns {team, sub}.
  defp subscribed_team(plan \\ "supporter") do
    team = team_fixture()
    {:ok, sub} = Billing.subscribe(team, plan)
    {team, sub}
  end

  # Stripe-shaped lifecycle events keyed on the gateway customer id.
  defp event(type, customer_id, extra \\ %{}) do
    object = Map.merge(%{"customer" => customer_id}, extra)

    Jason.encode!(%{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => type,
      "data" => %{"object" => object}
    })
  end

  defp sig, do: StubGateway.test_signature()

  defp reload(%Subscription{id: id}), do: Repo.get!(Subscription, id)
  defp reload_bp(%Barkpark{id: id}), do: Repo.get!(Barkpark, id)

  ## ── Webhook lifecycle ──

  describe "handle_webhook/2 — invoice.payment_failed → past_due (grace, no suspend)" do
    test "marks the live sub past_due and does NOT suspend within grace" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      # The REAL invoice.payment_failed Invoice object carries no period end, so
      # mark_past_due anchors a default FUTURE grace window — no synthetic field.
      raw = event("invoice.payment_failed", sub.gateway_customer_id)

      assert {:ok, %Subscription{status: "past_due", past_due: true}} =
               Billing.handle_webhook(raw, sig())

      # Still entitled (in grace) and the box is NOT suspended.
      assert Billing.entitled?(team)
      refute reload_bp(bp).suspended
    end

    test "a past_due sub whose grace window has elapsed loses entitlement and suspends boxes" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      # Real path: the failed-payment webhook lands past_due in grace (entitled,
      # box untouched) — a single webhook never suspends.
      assert {:ok, %Subscription{status: "past_due"}} =
               Billing.handle_webhook(
                 event("invoice.payment_failed", sub.gateway_customer_id),
                 sig()
               )

      assert Billing.entitled?(team)
      refute reload_bp(bp).suspended

      # Simulate the grace window elapsing: re-anchor grace_ends_at into the past
      # and re-enforce. No sweep detects this in production (charter D657 decided
      # against one) — elapsed grace is felt at request time, via entitled?/1.
      past = DateTime.add(DateTime.utc_now(), -1, :day)
      {:ok, _} = Billing.mark_past_due(reload(sub), %{grace_ends_at: past})

      refute Billing.entitled?(team)
      assert %Barkpark{suspended: true, suspended_reason: "billing_past_due"} = reload_bp(bp)
    end
  end

  describe "mark_past_due/2 — dunning email dedup (transition signal)" do
    test "the FIRST active→past_due returns the sub; a repeat returns {:ok, :already_past_due}" do
      {_team, sub} = subscribed_team()

      # First transition: a real state change → the sub (the router emails once).
      assert {:ok, %Subscription{status: "past_due", past_due: true}} = Billing.mark_past_due(sub)

      # A webhook redelivery / repeat dunning event on the now-past_due row →
      # NOT a %Subscription{} (so the router seam skips the duplicate email).
      assert {:ok, :already_past_due} = Billing.mark_past_due(reload(sub))
      assert {:ok, :already_past_due} = Billing.mark_past_due(reload(sub))

      # DB is STILL correctly past_due after the repeats — dedup is email-only.
      assert %Subscription{status: "past_due", past_due: true} = reload(sub)
    end

    test "a repeat on an already-past_due sub still re-enforces (grace-elapsed suspend)" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      # In grace: past_due, entitled, box untouched.
      assert {:ok, %Subscription{status: "past_due"}} = Billing.mark_past_due(sub)
      assert Billing.entitled?(team)
      refute reload_bp(bp).suspended

      # A repeat that carries an EXPLICIT elapsed grace window STILL runs the
      # write + maybe_enforce even though it returns the already-past_due signal —
      # the box is suspended, state stays correct. Note the explicit attrs: this
      # is the ONLY way to reach maybe_enforce/1's suspend (the attr-less path
      # always re-anchors forward — see the re-anchor describe block below).
      past = DateTime.add(DateTime.utc_now(), -1, :day)

      assert {:ok, :already_past_due} =
               Billing.mark_past_due(reload(sub), %{grace_ends_at: past})

      refute Billing.entitled?(team)
      assert %Barkpark{suspended: true, suspended_reason: "billing_past_due"} = reload_bp(bp)
    end
  end

  # cch-w57-s2. billing.ex used to describe grace as a window that ends with the
  # team's boxes suspended. It never does on the webhook path: mark_past_due/2
  # opens with Map.put_new_lazy(attrs, :grace_ends_at, &default_grace_anchor/0),
  # so every attr-less redelivery slides the deadline @grace_days further out and
  # maybe_enforce/1's in-window arm always wins. This block DRIVES that slide, so
  # the retracted prose is pinned by behaviour: delete the put_new_lazy and it reds.
  # cch-w57-bl re-pointed it from current_period_end to grace_ends_at — the SAME
  # property, now read off the column that actually carries the dunning anchor.
  describe "mark_past_due/2 — the grace anchor slides FORWARD on every attr-less call" do
    test "two attr-less calls move grace_ends_at further out (grace never elapses here)" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      assert {:ok, %Subscription{status: "past_due"}} = Billing.mark_past_due(sub)
      first = reload(sub).grace_ends_at

      assert %DateTime{} = first,
             "mark_past_due/2 anchored NO grace window — an attr-less call must " <>
               "set grace_ends_at (Map.put_new_lazy/3), or a past_due team is NOT entitled at all"

      # A webhook redelivery carrying no period end (the real invoice.payment_failed
      # shape). The anchor is RE-applied, not left standing.
      assert {:ok, :already_past_due} = Billing.mark_past_due(reload(sub))
      second = reload(sub).grace_ends_at

      assert DateTime.compare(second, first) == :gt,
             "the grace anchor did NOT slide forward on the second attr-less call " <>
               "(#{inspect(first)} -> #{inspect(second)}) — the docs claim it always re-anchors"

      # And the consequence the prose now states: still entitled, box untouched.
      assert Billing.entitled?(team)
      refute reload_bp(bp).suspended
    end
  end

  describe "handle_webhook/2 — customer.subscription.deleted → canceled + suspend" do
    test "cancels the sub, stamps canceled_at, and suspends every managed box" do
      {team, sub} = subscribed_team()
      bp1 = barkpark_fixture(team)
      bp2 = barkpark_fixture(team)

      raw = event("customer.subscription.deleted", sub.gateway_customer_id)

      assert {:ok, %Subscription{status: "canceled"} = canceled} =
               Billing.handle_webhook(raw, sig())

      assert canceled.canceled_at
      refute Billing.entitled?(team)

      for bp <- [bp1, bp2] do
        assert %Barkpark{suspended: true, suspended_reason: "billing_lapsed"} = reload_bp(bp)
      end
    end

    test "is idempotent — a replay finds no live sub, no double-suspend, no crash" do
      {team, sub} = subscribed_team()
      _bp = barkpark_fixture(team)
      raw = event("customer.subscription.deleted", sub.gateway_customer_id)

      assert {:ok, %Subscription{status: "canceled"}} = Billing.handle_webhook(raw, sig())
      # Replay: the row is already canceled (excluded from the live lookup).
      assert {:ok, :ignored} = Billing.handle_webhook(raw, sig())

      # Still exactly one subscription row.
      assert 1 == Repo.aggregate(from(s in Subscription, where: s.team_id == ^team.id), :count)
    end
  end

  describe "handle_webhook/2 — recovery" do
    test "invoice.paid after past_due → back to active, past_due cleared, boxes resumed" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      # Lapse via the real webhook (grace anchored in the FUTURE → not yet
      # suspended), then drive the box into suspension by re-anchoring grace into
      # the past — the deferred-reconcile stand-in.
      {:ok, _} =
        Billing.handle_webhook(event("invoice.payment_failed", sub.gateway_customer_id), sig())

      past = DateTime.add(DateTime.utc_now(), -1, :day)
      {:ok, _} = Billing.mark_past_due(reload(sub), %{grace_ends_at: past})

      assert reload_bp(bp).suspended

      # Recover.
      assert {:ok, %Subscription{status: "active", past_due: false}} =
               Billing.handle_webhook(event("invoice.paid", sub.gateway_customer_id), sig())

      assert Billing.entitled?(team)
      refute reload_bp(bp).suspended
    end

    test "invoice.paid for an already-active sub is a no-op {:ok, :ignored}" do
      {_team, sub} = subscribed_team()

      assert {:ok, :ignored} =
               Billing.handle_webhook(event("invoice.paid", sub.gateway_customer_id), sig())
    end
  end

  describe "handle_webhook/2 — customer.subscription.updated dual membership" do
    test "status=canceled drives a cancel (lifecycle owns it, not activation)" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      raw =
        event("customer.subscription.updated", sub.gateway_customer_id, %{"status" => "canceled"})

      assert {:ok, %Subscription{status: "canceled"}} = Billing.handle_webhook(raw, sig())
      assert reload_bp(bp).suspended
    end

    test "status=active after past_due recovers" do
      {team, sub} = subscribed_team()
      {:ok, _} = Billing.mark_past_due(sub)
      assert Repo.get!(Subscription, sub.id).status == "past_due"

      raw =
        event("customer.subscription.updated", sub.gateway_customer_id, %{"status" => "active"})

      assert {:ok, %Subscription{status: "active"}} = Billing.handle_webhook(raw, sig())
      assert Billing.entitled?(team)
    end
  end

  describe "handle_webhook/2 — safety" do
    test "a forged signature on a lifecycle event changes nothing" do
      {_team, sub} = subscribed_team()
      raw = event("customer.subscription.deleted", sub.gateway_customer_id)

      assert {:error, :invalid_signature} = Billing.handle_webhook(raw, "forged")
      assert reload(sub).status == "active"
    end

    test "a lifecycle event for an unknown customer is ignored, nothing written" do
      raw = event("customer.subscription.deleted", "cus_stub_does_not_exist")
      assert {:ok, :ignored} = Billing.handle_webhook(raw, sig())
    end
  end

  ## ── Re-activation during dunning (M4) ──

  describe "activate_subscription/2 while past_due" do
    test "a fresh activating event for a past_due team RECOVERS — no second row, no collision" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      # Drive to past_due and past grace → suspended.
      past = DateTime.add(DateTime.utc_now(), -1, :day)
      {:ok, _} = Billing.mark_past_due(reload(sub), %{grace_ends_at: past})
      assert reload_bp(bp).suspended

      # A re-subscribe (the activating webhook path) must RECOVER the live row, not
      # INSERT a second one (which would collide with one-live-per-team and 400).
      assert {:ok, %Subscription{status: "active"}} =
               Billing.activate_subscription(team.id, "supporter")

      assert Billing.entitled?(team)
      refute reload_bp(bp).suspended
      assert 1 == Repo.aggregate(from(s in Subscription, where: s.team_id == ^team.id), :count)
    end

    test "an already-active team is a no-op {:ok, :already_active}" do
      {team, _sub} = subscribed_team()
      assert {:ok, :already_active} = Billing.activate_subscription(team.id, "supporter")
    end
  end

  ## ── Entitlement ──

  describe "entitled?/1" do
    test "active → true; no sub → false" do
      {team, _sub} = subscribed_team()
      assert Billing.entitled?(team)
      refute Billing.entitled?(team_fixture())
    end

    test "past_due within grace → true; past grace → false" do
      {team, sub} = subscribed_team()

      {:ok, _} =
        Billing.mark_past_due(sub, %{
          grace_ends_at: DateTime.add(DateTime.utc_now(), 3, :day)
        })

      assert Billing.entitled?(team)

      sub = reload(sub)

      {:ok, _} =
        Billing.mark_past_due(sub, %{
          grace_ends_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      refute Billing.entitled?(team)
    end
  end

  ## ── Self-serve ──

  describe "billing_portal_url/2" do
    test "returns the stub portal url for a subscribed team" do
      {team, sub} = subscribed_team()

      assert {:ok, "https://portal.stub/" <> _digest} = Billing.billing_portal_url(team)
      # Keyed to the gateway customer id.
      assert {:ok, url} = StubGateway.create_billing_portal_session(sub.gateway_customer_id)
      assert {:ok, ^url} = Billing.billing_portal_url(team)
    end

    test "no subscription → {:error, :no_subscription}" do
      assert {:error, :no_subscription} = Billing.billing_portal_url(team_fixture())
    end
  end

  describe "request_cancel/2" do
    test "grace (default) marks cancel_at_period_end and STAYS entitled" do
      {team, _sub} = subscribed_team()

      assert {:ok, %Subscription{cancel_at_period_end: true, status: "active"}} =
               Billing.request_cancel(team, true)

      assert Billing.entitled?(team)
    end

    test "immediate cancels now, drops entitlement, suspends boxes" do
      {team, _sub} = subscribed_team()
      bp = barkpark_fixture(team)

      assert {:ok, %Subscription{status: "canceled"}} = Billing.request_cancel(team, false)
      refute Billing.entitled?(team)
      assert reload_bp(bp).suspended
    end

    test "no subscription → {:error, :no_subscription}" do
      assert {:error, :no_subscription} = Billing.request_cancel(team_fixture(), true)
    end
  end

  # cch-w57-s2. A Stripe Customer Portal un-cancel arrives as a
  # customer.subscription.updated whose status is UNCHANGED ("active") and whose
  # cancel_at_period_end flipped to false. That arm used to return {:ok, :ignored}
  # and discard the payload, so the console kept the "Ending <date>" pill and hid
  # the Cancel control forever — a state the control plane could not support.
  describe "handle_webhook/2 — a portal un-cancel clears cancel_at_period_end" do
    defp updated_active(sub, extra) do
      event(
        "customer.subscription.updated",
        sub.gateway_customer_id,
        Map.merge(%{"status" => "active"}, extra)
      )
    end

    test "request_cancel(true) then an active update carrying false un-cancels the row" do
      {team, sub} = subscribed_team()

      assert {:ok, %Subscription{cancel_at_period_end: true}} = Billing.request_cancel(team, true)

      raw = updated_active(sub, %{"cancel_at_period_end" => false})
      result = Billing.handle_webhook(raw, sig())

      # Assert the ROW first, so a regression names the stuck flag rather than a
      # return-shape mismatch.
      refute reload(sub).cancel_at_period_end,
             "cancel_at_period_end is STUCK true after a portal un-cancel " <>
               "(webhook returned #{inspect(result)}) — the console keeps showing the " <>
               "Ending pill and refuses to offer Cancel again"

      assert {:ok, %Subscription{cancel_at_period_end: false}} = result

      # An un-cancel is not a status change: the row stays active and entitled.
      assert reload(sub).status == "active"
      assert Billing.entitled?(team)
    end

    test "a portal re-cancel on an active row sets the flag back to true" do
      {_team, sub} = subscribed_team()
      refute reload(sub).cancel_at_period_end

      raw = updated_active(sub, %{"cancel_at_period_end" => true})
      assert {:ok, %Subscription{cancel_at_period_end: true}} = Billing.handle_webhook(raw, sig())
      assert reload(sub).cancel_at_period_end
    end

    test "an active update with NO cancel_at_period_end field leaves the flag alone" do
      {team, sub} = subscribed_team()
      {:ok, _} = Billing.request_cancel(team, true)

      # Absent means "Stripe said nothing", NEVER false — a missing field must not
      # silently un-cancel a team that asked to leave.
      assert {:ok, :ignored} = Billing.handle_webhook(updated_active(sub, %{}), sig())
      assert reload(sub).cancel_at_period_end

      # A non-boolean is equally not an instruction.
      raw = updated_active(sub, %{"cancel_at_period_end" => nil})
      assert {:ok, :ignored} = Billing.handle_webhook(raw, sig())
      assert reload(sub).cancel_at_period_end
    end

    test "an active update repeating the flag the row already holds is a no-op" do
      {team, sub} = subscribed_team()
      {:ok, _} = Billing.request_cancel(team, true)

      raw = updated_active(sub, %{"cancel_at_period_end" => true})
      assert {:ok, :ignored} = Billing.handle_webhook(raw, sig())
      assert reload(sub).cancel_at_period_end
    end

    test "the un-cancel arm does NOT lift current_period_end from the payload" do
      {team, sub} = subscribed_team()
      {:ok, _} = Billing.request_cancel(team, true)
      before = reload(sub).current_period_end

      stripe_period_end = DateTime.utc_now() |> DateTime.add(24, :day) |> DateTime.to_unix()

      raw =
        updated_active(sub, %{
          "cancel_at_period_end" => false,
          "current_period_end" => stripe_period_end
        })

      assert {:ok, %Subscription{}} = Billing.handle_webhook(raw, sig())

      assert reload(sub).current_period_end == before,
             "current_period_end was written from webhook payload data (charter D672 refuses " <>
               "this: one column carries the grace anchor, trial expiry AND the renewal date)"

      assert Billing.entitled?(team)
    end
  end

  ## ── Resubscribe after cancel: the console's restore promise, with teeth ──

  # cch-w50-s3. The cancel modal tells an owner their instances "come back if you
  # resubscribe". Before this block that sentence had no executor: a cancel stamps
  # `billing_lapsed` (Registry.suspend_team_barkparks/2), the resubscribe webhook
  # lands `do_activate_from_session`'s `nil ->` INSERT branch (a canceled row is
  # invisible to live_subscription/1), and reconcile_plan_limit restores ONLY
  # `quota_exceeded` rows — so every box stayed suspended forever.
  describe "handle_webhook/2 — resubscribe after cancel restores the team's boxes" do
    defp checkout_completed(team_id, plan) do
      Jason.encode!(%{
        "id" => "evt_#{System.unique_integer([:positive])}",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "metadata" => %{"team_id" => team_id, "plan" => plan},
            "customer" => "cus_resub_#{System.unique_integer([:positive])}",
            "subscription" => "sub_resub_#{System.unique_integer([:positive])}"
          }
        }
      })
    end

    defp cancel_via_webhook(sub) do
      assert {:ok, %Subscription{status: "canceled"}} =
               Billing.handle_webhook(
                 event("customer.subscription.deleted", sub.gateway_customer_id),
                 sig()
               )
    end

    defp live_barkparks(team), do: Registry.list_barkparks(team) |> Enum.reject(& &1.suspended)

    test "a billing-lapsed box is LIVE again after the resubscribe checkout lands" do
      {team, sub} = subscribed_team("supporter")
      bp = barkpark_fixture(team)

      cancel_via_webhook(sub)
      assert %Barkpark{suspended: true, suspended_reason: "billing_lapsed"} = reload_bp(bp)

      assert {:ok, %Subscription{status: "active", plan: "supporter"}} =
               Billing.handle_webhook(checkout_completed(team.id, "supporter"), sig())

      assert %Barkpark{suspended: false, suspended_reason: nil} = reload_bp(bp),
             "the cancel modal promises the box comes back on resubscribe — it must actually come back"
    end

    # ORDERING PIN — this is the whole reason the resume lives INSIDE
    # do_activate_from_session's insert branch rather than beside
    # reconcile_plan_limit in activate_from_session.
    #
    # resume BEFORE reconcile (shipped): reconcile sees 5 live on a limit of 3 and
    # re-suspends the 2 newest as `quota_exceeded` → live == 3. Correct.
    # resume AFTER reconcile: reconcile sees ZERO live boxes (all still
    # billing_lapsed) so it suspends nothing, then the blanket resume clears every
    # flag → live == 5 on a 3-box plan. A live billing hole, not a style
    # preference. Moving the call reds THIS test with live == 5.
    #
    # register_barkpark/2 enforces the ceiling on create, so overflow is only
    # reachable via a DOWNGRADE — the fixture must buy on support_plus first.
    test "resubscribing on a SMALLER plan restores only up to the new ceiling" do
      {team, sub} = subscribed_team("support_plus")
      bps = for _ <- 1..5, do: barkpark_fixture(team)
      assert length(live_barkparks(team)) == 5

      cancel_via_webhook(sub)
      assert Enum.all?(bps, &(reload_bp(&1).suspended_reason == "billing_lapsed"))

      assert {:ok, %Subscription{status: "active", plan: "supporter"}} =
               Billing.handle_webhook(checkout_completed(team.id, "supporter"), sig())

      live = live_barkparks(team)

      assert length(live) == 3,
             "supporter's ceiling is 3; a resume that outruns the reconcile would leave " <>
               "#{length(live)} boxes running on a 3-box plan"

      quota_suspended =
        Registry.list_barkparks(team) |> Enum.filter(&(&1.suspended_reason == "quota_exceeded"))

      assert length(quota_suspended) == 2

      # And no box is left carrying the stale billing reason.
      refute Enum.any?(Registry.list_barkparks(team), &(&1.suspended_reason == "billing_lapsed"))
    end
  end

  ## ── cch-w55-s4: a paid invoice lifts the BILLING axis, and only that ──

  # THE OVER-GRANT THESE PIN. `Registry.resume_team_barkparks/1`'s entire where
  # clause is `team_id and suspended == true` — no reason scope, no mode scope,
  # while its suspend twin has both. Both billing recovery paths called it, and
  # `recover_subscription/1` had NOTHING behind it (unlike
  # do_activate_from_session, whose reconcile re-stamps the overflow). So paying
  # a failed invoice cleared `quota_exceeded` flags a downgrade had set, with
  # nothing scheduled to take that capacity back, and revived `self_hosted` rows
  # the suspend side refuses to touch.
  #
  # Each test below reds if `resume_billing_suspended/1` is reverted to the blind
  # resume (measured: 3 failures, with the counts named in the messages).
  describe "invoice.paid recovery is reason- and mode-scoped (cch-w55-s4)" do
    defp live_bps(team), do: Registry.list_barkparks(team) |> Enum.reject(& &1.suspended)

    # Drive `sub` into dunning and past grace, so the team's managed boxes carry
    # `billing_past_due` — the real path a paid invoice recovers from.
    defp lapse_into_past_due(sub) do
      {:ok, _} =
        Billing.handle_webhook(event("invoice.payment_failed", sub.gateway_customer_id), sig())

      past = DateTime.add(DateTime.utc_now(), -1, :day)
      {:ok, _} = Billing.mark_past_due(reload(sub), %{grace_ends_at: past})
      :ok
    end

    test "a quota_exceeded box is NOT lifted by a paid invoice, and nothing is scheduled to re-suspend it" do
      {team, sub} = subscribed_team("supporter")
      quota_bp = barkpark_fixture(team)

      {:ok, _} = Registry.suspend_barkpark(quota_bp, Billing.quota_suspended_reason())
      assert reload_bp(quota_bp).suspended_reason == "quota_exceeded"

      lapse_into_past_due(sub)

      assert {:ok, %Subscription{status: "active", past_due: false}} =
               Billing.handle_webhook(event("invoice.paid", sub.gateway_customer_id), sig())

      assert %Barkpark{suspended: true, suspended_reason: "quota_exceeded"} = reload_bp(quota_bp),
             "paying a failed invoice lifted a QUOTA suspension the billing axis never set — " <>
               "and no reconcile runs behind recover_subscription/1, so nothing takes that " <>
               "capacity back"

      # There is no worker to re-suspend it either: the resume must simply not
      # have touched the row.
      assert [] == Repo.all(from(j in Oban.Job, select: j.worker)),
             "nothing is enqueued to re-suspend an over-granted box — the resume itself must be scoped"
    end

    test "a billing_past_due box IS lifted by a paid invoice (the narrowing must not strand a payer)" do
      {team, sub} = subscribed_team("supporter")
      bp = barkpark_fixture(team)

      lapse_into_past_due(sub)
      assert %Barkpark{suspended: true, suspended_reason: "billing_past_due"} = reload_bp(bp)

      assert {:ok, %Subscription{status: "active"}} =
               Billing.handle_webhook(event("invoice.paid", sub.gateway_customer_id), sig())

      assert %Barkpark{suspended: false, suspended_reason: nil} = reload_bp(bp),
             "a resume scoped to billing_lapsed ALONE strands every grace-elapsed box forever — " <>
               "the over-grant traded for a permanent under-restore"
    end

    test "a downgraded team is NOT running 5 boxes on a 3-box plan after a past_due → paid cycle" do
      {team, sub} = subscribed_team("support_plus")
      for _ <- 1..5, do: barkpark_fixture(team)
      assert length(live_bps(team)) == 5

      # The downgrade the reconciler enforces: 5 live, ceiling 3 → 2 suspended
      # as `quota_exceeded`. No billing suspension anywhere in this fixture.
      # The DOWNGRADE (support_plus → supporter, ceiling 10 → 3). Overflow is
      # only reachable this way: register_barkpark/2 enforces the ceiling on
      # create.
      {:ok, _} = sub |> Subscription.changeset(%{plan: "supporter"}) |> Repo.update()
      assert Billing.barkpark_limit(team) == 3
      assert %{suspended: 2, restored: 0} = Billing.reconcile_plan_limit(team)
      assert length(live_bps(team)) == 3

      # A merely past_due → paid cycle. It must settle billing, not hand back
      # the two boxes the plan does not cover.
      lapse_into_past_due(sub)

      assert {:ok, %Subscription{status: "active"}} =
               Billing.handle_webhook(event("invoice.paid", sub.gateway_customer_id), sig())

      live = length(live_bps(team))

      assert live == 3,
             "supporter's ceiling is 3; paying a failed invoice left #{live} boxes running — " <>
               "the blind resume cleared the downgrade's quota flags for free"
    end

    test "a self_hosted row the suspend path refuses to touch is not revived by the billing resume" do
      team = team_fixture()
      managed = barkpark_fixture(team, %{mode: "managed"})
      self_hosted = barkpark_fixture(team, %{mode: "self_hosted"})

      # The mode asymmetry, stated by running: the suspend side reports 1, not 2.
      assert {:ok, 1} = Registry.suspend_team_barkparks(team, "billing_lapsed")
      refute reload_bp(self_hosted).suspended

      # Suspend the self_hosted row by another route entirely, so the resume has
      # something out-of-axis to (wrongly) revive.
      {:ok, _} = Registry.suspend_barkpark(self_hosted, "billing_lapsed")
      assert reload_bp(self_hosted).suspended

      assert {:ok, 1} = Registry.resume_billing_suspended(team),
             "the billing resume must be mode-scoped like its suspend twin — one managed row"

      refute reload_bp(managed).suspended

      assert reload_bp(self_hosted).suspended,
             "resume revived a self_hosted row that suspend_team_barkparks/2 returns count 0 on"
    end

    test "resume_billing_suspended/1 is idempotent and lifts neither quota nor foreign teams" do
      team = team_fixture()
      other = team_fixture()
      lapsed = barkpark_fixture(team)
      quota = barkpark_fixture(team)
      foreign = barkpark_fixture(other)

      {:ok, _} = Registry.suspend_barkpark(lapsed, "billing_lapsed")
      {:ok, _} = Registry.suspend_barkpark(quota, Billing.quota_suspended_reason())
      {:ok, _} = Registry.suspend_barkpark(foreign, "billing_lapsed")

      assert {:ok, 1} = Registry.resume_billing_suspended(team)
      assert {:ok, 0} = Registry.resume_billing_suspended(team)

      refute reload_bp(lapsed).suspended
      assert reload_bp(quota).suspended
      assert reload_bp(foreign).suspended
    end
  end

  ## ── cch-w50-bl: the feed must not report a change that never happened ──

  # THE LIE THIS PINS. `Registry.resume_billing_suspended/1` is a bulk
  # `update_all` that broadcasts NOTHING, while `reconcile_plan_limit/1` suspends
  # row-by-row through `suspend_one/2`, which DOES broadcast. Before the
  # narrowing the resume was reason-blind: a resubscribe silently lifted a box
  # that was already `quota_exceeded`, the reconcile behind it re-suspended that
  # same box against the smaller ceiling, and the team's dashboard received a
  # `barkpark.suspended` for a box that was suspended before the webhook arrived
  # and suspended after it — a transition that never happened, with no
  # `barkpark.restored` in front of it to pair against.
  #
  # The narrowing removes the CAUSE (a quota row is never resumed, so it is never
  # in the reconcile's live set); this pins the CONSEQUENCE on the feed itself.
  # MUTATION: revert `do_activate_from_session`'s call to the reason-blind
  # `Registry.resume_team_barkparks/1` and this reds with the unpaired suspend.
  describe "the resubscribe event feed pairs every suspend (cch-w50-bl)" do
    # Give the reconciler's `sort_by(inserted_at, {:desc, DateTime})` an
    # unambiguous order, so which rows land in the overflow is a fact and not a
    # tie-break: the quota box is stamped NEWEST, squarely inside the slice an
    # over-wide resume hands back to the reconcile.
    defp age_rows(bps) do
      bps
      |> Enum.with_index()
      |> Enum.each(fn {bp, i} ->
        at = DateTime.add(DateTime.utc_now(), -3600 + i * 60, :second)
        Repo.update_all(from(b in Barkpark, where: b.id == ^bp.id), set: [inserted_at: at])
      end)
    end

    # Every `{:bpcloud_event, _}` sitting in this process's mailbox, in arrival
    # order. The webhook runs synchronously in the test process, so by the time
    # `handle_webhook/2` returns the whole trace is already delivered.
    defp drain_events(acc \\ []) do
      receive do
        {:bpcloud_event, ev} -> drain_events([ev | acc])
      after
        50 -> Enum.reverse(acc)
      end
    end

    # THE PAIRING LAW, folded over the trace. `known` seeds each WATCHED box's
    # availability as a feed reader understands it at t0. A `barkpark.suspended`
    # for a box the reader already believes suspended is UNPAIRED — the feed
    # asserting a transition that did not occur. A suspend that FOLLOWS a
    # restore is paired and fine, which is why this is a fold and not a
    # "contains no suspend" grep.
    defp unpaired_suspends(trace, known) do
      {unpaired, _} =
        Enum.reduce(trace, {[], known}, fn ev, {bad, state} ->
          id = Map.get(ev.payload || %{}, :barkpark_id)

          case {ev.type, Map.fetch(state, id)} do
            {"barkpark.restored", {:ok, _}} -> {bad, Map.put(state, id, :live)}
            {"barkpark.suspended", {:ok, :live}} -> {bad, Map.put(state, id, :suspended)}
            {"barkpark.suspended", {:ok, :suspended}} -> {[id | bad], state}
            _ -> {bad, state}
          end
        end)

      Enum.reverse(unpaired)
    end

    test "a resubscribe onto a SMALLER plan emits no unpaired suspend for an untouched box" do
      {team, sub} = subscribed_team("support_plus")
      lapsing = for _ <- 1..4, do: barkpark_fixture(team)
      quota_bp = barkpark_fixture(team)
      age_rows(lapsing ++ [quota_bp])

      # The box whose availability NEVER changes across this whole test: over
      # quota before the cancel, still over quota after the resubscribe.
      {:ok, _} = Registry.suspend_barkpark(quota_bp, Billing.quota_suspended_reason())
      suspended_at_before = reload_bp(quota_bp).suspended_at

      cancel_via_webhook(sub)

      # The bulk suspend skips rows that are already suspended, so the quota box
      # keeps its own reason — this mixed fleet is the production shape.
      assert reload_bp(quota_bp).suspended_reason == "quota_exceeded"
      assert Enum.all?(lapsing, &(reload_bp(&1).suspended_reason == "billing_lapsed"))

      :ok = Events.subscribe(team.id)
      _ = drain_events()

      assert {:ok, %Subscription{status: "active", plan: "supporter"}} =
               Billing.handle_webhook(checkout_completed(team.id, "supporter"), sig())

      trace = drain_events()

      # THE LAW.
      assert unpaired_suspends(trace, %{quota_bp.id => :suspended}) == [],
             "the feed carries a barkpark.suspended for a box that was ALREADY suspended when " <>
               "the webhook arrived, with no barkpark.restored to pair it against — the silent " <>
               "bulk resume lifted it and the reconcile broadcast taking it back. Trace: " <>
               inspect(trace)

      refute Enum.any?(trace, &(Map.get(&1.payload || %{}, :barkpark_id) == quota_bp.id)),
             "a box whose availability never changed must produce NO feed traffic at all"

      # ANTI-VACUITY: the subscription is live and the reconcile really ran.
      # supporter's ceiling is 3 against the 4 boxes the billing axis legitimately
      # resumed, so exactly ONE suspend belongs on this feed — for a box that was
      # genuinely live a moment earlier.
      suspends = Enum.filter(trace, &(&1.type == "barkpark.suspended"))

      assert length(suspends) == 1,
             "expected exactly one LEGITIMATE suspend on the feed; got #{length(suspends)} — " <>
               inspect(trace)

      # A second, independent witness that the row never moved: a blind resume
      # nulls `suspended_at`, and the re-suspend behind it stamps a fresh one.
      after_row = reload_bp(quota_bp)
      assert after_row.suspended and after_row.suspended_reason == "quota_exceeded"

      assert after_row.suspended_at == suspended_at_before,
             "suspended_at moved on a box nothing was supposed to touch"

      assert length(live_barkparks(team)) == 3
    end
  end

  ## ── Registry suspension primitives ──

  describe "Registry.suspend_team_barkparks/2 + resume_team_barkparks/1" do
    test "suspends only managed rows, leaves self_hosted/byo untouched, idempotent" do
      team = team_fixture()
      managed = barkpark_fixture(team, %{mode: "managed"})
      self_hosted = barkpark_fixture(team, %{mode: "self_hosted"})
      byo = barkpark_fixture(team, %{mode: "byo"})

      assert {:ok, 1} = Registry.suspend_team_barkparks(team, "billing_lapsed")
      assert reload_bp(managed).suspended
      refute reload_bp(self_hosted).suspended
      refute reload_bp(byo).suspended

      # Idempotent: a second call suspends nothing.
      assert {:ok, 0} = Registry.suspend_team_barkparks(team, "billing_lapsed")

      assert {:ok, 1} = Registry.resume_team_barkparks(team)
      refute reload_bp(managed).suspended
      assert {:ok, 0} = Registry.resume_team_barkparks(team)
    end

    test "is team-scoped — never touches another team's boxes" do
      team_a = team_fixture()
      team_b = team_fixture()
      bp_a = barkpark_fixture(team_a)
      bp_b = barkpark_fixture(team_b)

      {:ok, _} = Registry.suspend_team_barkparks(team_a, "billing_lapsed")
      assert reload_bp(bp_a).suspended
      refute reload_bp(bp_b).suspended
    end
  end

  ## ── Gateway request shapes (pure builder, never sent) ──

  describe "StripeGateway — portal + cancel request shapes" do
    test "create_billing_portal_session posts to /billing_portal/sessions with customer + return_url" do
      req =
        StripeGateway.build_request("/billing_portal/sessions", :post, %{
          "customer" => "cus_123",
          "return_url" => "https://barkpark.cloud/?billing=portal"
        })

      assert req.method == :post
      assert req.url == "https://api.stripe.com/v1/billing_portal/sessions"

      assert req.body ==
               "customer=cus_123&return_url=https%3A%2F%2Fbarkpark.cloud%2F%3Fbilling%3Dportal"
    end

    test "cancel at period end posts cancel_at_period_end=true to /subscriptions/:id" do
      req =
        StripeGateway.build_request("/subscriptions/sub_123", :post, %{
          "cancel_at_period_end" => true
        })

      assert req.method == :post
      assert req.url == "https://api.stripe.com/v1/subscriptions/sub_123"
      assert req.body == "cancel_at_period_end=true"
    end

    test "immediate cancel is a DELETE to /subscriptions/:id" do
      req = StripeGateway.build_request("/subscriptions/sub_123", :delete, %{})

      assert req.method == :delete
      assert req.url == "https://api.stripe.com/v1/subscriptions/sub_123"
      assert req.body == ""
    end

    test "the live portal/cancel paths fail closed with no injected client (no spend)" do
      assert {:error, :http_client_not_configured} =
               StripeGateway.create_billing_portal_session("cus_123")

      assert {:error, :http_client_not_configured} =
               StripeGateway.cancel_subscription("sub_123", at_period_end: true)
    end
  end
end
