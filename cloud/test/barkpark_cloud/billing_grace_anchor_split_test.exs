# The migration is not part of the compiled app (migrations live outside the lib
# path), so it is loaded HERE — before this file compiles — rather than in a
# setup block: the backfill case calls the migration's own statement builder, and
# a runtime-only load would leave that call compiling against an unknown module.
unless Code.ensure_loaded?(BarkparkCloud.Repo.Migrations.AddGraceEndsAtToSubscriptions) do
  Code.require_file(
    Path.expand(
      "../../priv/repo/migrations/20260904210000_add_grace_ends_at_to_subscriptions.exs",
      __DIR__
    )
  )
end

defmodule BarkparkCloud.BillingGraceAnchorSplitTest do
  @moduledoc """
  cch-w57-bl — `current_period_end` used to be three clocks in one column: the
  dunning grace anchor, the trial expiry, and (the moment anything synced it)
  Stripe's renewal date. `entitled?/1` and `maybe_enforce/1` both branched on
  exactly that column. This file drives the two hazards wave 57 measured against
  a period-end sync a builder would plausibly write, now that the dunning anchor
  lives in its own `grace_ends_at`.

  Every case here writes `current_period_end` DIRECTLY through the changeset —
  that is the point. No production path syncs it (charter D672), so a test that
  went through a webhook would prove nothing; the column is set to exactly what a
  sync WOULD have written, and the assertion is that the grace decision does not
  move.

  MUTATION-PROVED (each reverted one at a time, run, restored — output in the PR
  body):

    * reverting `entitled?/1`'s past_due arm to
      `%Subscription{status: "past_due", current_period_end: pe} -> is_nil(pe) or
      DateTime.compare(pe, DateTime.utc_now()) == :gt` reds BOTH hazards:
      the EXTENDS case (a 27-day renewal re-opens an elapsed grace) and the
      ABSENT-FIELD case (a nil anchor is entitled forever).
    * reverting `maybe_enforce/1`'s head to `current_period_end: pe` +
      `is_nil(pe) or …` reds the two suspend assertions for the same reasons.

  €0 — StubGateway, no live Stripe, no network.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Billing.{StripeGateway, Subscription}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Repo.Migrations.AddGraceEndsAtToSubscriptions

  # What a Stripe renewal date 27 days out looks like — the EXTENDS hazard's
  # payload value, as measured in wave 57's verify round.
  @renewal_days 27

  ## Fixtures

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp subscribed_team do
    team = team_fixture()
    {:ok, sub} = Billing.subscribe(team, "supporter")
    {team, sub}
  end

  defp reload(%Subscription{id: id}), do: Repo.get!(Subscription, id)
  defp reload_bp(%Barkpark{id: id}), do: Repo.get!(Barkpark, id)

  defp days_out(n), do: DateTime.utc_now() |> DateTime.add(n, :day) |> DateTime.truncate(:microsecond)

  # Write columns straight onto the row — the stand-in for the sync this tree
  # refuses to have.
  defp force!(%Subscription{} = sub, attrs) do
    sub |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  ## ── HAZARD (a): EXTENDS ────────────────────────────────────────────────

  describe "EXTENDS — a Stripe renewal date does not move the dunning grace window" do
    test "an ELAPSED grace stays elapsed even with a 27-day renewal on current_period_end" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      # In dunning, grace already elapsed: not entitled, and the box is suspended
      # by the same call that wrote the anchor.
      {:ok, _} = Billing.mark_past_due(sub, %{grace_ends_at: days_out(-1)})
      refute Billing.entitled?(team)
      assert %Barkpark{suspended: true, suspended_reason: "billing_past_due"} = reload_bp(bp)

      # The sync a builder would plausibly write: customer.subscription.updated
      # carrying a renewal 27 days out, landing on current_period_end. Before the
      # split this WAS the grace anchor, so this single write bought the team
      # ~27 days of free running boxes.
      sub = force!(reload(sub), %{current_period_end: days_out(@renewal_days)})
      assert %DateTime{} = sub.current_period_end

      refute Billing.entitled?(team),
             "a Stripe renewal date on current_period_end RE-OPENED an elapsed grace window " <>
               "(grace_ends_at #{inspect(sub.grace_ends_at)}, renewal " <>
               "#{inspect(sub.current_period_end)}) — the two clocks are fused again"

      # And the enforcement half agrees: re-running the dunning write with the
      # SAME elapsed anchor still suspends, renewal date notwithstanding.
      {:ok, :already_past_due} = Billing.mark_past_due(reload(sub), %{grace_ends_at: days_out(-1)})
      assert reload_bp(bp).suspended
    end

    test "NEGATIVE CONTROL — moving grace_ends_at itself DOES re-open the window" do
      # Without this the case above passes on a tree where entitled?/1 always
      # returns false for past_due, which would be a different bug entirely.
      {team, sub} = subscribed_team()

      {:ok, _} = Billing.mark_past_due(sub, %{grace_ends_at: days_out(-1)})
      refute Billing.entitled?(team)

      force!(reload(sub), %{grace_ends_at: days_out(3)})
      assert Billing.entitled?(team)
    end

    test "the dunning write leaves current_period_end — the TRIAL expiry — untouched" do
      {_team, sub} = subscribed_team()

      trial_expiry = days_out(9)
      force!(reload(sub), %{current_period_end: trial_expiry})

      {:ok, _} = Billing.mark_past_due(reload(sub), %{})
      sub = reload(sub)

      assert %DateTime{} = sub.grace_ends_at
      assert DateTime.compare(sub.current_period_end, trial_expiry) == :eq,
             "mark_past_due/2 overwrote current_period_end — the dunning anchor is back on the " <>
               "trial-expiry column"
    end
  end

  ## ── HAZARD (c): THE ABSENT FIELD ───────────────────────────────────────

  describe "ABSENT FIELD — a past_due row with no grace anchor is NOT entitled" do
    test "an explicitly-nil grace_ends_at (what an absent payload field writes) de-entitles" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      # `Map.put_new_lazy/3` is DEFEATED by an explicitly-present nil key — this
      # is exactly what an unguarded read of an ABSENT `current_period_end` off a
      # payload whose API version does not carry it produces.
      {:ok, _} = Billing.mark_past_due(sub, %{grace_ends_at: nil})
      sub = reload(sub)

      assert sub.status == "past_due"
      assert is_nil(sub.grace_ends_at), "the fixture did not reproduce the nil anchor"

      refute Billing.entitled?(team),
             "a past_due row with NO grace anchor is entitled — is_nil still means 'no " <>
               "enforcement', so an unpaid box never suspends and never expires"

      assert %Barkpark{suspended: true, suspended_reason: "billing_past_due"} = reload_bp(bp),
             "maybe_enforce/1 no-opped on a nil anchor — the unpaid box is still running"
    end

    test "a nil anchor de-entitles even with a far-future current_period_end on the row" do
      # The two hazards COMBINED — the shape a sync against an unpinned API
      # version actually produces: nothing on the grace column, a renewal date on
      # the trial column.
      {team, sub} = subscribed_team()

      {:ok, _} = Billing.mark_past_due(sub, %{grace_ends_at: nil})
      force!(reload(sub), %{current_period_end: days_out(@renewal_days)})

      refute Billing.entitled?(team)
    end

    test "NEGATIVE CONTROL — the attr-less webhook path anchors grace and stays entitled" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      {:ok, _} = Billing.mark_past_due(sub)

      assert %DateTime{} = reload(sub).grace_ends_at
      assert Billing.entitled?(team)
      refute reload_bp(bp).suspended
    end
  end

  ## ── The pinned Stripe API version ──────────────────────────────────────

  describe "StripeGateway — Stripe-Version is pinned by this tree" do
    test "every built request carries the pinned version header" do
      for {path, method, params} <- [
            {"/customers", :post, %{"email" => "a@b.com"}},
            {"/checkout/sessions", :post, %{"mode" => "subscription"}},
            {"/subscriptions/sub_123", :delete, %{}}
          ] do
        req = StripeGateway.build_request(path, method, params)

        assert {"Stripe-Version", version} =
                 Enum.find(req.headers, &(elem(&1, 0) == "Stripe-Version")),
               "#{method} #{path} sent NO Stripe-Version — the payload shape is the Stripe " <>
                 "ACCOUNT's default API version, not a decision this tree makes"

        assert version == StripeGateway.api_version()
      end
    end

    test "the pin is a dated Stripe version string, and the moduledoc records it" do
      version = StripeGateway.api_version()
      assert version =~ ~r/^\d{4}-\d{2}-\d{2}\.[a-z]+$/

      {:docs_v1, _, :elixir, _, %{"en" => doc}, _, _} = Code.fetch_docs(StripeGateway)

      assert doc =~ version,
             "the moduledoc does not name the pinned version #{version} — criterion 4 asks for " <>
               "the version to be RECORDED, not just sent"
    end
  end

  ## ── The migration's backfill ───────────────────────────────────────────

  describe "the grace_ends_at backfill" do
    test "carries a past_due row's old anchor across, and leaves a trial row alone" do
      {_team, past_due} = subscribed_team()
      old_anchor = days_out(2)
      {:ok, _} = Billing.mark_past_due(past_due, %{grace_ends_at: old_anchor})

      # Rewind to the PRE-migration shape: the anchor on the shared column, the
      # new column empty — exactly the row the migration finds on disk.
      force!(reload(past_due), %{grace_ends_at: nil, current_period_end: old_anchor})

      trial_team = team_fixture()
      {:ok, trial} = Billing.grant_trial(trial_team)
      assert %DateTime{} = reload(trial).current_period_end

      Repo.query!(AddGraceEndsAtToSubscriptions.backfill_sql(), [])

      assert DateTime.compare(reload(past_due).grace_ends_at, old_anchor) == :eq,
             "the backfill did not carry the past_due row's grace anchor across — every team " <>
               "in dunning is de-entitled the instant this release boots"

      assert is_nil(reload(trial).grace_ends_at),
             "the backfill invented a dunning deadline on a TRIAL row — current_period_end " <>
               "there is the trial expiry, not a grace window"
    end

    test "re-running it is a no-op — it does not overwrite an anchor already set" do
      {_team, sub} = subscribed_team()
      {:ok, _} = Billing.mark_past_due(sub, %{grace_ends_at: days_out(1)})
      force!(reload(sub), %{current_period_end: days_out(@renewal_days)})

      anchor = reload(sub).grace_ends_at
      Repo.query!(AddGraceEndsAtToSubscriptions.backfill_sql(), [])

      assert DateTime.compare(reload(sub).grace_ends_at, anchor) == :eq,
             "a re-run clobbered a live grace anchor with current_period_end"
    end
  end
end
