defmodule BarkparkCloud.Notifications.AlertDetailReachabilityCensus do
  @moduledoc """
  The DERIVED census of alert dispatch sites and whether each one can carry a
  free-text `:detail` — the string `EventEmail.detail/1` scrubs on the way out.

  ## Why this exists

  `cchi-w27-bl-scrub-test-green-by-construction` (wave 27) found that the scrub
  test in `router_notifications_test.exs` loops three events through
  `EventEmail.build/4` with a hand-built `%{detail: capture}`. The assertion is
  live — delete the scrub and all three arms red — but for some events the
  FIXTURE manufactures a payload no producer in `cloud/lib` emits. A green there
  is a prophylactic green, not live-path coverage, and nothing said so.

  The row asked for a mechanism that fires when an event's reachability CHANGES.
  It asked because the change had already happened and nobody noticed: the row
  was filed asserting `:deployment_failed` had "ZERO dispatch sites anywhere in
  the repository", and by the time it was dispatched wave 28 S6 had added
  `Registry.maybe_dispatch_deployment_failed/2` plus the reaper's
  `DeploymentAlertWorker` — both carrying the deployment's `failure_reason` as
  `:detail`. The row's own premise went stale in-place with the suite fully
  green. That is the drift this census exists to red on.

  ## The derivation

  Parse every `.ex` under `cloud/lib`. Collect every call to one of the three
  dispatch entry points — `dispatch_event`, `dispatch_site_event`,
  `dispatch_barkpark_event`, remote-qualified or bare — whose EVENT argument is
  a literal atom. Classify what it hands over as a payload:

    * `:no_payload_arg`    — arity-2 call. The event carries no detail, ever.
    * `:literal_no_detail` — a literal `%{}` with no `:detail` key.
    * `:literal_detail`    — a literal `%{}` WITH a `:detail` key.
    * `:indirect_payload`  — a variable or a call. Shape alone cannot rule; the
      pinned table below carries a human verdict for each such row, and a change
      to the row reds the census and forces that verdict to be re-read.

  KEYED ON `{event, file, dispatch_fun, class}` — never on a line number. The
  sibling `WithholdCensus` rejects line numbers for the same reason: they red on
  any edit above the branch, which trains a builder to re-stamp instead of read.
  """

  @dispatchers [:dispatch_event, :dispatch_site_event, :dispatch_barkpark_event]

  @doc "The tree this census owns."
  def source_root, do: Path.expand("../../../lib", __DIR__)

  @doc "Every literal-event dispatch site under `cloud/lib`, with its payload class."
  def rows(root \\ source_root()) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(&rows_for(&1, root))
    |> Enum.sort()
    |> Enum.uniq()
  end

  @doc "The dispatch sites for one event."
  def rows_for_event(event, root \\ source_root()) do
    rows(root) |> Enum.filter(fn {e, _, _, _} -> e == event end)
  end

  @doc """
  Can this event reach `EventEmail.detail/1` with a non-empty string?

  `:never` when every dispatch site is proven detail-free by shape, `:yes` when
  at least one site hands over a literal `:detail`, `:indeterminate` when the
  only candidates are indirect payloads a human must read.
  """
  def detail_reachability(event, root \\ source_root()) do
    classes = rows_for_event(event, root) |> Enum.map(&elem(&1, 3))

    cond do
      classes == [] -> :no_producer
      :literal_detail in classes -> :yes
      :indirect_payload in classes -> :indeterminate
      true -> :never
    end
  end

  defp rows_for(path, root) do
    ast = path |> File.read!() |> Code.string_to_quoted!()
    rel = Path.relative_to(path, root)
    {_, rows} = Macro.prewalk(ast, [], &collect(&1, &2, rel))
    rows
  end

  # A remote call — `Notifications.dispatch_site_event(id, :evt, payload)`.
  defp collect({{:., _, [_mod, fun]}, _, args} = node, acc, rel)
       when fun in @dispatchers and is_list(args),
       do: {node, add(args, fun, acc, rel)}

  # A bare local call — the router's own `dispatch_barkpark_event/2,3`.
  defp collect({fun, _, args} = node, acc, rel) when fun in @dispatchers and is_list(args),
    do: {node, add(args, fun, acc, rel)}

  defp collect(node, acc, _rel), do: {node, acc}

  defp add([_subject, event | rest], fun, acc, rel) when is_atom(event),
    do: [{event, rel, fun, class(rest)} | acc]

  defp add(_args, _fun, acc, _rel), do: acc

  defp class([]), do: :no_payload_arg

  defp class([{:%{}, _, pairs}]) when is_list(pairs) do
    if Enum.any?(pairs, &match?({:detail, _}, &1)),
      do: :literal_detail,
      else: :literal_no_detail
  end

  defp class([_other]), do: :indirect_payload
  defp class(_), do: :unknown
