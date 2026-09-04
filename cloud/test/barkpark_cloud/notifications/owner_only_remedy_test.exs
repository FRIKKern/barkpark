defmodule BarkparkCloud.Notifications.OwnerOnlyRemedyTest do
  @moduledoc """
  cch-w42-s6 (charter D475, D332) — the two BILLING alerts stop prescribing, to
  every member of a team, a remedy only the team OWNER can perform.

  ## What was wrong

  `subscription_past_due` said "Update your billing to avoid interruption." and
  `trial_expiring` said "Upgrade to keep your instance running". Both imperatives
  route to `require_current_team_owner` doors (`POST /v1/billing/checkout`,
  `POST /v1/billing/portal`) whose 403 for a member — AND for a non-owner ADMIN —
  is pinned by run in `router_test.exs`. But the alert fan-out reads
  `Accounts.list_team_member_emails/1`, which has no role predicate, so every
  member was mailed an instruction the server refuses them. The console had
  already written the honest sentence ("Only the team owner can manage billing.")
  — the two surfaces disagreed about the same person.

  ## What is asserted here, and what is deliberately NOT

  The fix is ROLE-AWARE COPY, never a narrower audience: `trial_expiring` is on
  `Notifications.@always_send` because its reach must be maximal, and the true
  half of both sentences (suspension, automatic teardown) is what a member most
  needs. So the audience is asserted UNCHANGED — a plain member still gets a
  `sent` `alert` Delivery row for both events — and only the sentence differs.

  The split is OWNER vs NOT-OWNER, not this epic's usual `owner|admin` band,
  because the gate is `Authz.team_owner?`: an ADMIN gets the non-owner copy, and
  that is asserted explicitly rather than left to the member case.

  This file does NOT claim the chat rail changed. `Render.render/2` has stated
  the consequence and prescribed nothing since cch-w32-s1; `render_test.exs`
  still owns that.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Notifications.EmailSettings
  alias BarkparkCloud.Notifications.EventEmail

  # The two imperatives, quoted as the reader receives them. If either sentence
  # is reworded in `event_email.ex` without updating these, the owner assertions
  # below go red — which is the point: this file is what makes the copy load-bearing.
  @past_due_imperative "Update your billing"
  @trial_imperative "Upgrade to keep your instance running"

  # The console's own sentence (`app.js` billing panel), reused rather than
  # inventing a third phrasing for the same fact.
  @past_due_authority "Only the team owner can manage billing."
  @trial_authority "Only the team owner can upgrade the plan."

  defp build(event, role, payload \\ %{name: "acme", days: 3}) do
    EventEmail.build(%EmailSettings{}, event, payload, %{
      email: "reader@example.com",
      role: role
    })
  end

  ## ── The rendered bodies, per role ────────────────────────────────────────

  describe "an OWNER still gets the imperative" do
    test "subscription_past_due" do
      body = build(:subscription_past_due, "owner").text_body

      assert body ==
               "A payment failed and your subscription is past due. " <>
                 "Update your billing to avoid interruption."
    end

    test "trial_expiring" do
      body = build(:trial_expiring, "owner").text_body

      assert body ==
               "Your Barkpark free trial ends in 3 days. Upgrade to keep your instance " <>
                 "running — it's torn down automatically when the trial ends."
    end
  end

  describe "a MEMBER is told the consequence and who can act, never the remedy" do
    test "subscription_past_due keeps the suspension warning" do
      body = build(:subscription_past_due, "member").text_body

      refute body =~ @past_due_imperative
      assert body =~ "hosted instances may be suspended"
      assert body =~ @past_due_authority
    end

    test "trial_expiring keeps the automatic teardown" do
      body = build(:trial_expiring, "member").text_body

      refute body =~ @trial_imperative
      assert body =~ "in 3 days"
      assert body =~ "torn down automatically when the trial ends"
      assert body =~ @trial_authority
    end
  end

  describe "an ADMIN is NOT an owner here — the gate is Authz.team_owner?" do
    # `require_current_team_owner` refuses a non-owner admin too (pinned by
    # `router_test.exs`). A builder reusing this epic's usual `owner|admin` band
    # would ship the wrong split, and this is the test that catches it.
    test "both events render the non-owner copy to an admin" do
      past_due = build(:subscription_past_due, "admin").text_body
      trial = build(:trial_expiring, "admin").text_body

      refute past_due =~ @past_due_imperative
      assert past_due =~ @past_due_authority

      refute trial =~ @trial_imperative
      assert trial =~ @trial_authority
    end
  end

  describe "the role read FAILS CLOSED" do
    test "a bare-address recipient, a nil role and an unknown role all get the non-owner copy" do
      bare = EventEmail.build(%EmailSettings{}, :subscription_past_due, %{}, "x@example.com")

      for body <- [
            bare.text_body,
            build(:subscription_past_due, nil).text_body,
            build(:subscription_past_due, "billing-contact").text_body
          ] do
        refute body =~ @past_due_imperative
        assert body =~ @past_due_authority
      end

      # A bare address is still addressed correctly — the role rides beside the
      # address, it does not replace it.
      assert bare.to == [{"", "x@example.com"}]
    end
  end

  describe "the trial body is composed from the :days INTEGER, in the render arm" do
    # The remedy used to be authored in `TrialExpiryWorker.notify/3` as `:detail`
    # — per TEAM, before any recipient existed — so no recipient-aware renderer
    # could reach it. These two tests are what proves the move actually happened
    # rather than a `build/4` change that left trial-expiry lying.
    test "a stale pre-written :detail cannot put the imperative back" do
      payload = %{
        name: "acme",
        days: 3,
        detail:
          "Your Barkpark free trial ends in 3 days. Upgrade to keep your instance running — " <>
            "it's torn down automatically when the trial ends."
      }

      body = build(:trial_expiring, "member", payload).text_body

      refute body =~ @trial_imperative
      assert body == build(:trial_expiring, "member").text_body
    end

    test "the window degrades to 'soon', never 'in  days'" do
      for payload <- [%{name: "acme"}, %{name: "acme", days: nil}, %{name: "acme", days: "soon"}] do
        for role <- ["owner", "member"] do
          body = build(:trial_expiring, role, payload).text_body
          assert body =~ "ends soon."
          refute body =~ "in  day"
        end
      end

      assert build(:trial_expiring, "owner", %{name: "acme", days: 1}).text_body =~ "in 1 day."
    end
  end

  ## ── The AUDIENCE is unchanged ────────────────────────────────────────────

  describe "every member is still mailed both events (the fix is copy, not a filter)" do
    setup do
      n = System.unique_integer([:positive])
      {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

      {:ok, owner} =
        Accounts.register_user(%{
          email: "owner-#{n}@example.com",
          password: "correct horse staple"
        })

      {:ok, member} =
        Accounts.register_user(%{
          email: "member-#{n}@example.com",
          password: "correct horse staple"
        })

      {:ok, _} = Accounts.add_member(team, owner, "owner")
      {:ok, _} = Accounts.add_member(team, member, "member")

      %{team: team, owner: owner.email, member: member.email}
    end

    for {event, imperative} <- [
          {:subscription_past_due, @past_due_imperative},
          {:trial_expiring, @trial_imperative}
        ] do
      test "#{event}: the member gets a sent alert row, with the non-owner sentence", ctx do
        event = unquote(event)
        :ok = Notifications.dispatch_event(ctx.team, event, %{name: "acme", days: 3})

        rows =
          Repo.all(
            from(d in Delivery,
              where: d.team_id == ^ctx.team.id and d.event == ^Atom.to_string(event)
            )
          )

        # THE AUDIENCE, unchanged: both addresses, both `sent`, both `alert`.
        assert Enum.sort(Enum.map(rows, & &1.recipient)) == Enum.sort([ctx.owner, ctx.member])
        assert Enum.all?(rows, &(&1.status == "sent" and &1.kind == "alert"))

        # Indexed by recipient rather than popped in order: the fan-out's order is
        # membership age, and an assertion that quietly depended on it would pass
        # for the wrong reason the day that changed.
        bodies =
          Map.new(1..2, fn _ ->
            assert_receive {:email, email}
            {elem(hd(email.to), 1), email.text_body}
          end)

        refute bodies[ctx.member] =~ unquote(imperative)
        assert bodies[ctx.member] =~ "Only the team owner"
        assert bodies[ctx.owner] =~ unquote(imperative)
      end
    end
  end
end
