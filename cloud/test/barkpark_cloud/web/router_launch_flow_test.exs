defmodule BarkparkCloud.Web.RouterLaunchFlowTest do
  @moduledoc """
  dwb-6 — the launch-with-template response SHAPES the `/new` SPA relies on to
  drive the flow:

    * 201 {barkpark: {id, …}} — the optimistic row + progress step key off the id
    * 402 {error: "no_active_subscription", checkout_path} — the "price before any
      charge" screen (dwb-13 auto-starts the ONE free trial, so this only fires
      once the trial is spent; the SPA then shows tiers + a checkout CTA)
    * 403 {error: "limit_reached", upgrade_path} — the plan-ceiling screen

  These pin the CONTRACT the client parses; the SPA can't be browser-tested here.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry}
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  # Mark the team's one free trial as already used so the dwb-13 auto-start returns
  # :trial_used and the 402 stands (mirrors go_live_limit_test.exhaust_trial/1).
  defp exhaust_trial(team) do
    past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(t in Team, where: t.id == ^team.id),
        set: [trial_started_at: past, trial_ends_at: past]
      )

    :ok
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  test "launch with a template → 201 {barkpark:{id}} carrying the chosen template" do
    {user, team} = user_with_team()
    {:ok, _} = Billing.subscribe(team, "supporter")
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = call(:post, "/v1/launch", %{name: "My Blog", template: "blog-starter"}, token)
    assert conn.status == 201
    bp = json_body(conn)["barkpark"]
    assert is_binary(bp["id"])
    assert bp["name"] == "My Blog"

    [row] = Registry.list_barkparks(team)
    assert row.template == "blog-starter"
  end

  ## Double submit — dwb-launch-flow-double-submit-test
  #
  # The SERVER half of dwb-6 criterion 4. The /new client jumps to the progress
  # view on `409 {barkpark: {id}}` ("already provisioning"); this block pins that
  # the server emits exactly that for an EQUIVALENT second launch — same team,
  # same name, same template, same provider — while the first is still in
  # flight, and that the duplicate creates nothing: ONE barkparks row, ONE
  # provision job, ONE trial/billing transition, ONE go-live audit. Every request
  # carries an explicit name, so nothing here depends on a derived default name.
  #
  # Two billing shapes, because the pre-fix failure differed between them: a
  # TRIAL team (ceiling 1) got the plan-limit 403 on its own double-click, a
  # SUPPORTER team (ceiling 3) got a 422 slug-taken. Neither is the 409 the
  # client parses. Removing the go_live reconcile reds every non-control test.

  @dup_body %{name: "Dup Blog", template: "blog-starter"}

  # :trial starts UN-entitled with an unused ledger, so the FIRST launch
  # auto-starts its one free trial (dwb-13) — the trial transition under test.
  # :supporter is already subscribed, so no billing transition may happen.
  defp dup_team(plan) do
    {user, team} = user_with_team()
    if plan == :supporter, do: {:ok, _} = Billing.subscribe(team, "supporter")
    {:ok, token} = Accounts.create_user_session_token(user)
    {team, token}
  end

  # Everything a duplicate launch could multiply, read from the DATABASE —
  # never from the responses.
  defp dup_ledger(team) do
    ids = team |> Registry.list_barkparks() |> Enum.map(& &1.id)

    count = fn query -> Repo.aggregate(query, :count, :id) end

    %{
      rows: ids,
      provision_jobs:
        count.(
          from(j in BarkparkCloud.Registry.ProvisionJob,
            where: j.barkpark_id in ^ids and j.kind == "provision"
          )
        ),
      subscriptions:
        count.(from(s in BarkparkCloud.Billing.Subscription, where: s.team_id == ^team.id)),
      go_live_audits:
        count.(
          from(a in BarkparkCloud.Accounts.AuditEvent,
            where: a.team_id == ^team.id and a.action == "barkpark.go_live"
          )
        ),
      trial_started_at: Repo.get!(Team, team.id).trial_started_at
    }
  end

  defp assert_one_of_everything(ledger, id, plan) do
    assert ledger.rows == [id]
    assert ledger.provision_jobs == 1
    assert ledger.subscriptions == 1
    assert ledger.go_live_audits == 1

    case plan do
      :trial -> assert %DateTime{} = ledger.trial_started_at
      :supporter -> assert is_nil(ledger.trial_started_at)
    end
  end

  defp assert_already_provisioning(conn, id) do
    assert conn.status == 409,
           "want 409 already_provisioning, got #{conn.status} #{conn.resp_body}"

    body = json_body(conn)
    assert body["error"] == "already_provisioning"
    assert body["barkpark"]["id"] == id
    assert body["barkpark"]["name"] == "Dup Blog"
  end

  describe "double submit (same user, equivalent launch)" do
    for plan <- [:trial, :supporter] do
      test "#{plan}: sequential re-post → 409 already_provisioning naming the first id; nothing doubles" do
        plan = unquote(plan)
        {team, token} = dup_team(plan)

        first = call(:post, "/v1/launch", @dup_body, token)
        assert first.status == 201
        id = json_body(first)["barkpark"]["id"]
        after_first = dup_ledger(team)
        assert_one_of_everything(after_first, id, plan)

        assert_already_provisioning(call(:post, "/v1/launch", @dup_body, token), id)
        # A third click gets the same answer — the reconcile is stable.
        assert_already_provisioning(call(:post, "/v1/launch", @dup_body, token), id)

        # The duplicates changed NOTHING: same row, same job count, same
        # subscription count, the trial stamp not moved, one audit.
        assert dup_ledger(team) == after_first
      end

      test "#{plan}: racing pair → one 201 + one 409, both naming the SAME id; nothing doubles" do
        plan = unquote(plan)
        {team, token} = dup_team(plan)
        parent = self()

        # The go_live_limit_test race shape: each racer borrows the test's
        # sandbox connection. The pair interleaves at the APPLICATION level —
        # both can read "no twin yet" before either inserts, which is where a
        # duplicate is born. The database side (the team row FOR UPDATE and the
        # (team_id, slug) unique index) picks the loser; the loser must still
        # answer 409 with the WINNER's id.
        responses =
          for _ <- 1..2 do
            Task.async(fn ->
              Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
              conn = call(:post, "/v1/launch", @dup_body, token)
              {conn.status, json_body(conn)}
            end)
          end
          |> Enum.map(&Task.await(&1, 30_000))

        assert responses |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [201, 409],
               "want exactly one 201 and one 409, got #{inspect(responses)}"

        assert [id] = responses |> Enum.map(fn {_, b} -> b["barkpark"]["id"] end) |> Enum.uniq()
        assert is_binary(id)
        assert {409, %{"error" => "already_provisioning"}} = List.keyfind(responses, 409, 0)

        assert_one_of_everything(dup_ledger(team), id, plan)
      end
    end

    # CONTROLS — the reconcile keys on the EQUIVALENT in-flight launch, not on
    # "any launch by this team". Without these, a server that 409'd every second
    # launch would pass the block above.
    test "control: a DIFFERENT name is a new instance (201), not a reconcile" do
      {team, token} = dup_team(:supporter)
      a = json_body(call(:post, "/v1/launch", @dup_body, token))["barkpark"]["id"]

      conn = call(:post, "/v1/launch", %{@dup_body | name: "Other Blog"}, token)
      assert conn.status == 201
      refute json_body(conn)["barkpark"]["id"] == a
      assert length(dup_ledger(team).rows) == 2
    end

    test "control: the same name with a DIFFERENT template is refused, not reconciled" do
      {team, token} = dup_team(:supporter)
      assert call(:post, "/v1/launch", @dup_body, token).status == 201

      conn = call(:post, "/v1/launch", %{@dup_body | template: "website-starter"}, token)
      assert conn.status == 422
      assert length(dup_ledger(team).rows) == 1
    end

    test "control: a LIVE first instance (host set) is not 'already provisioning'" do
      {team, token} = dup_team(:supporter)
      id = json_body(call(:post, "/v1/launch", @dup_body, token))["barkpark"]["id"]

      {1, _} =
        Repo.update_all(from(b in BarkparkCloud.Registry.Barkpark, where: b.id == ^id),
          set: [host: "203.0.113.7"]
        )

      assert call(:post, "/v1/launch", @dup_body, token).status == 422
      assert dup_ledger(team).rows == [id]
    end

    test "control: a FAILED first provision is not 'already provisioning' (Retry owns it)" do
      {team, token} = dup_team(:supporter)
      id = json_body(call(:post, "/v1/launch", @dup_body, token))["barkpark"]["id"]

      {1, _} =
        Repo.update_all(
          from(j in BarkparkCloud.Registry.ProvisionJob, where: j.barkpark_id == ^id),
          set: [status: "failed"]
        )

      assert call(:post, "/v1/launch", @dup_body, token).status == 422
      assert dup_ledger(team).provision_jobs == 1
    end
  end

  # The NAMELESS double submit. go_live defaults an absent/blank/whitespace
  # name from the template title, so two nameless submissions of one template
  # are the same launch and must reconcile exactly like two named ones. The
  # twin check uses go_live's own resolved name/slug (`launch_identity/1`);
  # feeding it the raw `name` param instead reds every test in this block.
  describe "double submit with no name (the template-defaulted name)" do
    for {label, extra} <- [
          {"absent", %{}},
          {"blank", %{name: ""}},
          {"spaces-only", %{name: "   "}}
        ] do
      @nameless_body Map.merge(%{template: "blog-starter"}, extra)

      test "#{label} name, sequential → 201 then 409 already_provisioning, same id; one row, one job" do
        body = @nameless_body
        {team, token} = dup_team(:supporter)

        first = call(:post, "/v1/launch", body, token)
        assert first.status == 201
        id = json_body(first)["barkpark"]["id"]
        assert json_body(first)["barkpark"]["name"] == "Blog Starter"

        second = call(:post, "/v1/launch", body, token)

        assert second.status == 409,
               "want 409 already_provisioning, got #{second.status} #{second.resp_body}"

        assert json_body(second)["error"] == "already_provisioning"
        assert json_body(second)["barkpark"]["id"] == id

        ledger = dup_ledger(team)
        assert ledger.rows == [id]
        assert ledger.provision_jobs == 1
      end

      test "#{label} name, racing pair → one 201 + one 409, same id; one row, one job" do
        body = @nameless_body
        {team, token} = dup_team(:supporter)
        parent = self()

        responses =
          for _ <- 1..2 do
            Task.async(fn ->
              Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
              conn = call(:post, "/v1/launch", body, token)
              {conn.status, json_body(conn)}
            end)
          end
          |> Enum.map(&Task.await(&1, 30_000))

        assert responses |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [201, 409],
               "want exactly one 201 and one 409, got #{inspect(responses)}"

        assert [id] = responses |> Enum.map(fn {_, b} -> b["barkpark"]["id"] end) |> Enum.uniq()
        assert {409, %{"error" => "already_provisioning"}} = List.keyfind(responses, 409, 0)

        ledger = dup_ledger(team)
        assert ledger.rows == [id]
        assert ledger.provision_jobs == 1
      end
    end
  end

  # task-1f5c2cceae36e4d9 — the racing pair above flaked in CI as [201, 403]:
  # the loser's twin check ran BEFORE the winner committed and its quota check
  # ran AFTER, and the cond's quota arm 403'd without asking again. The race
  # tests cannot force that window, so this one does: a telemetry handler on the
  # repo's query event, scoped to THIS process, commits the winner's row (and
  # its provision job) the moment the loser's first twin lookup returns empty.
  # The loser then counts a full slot. Removing the re-check in the quota arm
  # reds this test with 403 limit_reached.
  describe "the winner commits between the loser's twin check and its quota check" do
    test "the quota arm re-asks for the twin → 409 with the winner's id, not 403" do
      {user, team} = user_with_team()
      # free = ceiling 1, so the winner's one row fills the only slot.
      {:ok, _} = Billing.subscribe(team, "free")
      {:ok, token} = Accounts.create_user_session_token(user)
      slug = "dup-blog"

      me = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:barkpark_cloud, :repo, :query],
        fn _event, _measure, meta, _cfg ->
          # The loser's FIRST in-flight-twin lookup (the only barkparks query
          # keyed on this slug and fleet_role) — fire once, in this process only.
          if self() == me and not Process.get(:winner_committed, false) and
               meta.query =~ ~s(FROM "barkparks") and meta.query =~ "fleet_role" and
               slug in meta.params do
            Process.put(:winner_committed, true)

            {:ok, winner} =
              Registry.register_managed_barkpark(team, "Dup Blog", slug,
                template: "blog-starter",
                provider: "hetzner"
              )

            {:ok, _job} = Registry.enqueue_provision_job(winner)
            send(me, {:winner, winner.id})
          end
        end,
        nil
      )

      conn =
        try do
          call(:post, "/v1/launch", @dup_body, token)
        after
          :telemetry.detach(handler)
        end

      # PRECONDITION: the interleaving really happened — the winner landed
      # mid-request, after the loser's twin lookup and before its quota check.
      assert_received {:winner, winner_id},
                      "the seam never fired: no twin lookup ran, so nothing was measured"

      assert conn.status == 409,
             "want 409 already_provisioning, got #{conn.status} #{conn.resp_body}"

      assert json_body(conn)["error"] == "already_provisioning"
      assert json_body(conn)["barkpark"]["id"] == winner_id

      ledger = dup_ledger(team)
      assert ledger.rows == [winner_id]
      assert ledger.provision_jobs == 1
    end
  end

  test "unentitled + trial spent → 402 {no_active_subscription, checkout_path}" do
    {user, team} = user_with_team()
    exhaust_trial(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = call(:post, "/v1/launch", %{name: "My Blog", template: "blog-starter"}, token)
    assert conn.status == 402
    body = json_body(conn)
    assert body["error"] == "no_active_subscription"
    assert body["checkout_path"] == "/v1/billing/checkout"

    # Nothing provisioned — the entitlement gate precedes any row/job.
    assert Registry.list_barkparks(team) == []
  end

  test "entitled but at the plan ceiling → 403 {limit_reached, upgrade_path}" do
    {user, team} = user_with_team()
    {:ok, _} = Billing.subscribe(team, "free")
    {:ok, token} = Accounts.create_user_session_token(user)

    assert call(:post, "/v1/launch", %{name: "First", template: "blog-starter"}, token).status ==
             201

    conn = call(:post, "/v1/launch", %{name: "Second", template: "blog-starter"}, token)
    assert conn.status == 403
    body = json_body(conn)
    assert body["error"] == "limit_reached"
    assert body["upgrade_path"] == "/v1/billing/checkout"
    assert length(Registry.list_barkparks(team)) == 1
  end

  # task-ef37ebad8249e82a — the /new form labels the name "(optional)" and sends
  # no `name` when the field is left blank. The server used to 422 name_required
  # on exactly that request; it now defaults the name from the template's catalog
  # title. Removing the default in go_live reds every test in this block.
  describe "a nameless launch with a template defaults the name from the template" do
    for {label, extra} <- [
          {"absent", %{}},
          {"empty", %{name: ""}},
          {"whitespace-only", %{name: "   \t "}}
        ] do
      test "#{label} name → 201, named from the template title, clean FQDN" do
        {user, team} = user_with_team()
        {:ok, _} = Billing.subscribe(team, "supporter")
        {:ok, token} = Accounts.create_user_session_token(user)

        conn =
          call(
            :post,
            "/v1/launch",
            Map.put(unquote(Macro.escape(extra)), :template, "blog-starter"),
            token
          )

        assert conn.status == 201, conn.resp_body
        assert json_body(conn)["barkpark"]["name"] == "Blog Starter"

        [row] = Registry.list_barkparks(team)
        assert row.name == "Blog Starter"
        assert row.slug == "blog-starter"
        assert row.template == "blog-starter"
        assert row.url == Barkpark.clean_url("blog-starter")
      end
    end

    test "two teams launching the same template nameless both succeed with distinct FQDNs" do
      {user_a, team_a} = user_with_team()
      {user_b, team_b} = user_with_team()
      {:ok, _} = Billing.subscribe(team_a, "supporter")
      {:ok, _} = Billing.subscribe(team_b, "supporter")
      {:ok, token_a} = Accounts.create_user_session_token(user_a)
      {:ok, token_b} = Accounts.create_user_session_token(user_b)

      assert call(:post, "/v1/launch", %{template: "blog-starter"}, token_a).status == 201
      assert call(:post, "/v1/launch", %{template: "blog-starter"}, token_b).status == 201

      [a] = Registry.list_barkparks(team_a)
      [b] = Registry.list_barkparks(team_b)
      # Clean-first: the first claimant gets the clean label; the second falls
      # back to the globally-unique `<slug>-<team_short_id>` form.
      assert a.url == Barkpark.clean_url("blog-starter")
      assert b.url == Barkpark.provisioning_url({"blog-starter", team_b.id})
      assert a.url != b.url
    end

    test "a given name still wins over the template default" do
      {user, team} = user_with_team()
      {:ok, _} = Billing.subscribe(team, "supporter")
      {:ok, token} = Accounts.create_user_session_token(user)

      assert call(:post, "/v1/launch", %{name: "Mine", template: "blog-starter"}, token).status ==
               201

      assert [%{name: "Mine", slug: "mine"}] = Registry.list_barkparks(team)
    end

    test "no template and no name → 422 name_required (nothing to derive from)" do
      {user, team} = user_with_team()
      {:ok, _} = Billing.subscribe(team, "supporter")
      {:ok, token} = Accounts.create_user_session_token(user)

      for body <- [%{}, %{name: ""}, %{name: "   "}] do
        conn = call(:post, "/v1/launch", body, token)
        assert conn.status == 422
        assert json_body(conn)["error"] == "name_required"
      end

      assert Registry.list_barkparks(team) == []
    end
  end
end