end

defmodule BarkparkCloud.Notifications.AlertDetailReachabilityTest do
  @moduledoc """
  Two halves, both owned by `cchi-w27-bl-scrub-test-green-by-construction`.

    * §1 pins the derived dispatch census, so an event that GAINS or LOSES a
      detail-carrying producer cannot do it silently. This is the mechanism the
      row asked for under "if a `:deployment_failed` dispatcher is ever added, a
      test fails" — and it is a test that fails, not a comment that goes stale.
    * §2 drives the REAL producers for the two events that are live, and asserts
      the secret is scrubbed out of the email an actual dispatch sends. The
      sibling arms in `router_notifications_test.exs` call `EventEmail.build/4`
      by hand; these do not.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn
  import Swoosh.TestAssertions

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications.AlertDetailReachabilityCensus, as: Census
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

  # A clearly fake capture. `sk-test-NOTREAL…` is not a credential shape anyone
  # issued; it exists only so the scrub has something to remove.
  @secret "sk-test-NOTREAL-9aB3xQ7zLmNpR4tV6wY2"
  @capture "ssh: remote said Authorization: Bearer " <> @secret
  @redacted "Authorization: Bearer [redacted]"

  ## ---------------------------------------------------------------------------
  ## §1. The census — what can carry a `:detail` today
  ## ---------------------------------------------------------------------------

  # Every literal-event dispatch site in `cloud/lib`, as of this commit. RE-KEY
  # THIS TABLE when it reds, do not delete the arm: the red IS the notification
  # that an event's reachability moved, and the PROPHYLACTIC labels in
  # `router_notifications_test.exs` are downstream of it.
  #
  # The `:indirect_payload` rows, read by hand:
  #
  #   * `registry.ex :deployment_failed` — `deployment_failed_payload/2` is
  #     `Map.put(identity, :detail, failure_reason || "")`. CARRIES detail.
  #   * `deployment_alert_worker.ex :deployment_failed` — passes the Oban arg
  #     the reaper built with that same `deployment_failed_payload/2`, JSON so
  #     its keys are strings. CARRIES detail; `detail/1` reads both key shapes.
  #   * `registry.ex :deployment_abandoned` — the failure payload PLUS
  #     `:refusals`. CARRIES detail.
  #   * `registry.ex :deployment_succeeded` — a success payload; `event_email.ex`
  #     notes it deliberately has no `:detail`.
  #   * `accounts.ex :member_joined` — `%{name:, email:, role:}` built one line
  #     above the dispatch (cch-w30-bl-member-joined-alert). NO `:detail`, by
  #     construction: there is no failure capture on a join, and
  #     `event_email.ex`'s arm renders no `detail/1` at all. It is classed
  #     `:indirect_payload` only because the map is BOUND rather than inline —
  #     the census reads shape, not reachability, and the bound form is what
  #     keeps the `dispatch_event(` call on ONE SOURCE LINE, which
  #     `__app.test.mjs`'s producer census requires (it matches per line, so a
  #     formatter-wrapped call is invisible to it).
  @dispatch_census [
    {:agent_reachable, "barkpark_cloud/web/router.ex", :dispatch_barkpark_event, :no_payload_arg},
    {:agent_unreachable, "barkpark_cloud/health/staleness_worker.ex", :dispatch_event,
     :literal_no_detail},
    {:agent_unreachable, "barkpark_cloud/web/router.ex", :dispatch_barkpark_event,
     :no_payload_arg},
    {:deployment_abandoned, "barkpark_cloud/registry.ex", :dispatch_site_event,
     :indirect_payload},
    {:deployment_failed, "barkpark_cloud/registry.ex", :dispatch_site_event, :indirect_payload},
    {:deployment_failed, "barkpark_cloud/workers/deployment_alert_worker.ex",
     :dispatch_site_event, :indirect_payload},
    {:deployment_refused, "barkpark_cloud/sites/auto_deploy_worker.ex", :dispatch_site_event,
     :literal_detail},
    {:deployment_succeeded, "barkpark_cloud/registry.ex", :dispatch_site_event,
     :indirect_payload},
    {:member_joined, "barkpark_cloud/accounts.ex", :dispatch_event, :indirect_payload},
    {:provision_failed, "barkpark_cloud/web/router.ex", :dispatch_barkpark_event,
     :literal_detail},
    {:provision_succeeded, "barkpark_cloud/web/router.ex", :dispatch_barkpark_event,
     :no_payload_arg},
    {:subscription_past_due, "barkpark_cloud/web/router.ex", :dispatch_event, :literal_no_detail},
    {:trial_expired, "barkpark_cloud/workers/trial_expiry_worker.ex", :dispatch_event,
     :literal_no_detail},
    {:trial_expiring, "barkpark_cloud/workers/trial_expiry_worker.ex", :dispatch_event,
     :literal_no_detail}
  ]

  describe "§1 the alert dispatch census" do
    test "the derived dispatch sites match the pinned table" do
      derived = Census.rows()
      pinned = Enum.sort(@dispatch_census)

      added = derived -- pinned
      removed = pinned -- derived

      assert added == [],
             "NEW alert dispatch sites are not in @dispatch_census. Re-key it, and check " <>
               "whether a PROPHYLACTIC label in router_notifications_test.exs is now stale:\n" <>
               inspect(added, pretty: true)

      assert removed == [],
             "pinned dispatch sites have DISAPPEARED from cloud/lib. Re-key @dispatch_census:\n" <>
               inspect(removed, pretty: true)
    end

    # THE SHARP EDGE. This is the assertion that reds the moment someone gives
    # `:agent_unreachable` a detail-carrying producer, which is exactly when its
    # PROPHYLACTIC arm in router_notifications_test.exs must be promoted to a
    # producer-level arm beside §2's two.
    test "agent_unreachable still reaches EventEmail.detail/1 with NOTHING" do
      sites = Census.rows_for_event(:agent_unreachable)

      assert sites != [], "the event lost its producers entirely — re-read the census"

      assert Census.detail_reachability(:agent_unreachable) == :never,
             "`:agent_unreachable` gained a payload that can carry :detail. Its scrub arm in " <>
               "router_notifications_test.exs is labelled PROPHYLACTIC on the premise that it " <>
               "cannot. Promote that arm to a producer-level one and re-label it. Sites:\n" <>
               inspect(sites, pretty: true)
    end

    # The counterpart, and the arm that would have fired in wave 28 had it
    # existed: `:deployment_failed` is NOT detail-free, so labelling its scrub
    # arm prophylactic today would be false.
    test "provision_failed and deployment_failed DO reach detail/1 — their arms are live" do
      assert Census.detail_reachability(:provision_failed) == :yes

      assert Census.detail_reachability(:deployment_failed) in [:yes, :indeterminate],
             "`:deployment_failed` lost every detail-carrying producer. If that is real, its " <>
               "scrub arm becomes prophylactic and must be re-labelled."
    end

    # A CONTROL. An event nobody dispatches must report `:no_producer` — proof
    # the census discriminates rather than answering the same thing for
    # everything. A uniform verdict is the signature of a broken instrument.
    test "an event with no producer at all reports :no_producer" do
      assert Census.detail_reachability(:this_event_does_not_exist) == :no_producer
    end
  end

  ## ---------------------------------------------------------------------------
  ## §2. Producer-level scrub — the real dispatch, not EventEmail.build/4
  ## ---------------------------------------------------------------------------

  defp team_with_owner do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    {:ok, user} =
      Accounts.register_user(%{email: "owner-#{n}@example.com", password: @password})

    {:ok, _} = Accounts.add_member(team, user, "owner")
    {team, user}
  end

  defp barkpark_for(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp post_json(path, body, token) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  describe "§2 a REAL producer's capture is scrubbed before it leaves the boundary" do
    # router.ex `POST /v1/internal/provision-jobs/:id/fail` — the one and only
    # `:provision_failed` producer, dispatching `%{detail: job.error}` where
    # `job.error` is whatever the off-box provisioner posted. A build PTY is
    # exactly where a bearer token ends up in a failure string.
    test "provision_failed: the provisioner's own error string reaches the inbox scrubbed" do
      {team, owner} = team_with_owner()
      bp = barkpark_for(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn =
        post_json("/v1/internal/provision-jobs/#{job.id}/fail", %{error: @capture}, @worker_token)

      # FIRST: the fixture really drove the producer. Without this the mail
      # assertion below could pass on an email nobody sent.
      assert conn.status == 200
      assert Repo.get(BarkparkCloud.Registry.ProvisionJob, job.id).error == @capture

      assert_email_sent(fn email ->
        assert {_, to} = hd(email.to)
        assert to == owner.email

        refute email.text_body =~ @secret,
               "the provisioner's raw capture reached a person's inbox unscrubbed"

        assert email.text_body =~ @redacted
      end)
    end

    # registry.ex `transition_deployment_fenced/4` — the fenced writer the
    # builder route, the agent route and `Sites.Deploy.fail/2` all funnel
    # through. Its `failure_reason` rides to `detail/1` as `:detail`.
    #
    # This arm is the direct refutation of the filing premise that
    # `:deployment_failed` "has ZERO dispatch sites anywhere in the repository".
    test "deployment_failed: the builder's failure_reason reaches the inbox scrubbed" do
      {team, owner} = team_with_owner()
      bp = barkpark_for(team)
      n = System.unique_integer([:positive])
      {:ok, site} = Registry.create_site(bp, %{name: "Shop #{n}", slug: "shop-#{n}"})
      {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
      {:ok, claimed} = Registry.claim_next_deployment("builder-#{n}")

      assert {:ok, _} =
               Registry.transition_deployment_fenced(
                 claimed.id,
                 "builder-#{n}",
                 claimed.claim_epoch,
                 %{status: "failed", failure_reason: @capture}
               )

      # FIRST: the fixture really produced the defect it claims to.
      failed = Repo.get(Deployment, claimed.id)
      assert failed.status == "failed"
      assert failed.failure_reason == @capture

      assert_email_sent(fn email ->
        assert {_, to} = hd(email.to)
        assert to == owner.email

        refute email.text_body =~ @secret,
               "the builder's raw failure_reason reached a person's inbox unscrubbed"

        assert email.text_body =~ @redacted
      end)
    end

    # THE CONTROL THAT MUST STAY QUIET. A failure whose capture holds no secret
    # must arrive with its sentence intact and no `[redacted]` in it — otherwise
    # §2 has merely traded a vacuous green for a scrub that eats everything.
    test "a clean failure_reason is delivered verbatim — the scrub redacts nothing" do
      {team, owner} = team_with_owner()
      bp = barkpark_for(team)
      n = System.unique_integer([:positive])
      {:ok, site} = Registry.create_site(bp, %{name: "Shop #{n}", slug: "shop-#{n}"})
      {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
      {:ok, claimed} = Registry.claim_next_deployment("builder-#{n}")

      clean = "build of 0f28d541e9a1b2c3d4e5f60718293a4b5c6d7e8f failed: exit status 1"

      assert {:ok, _} =
               Registry.transition_deployment_fenced(
                 claimed.id,
                 "builder-#{n}",
                 claimed.claim_epoch,
                 %{status: "failed", failure_reason: clean}
               )

      assert_email_sent(fn email ->
        assert {_, to} = hd(email.to)
        assert to == owner.email
        # `assert_email_sent/1` asserts on the fun's RETURN VALUE, and `refute`
        # returns nil — so a refute must never be the last expression here, or
        # the arm fails for a reason that has nothing to do with the email.
        refute email.text_body =~ "[redacted]",
               "the scrub redacted a capture that holds no secret"

        assert email.text_body =~ clean
      end)
    end
  end
end
