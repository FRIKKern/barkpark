defmodule BarkparkCloud.Workers.TokenExpiryWarningWorkerTest do
  @moduledoc """
  cch-w30-bl — the PAT expiry warning and, above all, ITS RECIPIENT RULE.

  Wave 30 dropped the `token_expiring` toggle because nothing dispatched it and
  the obvious producer would have been WRONG: `Notifications.dispatch_event/3`
  fans to `team_member_emails/1` with no role predicate, so a token warning
  routed that way publishes one member's credential names and rotation schedule
  to their whole team. This suite is the feature AND the fence:

    * the positive test runs the worker on a THREE-member team and counts the
      `token_expiring` Delivery rows — exactly ONE, addressed to the owner;
    * the negative tests pin the rule from both sides — the alert path CAN fan
      (proved by running it), and `:token_expiring` is structurally unable to
      travel it (proved by running THAT too, and by reading the worker's own
      source for the forbidden call);
    * the body test rejects the empty `detail(payload)` render the filing
      measured, by asserting the token's NAME and its EXPIRY date are in it.

  `async: true` is safe: Oban runs in `:manual` (config/test.exs) and the Swoosh
  Test adapter delivers to this process's own mailbox.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  import Swoosh.TestAssertions

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.UserToken
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.{Delivery, EmailSettings}
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Workers.TokenExpiryWarningWorker

  ## Fixtures

  defp user_fixture(prefix) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "#{prefix}-#{n}@example.com",
        password: "correct horse staple"
      })

    user
  end

  # A team with THREE members — an owner (the token holder) and two others. The
  # third member is not decoration: with two the "one row" assertion could pass
  # by an off-by-one, and the fan-out it fences against is per-MEMBER.
  defp three_member_team do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    owner = user_fixture("owner")
    admin = user_fixture("admin")
    member = user_fixture("member")

    {:ok, _} = Accounts.add_member(team, owner, "owner")
    {:ok, _} = Accounts.add_member(team, admin, "admin")
    {:ok, _} = Accounts.add_member(team, member, "member")

    {team, owner, admin, member}
  end

  # A PAT row written directly, so `expires_at` lands on an EXACT instant.
  # `Accounts.create_personal_access_token/3` only takes whole
  # `:expires_in_days`, which cannot express "inside the window but not on a day
  # boundary" — the shape the window arithmetic actually has to get right.
  defp pat_fixture(user, team, opts) do
    n = System.unique_integer([:positive])

    attrs = %{
      user_id: user.id,
      team_id: team.id,
      name: Keyword.get(opts, :name, "ci-deploy-#{n}"),
      abilities: ["read"],
      token_hash: UserToken.hash_token("bpc_pat_fixture_#{n}"),
      expires_at: Keyword.fetch!(opts, :expires_at)
    }

    {:ok, token} =
      %UserToken{}
      |> UserToken.pat_changeset(attrs)
      |> Repo.insert()

    if revoked = Keyword.get(opts, :revoked_at) do
      {:ok, token} =
        token |> Ecto.Changeset.change(%{revoked_at: revoked}) |> Repo.update()

      token
    else
      token
    end
  end

  defp in_days(days) do
    DateTime.utc_now()
    |> DateTime.add(trunc(days * 86_400), :second)
    |> DateTime.truncate(:microsecond)
  end

  # EVERY `token_expiring` delivery row in the database, at any status and any
  # scope. Deliberately NOT filtered by team_id or recipient: a filter would be
  # the very assumption under test — a fan-out row addressed to a third member
  # must be VISIBLE to this helper, or the fence cannot lose.
  defp token_expiring_rows do
    Repo.all(from(d in Delivery, where: d.event == "token_expiring", order_by: d.recipient))
  end

  ## ── The feature, and criterion 1 ─────────────────────────────────────────

  describe "the warning reaches the token's owner and NOBODY else" do
    test "a 3-member team, one owner PAT nearing expiry -> exactly ONE row, to the owner" do
      {team, owner, admin, member} = three_member_team()
      _token = pat_fixture(owner, team, expires_at: in_days(2))

      assert %{warned: 1, failed: 0} = TokenExpiryWarningWorker.run(DateTime.utc_now())

      assert [%Delivery{} = row] = token_expiring_rows()
      assert row.recipient == owner.email
      assert row.recipient != admin.email
      assert row.recipient != member.email

      # The USER-SCOPED transactional path, exactly as password_reset /
      # email_verification ride it. A team_id here would put this token's
      # existence into the team's delivery log — the disclosure re-entering
      # through the audit trail.
      assert is_nil(row.team_id)
      assert row.kind == "transactional"
      assert row.carrier == "platform"
      assert row.status == "sent"
    end

    test "the budget is one-shot: a second pass the same day sends nothing more" do
      {team, owner, _admin, _member} = three_member_team()
      _token = pat_fixture(owner, team, expires_at: in_days(3))

      assert %{warned: 1} = TokenExpiryWarningWorker.run(DateTime.utc_now())
      assert %{warned: 0, failed: 0} = TokenExpiryWarningWorker.run(DateTime.utc_now())

      assert [%Delivery{}] = token_expiring_rows()
    end

    test "the daily cron entry runs the same scan (perform/1 is not a second code path)" do
      {team, owner, _admin, _member} = three_member_team()
      _token = pat_fixture(owner, team, expires_at: in_days(1))

      assert {:ok, %{warned: 1}} = perform_job(TokenExpiryWarningWorker, %{})
      assert [%Delivery{recipient: to}] = token_expiring_rows()
      assert to == owner.email
    end
  end

  describe "the window and the liveness clauses select honestly" do
    test "a token expiring beyond the 7-day window is NOT warned yet" do
      {team, owner, _admin, _member} = three_member_team()
      _token = pat_fixture(owner, team, expires_at: in_days(20))

      assert %{warned: 0, failed: 0} = TokenExpiryWarningWorker.run(DateTime.utc_now())
      assert [] == token_expiring_rows()
    end

    test "a REVOKED token is never warned — it has no future to warn about" do
      {team, owner, _admin, _member} = three_member_team()

      _token =
        pat_fixture(owner, team,
          expires_at: in_days(2),
          revoked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        )

      assert %{warned: 0} = TokenExpiryWarningWorker.run(DateTime.utc_now())
      assert [] == token_expiring_rows()
    end

    test "a token that ALREADY expired is never warned — that would be future tense about a past fact" do
      {team, owner, _admin, _member} = three_member_team()
      _token = pat_fixture(owner, team, expires_at: in_days(-1))

      assert %{warned: 0} = TokenExpiryWarningWorker.run(DateTime.utc_now())
      assert [] == token_expiring_rows()
    end

    test "a never-expiring PAT (expires_at nil) is never warned" do
      {team, owner, _admin, _member} = three_member_team()

      {:ok, _plain, _t} =
        Accounts.create_personal_access_token(owner, team, %{
          name: "forever",
          expires_in_days: nil
        })

      assert %{warned: 0} = TokenExpiryWarningWorker.run(DateTime.utc_now())
      assert [] == token_expiring_rows()
    end

    test "warning_window_days/0 is the window the scan actually uses" do
      {team, owner, _admin, _member} = three_member_team()
      days = TokenExpiryWarningWorker.warning_window_days()

      # Just INSIDE the published window, and just OUTSIDE it. If the accessor
      # ever drifts from the scan's horizon, one of these two flips.
      inside = pat_fixture(owner, team, expires_at: in_days(days - 0.5))
      _outside = pat_fixture(owner, team, expires_at: in_days(days + 0.5))

      assert %{warned: 1} = TokenExpiryWarningWorker.run(DateTime.utc_now())

      assert [%Delivery{recipient: to}] = token_expiring_rows()
      assert to == owner.email
      assert Repo.get!(UserToken, inside.id).expiry_warned_at != nil
    end
  end

  ## ── Criterion 2: the NEGATIVE tests that PIN the rule ────────────────────

  describe "the team fan-out is real, and this warning may not travel it" do
    test "dispatch_event/3 fans an alert to EVERY member — the hazard, run, not asserted in prose" do
      {team, owner, admin, member} = three_member_team()

      # `:test` is on `@always_send`, so this is the alert path at full strength
      # with no toggle in the way. It is the shape a `token_expiring` producer
      # would have taken if anyone had "just dispatched it".
      :ok = Notifications.dispatch_event(team, :test, %{})

      fanned =
        Repo.all(from(d in Delivery, where: d.event == "test", order_by: d.recipient))

      assert length(fanned) == 3

      assert Enum.sort(Enum.map(fanned, & &1.recipient)) ==
               Enum.sort([owner.email, admin.email, member.email])

      # And every one of them is TEAM-scoped, i.e. visible in the team log.
      assert Enum.all?(fanned, &(&1.team_id == team.id))
    end

    test "routing :token_expiring through dispatch_event/3 is STRUCTURALLY unreachable — it delivers to nobody" do
      {team, owner, _admin, _member} = three_member_team()
      _token = pat_fixture(owner, team, expires_at: in_days(2))

      # The forbidden call, made on purpose. `token_expiring` is neither an
      # `EmailSettings` toggle column (wave 30's migration dropped it) nor on
      # `Notifications`'s `@always_send`, so `event_enabled?/2`'s catch-all
      # returns false and the fan-out never runs.
      :ok = Notifications.dispatch_event(team, :token_expiring, %{name: "ci-deploy"})

      assert [] == token_expiring_rows()

      # The two locks that make the line above true, asserted directly so a
      # future edit that re-opens either one reds HERE rather than shipping a
      # silent fan-out.
      refute :token_expiring in EmailSettings.events()

      refute EmailSettings.event_enabled?(
               Notifications.get_or_create_settings(team),
               :token_expiring
             )
    end

    test "the worker's own source never names dispatch_event" do
      source = File.read!("lib/barkpark_cloud/workers/token_expiry_warning_worker.ex")

      # The moduledoc discusses the forbidden function at length, so a bare
      # substring search would match prose. Only a CALL counts: the function
      # name immediately followed by an open paren.
      refute Regex.match?(~r/dispatch_event\(/, source)

      # And the positive half — the worker DOES reach the user-scoped path.
      assert Regex.match?(~r/Notifications\.deliver_token_expiring\(/, source)
    end
  end

  ## ── Criterion 3: the rendered body ───────────────────────────────────────

  describe "the rendered body names the token and its expiry" do
    test "body is non-empty and carries the token NAME and the expiry DATE" do
      {team, owner, _admin, _member} = three_member_team()
      expires_at = in_days(4)
      _token = pat_fixture(owner, team, name: "prod-deploy-key", expires_at: expires_at)

      assert %{warned: 1} = TokenExpiryWarningWorker.run(DateTime.utc_now())

      date = Calendar.strftime(expires_at, "%Y-%m-%d")

      assert_email_sent(fn email ->
        assert [{_, to}] = email.to
        assert to == owner.email
        assert email.subject =~ "prod-deploy-key"

        # The measured defect the filing names: `event_email.ex` rendered
        # `token_expiring` as a bare `detail(payload)`, shipping `text_body ==
        # ""`. An emptiness check alone would pass on any filler, so the two
        # FACTS are asserted by content.
        assert is_binary(email.text_body)
        assert String.trim(email.text_body) != ""
        assert email.text_body =~ "prod-deploy-key"
        assert email.text_body =~ date
      end)
    end
  end
end
