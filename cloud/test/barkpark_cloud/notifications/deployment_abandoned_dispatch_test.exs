defmodule BarkparkCloud.Notifications.DeploymentAbandonedDispatchTest do
  @moduledoc """
  dr-w13-bl-abandonment-splits-off-the-flood — the chain the fleet GAVE UP ON
  gets its own event, its own subject and its own toggle, and the routine failure
  flood is left exactly as it was.

  ## What this proves, and why it drives the REAL edge

  Charter D193 refuted the premise that an abandonment notifies nobody: it always
  did, as `deployment_failed`, indistinguishable from ~870 routine failures a
  day. So every test here walks a real deployment through
  `Registry.transition_deployment_fenced/4` — the same fenced edge
  `Sites.Deploy.fail/3` uses — and reads the MAILBOX. A test that hand-called the
  policy would prove the predicate and say nothing about which alert a person
  gets.

  THE REASON IS NEVER RE-TYPED. It is built through the public producer,
  `Sites.Deploy.abandonment_reason/3`, so a reword of that sentence reds here
  instead of silently degrading every abandonment back into the flood — the same
  discipline `deploy_ledger_test.exs` applies to the classifier.

  ## The arm that matters most is the SERVING one

  #17129 narrowed `deployment_failed` to attempts that destroyed content, so a
  failure on a site that is already serving mails nobody. An abandonment on a
  serving site is the normal case (the site keeps serving the revision before the
  one nobody could ship), so if the split sat BELOW that gate the most severe
  outcome in the fleet would be the quietest thing in it. The first test is
  therefore driven on a site with content on the web, and asserts the site really
  IS serving before it reads the mailbox.

  `async: false`: these assert on the shared `Swoosh.Adapters.Test` mailbox.
  """
  use BarkparkCloud.DataCase, async: false
  import Swoosh.TestAssertions

  alias BarkparkCloud.{Accounts, DeployLedger, Notifications, Registry}
  alias BarkparkCloud.Notifications.EmailSettings
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Sites.Deploy

  @abandoned_subject "Rebuild chain given up on"
  @failed_subject "Deployment failed"

  # The capacity chain's own bound — 12 refusals — read through the producer that
  # writes the sentence rather than pinned here as a literal.
  @cause "BOX_AT_CAPACITY_DEFERRED"
  @rounds 12

  ## Fixtures

  defp team_with_owner do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "owner-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _} = Accounts.add_member(team, user, "owner")
    {team, user}
  end

  defp setup_site do
    {team, owner} = team_with_owner()
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "Shop #{n}", slug: "shop-#{n}"})
    {team, site, owner}
  end

  defp flush_emails(n \\ 0) do
    receive do
      {:email, _} -> flush_emails(n + 1)
    after
      50 -> n
    end
  end

  defp transition(claimed, worker, attrs) do
    Registry.transition_deployment_fenced(claimed.id, worker, claimed.claim_epoch, attrs)
  end

  # Content ON THE WEB the honest way: a real row walked queued → building →
  # pushing → live through the fenced writer.
  defp serve_content!(site) do
    worker = "builder-live-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.create_deployment(site, %{git_ref: "live-ref"})
    {:ok, claimed} = Registry.claim_next_deployment(worker)

    for status <- ~w(building pushing) do
      {:ok, _} = transition(claimed, worker, %{status: status})
    end

    {:ok, live} =
      transition(claimed, worker, %{
        status: "live",
        became_live_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert live.status == "live"
    flush_emails()
    :ok
  end

  # THE ABANDONMENT, written exactly as `Sites.Deploy`'s abandonment branch
  # writes it: the producer's own terminal sentence, plus the three chain columns
  # it stamps in the SAME fenced write.
  defp abandon_through_fenced_writer(site) do
    reason =
      Deploy.abandonment_reason(
        # `Sites.Deploy.box_refusal/3`'s own anchored prefix, with the box's code
        # word — the shape `DeployLedger`'s `@deferral_prefix` reads the class
        # out of. It is private, so it is re-typed here and IMMEDIATELY checked:
        # the `classify/1` precondition in every test below reds if this string
        # stops being a capacity refusal, which is what keeps a green here from
        # being a fixture the classifier never recognised.
        "the instance refused the deploy (HTTP 409): box_at_capacity",
        @rounds,
        @cause
      )

    fail_through_fenced_writer(site, reason, %{
      deferral_depth: @rounds,
      deferral_bound: @rounds,
      deferral_cause: @cause
    })
  end

  defp fail_through_fenced_writer(site, reason, extra \\ %{}) do
    worker = "builder-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, claimed} = Registry.claim_next_deployment(worker)

    {:ok, failed} =
      transition(
        claimed,
        worker,
        Map.merge(extra, %{status: "failed", failure_reason: reason})
      )

    failed
  end

  ## 1. THE SPLIT

  test "an ABANDONED_* transition mails its OWN subject, on a site that is serving" do
    {_team, site, owner} = setup_site()
    serve_content!(site)

    failed = abandon_through_fenced_writer(site)

    # FIRST, the preconditions — so a green below cannot be a fixture that never
    # abandoned, and cannot be a dark site sneaking through the failure arm.
    assert Repo.get(Deployment, failed.id).status == "failed"
    assert DeployLedger.classify(failed) == "ABANDONED_AT_CAPACITY"
    assert DeployLedger.content_on_web?(site.id)

    assert_email_sent(fn email ->
      assert email.subject == @abandoned_subject
      assert {_, to} = hd(email.to)
      assert to == owner.email

      # THE COPY (charter D194). The CHAIN was given up on, after a stated
      # number of refusals — and the message may not claim the content is off
      # the web, which this row cannot establish.
      assert email.text_body =~ "rebuild chain"
      assert email.text_body =~ "given up on after #{@rounds} refusals"
      refute email.text_body =~ "never reached the web"
      refute email.text_body =~ "reached the web"

      # `assert_email_sent/1` asserts the FUNCTION'S RETURN VALUE is truthy, and
      # `refute/1` returns `false` — so a fun ending on a refute fails the
      # assertion no matter what it proved. The explicit `true` is what makes the
      # refutes above readable as refutes instead of as the return value.
      true
    end)
  end

  ## 2. THE FLOOD IS UNTOUCHED

  test "CONTROL — a routine failure still mails `deployment_failed`, unchanged" do
    {_team, site, owner} = setup_site()
    # A dark site: #17129 narrowed the failure alert to attempts that destroyed
    # content, so this is the arm where a routine failure still speaks at all.
    refute DeployLedger.content_on_web?(site.id)

    failed = fail_through_fenced_writer(site, "unauthorized: invalid token")

    assert Repo.get(Deployment, failed.id).status == "failed"
    refute DeployLedger.classify(failed) =~ "ABANDONED_"

    assert_email_sent(fn email ->
      assert email.subject == @failed_subject
      assert {_, to} = hd(email.to)
      assert to == owner.email
    end)
  end

  ## 3. THE TOGGLE IS ITS OWN

  test "the new atom is in the vocabulary and the alert rides ITS OWN toggle" do
    assert :deployment_abandoned in EmailSettings.events()
    assert "deployment_abandoned" in Notifications.chat_events()

    {team, site, _owner} = setup_site()
    serve_content!(site)

    # ARM ONE — the toggle's DEFAULT is ON and the alert really speaks on this
    # fixture. Without this arm the silence below would be satisfied by any
    # implementation that sent nothing at all, which is exactly what the
    # pre-split tree does here.
    spoke = abandon_through_fenced_writer(site)
    assert DeployLedger.classify(spoke) == "ABANDONED_AT_CAPACITY"
    assert_email_sent(fn email -> email.subject == @abandoned_subject end)
    flush_emails()

    # ARM TWO — muting the ABANDONMENT alone silences it, which is proof it is
    # not still riding `deployment_failed`'s toggle under a new subject.
    {:ok, _settings} = Notifications.update_settings(team, %{deployment_abandoned: false})
    flush_emails()

    failed = abandon_through_fenced_writer(site)
    assert DeployLedger.classify(failed) == "ABANDONED_AT_CAPACITY"
    assert_no_email_sent()
  end
end
