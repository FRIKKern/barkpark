defmodule BarkparkCloud.ProvisioningTest do
  @moduledoc """
  The provision-jobs queue — the bridge between this Elixir control plane and the
  off-box Go warm-pool provisioner.

  Two halves:

    * the Registry context functions — enqueue / claim (race-safe, oldest-first,
      nil-when-empty) / succeed (flips the Barkpark to up at its IP) / fail (the
      Barkpark stays provisioning).
    * the /v1/internal/provision-jobs/* HTTP endpoints — reachable ONLY with the
      shared WORKER token, rejecting user tokens, agent tokens, and no token.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Events, Registry}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob, Vault}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

  ## Fixtures (mirrors RouterTest)

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  ## Request helpers

  defp call(method, path, body, token) do
    call(method, path, body, token, nil)
  end

  defp call(method, path, body, token, team_id) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    conn = if team_id, do: put_req_header(conn, "x-barkpark-team", team_id), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Count a barkpark's ACTIVE (pending|claimed) jobs of a given kind — the set the
  # dwb-11 one-active-job index bounds to at most one.
  defp active_count(bp, kind) do
    from(j in ProvisionJob,
      where: j.barkpark_id == ^bp.id and j.kind == ^kind and j.status in ["pending", "claimed"]
    )
    |> Repo.aggregate(:count, :id)
  end

  # claim-fence (bp-c55): enqueue a `kind` job, claim it as "tok-A", age the claim
  # past the staleness threshold, then re-claim as "tok-B" — leaving the row claimed
  # by B with A now a stale ghost. Returns the job id.
  defp stale_reclaimed_job(team, kind \\ "provision") do
    bp = barkpark_fixture(team)

    {:ok, job} =
      case kind do
        "provision" ->
          Registry.enqueue_provision_job(bp)

        "deprovision" ->
          {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.44"})
          Registry.enqueue_deprovision_job(bp)
      end

    {claimed_a, _} = claim_for(kind, "tok-A")
    assert claimed_a.id == job.id
    assert claimed_a.claim_token == "tok-A"

    stale_at =
      DateTime.utc_now()
      |> DateTime.add(-(Registry.stale_after_seconds() + 60), :second)
      |> DateTime.truncate(:microsecond)

    from(j in ProvisionJob, where: j.id == ^job.id)
    |> Repo.update_all(set: [claimed_at: stale_at])

    {claimed_b, _} = claim_for(kind, "tok-B")
    assert claimed_b.id == job.id
    assert claimed_b.claim_token == "tok-B"

    job.id
  end

  defp claim_for("provision", tok), do: Registry.claim_next_job(tok)
  defp claim_for("deprovision", tok), do: Registry.claim_next_deprovision_job(tok)

  ## Context: enqueue / claim / succeed / fail

  describe "enqueue_provision_job/1" do
    test "inserts a pending job for the barkpark" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      assert {:ok, %ProvisionJob{} = job} = Registry.enqueue_provision_job(bp)
      assert job.status == "pending"
      assert job.barkpark_id == bp.id
      assert job.claim_token == nil
      assert job.claimed_at == nil
    end
  end

  # dwb-11: at most ONE active (pending|claimed) job of each kind per barkpark —
  # the money-path backstop that makes double-click Retry / double Remove safe.
  describe "one-active-job-per-barkpark idempotency (dwb-11)" do
    test "a second provision enqueue for the same barkpark is refused — never a second box" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      assert {:ok, %ProvisionJob{}} = Registry.enqueue_provision_job(bp)
      # The double-submit (Retry double-click): deduped, not a second pending job.
      assert {:error, :already_provisioning} = Registry.enqueue_provision_job(bp)
      assert active_count(bp, "provision") == 1
    end

    test "the partial unique index is the ATOMIC backstop even if the app-check is bypassed" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      {:ok, _first} =
        %ProvisionJob{}
        |> ProvisionJob.changeset(%{barkpark_id: bp.id, status: "pending"})
        |> Repo.insert()

      # A raw second insert (skipping enqueue's pre-check, i.e. a true concurrent
      # race) still cannot land a second ACTIVE provision — the DB serializes it
      # to a unique-constraint error keyed on the money-path index.
      assert {:error, %Ecto.Changeset{} = cs} =
               %ProvisionJob{}
               |> ProvisionJob.changeset(%{barkpark_id: bp.id, status: "pending"})
               |> Repo.insert()

      assert Enum.any?(cs.errors, fn {_f, {_m, opts}} ->
               opts[:constraint_name] == "provision_jobs_one_active_per_barkpark_kind_idx"
             end)

      assert active_count(bp, "provision") == 1
    end

    test "a legitimate retry AFTER a failure still enqueues (terminal job doesn't block)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")

      # The failed job is terminal (outside the partial index) → retry re-enqueues.
      assert {:ok, %ProvisionJob{status: "pending"}} = Registry.enqueue_provision_job(bp)
      assert active_count(bp, "provision") == 1
    end

    test "a second deprovision enqueue for the same barkpark is refused — one teardown" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      assert {:ok, %ProvisionJob{kind: "deprovision"}} = Registry.enqueue_deprovision_job(bp)
      assert {:error, :already_deprovisioning} = Registry.enqueue_deprovision_job(bp)
      assert active_count(bp, "deprovision") == 1
    end

    test "provision and deprovision jobs may coexist (index is kind-scoped)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      assert {:ok, _} = Registry.enqueue_provision_job(bp)
      assert {:ok, _} = Registry.enqueue_deprovision_job(bp)
      assert active_count(bp, "provision") == 1
      assert active_count(bp, "deprovision") == 1
    end
  end

  describe "claim_next_job/1" do
    test "claims the OLDEST pending job and CAS-es it to claimed" do
      {_user, team} = user_with_team()
      bp1 = barkpark_fixture(team, %{slug: "first"})
      bp2 = barkpark_fixture(team, %{slug: "second"})

      {:ok, first} = Registry.enqueue_provision_job(bp1)
      # Force a strictly-later inserted_at so "oldest" is unambiguous.
      _ =
        from(j in ProvisionJob, where: j.id == ^first.id)
        |> Repo.update_all(set: [inserted_at: ~U[2020-01-01 00:00:00.000000Z]])

      {:ok, _second} = Registry.enqueue_provision_job(bp2)

      assert {%ProvisionJob{} = claimed, %Barkpark{} = bp} = Registry.claim_next_job("ct-1")
      assert claimed.id == first.id
      assert claimed.status == "claimed"
      assert claimed.claim_token == "ct-1"
      assert claimed.claimed_at != nil
      assert bp.id == bp1.id
    end

    test "returns nil when no job is pending (the worker's 204 path)" do
      assert Registry.claim_next_job("ct-empty") == nil
    end

    test "an already-claimed job is not re-claimable; the next claim takes the next pending" do
      {_user, team} = user_with_team()
      bp1 = barkpark_fixture(team, %{slug: "a"})
      bp2 = barkpark_fixture(team, %{slug: "b"})
      {:ok, _} = Registry.enqueue_provision_job(bp1)
      {:ok, _} = Registry.enqueue_provision_job(bp2)

      {claimed1, _} = Registry.claim_next_job("ct-a")
      {claimed2, _} = Registry.claim_next_job("ct-b")

      assert claimed1.id != claimed2.id
      # The third claim finds nothing pending.
      assert Registry.claim_next_job("ct-c") == nil
    end

    test "a STALE claimed job IS re-claimable past the staleness threshold" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # First claim → claimed, attempts bumped to 1.
      {claimed, _} = Registry.claim_next_job("ct-1")
      assert claimed.status == "claimed"
      assert claimed.attempts == 1

      # Age the claim well past the staleness threshold (simulating a worker that
      # crashed / whose report failed in transit and left the row "claimed").
      stale_at =
        DateTime.utc_now()
        |> DateTime.add(-(Registry.stale_after_seconds() + 60), :second)
        |> DateTime.truncate(:microsecond)

      _ =
        from(j in ProvisionJob, where: j.id == ^job.id)
        |> Repo.update_all(set: [claimed_at: stale_at])

      # A fresh claim re-picks the stale job, bumps attempts, and resets claimed_at.
      assert {%ProvisionJob{} = reclaimed, %Barkpark{}} = Registry.claim_next_job("ct-2")
      assert reclaimed.id == job.id
      assert reclaimed.status == "claimed"
      assert reclaimed.claim_token == "ct-2"
      assert reclaimed.attempts == 2
      assert DateTime.compare(reclaimed.claimed_at, stale_at) == :gt
    end

    test "a FRESH claimed job is NOT re-claimable (a live worker is never raced)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _job} = Registry.enqueue_provision_job(bp)

      # Claim it; claimed_at is now (well within the staleness threshold).
      {claimed, _} = Registry.claim_next_job("ct-1")
      assert claimed.status == "claimed"

      # The next claim finds nothing claimable — the fresh claim is off-limits.
      assert Registry.claim_next_job("ct-2") == nil
    end

    test "a claimed provision_support job past the GENERIC threshold is NOT re-claimable " <>
           "(per-kind staleness, task-314de6aa36248bea)" do
      {_user, team} = user_with_team()
      main = barkpark_fixture(team)
      {:ok, main} = main |> Barkpark.fleet_changeset(%{fleet_role: "main"}) |> Repo.update()

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Support Lazy",
          slug: "support-lazy",
          parent_id: main.id,
          token_id: nil
        })

      {:ok, job} = Registry.enqueue_support_provision_job(support)
      {%ProvisionJob{} = claimed, _} = Registry.claim_next_support_provision_job("sup-A")
      assert claimed.id == job.id

      # Age the claim past the generic (~12m) threshold but under the support
      # (35m) budget — the Go support chain legitimately runs to 30 minutes, so
      # a second worker polling must NOT be handed the still-healthy job.
      mid_flight_at =
        DateTime.utc_now()
        |> DateTime.add(-(Registry.stale_after_seconds() + 60), :second)
        |> DateTime.truncate(:microsecond)

      _ =
        from(j in ProvisionJob, where: j.id == ^job.id)
        |> Repo.update_all(set: [claimed_at: mid_flight_at])

      assert Registry.claim_next_support_provision_job("sup-B") == nil
      assert Repo.get(ProvisionJob, job.id).claim_token == "sup-A"

      # Past the SUPPORT threshold the claim is honestly abandoned → re-claimable.
      stale_at =
        DateTime.utc_now()
        |> DateTime.add(-(Registry.support_stale_after_seconds() + 60), :second)
        |> DateTime.truncate(:microsecond)

      _ =
        from(j in ProvisionJob, where: j.id == ^job.id)
        |> Repo.update_all(set: [claimed_at: stale_at])

      assert {%ProvisionJob{} = reclaimed, %Barkpark{}} =
               Registry.claim_next_support_provision_job("sup-B")

      assert reclaimed.id == job.id
      assert reclaimed.claim_token == "sup-B"
    end

    test "a stale claim past the attempt cap is FAILED instead of re-handed-out" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      max = Registry.max_provision_attempts()

      # Park the job at the attempt cap and make its claim stale.
      stale_at =
        DateTime.utc_now()
        |> DateTime.add(-(Registry.stale_after_seconds() + 60), :second)
        |> DateTime.truncate(:microsecond)

      _ =
        from(j in ProvisionJob, where: j.id == ^job.id)
        |> Repo.update_all(set: [status: "claimed", claimed_at: stale_at, attempts: max])

      # The over-budget stale job is failed, and since it was the only claimable
      # row, the claim returns nil (nothing handed out).
      assert Registry.claim_next_job("ct-cap") == nil

      reloaded = Repo.get(ProvisionJob, job.id)
      assert reloaded.status == "failed"
      assert reloaded.error =~ "exceeded max provision attempts"
    end

    test "an over-budget stale job is failed but a younger pending job is still claimed" do
      {_user, team} = user_with_team()
      stale_bp = barkpark_fixture(team, %{slug: "stale"})
      fresh_bp = barkpark_fixture(team, %{slug: "fresh"})
      {:ok, stale_job} = Registry.enqueue_provision_job(stale_bp)
      {:ok, pending_job} = Registry.enqueue_provision_job(fresh_bp)
      max = Registry.max_provision_attempts()

      # The stale job is the OLDEST (smallest inserted_at) AND over budget, so the
      # claim loop must fail it and move on to the younger pending job.
      old_ts = ~U[2020-01-01 00:00:00.000000Z]

      _ =
        from(j in ProvisionJob, where: j.id == ^stale_job.id)
        |> Repo.update_all(
          set: [status: "claimed", claimed_at: old_ts, inserted_at: old_ts, attempts: max]
        )

      assert {%ProvisionJob{} = claimed, _} = Registry.claim_next_job("ct-skip")
      assert claimed.id == pending_job.id
      assert claimed.status == "claimed"

      assert Repo.get(ProvisionJob, stale_job.id).status == "failed"
    end

    test "race-safe: N concurrent claimers over N jobs each get a DISTINCT job, none duplicated" do
      {_user, team} = user_with_team()

      # Insert outside the per-test sandbox connection so the spawned tasks can
      # see the rows (shared-mode sandbox; async:true tests still share within
      # the test's own checked-out connection via allowances).
      n = 8

      for i <- 1..n do
        bp = barkpark_fixture(team, %{slug: "race-#{i}"})
        {:ok, _} = Registry.enqueue_provision_job(bp)
      end

      parent = self()

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

            case Registry.claim_next_job("ct-race-#{i}") do
              {job, _bp} -> job.id
              nil -> nil
            end
          end)
        end

      claimed_ids = tasks |> Enum.map(&Task.await/1) |> Enum.reject(&is_nil/1)

      # Every claim returned a DISTINCT job id — no double-claim.
      assert length(claimed_ids) == length(Enum.uniq(claimed_ids))
      # And every job ended up claimed exactly once.
      assert Repo.aggregate(from(j in ProvisionJob, where: j.status == "claimed"), :count) == n
      assert Repo.aggregate(from(j in ProvisionJob, where: j.status == "pending"), :count) == 0
    end
  end

  describe "claim_next_deprovision_job/1" do
    test "claims a pending DEPROVISION job and ignores pending provision jobs (kind isolation)" do
      {_user, team} = user_with_team()
      prov_bp = barkpark_fixture(team, %{slug: "prov"})
      dep_bp = barkpark_fixture(team, %{slug: "dep"})
      {:ok, _} = Registry.upsert_health(dep_bp, %{host: "203.0.113.40"})
      {:ok, _prov_job} = Registry.enqueue_provision_job(prov_bp)
      {:ok, dep_job} = Registry.enqueue_deprovision_job(dep_bp)

      assert {%ProvisionJob{} = claimed, %Barkpark{} = bp} =
               Registry.claim_next_deprovision_job("ct-dep")

      assert claimed.id == dep_job.id
      assert claimed.kind == "deprovision"
      assert claimed.status == "claimed"
      assert bp.id == dep_bp.id
      # The provision job is untouched — the two drains never cross.
      assert Registry.claim_next_deprovision_job("ct-dep-2") == nil
    end

    test "a STALE claimed deprovision job IS re-claimable past the staleness threshold" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.41"})
      {:ok, job} = Registry.enqueue_deprovision_job(bp)

      # First claim → claimed, attempts bumped to 1.
      {claimed, _} = Registry.claim_next_deprovision_job("ct-1")
      assert claimed.status == "claimed"
      assert claimed.attempts == 1

      # Age the claim past the staleness threshold (a worker that crashed mid-
      # teardown / whose succeed-report failed in transit and left the row claimed).
      stale_at =
        DateTime.utc_now()
        |> DateTime.add(-(Registry.stale_after_seconds() + 60), :second)
        |> DateTime.truncate(:microsecond)

      _ =
        from(j in ProvisionJob, where: j.id == ^job.id)
        |> Repo.update_all(set: [claimed_at: stale_at])

      # A new worker re-claims the stale deprovision job — recoverable, idempotent.
      assert {%ProvisionJob{} = reclaimed, %Barkpark{}} =
               Registry.claim_next_deprovision_job("ct-2")

      assert reclaimed.id == job.id
      assert reclaimed.kind == "deprovision"
      assert reclaimed.status == "claimed"
      assert reclaimed.claim_token == "ct-2"
      assert reclaimed.attempts == 2
    end

    test "a FRESH claimed deprovision job is NOT re-claimable (a live worker is never raced)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.42"})
      {:ok, _job} = Registry.enqueue_deprovision_job(bp)

      {claimed, _} = Registry.claim_next_deprovision_job("ct-1")
      assert claimed.status == "claimed"

      assert Registry.claim_next_deprovision_job("ct-2") == nil
    end
  end

  describe "succeed_job/2" do
    # cch-w34-s2: succeed_job lands the HOST, and leaves health "unknown" — the
    # machine exists, but nothing has reported yet, so there is nothing to call
    # healthy. The row goes green on the first POST /v1/agent/report.
    test "marks the job succeeded with the ip and leaves health unknown at that host" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, %ProvisionJob{} = done} = Registry.succeed_job(job.id, "203.0.113.7")
      assert done.status == "succeeded"
      assert done.result_ip == "203.0.113.7"

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "unknown"
      assert reloaded.host == "203.0.113.7"
      assert reloaded.agent_status == "offline"
    end

    test "instance-admin-token: persists the reported admin token ENCRYPTED at rest" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      token = "bp_admin_super-secret-instance-bearer"

      assert {:ok, %ProvisionJob{status: "succeeded"}} =
               Registry.succeed_job(job.id, "203.0.113.7", admin_token: token)

      reloaded = Registry.get_barkpark(bp.id)
      # The stored column is CIPHERTEXT, never the plaintext token.
      assert is_binary(reloaded.admin_token_encrypted)
      assert reloaded.admin_token_encrypted != token
      refute String.contains?(reloaded.admin_token_encrypted, token)
      # …and it round-trips through the SAME Vault seam the provider token uses.
      assert {:ok, ^token} = Vault.decrypt(reloaded.admin_token_encrypted)
      # The reveal sugar decrypts it back for the owner-facing route.
      assert {:ok, ^token} = Registry.reveal_admin_token(reloaded)
      # The host/health flip still happened in the same write.
      assert reloaded.host == "203.0.113.7"
      assert reloaded.health_status == "unknown"
    end

    test "ip-only succeed (no admin_token) leaves the encrypted column nil (back-compat)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, %ProvisionJob{status: "succeeded"}} =
               Registry.succeed_job(job.id, "203.0.113.7")

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.admin_token_encrypted == nil
      assert {:ok, nil} = Registry.reveal_admin_token(reloaded)
      assert reloaded.host == "203.0.113.7"
    end

    test "provision_support token_id: persists fleet_token_id on the SUPPORT row (task-5866ec745efcd7f7)" do
      {_user, team} = user_with_team()
      main = barkpark_fixture(team)
      n = System.unique_integer([:positive])

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Helper #{n}",
          slug: "helper-#{n}",
          parent_id: main.id,
          token_id: nil
        })

      {:ok, job} = Registry.enqueue_support_provision_job(support)

      assert {:ok, %ProvisionJob{status: "succeeded"}} =
               Registry.succeed_job(job.id, "203.0.113.7", token_id: "tok_opaque_42")

      reloaded = Registry.get_barkpark(support.id)
      # The CP row is now the durable token-id holder (PDF-D68) — what
      # `bp cloud support remove` reads to revoke the support's ledger token.
      assert reloaded.fleet_token_id == "tok_opaque_42"
      # The host/health flip happened in the SAME write.
      assert reloaded.host == "203.0.113.7"
      assert reloaded.health_status == "unknown"
    end

    test "ip-only support succeed (no token_id) leaves fleet_token_id nil (older workers, back-compat)" do
      {_user, team} = user_with_team()
      main = barkpark_fixture(team)
      n = System.unique_integer([:positive])

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Helper #{n}",
          slug: "helper-#{n}",
          parent_id: main.id,
          token_id: nil
        })

      {:ok, job} = Registry.enqueue_support_provision_job(support)

      assert {:ok, %ProvisionJob{status: "succeeded"}} =
               Registry.succeed_job(job.id, "203.0.113.7")

      reloaded = Registry.get_barkpark(support.id)
      assert reloaded.fleet_token_id == nil
      assert reloaded.host == "203.0.113.7"
    end

    test "token_id on a NON-support row is ignored — a main never carries a token id" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, %ProvisionJob{status: "succeeded"}} =
               Registry.succeed_job(job.id, "203.0.113.7", token_id: "tok_should_not_land")

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.fleet_token_id == nil
      assert reloaded.host == "203.0.113.7"
    end

    test "unknown id → {:error, :not_found}" do
      assert Registry.succeed_job(Ecto.UUID.generate(), "1.2.3.4") == {:error, :not_found}
    end

    test "a non-UUID id → {:error, :not_found} (no 500/CastError)" do
      assert Registry.succeed_job("not-a-uuid", "1.2.3.4") == {:error, :not_found}
    end

    test "rolls back the job flip when the barkpark health upsert fails (no split-brain)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # An ip the narrow health_changeset rejects (spaces violate @host_format) —
      # the barkpark health/host upsert MUST fail. The whole call rolls back: the
      # job stays NOT-succeeded and the barkpark stays provisioning (host=nil), so
      # there is never a "succeeded job / still-provisioning barkpark" split-brain.
      assert {:error, %Ecto.Changeset{}} = Registry.succeed_job(job.id, "bad ip with spaces")

      reloaded_job = Repo.get(ProvisionJob, job.id)
      refute reloaded_job.status == "succeeded"
      assert reloaded_job.result_ip == nil

      reloaded_bp = Registry.get_barkpark(bp.id)
      assert reloaded_bp.health_status == "unknown"
      assert reloaded_bp.host == nil
    end

    test "IDEMPOTENT: a re-succeed of an already-succeeded job returns {:ok} with NO double work" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # First succeed: job → succeeded, barkpark → up. Capture the barkpark's
      # updated_at — the no-double-work assertion is that a re-succeed leaves it
      # UNTOUCHED (the health/host upsert never re-runs).
      assert {:ok, _done} = Registry.succeed_job(job.id, "203.0.113.7")
      bp_after_first = Registry.get_barkpark(bp.id)
      assert bp_after_first.health_status == "unknown"
      first_updated_at = bp_after_first.updated_at

      # A retried/duplicate succeed (the worker re-POSTs after a dropped response).
      # It returns {:ok, job} — the worker keeps its box — WITHOUT re-running the
      # barkpark upsert. Pass a DIFFERENT ip to prove the side-effect is skipped:
      # if the upsert re-ran, host would change to the new ip.
      assert {:ok, %ProvisionJob{status: "succeeded"} = again} =
               Registry.succeed_job(job.id, "10.10.10.10")

      assert again.id == job.id
      # result_ip is unchanged from the first succeed — the re-POST did no work.
      assert again.result_ip == "203.0.113.7"

      bp_after_second = Registry.get_barkpark(bp.id)
      # The barkpark is untouched: same host, same updated_at (no second upsert).
      assert bp_after_second.host == "203.0.113.7"
      assert bp_after_second.updated_at == first_updated_at
    end

    test "STATUS GUARD: succeed on a FAILED job → {:error, :conflict}, job stays failed, barkpark untouched" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # Drive the job terminal-failed first.
      assert {:ok, _} = Registry.fail_job(job.id, "hetzner: out of capacity")

      # A succeed arriving for an already-failed job must NOT resurrect it.
      assert {:error, :conflict} = Registry.succeed_job(job.id, "203.0.113.7")

      reloaded_job = Repo.get(ProvisionJob, job.id)
      assert reloaded_job.status == "failed"
      assert reloaded_job.result_ip == nil

      reloaded_bp = Registry.get_barkpark(bp.id)
      assert reloaded_bp.health_status == "unknown"
      assert reloaded_bp.host == nil
    end
  end

  describe "fail_job/2" do
    test "marks the job failed and leaves the barkpark provisioning (health unchanged)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, %ProvisionJob{} = failed} =
               Registry.fail_job(job.id, "hetzner: quota exceeded")

      assert failed.status == "failed"
      assert failed.error == "hetzner: quota exceeded"

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "unknown"
      assert reloaded.host == nil
    end

    test "stores an error longer than 255 chars (compound fallback-ladder message)" do
      # The worker's real multi-candidate error ("failed on all 5 candidate
      # type/locations: ...") is ~600 chars. With error as varchar(255) the
      # /fail report itself 500'd and the job stalled in "claimed" forever.
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # DERIVED from the producer, not pasted. `CreateWithFallback`
      # (internal/cli/cloud/provider.go:569-578, READ-ONLY) composes exactly:
      #
      #   fmt.Errorf("create %q failed on all %d candidate type/locations:%s",
      #              base.Name, len(candidates), sb.String())
      #   fmt.Fprintf(&sb, "\n  - %s/%s: %s", spec.ServerType, spec.Region, err)
      #
      # The old pasted fixture wrote "…locations: " followed by "- cx23/fsn1: …"
      # — a trailing space where the producer has none, and a bare "- " where the
      # producer emits "\n  - ". That drift is exactly what let a whole-string
      # substring scan of the aggregate survive two waves (wave 25 S1). The
      # candidate ladder is HetznerCandidates (provider.go:543-552).
      ladder = [
        {"cx22", "fsn1"},
        {"cx23", "fsn1"},
        {"cx23", "hel1"},
        {"cx33", "nbg1"},
        {"cpx22", "fsn1"}
      ]

      entries =
        Enum.map_join(ladder, fn {type, region} ->
          "\n  - #{type}/#{region}: hcloud server create \"bp-stopwatch\": exit status 1: server limit reached, resource_unavailable for this server type"
        end)

      long_error =
        "create \"bp-stopwatch\" failed on all #{length(ladder)} candidate type/locations:" <>
          entries

      # The shape the producer guarantees: no space after the header's colon, and
      # every entry newline-two-space-dash prefixed.
      assert long_error =~ ~r/candidate type\/locations:\n  - /
      refute long_error =~ "locations: "
      assert String.length(long_error) > 255
      assert {:ok, %ProvisionJob{} = failed} = Registry.fail_job(job.id, long_error)
      assert failed.status == "failed"
      assert failed.error == long_error
    end

    test "unknown id → {:error, :not_found}" do
      assert Registry.fail_job(Ecto.UUID.generate(), "x") == {:error, :not_found}
    end

    test "a non-UUID id → {:error, :not_found} (no 500/CastError)" do
      assert Registry.fail_job("not-a-uuid", "x") == {:error, :not_found}
    end

    test "IDEMPOTENT: a re-fail of an already-failed job returns {:ok} unchanged" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, _} = Registry.fail_job(job.id, "hetzner: quota exceeded")

      # A retried/duplicate fail (dropped response) self-heals to {:ok} and does
      # NOT overwrite the original error.
      assert {:ok, %ProvisionJob{status: "failed"} = again} =
               Registry.fail_job(job.id, "a different reason")

      assert again.id == job.id
      assert again.error == "hetzner: quota exceeded"
    end

    test "STATUS GUARD: fail on a SUCCEEDED job → {:error, :conflict}, job stays succeeded" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # Drive the job terminal-succeeded first (barkpark now up).
      assert {:ok, _} = Registry.succeed_job(job.id, "198.51.100.9")

      # A straggler fail must NOT un-succeed a live box.
      assert {:error, :conflict} = Registry.fail_job(job.id, "too late")

      reloaded_job = Repo.get(ProvisionJob, job.id)
      assert reloaded_job.status == "succeeded"
      assert reloaded_job.result_ip == "198.51.100.9"

      reloaded_bp = Registry.get_barkpark(bp.id)
      assert reloaded_bp.health_status == "unknown"
      assert reloaded_bp.host == "198.51.100.9"
    end
  end

  ## dwb-14: step narration + dwb-15: graceful release (context level)

  describe "append_provision_step/4 (dwb-14)" do
    test "appends a stamped step entry, preserving order" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, job} = Registry.append_provision_step(job.id, "create", "started")
      {:ok, job} = Registry.append_provision_step(job.id, "create", "done")
      {:ok, job} = Registry.append_provision_step(job.id, "secure", "started", "dns")

      assert [
               %{"step" => "create", "status" => "started", "at" => at0},
               %{"step" => "create", "status" => "done"},
               %{"step" => "secure", "status" => "started", "detail" => "dns"}
             ] = job.steps

      # `at` is a server-stamped ISO-8601 timestamp (never trusted from the worker).
      assert {:ok, _, _} = DateTime.from_iso8601(at0)

      # Refetch proves it PERSISTED (survives a page refresh).
      assert length(Repo.get(ProvisionJob, job.id).steps) == 3
    end

    test "an unknown step or status → {:error, :invalid_step}" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:error, :invalid_step} = Registry.append_provision_step(job.id, "teleport", "done")
      assert {:error, :invalid_step} = Registry.append_provision_step(job.id, "create", "mid")
      assert Repo.get(ProvisionJob, job.id).steps == []
    end

    # C2/D45: the Go worker's golden-path VERIFY gate narrates as the `verify`
    # step (started → per-probe progress captions → done|failed). This pins the
    # vocabulary server-side — if `verify` ever falls out of @steps the worker's
    # narration would be silently 422-swallowed and the /new timeline would skip
    # from content straight to ready, hiding the gate from the user.
    test "the golden-path `verify` step is valid vocabulary (C2/D45)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, job} = Registry.append_provision_step(job.id, "verify", "started")

      # C8/D53: each verify probe report persists as its OWN `progress` entry —
      # one durable row per probe for the checklist — NOT a single caption
      # overwriting the last (that is every OTHER step's dwb-19 behavior).
      {:ok, job} =
        Registry.append_provision_step(
          job.id,
          "verify",
          "progress",
          "verify.login: POST /v1/auth/login → 401 (auth stack answered) (63ms)"
        )

      assert [
               %{"step" => "verify", "status" => "started"},
               %{"step" => "verify", "status" => "progress", "detail" => detail}
             ] = job.steps

      assert detail =~ "verify.login"

      # A red probe appends a terminal failed entry with its evidence.
      {:ok, job} =
        Registry.append_provision_step(job.id, "verify", "failed", "verify.login: 500 — boom")

      assert [
               %{"step" => "verify", "status" => "started"},
               %{"step" => "verify", "status" => "progress"},
               %{"step" => "verify", "status" => "failed", "detail" => "verify.login: 500 — boom"}
             ] = job.steps
    end

    test "an unknown job id → {:error, :not_found}" do
      assert {:error, :not_found} =
               Registry.append_provision_step(Ecto.UUID.generate(), "create", "started")
    end

    test "best-effort: a late step after the job is terminal still records (telemetry)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")

      assert {:ok, job} = Registry.append_provision_step(job.id, "create", "failed", "sold out")
      assert [%{"step" => "create", "status" => "failed"}] = job.steps
      # The append did NOT resurrect the job's status.
      assert Repo.get(ProvisionJob, job.id).status == "failed"
    end

    # C8 (D53): the `verify` gate's probes persist as DISCRETE `progress` entries
    # (one row per probe) so C3's `.bp-tl-probes` checklist populates — closing
    # the C1-wave debt where a single mutating caption left the checklist empty.
    # A failed probe (the #957 class) is still a terminal `failed` transition,
    # never a lying green.
    test "append_provision_step persists a verify/progress probe as a discrete entry (C8)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, job} = Registry.append_provision_step(job.id, "verify", "started")

      {:ok, job} =
        Registry.append_provision_step(job.id, "verify", "progress", "verify.login: 401 in 182ms")

      assert [
               %{"step" => "verify", "status" => "started"},
               %{
                 "step" => "verify",
                 "status" => "progress",
                 "detail" => "verify.login: 401 in 182ms"
               }
             ] = job.steps

      # It PERSISTED as its own progress row — the shape the C3 checklist reads.
      assert [
               %{"step" => "verify", "status" => "started"},
               %{
                 "step" => "verify",
                 "status" => "progress",
                 "detail" => "verify.login: 401 in 182ms"
               }
             ] = Repo.get(ProvisionJob, job.id).steps
    end

    # C8: the full green gate narrates one `progress` row per probe, in order, so
    # the checklist shows THREE items (api, login, studio) rather than one
    # overwriting caption.
    test "the verify gate persists one discrete row per probe (checklist populates)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, _} = Registry.append_provision_step(job.id, "verify", "started")
      {:ok, _} = Registry.append_provision_step(job.id, "verify", "progress", "verify.api: 200")
      {:ok, _} = Registry.append_provision_step(job.id, "verify", "progress", "verify.login: 401")

      {:ok, job} =
        Registry.append_provision_step(job.id, "verify", "progress", "verify.studio: 200")

      {:ok, job} = Registry.append_provision_step(job.id, "verify", "done")

      probes =
        for %{"step" => "verify", "status" => "progress", "detail" => d} <- job.steps, do: d

      assert probes == ["verify.api: 200", "verify.login: 401", "verify.studio: 200"]

      # started + 3 probes + done = 5 rows; the terminal `done` is its own entry.
      assert length(job.steps) == 5
      assert List.last(job.steps)["status"] == "done"
    end

    # C8 regression: the discrete-row behavior is `verify`-ONLY. Every other
    # step's `progress` must stay dwb-19 byte-identical — an in-place caption
    # UPDATE on the in-flight `started` entry, never a new array row.
    test "a non-verify step's progress still updates in place (dwb-19 unchanged)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, _} = Registry.append_provision_step(job.id, "secure", "started", "opening dns")
      {:ok, _} = Registry.append_provision_step(job.id, "secure", "progress", "dns record set")
      {:ok, job} = Registry.append_provision_step(job.id, "secure", "progress", "issuing tls")

      # ONE entry — the started row, its detail overwritten by the latest caption.
      assert [%{"step" => "secure", "status" => "started", "detail" => "issuing tls"}] = job.steps
      assert length(Repo.get(ProvisionJob, job.id).steps) == 1
    end
  end

  # C1: the honest `verify` step vocabulary (golden-path probes).
  describe "ProvisionJob step vocabulary — verify (C1)" do
    test "step_names/0 returns the steps in order, verify between content and ready" do
      assert ProvisionJob.step_names() == ~w(create freshen secure configure content verify ready)
    end

    # dwb-17: the Go worker's warm-image freshen narrates as the `freshen` step
    # (started → "Updating Barkpark v0.42 → v0.45…" / "Already up to date" progress
    # → done). This pins the vocabulary server-side — if `freshen` fell out of
    # @steps the worker's narration would be silently 422-swallowed and the /new
    # timeline would hide the update from the user.
    test "the freshen step is valid vocabulary for every status (dwb-17)" do
      assert "freshen" in ProvisionJob.step_names()

      for status <- ProvisionJob.step_statuses() do
        assert {:ok, {"freshen", ^status}} = ProvisionJob.validate_step("freshen", status)
      end
    end

    test "the freshen step persists a narrated update transition (dwb-17)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, job} = Registry.append_provision_step(job.id, "freshen", "started")

      {:ok, job} =
        Registry.append_provision_step(
          job.id,
          "freshen",
          "progress",
          "Updating Barkpark v0.42 → v0.45…"
        )

      # dwb-19: the progress caption UPDATES the in-flight `started` entry in place
      # (no new array entry), so there is still exactly one entry after progress.
      assert [%{"step" => "freshen", "status" => "started", "detail" => detail}] = job.steps
      assert detail =~ "Updating Barkpark"

      {:ok, _job} =
        Registry.append_provision_step(job.id, "freshen", "done", "Updated Barkpark to v0.45")

      # The terminal `done` is a new entry appended after the (progress-updated)
      # `started` — the persisted array survives a page refresh.
      persisted = Repo.get(ProvisionJob, job.id).steps
      assert [%{"status" => "started"}, %{"status" => "done"}] = persisted

      assert %{"step" => "freshen", "status" => "done", "detail" => "Updated Barkpark to v0.45"} =
               List.last(persisted)
    end

    test "validate_step accepts {\"verify\", status} for every known status" do
      for status <- ProvisionJob.step_statuses() do
        assert {:ok, {"verify", ^status}} = ProvisionJob.validate_step("verify", status)
      end
    end

    test "validate_step still rejects an unknown step" do
      assert :error = ProvisionJob.validate_step("boot", "started")
    end

    # Probe NAMES are detail vocabulary, never steps: C2's worker must report
    # step="verify" with the probe evidence in `detail` — a per-probe step name
    # would explode the vocabulary and break every step-keyed renderer.
    test "validate_step rejects a probe name as a step" do
      for probe <- ~w(verify.api verify.login verify.studio) do
        assert :error = ProvisionJob.validate_step(probe, "progress")
      end
    end
  end

  describe "append_provision_step/4 — dwb-19 live captions (progress)" do
    test "a progress caption UPDATES the in-flight started entry in place (no new entry)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, job} = Registry.append_provision_step(job.id, "create", "started")
      assert length(job.steps) == 1

      # Two captions in a row: the array MUST stay a single entry (in-place update),
      # and the detail is the LATEST caption.
      {:ok, job} =
        Registry.append_provision_step(
          job.id,
          "create",
          "progress",
          "Asking Hetzner for a server…"
        )

      assert length(job.steps) == 1

      assert [
               %{
                 "step" => "create",
                 "status" => "started",
                 "detail" => "Asking Hetzner for a server…"
               }
             ] = job.steps

      {:ok, job} =
        Registry.append_provision_step(job.id, "create", "progress", "Server up at 46.4.1.2")

      assert length(job.steps) == 1

      assert [%{"step" => "create", "status" => "started", "detail" => "Server up at 46.4.1.2"}] =
               job.steps

      # It PERSISTED (survives a refresh) — the detail rode the row json.
      refetched = Repo.get(ProvisionJob, job.id)
      assert [%{"detail" => "Server up at 46.4.1.2"}] = refetched.steps

      # A `done` transition still APPENDS (one entry per real transition), leaving
      # the caption on the started entry intact.
      {:ok, job} = Registry.append_provision_step(job.id, "create", "done")
      assert length(job.steps) == 2

      assert [
               %{"status" => "started", "detail" => "Server up at 46.4.1.2"},
               %{"status" => "done"}
             ] = job.steps
    end

    test "progress on a TERMINAL step (already done) is a no-op — no growth, no resurrection" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, _} = Registry.append_provision_step(job.id, "create", "started")
      {:ok, job} = Registry.append_provision_step(job.id, "create", "done")
      before = job.steps
      assert length(before) == 2

      # A late caption for a finished step must not append and must not mutate.
      assert {:ok, job} = Registry.append_provision_step(job.id, "create", "progress", "stale")
      assert job.steps == before
    end

    test "progress on a step that never started is a no-op" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, job} =
               Registry.append_provision_step(job.id, "secure", "progress", "too early")

      assert job.steps == []
    end

    test "the in-flight update targets ONLY the matching step" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, _} = Registry.append_provision_step(job.id, "create", "started")
      {:ok, _} = Registry.append_provision_step(job.id, "create", "done")
      {:ok, _} = Registry.append_provision_step(job.id, "secure", "started")

      {:ok, job} =
        Registry.append_provision_step(
          job.id,
          "secure",
          "progress",
          "Requesting your TLS certificate…"
        )

      assert [
               %{"step" => "create", "status" => "started"},
               %{"step" => "create", "status" => "done"},
               %{
                 "step" => "secure",
                 "status" => "started",
                 "detail" => "Requesting your TLS certificate…"
               }
             ] = job.steps
    end
  end

  describe "append_provision_console/2 (dwb-16)" do
    test "appends a stamped line, preserving order + persisting" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, job} = Registry.append_provision_console(job.id, "provisioning acme.barkpark.cloud…")
      {:ok, job} = Registry.append_provision_console(job.id, "create: started")
      {:ok, job} = Registry.append_provision_console(job.id, "create: done\n")

      assert [
               %{"line" => "provisioning acme.barkpark.cloud…", "at" => at0},
               %{"line" => "create: started"},
               # a trailing newline is trimmed
               %{"line" => "create: done"}
             ] = job.console

      assert {:ok, _, _} = DateTime.from_iso8601(at0)
      # Refetch proves it PERSISTED (survives a page refresh).
      assert length(Repo.get(ProvisionJob, job.id).console) == 3
    end

    test "a blank/non-binary line → {:error, :invalid}, nothing persisted" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:error, :invalid} = Registry.append_provision_console(job.id, "   ")
      assert {:error, :invalid} = Registry.append_provision_console(job.id, "")
      assert {:error, :invalid} = Registry.append_provision_console(job.id, nil)
      assert {:error, :invalid} = Registry.append_provision_console(job.id, 42)
      assert Repo.get(ProvisionJob, job.id).console == []
    end

    test "an unknown job id → {:error, :not_found}" do
      assert {:error, :not_found} =
               Registry.append_provision_console(Ecto.UUID.generate(), "hello")
    end

    test "CAPPED append-only: oldest lines drop past the 300-line cap" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # Append 305 lines; only the last 300 survive, oldest dropped, order kept.
      for i <- 1..305 do
        {:ok, _} = Registry.append_provision_console(job.id, "line #{i}")
      end

      console = Repo.get(ProvisionJob, job.id).console
      assert length(console) == 300
      assert List.first(console)["line"] == "line 6"
      assert List.last(console)["line"] == "line 305"
    end

    # cch-w33-s3: the PROVISION twin of the deploy-side disclosure. This file had
    # NO oversized-line fixture at all before this wave — the chop was untested
    # on this side, so it could have been silently rejecting rather than
    # truncating and nothing here would have noticed.

    test "cch-w33-s3: an oversized line TRUNCATES and DISCLOSES its original length" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, job} =
               Registry.append_provision_console(job.id, String.duplicate("x", 5_000))

      assert [%{"line" => line, "truncated_from" => 5_000}] = job.console
      assert String.length(line) == 2_000

      # PERSISTS — a refetch, not just the returned struct.
      assert [%{"line" => persisted, "truncated_from" => 5_000}] =
               Repo.get(ProvisionJob, job.id).console

      assert String.length(persisted) == 2_000
    end

    test "cch-w33-s3: a line of EXACTLY 2 KB is untouched and carries NO marker" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, job} =
               Registry.append_provision_console(job.id, String.duplicate("x", 2_000))

      assert [%{"line" => line} = entry] = job.console
      assert String.length(line) == 2_000
      refute Map.has_key?(entry, "truncated_from")
    end

    test "cch-w33-s3: the ring drop DISCLOSES its cumulative count on the oldest survivor" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      for i <- 1..305 do
        {:ok, _} = Registry.append_provision_console(job.id, "line #{i}")
      end

      console = Repo.get(ProvisionJob, job.id).console
      assert List.first(console)["dropped_before"] == 5

      for i <- 306..315 do
        {:ok, _} = Registry.append_provision_console(job.id, "line #{i}")
      end

      console = Repo.get(ProvisionJob, job.id).console
      assert length(console) == 300
      assert List.first(console)["line"] == "line 16"
      assert List.first(console)["dropped_before"] == 15
    end

    test "cch-w33-s3: BELOW the cap nothing is dropped and the count reads 0" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, job} = Registry.append_provision_console(job.id, "create: started")

      assert [entry] = job.console
      refute Map.has_key?(entry, "dropped_before")
      assert Map.get(entry, "dropped_before", 0) == 0
    end

    test "best-effort: a late line after the job is terminal still records" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")

      assert {:ok, job} = Registry.append_provision_console(job.id, "cleanup: torn down")
      assert [%{"line" => "cleanup: torn down"}] = job.console
      assert Repo.get(ProvisionJob, job.id).status == "failed"
    end
  end

  describe "release_job/1 (dwb-15)" do
    test "a CLAIMED job → pending, claim cleared, attempt NOT consumed" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.enqueue_provision_job(bp)
      {claimed, _} = Registry.claim_next_job("ct-rel")
      assert claimed.status == "claimed"
      assert claimed.attempts == 1

      assert {:ok, released} = Registry.release_job(claimed.id)
      assert released.status == "pending"
      assert is_nil(released.claim_token)
      assert is_nil(released.claimed_at)
      # The claim's attempt bump is UNDONE so the graceful release+reclaim is
      # attempt-neutral (a re-claim brings it back to 1, not 2).
      assert released.attempts == 0

      # It is immediately re-claimable.
      {reclaimed, _} = Registry.claim_next_job("ct-rel-2")
      assert reclaimed.id == claimed.id
      assert reclaimed.attempts == 1
    end

    test "IDEMPOTENT: releasing an already-pending job is a no-op {:ok}" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, released} = Registry.release_job(job.id)
      assert released.status == "pending"
      # A double release can't drive attempts negative.
      assert released.attempts == 0
    end

    test "STATUS GUARD: releasing a SUCCEEDED job → {:error, :conflict} (never resurrect a live box)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.succeed_job(job.id, "198.51.100.9")

      assert {:error, :conflict} = Registry.release_job(job.id)
      assert Repo.get(ProvisionJob, job.id).status == "succeeded"
    end

    test "STATUS GUARD: releasing a FAILED job → {:error, :conflict}" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")

      assert {:error, :conflict} = Registry.release_job(job.id)
      assert Repo.get(ProvisionJob, job.id).status == "failed"
    end

    test "an unknown job id → {:error, :not_found}" do
      assert {:error, :not_found} = Registry.release_job(Ecto.UUID.generate())
    end
  end

  ## go-live enqueues a job

  describe "go-live enqueues a provision job" do
    test "POST /v1/go-live leaves exactly one pending job for the new barkpark" do
      {user, team} = user_with_team()
      # go-live now GATES on an active subscription (the subscription replaced the
      # per-go-live charge) — subscribe the team first so launch is permitted.
      {:ok, _sub} = Billing.subscribe(team, "supporter")
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/go-live", %{name: "My Prod", plan: "supporter"}, token)
      assert conn.status == 201

      [bp] = Registry.list_barkparks(team)
      jobs = Repo.all(from j in ProvisionJob, where: j.barkpark_id == ^bp.id)
      assert [%ProvisionJob{status: "pending"}] = jobs

      # go-live now assigns the CLEAN <slug>.barkpark.cloud FQDN for a free,
      # non-reserved name; the worker stands up the label read back off the url,
      # so the provisioned FQDN == the customer-facing FQDN.
      assert bp.url == "https://my-prod.barkpark.cloud"
      assert Barkpark.subdomain_from_url(bp) == "my-prod"
      assert json_body(conn)["barkpark"]["url"] == bp.url
    end

    test "two teams that both name a Barkpark 'prod' get DISTINCT global FQDNs (the bug fix)" do
      {user_a, team_a} = user_with_team()
      {user_b, team_b} = user_with_team()
      {:ok, _} = Billing.subscribe(team_a, "supporter")
      {:ok, _} = Billing.subscribe(team_b, "supporter")
      {:ok, token_a} = Accounts.create_user_session_token(user_a)
      {:ok, token_b} = Accounts.create_user_session_token(user_b)

      assert call(:post, "/v1/go-live", %{name: "prod", plan: "supporter"}, token_a).status == 201
      assert call(:post, "/v1/go-live", %{name: "prod", plan: "supporter"}, token_b).status == 201

      [bp_a] = Registry.list_barkparks(team_a)
      [bp_b] = Registry.list_barkparks(team_b)

      # Same per-team slug ...
      assert bp_a.slug == "prod"
      assert bp_b.slug == "prod"
      # ... but DISTINCT global FQDNs — no cross-tenant collision.
      assert bp_a.url != bp_b.url
    end

    test "POST /v1/launch (the alias) also enqueues" do
      {user, team} = user_with_team()
      {:ok, _sub} = Billing.subscribe(team, "supporter")
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/launch", %{provider: "hetzner", name: "Launched"}, token)
      assert conn.status == 201
      assert Repo.aggregate(ProvisionJob, :count) == 1
    end
  end

  ## Internal endpoints — worker auth + behaviour

  describe "POST /v1/internal/provision-jobs/claim" do
    test "worker token + a pending job → 200 {job_id, name, slug, region=nil, server_type=nil}" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{name: "Acme", slug: "acme"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, @worker_token)
      assert conn.status == 200

      body = json_body(conn)
      assert body["job_id"] == job.id
      assert body["name"] == "Acme"
      # `slug` is the GLOBALLY-unique provisioning subdomain (<slug>-<team_short_id>),
      # NOT the bare per-team slug — this is the label the worker turns into the DNS
      # record + box name, so it must be globally unique.
      assert body["slug"] == Barkpark.provisioning_subdomain(bp)
      assert body["slug"] == "acme-" <> Barkpark.team_short_id(team.id)
      assert body["slug"] != "acme"
      # azh-w3: an UNPINNED row emits nil region/server_type (not the warm-pool
      # default) — the signal the Go warm pin-guard reads as "serve from the pool";
      # the worker fills the env-derived hetzner default before any one-shot create.
      assert body["region"] == nil
      assert body["server_type"] == nil

      # The job is now claimed.
      assert Repo.get(ProvisionJob, job.id).status == "claimed"
    end

    test "worker token + no pending job → 204 (empty body)" do
      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, @worker_token)
      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "no token → 401" do
      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, nil)
      assert conn.status == 401
    end

    test "a USER session token → 401 (never user-reachable)" do
      {user, _team} = user_with_team()
      {:ok, user_token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, user_token)
      assert conn.status == 401
    end

    test "an AGENT token → 401 (never agent-reachable)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      conn = call(:post, "/v1/internal/provision-jobs/claim", %{}, agent_token)
      assert conn.status == 401
    end
  end

  describe "POST /v1/internal/provision-jobs/:id/succeed" do
    test "worker token + {ip} → 200 ok, job succeeded, barkpark hosted at ip, health unknown" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/succeed",
          %{ip: "198.51.100.9"},
          @worker_token
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "unknown"
      assert reloaded.host == "198.51.100.9"
    end

    test "missing ip → 422" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn = call(:post, "/v1/internal/provision-jobs/#{job.id}/succeed", %{}, @worker_token)
      assert conn.status == 422
    end

    test "instance-admin-token: {ip, admin_token} persists the token ENCRYPTED" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      token = "bp_admin_http-reported-instance-token"

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/succeed",
          %{ip: "198.51.100.9", admin_token: token},
          @worker_token
        )

      assert conn.status == 200

      reloaded = Registry.get_barkpark(bp.id)
      assert is_binary(reloaded.admin_token_encrypted)
      assert reloaded.admin_token_encrypted != token
      assert {:ok, ^token} = Registry.reveal_admin_token(reloaded)
      assert reloaded.host == "198.51.100.9"
    end

    test "provision_support token_id: {ip, token_id} over HTTP persists fleet_token_id on the support row (task-5866ec745efcd7f7)" do
      {_user, team} = user_with_team()
      main = barkpark_fixture(team)
      n = System.unique_integer([:positive])

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Helper #{n}",
          slug: "helper-#{n}",
          parent_id: main.id,
          token_id: nil
        })

      {:ok, job} = Registry.enqueue_support_provision_job(support)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/succeed",
          %{ip: "198.51.100.9", token_id: "tok_http_reported_1"},
          @worker_token
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      reloaded = Registry.get_barkpark(support.id)
      assert reloaded.fleet_token_id == "tok_http_reported_1"
      assert reloaded.host == "198.51.100.9"
      assert reloaded.health_status == "unknown"
    end

    test "dwb (charter D9): the update-status kick is fire-and-forget — succeed 200s and flips the box live regardless of the probe's fate" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # The worker reports {ip, admin_token}, so the post-succeed kick fires an
      # isu-6 self-update probe at the just-provisioned box. The kick is a raw
      # `spawn` (deliberately NOT Task.start — see kick_update_status_refresh/1:
      # $callers propagation would let the probe borrow this test's Ecto.Sandbox
      # connection and race teardown), so under async tests the spawned probe
      # dies cleanly on sandbox ownership before any HTTP. What THIS test proves
      # is the route contract: the kick can NEVER block or fail the 200,
      # whatever the probe's fate. refresh_update_status itself is covered by
      # registry_update_status_test.exs.
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/succeed",
          %{ip: "198.51.100.9", admin_token: "bp_admin_unreachable-probe"},
          @worker_token
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      # The synchronous succeed work is unaffected: the box is flipped live.
      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "unknown"
      assert reloaded.host == "198.51.100.9"
    end

    test "unknown job id → 404" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/succeed",
          %{ip: "1.2.3.4"},
          @worker_token
        )

      assert conn.status == 404
    end

    test "a MALFORMED (non-UUID) job id → 404, not 500" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/not-a-uuid/succeed",
          %{ip: "1.2.3.4"},
          @worker_token
        )

      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "a USER token → 401" do
      {user, _team} = user_with_team()
      {:ok, user_token} = Accounts.create_user_session_token(user)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/succeed",
          %{ip: "1.2.3.4"},
          user_token
        )

      assert conn.status == 401
    end

    test "IDEMPOTENT: a retried succeed on an already-succeeded job → 200 (worker keeps box)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      path = "/v1/internal/provision-jobs/#{job.id}/succeed"
      assert call(:post, path, %{ip: "198.51.100.9"}, @worker_token).status == 200

      # The dropped-response retry: same endpoint, 200 again — the worker keeps box.
      conn = call(:post, path, %{ip: "198.51.100.9"}, @worker_token)
      assert conn.status == 200
      assert json_body(conn)["ok"] == true
      assert Repo.get(ProvisionJob, job.id).status == "succeeded"
    end

    test "STATUS GUARD: succeed on a FAILED job → 409 (worker tears down orphan box)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "out of capacity")

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/succeed",
          %{ip: "198.51.100.9"},
          @worker_token
        )

      assert conn.status == 409
      assert json_body(conn)["error"] == "conflict"
      assert Repo.get(ProvisionJob, job.id).status == "failed"
    end
  end

  describe "POST /v1/internal/provision-jobs/:id/fail" do
    test "worker token + {error} → 200 ok, job failed, barkpark stays provisioning" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn =
        call(:post, "/v1/internal/provision-jobs/#{job.id}/fail", %{error: "boom"}, @worker_token)

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      assert Repo.get(ProvisionJob, job.id).status == "failed"
      assert Registry.get_barkpark(bp.id).health_status == "unknown"
    end

    test "unknown job id → 404" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/fail",
          %{error: "x"},
          @worker_token
        )

      assert conn.status == 404
    end

    test "a MALFORMED (non-UUID) job id → 404, not 500" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/not-a-uuid/fail",
          %{error: "x"},
          @worker_token
        )

      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "an AGENT token → 401" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/fail",
          %{error: "x"},
          agent_token
        )

      assert conn.status == 401
    end

    test "no token → 401" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/fail",
          %{error: "x"},
          nil
        )

      assert conn.status == 401
    end

    test "IDEMPOTENT: a retried fail on an already-failed job → 200" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      path = "/v1/internal/provision-jobs/#{job.id}/fail"
      assert call(:post, path, %{error: "boom"}, @worker_token).status == 200

      conn = call(:post, path, %{error: "boom again"}, @worker_token)
      assert conn.status == 200
      assert json_body(conn)["ok"] == true
      assert Repo.get(ProvisionJob, job.id).status == "failed"
    end

    test "STATUS GUARD: fail on a SUCCEEDED job → 409 (don't un-succeed a live box)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.succeed_job(job.id, "198.51.100.9")

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/fail",
          %{error: "too late"},
          @worker_token
        )

      assert conn.status == 409
      assert json_body(conn)["error"] == "conflict"

      reloaded = Repo.get(ProvisionJob, job.id)
      assert reloaded.status == "succeeded"
      assert Registry.get_barkpark(bp.id).health_status == "unknown"
    end
  end

  describe "POST /v1/internal/provision-jobs/:id/step (dwb-14)" do
    test "worker token + {step,status} → 200, appends, and broadcasts fleet to the team" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # Subscribe THIS process to the team's :pg group so we can prove the SSE
      # broadcast fires (the /new page refetches on it).
      :ok = Events.subscribe(team.id)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/step",
          %{step: "secure", status: "started", detail: "dns"},
          @worker_token
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      # PERSISTED on the row.
      assert [%{"step" => "secure", "status" => "started", "detail" => "dns"}] =
               Repo.get(ProvisionJob, job.id).steps

      # BROADCAST to the owning team.
      assert_receive {:bpcloud_event, %{type: "fleet"}}
    end

    test "surfaces on the barkpark row json as provision_steps (refresh-durable)" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      _ =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/step",
          %{step: "create", status: "started"},
          @worker_token
        )

      _ =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/step",
          %{step: "create", status: "done"},
          @worker_token
        )

      {:ok, user_token} = Accounts.create_user_session_token(user)
      conn = call(:get, "/v1/barkparks", nil, user_token)
      assert conn.status == 200

      row = Enum.find(json_body(conn)["barkparks"], &(&1["id"] == bp.id))

      assert [
               %{"step" => "create", "status" => "started"},
               %{"step" => "create", "status" => "done"}
             ] =
               row["provision_steps"]
    end

    test "unknown step → 422 invalid_step" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/step",
          %{step: "warp", status: "done"},
          @worker_token
        )

      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid_step"
    end

    test "unknown job id → 404" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/step",
          %{step: "create", status: "started"},
          @worker_token
        )

      assert conn.status == 404
    end

    test "a USER token → 401 (internal endpoint)" do
      {user, _team} = user_with_team()
      {:ok, user_token} = Accounts.create_user_session_token(user)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/step",
          %{step: "create", status: "started"},
          user_token
        )

      assert conn.status == 401
    end

    test "dwb-19: a progress caption → 200, updates the in-flight step in place + BROADCASTS" do
      {_user, team} = user_with_team()
      :ok = Events.subscribe(team.id)
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      _ =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/step",
          %{step: "create", status: "started"},
          @worker_token
        )

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/step",
          %{step: "create", status: "progress", detail: "Asking Hetzner for a server…"},
          @worker_token
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      # In place: still ONE entry, now carrying the caption — no new entry per caption.
      assert [
               %{
                 "step" => "create",
                 "status" => "started",
                 "detail" => "Asking Hetzner for a server…"
               }
             ] =
               Repo.get(ProvisionJob, job.id).steps

      assert_receive {:bpcloud_event, %{type: "fleet"}}
    end

    test "dwb-19: progress on a terminal step → 200 no-op (no growth, no resurrection)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      _ =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/step",
          %{step: "create", status: "started"},
          @worker_token
        )

      _ =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/step",
          %{step: "create", status: "done"},
          @worker_token
        )

      before = Repo.get(ProvisionJob, job.id).steps

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/step",
          %{step: "create", status: "progress", detail: "stale"},
          @worker_token
        )

      assert conn.status == 200
      assert Repo.get(ProvisionJob, job.id).steps == before
    end
  end

  describe "POST /v1/internal/provision-jobs/:id/console (dwb-16)" do
    test "worker token → 200, appends the line + BROADCASTS fleet" do
      {_user, team} = user_with_team()
      :ok = Events.subscribe(team.id)
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/console",
          %{line: "configure: done"},
          @worker_token
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      assert [%{"line" => "configure: done"}] = Repo.get(ProvisionJob, job.id).console
      assert_receive {:bpcloud_event, %{type: "fleet"}}
    end

    test "surfaces on the barkpark row json as provision_console (refresh-durable)" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      _ =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/console",
          %{line: "create: started"},
          @worker_token
        )

      {:ok, user_token} = Accounts.create_user_session_token(user)
      conn = call(:get, "/v1/barkparks", nil, user_token)
      assert conn.status == 200

      row = Enum.find(json_body(conn)["barkparks"], &(&1["id"] == bp.id))
      assert [%{"line" => "create: started"}] = row["provision_console"]
    end

    test "blank line → 422 invalid" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      conn =
        call(:post, "/v1/internal/provision-jobs/#{job.id}/console", %{line: "  "}, @worker_token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid"
    end

    test "unknown job id → 404" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/console",
          %{line: "hi"},
          @worker_token
        )

      assert conn.status == 404
    end

    test "a USER token → 401 (internal endpoint)" do
      {user, _team} = user_with_team()
      {:ok, user_token} = Accounts.create_user_session_token(user)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/console",
          %{line: "hi"},
          user_token
        )

      assert conn.status == 401
    end
  end

  describe "POST /v1/internal/provision-jobs/:id/release (dwb-15)" do
    test "worker token → 200, a claimed job flips back to pending (no attempt consumed)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.enqueue_provision_job(bp)
      {claimed, _} = Registry.claim_next_job("ct-http-rel")

      conn = call(:post, "/v1/internal/provision-jobs/#{claimed.id}/release", %{}, @worker_token)
      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      reloaded = Repo.get(ProvisionJob, claimed.id)
      assert reloaded.status == "pending"
      assert reloaded.attempts == 0
    end

    test "IDEMPOTENT: a retried release on an already-pending job → 200" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      path = "/v1/internal/provision-jobs/#{job.id}/release"

      assert call(:post, path, %{}, @worker_token).status == 200
      assert call(:post, path, %{}, @worker_token).status == 200
    end

    test "STATUS GUARD: release of a SUCCEEDED job → 409" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.succeed_job(job.id, "198.51.100.9")

      conn = call(:post, "/v1/internal/provision-jobs/#{job.id}/release", %{}, @worker_token)
      assert conn.status == 409
      assert json_body(conn)["error"] == "conflict"
    end

    test "unknown job id → 404" do
      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/release",
          %{},
          @worker_token
        )

      assert conn.status == 404
    end

    test "a USER token → 401 (internal endpoint)" do
      {user, _team} = user_with_team()
      {:ok, user_token} = Accounts.create_user_session_token(user)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{Ecto.UUID.generate()}/release",
          %{},
          user_token
        )

      assert conn.status == 401
    end
  end

  describe "GET /v1/barkparks/:id/credentials (instance-admin-token retrieval)" do
    for role <- ["owner", "admin"] do
      test "secondary-team #{role} gets credentials with explicit team context" do
        {user, _primary_team} = user_with_team()
        secondary = team_fixture()
        {:ok, _} = Accounts.add_member(secondary, user, unquote(role))
        {:ok, token} = Accounts.create_user_session_token(user)
        bp = barkpark_fixture(secondary)
        {:ok, job} = Registry.enqueue_provision_job(bp)
        {:ok, _} = Registry.succeed_job(job.id, "203.0.113.8", admin_token: "bp_admin_secondary")

        conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, token, secondary.id)

        assert conn.status == 200
        assert json_body(conn)["admin_token"] == "bp_admin_secondary"
      end
    end

    test "secondary-team member with explicit team context gets 403" do
      {user, _primary_team} = user_with_team()
      secondary = team_fixture()
      {:ok, _} = Accounts.add_member(secondary, user, "member")
      {:ok, token} = Accounts.create_user_session_token(user)
      bp = barkpark_fixture(secondary)

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, token, secondary.id)

      assert conn.status == 403
    end

    test "outsider supplying another team's context gets indistinguishable 404" do
      {outsider, _primary_team} = user_with_team()
      {_owner, secondary} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(outsider)
      bp = barkpark_fixture(secondary)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.succeed_job(job.id, "203.0.113.9", admin_token: "bp_admin_hidden")

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, token, secondary.id)

      assert conn.status == 404
      refute String.contains?(conn.resp_body, "bp_admin_hidden")
    end

    test "team owner gets the decrypted admin token (show-to-owner)" do
      {owner, team} = user_with_team()
      {:ok, owner_token} = Accounts.create_user_session_token(owner)
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, _} =
        Registry.succeed_job(job.id, "203.0.113.7", admin_token: "bp_admin_owner-readable")

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, owner_token)

      assert conn.status == 200
      body = json_body(conn)
      assert body["admin_token"] == "bp_admin_owner-readable"
      assert body["url"] == bp.url
    end

    test "no token stored yet → 404 no_admin_token (ip-only / pre-feature instance)" do
      {owner, team} = user_with_team()
      {:ok, owner_token} = Accounts.create_user_session_token(owner)
      # Never went through a succeed-with-token, so no admin token is stored.
      bp = barkpark_fixture(team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, owner_token)

      assert conn.status == 404
      assert json_body(conn)["error"] == "no_admin_token"
    end

    test "a non-admin MEMBER of the owning team → 403 (team-admin gated)" do
      {_owner, team} = user_with_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      {:ok, member_token} = Accounts.create_user_session_token(member)
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.succeed_job(job.id, "203.0.113.7", admin_token: "bp_admin_secret")

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, member_token)

      assert conn.status == 403
    end

    test "a user from ANOTHER team → 404, no existence leak (never the token)" do
      {_owner, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.succeed_job(job.id, "203.0.113.7", admin_token: "bp_admin_secret")

      # A different user who owns a DIFFERENT team — admin of their own team, but
      # not a member of the owning team.
      {other, _other_team} = user_with_team()
      {:ok, other_token} = Accounts.create_user_session_token(other)

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, other_token)

      assert conn.status == 404
      refute String.contains?(conn.resp_body, "bp_admin_secret")
    end

    test "no token → 401" do
      {_owner, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, nil)

      assert conn.status == 401
    end
  end

  # ── THE ROOT-PAT PATH (cloud-agent onramp) ──────────────────────────────────
  #
  # Why this block exists. `/credentials` was SESSION-ONLY, so the committed
  # onramp config (#12729 — `.mcp.json`, `scripts/ensure-bp.sh`) had no way to
  # fetch an instance's credentials from a fresh container: a script carries a
  # Personal Access Token, never a browser session. The gate now accepts either
  # credential kind and narrows a PAT with the `root` ability ON TOP of the team
  # -admin role it already required of a session.
  #
  # THE REFUSALS ARE THE POINT, and they run on BOTH axes. A permission test
  # that only proves the allowed path works is half a test, so every arm below
  # asserts a body and not merely a status:
  #
  #   * the ABILITY axis — read / write / deploy PATs held by a real team admin
  #     are all refused. `deploy` is the load-bearing one: `Auth.ability_implies/0`
  #     widens both `write` and `deploy` INTO `read`, so a route gated on `read`
  #     is reachable by every PAT tier alive. Gating on `root` is what keeps the
  #     strongest credential the control plane holds out of a CI key's reach, and
  #     this row is the tripwire on any future widening of that table.
  #   * the ROLE axis — a `root` PAT whose holder has since been DEMOTED out of
  #     admin is refused. `pat_abilities_allowed?/2` caps the mint at `read` for
  #     a non-admin, so a root PAT can only ever be born privileged; nothing
  #     revokes it on demotion, which is exactly why the role is re-read here on
  #     every request rather than trusted from mint time.
  #   * the TENANCY axis — a root PAT is still confined to its own team, and a
  #     cross-team id is the same 404 a session gets, with no token in the body.
  # A live box whose stored admin ciphertext decrypts to `token` — the one shape
  # every row of the root-PAT block needs before it can be refused or served.
  defp creds_bp(team, token) do
    bp = barkpark_fixture(team)
    {:ok, job} = Registry.enqueue_provision_job(bp)
    {:ok, _} = Registry.succeed_job(job.id, "203.0.113.20", admin_token: token)
    bp
  end

  defp pat_for(user, team, abilities) do
    {:ok, plaintext, stored} =
      Accounts.create_personal_access_token(user, team, %{
        name: "onramp-#{Enum.join(abilities, "-")}-#{System.unique_integer([:positive])}",
        abilities: abilities
      })

    {plaintext, stored}
  end

  describe "GET /v1/barkparks/:id/credentials (root-PAT path)" do
    test "a root PAT held by the team owner gets the decrypted admin token" do
      {owner, team} = user_with_team()
      bp = creds_bp(team, "bp_admin_via_root_pat")
      {pat, stored} = pat_for(owner, team, ["root"])

      # The mint is EXCLUSIVE (`normalize_abilities/1` collapses root -> ["root"]),
      # so this PAT carries no `read`/`write`/`deploy` string of its own — the
      # implication table is what makes it reach anything, and it is the only
      # tier that implies `root`.
      assert stored.abilities == ["root"]

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, pat)

      assert conn.status == 200
      body = json_body(conn)
      assert body["admin_token"] == "bp_admin_via_root_pat"

      # Re-read the row: `succeed_job/3` set host/url AFTER the fixture handed
      # back its struct, so asserting against the stale struct would compare the
      # payload to `nil` and pass on an empty answer.
      live = Registry.get_barkpark(bp.id)
      assert body["host"] == live.host
      assert body["url"] == live.url
      assert body["host"] == "203.0.113.20"
    end

    test "a root PAT held by a team ADMIN (not the owner) also gets it" do
      {_owner, team} = user_with_team()
      admin = user_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "admin")
      bp = creds_bp(team, "bp_admin_for_the_admin")
      {pat, _} = pat_for(admin, team, ["root"])

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, pat)

      assert conn.status == 200
      assert json_body(conn)["admin_token"] == "bp_admin_for_the_admin"
    end

    for ability <- ~w(read write deploy) do
      test "a #{ability} PAT — held by the OWNER — is refused, and told it needed root" do
        {owner, team} = user_with_team()
        bp = creds_bp(team, "bp_admin_never_shown")
        {pat, _} = pat_for(owner, team, [unquote(ability)])

        conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, pat)

        assert conn.status == 403

        # FULL-MAP equality: an assertion that only keys into ["error"] cannot
        # notice the authority evidence going missing.
        assert json_body(conn) == %{
                 "error" => "forbidden",
                 "required" => "root",
                 "scope" => "token"
               }

        # The refusal is real, not a shape: the plaintext never reached the wire.
        refute String.contains?(conn.resp_body, "bp_admin_never_shown")
      end
    end

    # WHAT ACTUALLY PROTECTS THIS ROUTE FROM A STALE GRANT — and it is not the
    # role arm. This was written expecting a 403 and it measured a 401: a rank
    # drop runs `revoke_team_pats_exceeding_role/3` inside the same transaction
    # (and a removal runs `revoke_team_pats/2`), so the credential is DEAD, not
    # merely refused. Pinned here because it is the real property, and because a
    # change that stopped revoking would turn this 401 into a 403 that the role
    # arm below happens to catch — a silent downgrade from "revoked" to "denied"
    # that nothing else in the suite would notice.
    test "demoting the holder REVOKES the root PAT outright — 401, not a 403" do
      {_owner, team} = user_with_team()
      demoted = user_fixture()
      {:ok, _} = Accounts.add_member(team, demoted, "admin")
      bp = creds_bp(team, "bp_admin_withheld_after_demotion")

      # Minted while they still held admin — the only way a non-admin can end up
      # holding a root PAT at all (the mint caps a member at `read`).
      {pat, _} = pat_for(demoted, team, ["root"])
      assert call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, pat).status == 200

      {:ok, _} = Accounts.update_member_role(team, demoted, "member")

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, pat)

      assert conn.status == 401
      assert json_body(conn)["error"] == "unauthorized"
      refute String.contains?(conn.resp_body, "bp_admin_withheld_after_demotion")
    end

    # THE ROLE ARM ITSELF, driven directly — and labelled for what it is.
    #
    # No live path reaches this state today: every route that drops a grant
    # revokes the team's PATs with it (the test above), so the honest claim is
    # DEFENCE IN DEPTH and not "this closes a hole". Deleting the membership row
    # through the Repo is therefore not a shortcut around a real flow — it IS
    # the measurement: it isolates the gate from the revoker so the role arm can
    # be proven to carry weight on its own.
    #
    # It is a losable test. Delete the `Authz.team_admin?` branch from the route
    # and this row goes 200 with the plaintext admin token in the body, which is
    # exactly the failure the branch exists to prevent.
    test "a root PAT whose grant is gone but which was never revoked is refused on the ROLE axis" do
      {_owner, team} = user_with_team()
      ex_admin = user_fixture()
      {:ok, membership} = Accounts.add_member(team, ex_admin, "admin")
      bp = creds_bp(team, "bp_admin_never_reaches_an_ex_admin")

      {pat, _} = pat_for(ex_admin, team, ["root"])
      assert call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, pat).status == 200

      # Drop the grant WITHOUT the revocation the real flows perform.
      Repo.delete!(membership)

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, pat)

      assert conn.status == 403

      # `admin` on the TEAM scope, not `root` on the token scope: the role check
      # runs first, so the refusal names the authority they actually lack — the
      # ability was never the thing missing.
      assert json_body(conn) == %{
               "error" => "forbidden",
               "required" => "admin",
               "scope" => "team"
             }

      refute String.contains?(conn.resp_body, "bp_admin_never_reaches_an_ex_admin")
    end

    test "a plain member cannot mint a root PAT in the first place" do
      # The bound that makes the demotion case above the ONLY way a non-admin
      # holds `root`. Without it, the role check would be the only thing between
      # any member and a self-minted key to this route.
      {_owner, team} = user_with_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      assert {:error, :forbidden} =
               Accounts.create_personal_access_token(member, team, %{
                 name: "member-tries-root",
                 abilities: ["root"]
               })
    end

    test "a root PAT is confined to its own team — a foreign box is the same 404" do
      {outsider, outsider_team} = user_with_team()
      {_owner, owning_team} = user_with_team()
      bp = creds_bp(owning_team, "bp_admin_other_team")
      {pat, _} = pat_for(outsider, outsider_team, ["root"])

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, pat)

      # 404 and not 403: the same indistinguishable answer a session outsider
      # gets, so a root PAT cannot be used to probe which ids exist.
      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
      refute String.contains?(conn.resp_body, "bp_admin_other_team")
    end

    test "a garbage bearer is still 401, and a root PAT still 401s once revoked" do
      {owner, team} = user_with_team()
      bp = creds_bp(team, "bp_admin_gone")
      {pat, stored} = pat_for(owner, team, ["root"])

      assert call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, "bpc_pat_nonsense").status ==
               401

      assert {:ok, _} = Accounts.revoke_personal_access_token(owner, stored.id)

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, pat)
      assert conn.status == 401
      refute String.contains?(conn.resp_body, "bp_admin_gone")
    end

    test "the SESSION arm is unchanged — a member of the team still gets required: admin" do
      # The two session refusal shapes are pinned in router_ability_matrix_test.exs;
      # this restates the member one HERE, in the route's own suite, so a rewrite
      # of the gate that quietly re-routes a session through the PAT branch (and
      # starts answering `required: "root", scope: "token"` to a browser that has
      # no token at all) reds where the change was made.
      {_owner, team} = user_with_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      {:ok, session} = Accounts.create_user_session_token(member)
      bp = creds_bp(team, "bp_admin_not_for_members")

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, session)

      assert conn.status == 403

      assert json_body(conn) == %{
               "error" => "forbidden",
               "required" => "admin",
               "scope" => "team"
             }
    end
  end

  # claim-fence (bp-c55): a swept-and-re-claimed job's stale worker must NOT be able
  # to flip the row under the live claimant. When the worker echoes the claim_token
  # it holds, a transition whose token != the row's token is fenced out
  # (:stale_claim → 409). A token-LESS call keeps today's status-only behavior (the
  # Stage 1 compat window for the deployed Go fleet).
  describe "claim-fence — succeed/fail/release/deprovision (bp-c55)" do
    test "succeed_job: the STALE token is fenced, the LIVE token succeeds" do
      {_user, team} = user_with_team()
      id = stale_reclaimed_job(team)

      assert {:error, :stale_claim} =
               Registry.succeed_job(id, "203.0.113.1", claim_token: "tok-A")

      # Row untouched — still claimed by B, barkpark not flipped live.
      assert Repo.get(ProvisionJob, id).status == "claimed"

      assert {:ok, done} = Registry.succeed_job(id, "203.0.113.2", claim_token: "tok-B")
      assert done.status == "succeeded"
    end

    test "fail_job: the STALE token is fenced, the LIVE token succeeds" do
      {_user, team} = user_with_team()
      id = stale_reclaimed_job(team)

      assert {:error, :stale_claim} = Registry.fail_job(id, "boom", claim_token: "tok-A")
      assert Repo.get(ProvisionJob, id).status == "claimed"

      assert {:ok, failed} = Registry.fail_job(id, "boom", claim_token: "tok-B")
      assert failed.status == "failed"
    end

    test "release_job: the STALE token is fenced, the LIVE token succeeds" do
      {_user, team} = user_with_team()
      id = stale_reclaimed_job(team)

      assert {:error, :stale_claim} = Registry.release_job(id, claim_token: "tok-A")
      assert Repo.get(ProvisionJob, id).status == "claimed"

      assert {:ok, released} = Registry.release_job(id, claim_token: "tok-B")
      assert released.status == "pending"
    end

    test "succeed_deprovision_job: the STALE token is fenced, the LIVE token deletes" do
      {_user, team} = user_with_team()
      id = stale_reclaimed_job(team, "deprovision")
      bp_id = Repo.get(ProvisionJob, id).barkpark_id

      assert {:error, :stale_claim} =
               Registry.succeed_deprovision_job(id, claim_token: "tok-A")

      # The barkpark still exists (the teardown was fenced).
      assert Repo.get(Barkpark, bp_id)

      assert {:ok, :deleted} = Registry.succeed_deprovision_job(id, claim_token: "tok-B")
      refute Repo.get(Barkpark, bp_id)
    end

    test "token-LESS calls still behave exactly as today (Stage 1 compat)" do
      {_user, team} = user_with_team()

      s = stale_reclaimed_job(team)
      assert {:ok, done} = Registry.succeed_job(s, "203.0.113.9")
      assert done.status == "succeeded"

      f = stale_reclaimed_job(team)
      assert {:ok, failed} = Registry.fail_job(f, "x")
      assert failed.status == "failed"

      r = stale_reclaimed_job(team)
      assert {:ok, released} = Registry.release_job(r)
      assert released.status == "pending"
    end

    test "an already-succeeded job re-POSTed by its own (now-stale) worker stays 200" do
      {_user, team} = user_with_team()
      id = stale_reclaimed_job(team)

      # B commits it live.
      assert {:ok, _} = Registry.succeed_job(id, "203.0.113.5", claim_token: "tok-B")

      # Stale A re-POSTs succeed on the already-succeeded job — the idempotent
      # terminal short-circuit runs BEFORE the token check, so this is a 200, NOT
      # a fence. A dropped response must never make a worker tear down a live box.
      assert {:ok, done} = Registry.succeed_job(id, "203.0.113.5", claim_token: "tok-A")
      assert done.status == "succeeded"
    end

    test "HTTP: a stale-token succeed maps to 409 {stale_claim}" do
      {_user, team} = user_with_team()
      id = stale_reclaimed_job(team)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{id}/succeed",
          %{ip: "203.0.113.7", claim_token: "tok-A"},
          @worker_token
        )

      assert conn.status == 409
      assert json_body(conn) == %{"error" => "stale_claim"}
    end
  end

  # wave 13 S2. A provision failure is a REMOTE capture — ssh stderr, a provider
  # body — so it can carry a credential the control plane never chose to print.
  # Reading it takes nothing but team membership: GET /v1/barkparks is
  # require_user_or_pat + require_ability("read"), no platform-admin gate on the
  # path. These drive that exact read as a plain authenticated NON-admin user.
  describe "GET /v1/barkparks — a remote failure capture is scrubbed before a person reads it" do
    @secret "sk-live-9aB3xQ7zLmNpR4tV6wY2"
    @capture "ssh: remote said Authorization: Bearer sk-live-9aB3xQ7zLmNpR4tV6wY2"

    defp row_for(user, bp) do
      {:ok, user_token} = Accounts.create_user_session_token(user)
      conn = call(:get, "/v1/barkparks", nil, user_token)
      assert conn.status == 200
      Enum.find(json_body(conn)["barkparks"], &(&1["id"] == bp.id))
    end

    test "provision_error is scrubbed, and the DB row keeps the raw bytes" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, @capture)

      row = row_for(user, bp)

      refute row["provision_error"] =~ @secret
      assert row["provision_error"] == "ssh: remote said Authorization: Bearer [redacted]"

      # The boundary scrubs; the store does not. Ops recovery is via the DB and
      # the logs, so the raw bytes must still be there.
      assert Repo.get(ProvisionJob, job.id).error == @capture
    end

    test "provision_steps[].detail is scrubbed, and the DB row keeps the raw bytes" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      _ =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/step",
          %{step: "create", status: "failed", detail: @capture},
          @worker_token
        )

      row = row_for(user, bp)

      assert [%{"detail" => detail}] = row["provision_steps"]
      refute detail =~ @secret
      assert detail == "ssh: remote said Authorization: Bearer [redacted]"

      assert [%{"detail" => @capture}] = Repo.get(ProvisionJob, job.id).steps
    end

    test "provision_console[].line is scrubbed, and the DB row keeps the raw bytes" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      _ =
        call(
          :post,
          "/v1/internal/provision-jobs/#{job.id}/console",
          %{line: @capture},
          @worker_token
        )

      row = row_for(user, bp)

      assert [%{"line" => line}] = row["provision_console"]
      refute line =~ @secret
      assert line == "ssh: remote said Authorization: Bearer [redacted]"

      assert [%{"line" => @capture}] = Repo.get(ProvisionJob, job.id).console
    end

    test "a git SHA in the same capture survives the round trip verbatim" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, _} =
        Registry.fail_job(job.id, "build of 0f28d541e9a1b2c3d4e5f60718293a4b5c6d7e8f failed")

      assert row_for(user, bp)["provision_error"] ==
               "build of 0f28d541e9a1b2c3d4e5f60718293a4b5c6d7e8f failed"
    end
  end

  # ── cch-w33-s3: the disclosure reaches the browser, ON THE WIRE ─────────────
  #
  # The whole design of this slice rests on one claim: `truncated_from` and
  # `dropped_before` are EXTRA KEYS on a schemaless jsonb console entry, so they
  # need NO migration and NO serializer change. That claim is only worth
  # anything if it is proved end-to-end rather than asserted — both serializer
  # folds (`scrub_entry/2`, `caption_entry/3`) Map.put back only the keys they
  # fetched, and a fold that rebuilt the entry instead would drop these silently
  # while every context-level test above stayed green.
  describe "cch-w33-s3: console disclosure survives the builder POST → user GET" do
    defp wire_deployment(team) do
      bp = barkpark_fixture(team)
      n = System.unique_integer([:positive])
      {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
      {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
      {site, d}
    end

    defp console_over_the_wire(user, site, dep_id) do
      {:ok, user_token} = Accounts.create_user_session_token(user)
      conn = call(:get, "/v1/sites/#{site.id}/deployments", nil, user_token)
      assert conn.status == 200

      row = Enum.find(json_body(conn)["deployments"], &(&1["id"] == dep_id))
      assert row, "the deployment must be on the user-authed deployments page"
      row["console"]
    end

    test "truncated_from reaches a user-authed GET unchanged (no migration, no serializer change)" do
      {user, team} = user_with_team()
      {site, d} = wire_deployment(team)

      # As the BUILDER does it: the real route, with the real credential — which
      # since jpf-w1-builder-identity is the hosting box's own agent token, not
      # the shared fleet worker token.
      {:ok, builder_token, _} = Registry.mint_agent_token(site.barkpark_id, "report")

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{d.id}/console",
          %{line: String.duplicate("x", 5_000)},
          builder_token
        )

      assert conn.status == 200

      assert [%{"line" => line, "truncated_from" => 5_000}] =
               console_over_the_wire(user, site, d.id)

      assert String.length(line) == 2_000
    end

    test "dropped_before reaches the same GET on the oldest surviving entry" do
      {user, team} = user_with_team()
      {site, d} = wire_deployment(team)

      for i <- 1..305 do
        {:ok, _} = Registry.append_deployment_console(d.id, "line #{i}")
      end

      console = console_over_the_wire(user, site, d.id)

      assert length(console) == 300
      assert List.first(console)["line"] == "line 6"
      assert List.first(console)["dropped_before"] == 5
      refute Map.has_key?(List.last(console), "dropped_before")
    end
  end

  # ── dr-w4-s4: the fleet list carries HOST PRESSURE ─────────────────────────
  #
  # Until this slice `barkpark_json/3` carried ~30 fields and ZERO vitals, so a
  # box at 100% cpu and load1 5.57 was indistinguishable, on the wire, from an
  # idle one. These drive the REAL agent route (POST /v1/agent/report) so the
  # payload under test is the bytes the agent actually stores — never a
  # hand-built map with keys deleted, which would prove nothing about the shapes
  # in the field.
  describe "GET /v1/barkparks — host pressure rides the fleet row" do
    # The report body an agent that PREDATES the vitals beat sends: disk + pg +
    # backup + checks, and no cpu / mem / load1 / swap / beam key at all. This is
    # five of six boxes in the field today.
    defp pre_vitals_report do
      %{
        "agent_status" => "online",
        "version" => "0.1.0",
        "git_commit" => "abc123def",
        "dirty_tree" => false,
        "health_status" => "up",
        "disk_used_percent" => 41,
        "pg_size_bytes" => 123_456_789,
        "backup_ok" => true,
        "backup_detail" => "fresh",
        "health_checks" => []
      }
    end

    defp beat(bp, payload) do
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")
      conn = call(:post, "/v1/agent/report", payload, agent_token)
      assert conn.status == 200
      :ok
    end

    defp pressure_for(user, bp) do
      {:ok, user_token} = Accounts.create_user_session_token(user)
      conn = call(:get, "/v1/barkparks", nil, user_token)
      assert conn.status == 200
      row = Enum.find(json_body(conn)["barkparks"], &(&1["id"] == bp.id))
      assert row, "the barkpark must be on its own team's fleet page"
      row["pressure"]
    end

    test "a struggling box carries its vitals — cpu, load, swap and the BEAM's own footprint" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      :ok =
        beat(
          bp,
          Map.merge(pre_vitals_report(), %{
            "cpu_percent" => 100,
            "cpu_cores" => 2,
            "mem_used_percent" => 58,
            "load1" => 5.57,
            "swap_used_percent" => 99,
            "swap_total_bytes" => 2_147_483_648,
            "beam_pss_bytes" => 900_000_000,
            "beam_swap_bytes" => 1_900_000_000
          })
        )

      pressure = pressure_for(user, bp)

      assert pressure["cpu_percent"] == 100
      assert pressure["mem_used_percent"] == 58
      assert pressure["load1"] == 5.57
      # The fence's DENOMINATOR (D52): load1 5.57 on 2 cores is 2.79x — strained.
      # The same 5.57 on an 8-core box is 0.70x — idle. Without cores on the row
      # the consumer cannot tell those apart, and a hardcoded 2 goes silently
      # wrong on the first 4-core box.
      assert pressure["cpu_cores"] == 2
      assert pressure["disk_used_percent"] == 41
      # The vital `mem_used_percent` HIDES: MemAvailable clears the floor
      # precisely because the BEAM has been paged out, so a box reporting a
      # comfortable 58% memory is at 99% swap. The row has to carry both.
      assert pressure["swap_used_percent"] == 99
      assert pressure["swap_total_bytes"] == 2_147_483_648
      assert pressure["beam_pss_bytes"] == 900_000_000
      assert pressure["beam_swap_bytes"] == 1_900_000_000
      assert is_binary(pressure["reported_at"])
    end

    # THE 2026-08-06 GUERRILLA RUNAWAY. Every vital above is an AGGREGATE: they
    # said the box was at load 6.3 on 2 cores with /api/schemas flapping
    # 200/500/500, and not one of them could say that 66.3% of a core had gone to
    # ONE orphaned `journalctl -u bp-site-build-* --since -14d --no-pager` for
    # 2h46m. A human found it because a `bp` write failed. These two tests are the
    # detector's two arms, and the second is the one that makes the first mean
    # something.
    test "the runaway rides the row — pid, elapsed, CPU share and the argv to kill" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      :ok =
        beat(
          bp,
          Map.put(pre_vitals_report(), "runaway_procs", [
            %{
              "pid" => 3_369_344,
              "elapsed_s" => 10_001,
              "cpu_percent" => 66.3,
              "command" => "journalctl -u bp-site-build-* --since -14d --no-pager"
            }
          ])
        )

      assert [row] = pressure_for(user, bp)["runaway_procs"]
      assert row["pid"] == 3_369_344
      # 02:46:41, as SECONDS: a number needs no format parser.
      assert row["elapsed_s"] == 10_001
      assert row["cpu_percent"] == 66.3
      # The field that turns a statistic into an action. An operator kills
      # `journalctl -u bp-site-build-*`; nobody kills "pid 3369344".
      assert row["command"] == "journalctl -u bp-site-build-* --since -14d --no-pager"
    end

    test "a QUIET box reports [] and an UNMEASURED box reports nil — never the same" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      # The box after the kill: the probe RAN and found nothing.
      :ok = beat(bp, Map.put(pre_vitals_report(), "runaway_procs", []))
      assert pressure_for(user, bp)["runaway_procs"] == []

      # An agent that predates the probe, or a box with no `ps`: nobody looked.
      # Rendering this as [] would say "nothing to see" about a box nobody
      # examined — which is precisely the silence of 2026-08-06.
      :ok = beat(bp, pre_vitals_report())
      pressure = pressure_for(user, bp)
      assert Map.has_key?(pressure, "runaway_procs")
      assert pressure["runaway_procs"] == nil

      # And garbage is unmeasured too, never a half-rendered accusation.
      :ok = beat(bp, Map.put(pre_vitals_report(), "runaway_procs", "lots"))
      assert pressure_for(user, bp)["runaway_procs"] == nil
    end

    test "a runaway row missing any of its four fields is DROPPED, not half-rendered" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      good = %{
        "pid" => 3_369_344,
        "elapsed_s" => 10_001,
        "cpu_percent" => 66.3,
        "command" => "journalctl -u bp-site-build-*"
      }

      :ok =
        beat(
          bp,
          Map.put(pre_vitals_report(), "runaway_procs", [
            # No command: a number an operator cannot act on.
            Map.delete(good, "command"),
            # No elapsed: an accusation with no evidence.
            Map.delete(good, "elapsed_s"),
            # Empty command: the agent's "not attributable", never a guess.
            Map.put(good, "command", ""),
            good
          ])
        )

      # Exactly ONE survivor — and it is the complete row, so the three zeros
      # above are the shaper refusing and not the whole key failing to land.
      assert [survivor] = pressure_for(user, bp)["runaway_procs"]
      assert survivor["pid"] == 3_369_344
      assert survivor["command"] == "journalctl -u bp-site-build-*"
    end

    # dr-bl-w5-failed-slot-unit-is-invisible. Measured 2026-08-06 on guerrilla:
    # `barkpark-slot@blue` sat in `failed` (an 8m30s stop-sigterm timeout ending
    # in SIGKILL) and the fact was known ONLY to ssh. The row carried thirty-odd
    # fields and zero unit state, so every operator surface read `ok` — right by
    # accident, because green was serving, and structurally unable to be wrong.
    test "the blue/green UNIT STATE rides the row, systemd's own properties verbatim" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      :ok =
        beat(
          bp,
          Map.put(pre_vitals_report(), "slot_units", [
            %{
              "unit" => "barkpark-slot@blue.service",
              "active_state" => "failed",
              "sub_state" => "failed",
              "result" => "timeout",
              "main_pid" => 0,
              "exec_main_status" => 1,
              "state_since" => "Wed 2026-08-06 14:22:49 UTC"
            },
            %{
              "unit" => "barkpark-slot@green.service",
              "active_state" => "active",
              "sub_state" => "running",
              "result" => "success",
              "main_pid" => 1_604_014,
              "exec_main_status" => 0,
              "state_since" => "Tue 2026-09-01 21:37:14 UTC"
            }
          ])
        )

      assert [blue, green] = pressure_for(user, bp)["slot_units"]
      assert blue["unit"] == "barkpark-slot@blue.service"
      assert blue["active_state"] == "failed"
      assert blue["sub_state"] == "failed"
      # Result and exec_main_status are relayed as a PAIR. `exit-code` alone
      # reads a deliberate SIGTERM retire (status 143) as a crash — measured
      # 2026-09-01 on barkpark-site@search__b, and the reason PR #14863 exists.
      assert blue["result"] == "timeout"
      assert blue["exec_main_status"] == 1
      # A MEASURED pid 0 — the unit claims a state with no main process — is a
      # real fact and survives as itself, never collapsed into nil.
      assert blue["main_pid"] == 0
      # systemd's own timestamp string, VERBATIM. A reformat here would be a
      # second source of truth for a fact systemd already states.
      assert blue["state_since"] == "Wed 2026-08-06 14:22:49 UTC"
      assert green["active_state"] == "active"
      assert green["main_pid"] == 1_604_014
    end

    test "an INTACT pair reports [] and an UNMEASURED box reports nil — never the same" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      # The probe RAN and had nothing to report.
      :ok = beat(bp, Map.put(pre_vitals_report(), "slot_units", []))
      assert pressure_for(user, bp)["slot_units"] == []

      # No systemd, no dbus, or an agent that predates the probe: nobody looked.
      # Rendering this as [] would say "the deploy pair is fine" about a box
      # nothing examined — the exact silence this field exists to break.
      :ok = beat(bp, pre_vitals_report())
      pressure = pressure_for(user, bp)
      assert Map.has_key?(pressure, "slot_units")
      assert pressure["slot_units"] == nil
      assert pressure["slot_units_truncated"] == nil

      # Garbage is unmeasured too.
      :ok = beat(bp, Map.put(pre_vitals_report(), "slot_units", "all fine"))
      assert pressure_for(user, bp)["slot_units"] == nil

      # And the agent's -1 sentinel on the truncation count renders nil, while a
      # measured 0 ("the cap hid nothing") survives as 0 — so a short list can
      # never pass for a whole one.
      :ok = beat(bp, Map.put(pre_vitals_report(), "slot_units_truncated", -1))
      assert pressure_for(user, bp)["slot_units_truncated"] == nil
      :ok = beat(bp, Map.put(pre_vitals_report(), "slot_units_truncated", 0))
      assert pressure_for(user, bp)["slot_units_truncated"] == 0
    end

    test "a unit row without its three NAMING fields is dropped; the optional ones render nil" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      :ok =
        beat(
          bp,
          Map.put(pre_vitals_report(), "slot_units", [
            # No unit name: a state nobody can attribute to anything.
            %{"active_state" => "failed", "sub_state" => "failed"},
            # No active_state: the axis the whole field exists to carry.
            %{"unit" => "barkpark-slot@blue.service", "sub_state" => "failed"},
            # Empty unit: the agent's "not attributable", never a guess.
            %{"unit" => "", "active_state" => "failed", "sub_state" => "failed"},
            # Complete NAMING fields, unreadable optionals: this row SURVIVES.
            # Dropping it over an unparseable pid would delete the `failed` that
            # is the point of the row.
            %{
              "unit" => "barkpark-slot@green.service",
              "active_state" => "failed",
              "sub_state" => "failed",
              "main_pid" => -1,
              "exec_main_status" => -1
            }
          ])
        )

      assert [survivor] = pressure_for(user, bp)["slot_units"]
      assert survivor["unit"] == "barkpark-slot@green.service"
      assert survivor["active_state"] == "failed"
      assert survivor["result"] == nil
      assert survivor["main_pid"] == nil
      assert survivor["exec_main_status"] == nil
      assert survivor["state_since"] == nil
    end

    test "the LATEST beat wins — a newer report replaces an older one on the row" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      :ok = beat(bp, Map.put(pre_vitals_report(), "cpu_percent", 3))
      :ok = beat(bp, Map.put(pre_vitals_report(), "cpu_percent", 97))

      assert pressure_for(user, bp)["cpu_percent"] == 97
    end

    test "a pre-vitals agent renders UNMETERED — every absent signal is nil, never 0" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      # A REAL stored beat, exactly as a pre-#9784 agent sends it.
      :ok = beat(bp, pre_vitals_report())

      # The payload really is missing the keys — if the agent shape ever starts
      # carrying them this test must be re-cut, not silently pass.
      assert [%{type: "health", payload: payload} | _] = Registry.recent_events(bp, 5)
      refute Map.has_key?(payload, "cpu_percent")
      refute Map.has_key?(payload, "swap_used_percent")

      pressure = pressure_for(user, bp)

      # What it DID measure still arrives.
      assert pressure["disk_used_percent"] == 41

      # What it did not measure reads "we did not measure" — a 0 here would be a
      # perfectly idle machine, which is a lie about a box nobody has metered.
      for key <- ~w(cpu_percent cpu_cores mem_used_percent load1 swap_used_percent
                    swap_total_bytes beam_pss_bytes beam_swap_bytes) do
        assert Map.has_key?(pressure, key), "the pressure block must always carry #{key}"

        assert pressure[key] == nil,
               "#{key} must be unmetered (nil), got #{inspect(pressure[key])}"
      end
    end

    test "the agent's -1 'probe not wired' sentinel is unmetered too, never a fake reading" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      :ok =
        beat(
          bp,
          Map.merge(pre_vitals_report(), %{
            "cpu_percent" => -1,
            "mem_used_percent" => -1,
            "load1" => -1,
            "swap_used_percent" => -1,
            "swap_total_bytes" => -1,
            "beam_pss_bytes" => -1,
            "beam_swap_bytes" => -1
          })
        )

      pressure = pressure_for(user, bp)

      for key <- ~w(cpu_percent mem_used_percent load1 swap_used_percent
                    swap_total_bytes beam_pss_bytes beam_swap_bytes) do
        assert pressure[key] == nil, "the -1 sentinel must render unmetered, got #{key}"
      end

      # A swapless box is a MEASURED zero and must survive as one — the sentinel
      # guard is `< 0`, not `falsy`.
      :ok =
        beat(
          bp,
          Map.merge(pre_vitals_report(), %{"swap_used_percent" => 0, "swap_total_bytes" => 0})
        )

      swapless = pressure_for(user, bp)
      assert swapless["swap_used_percent"] == 0
      assert swapless["swap_total_bytes"] == 0
    end

    # THE DENOMINATOR AND ITS LATENCY (charter D103). An error RATE without the
    # request volume it came out of cannot be read: the same 5xx/s is a 7x range
    # of severity across the traffic levels actually observed on the fleet. Both
    # values are already on the wire (the agent posts them on every beat) and
    # already stored in the raw beat payload — this asserts they reach the row.
    test "the request rate and its p95 ride the row — the denominator a share needs" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      :ok =
        beat(
          bp,
          Map.merge(pre_vitals_report(), %{
            "req_per_s" => 1.75,
            "p95_ms" => 32_777,
            "err_5xx_per_s" => 0.22
          })
        )

      pressure = pressure_for(user, bp)

      assert pressure["req_per_s"] == 1.75
      assert pressure["p95_ms"] == 32_777
      # The pairing is the whole point: 0.22 5xx/s against 1.75 req/s is 12.6%
      # of traffic. The same 0.22 against 11 req/s is 2.0%. Only the row that
      # carries both can tell those apart.
      assert pressure["err_5xx_per_s"] == 0.22

      # A genuinely idle box is a MEASURED zero and must survive as one — the
      # guard is `< 0`, not `falsy`, or "serving nothing" collapses into
      # "nobody measured".
      :ok = beat(bp, Map.merge(pre_vitals_report(), %{"req_per_s" => 0.0, "p95_ms" => 0}))

      idle = pressure_for(user, bp)
      assert idle["req_per_s"] == 0.0
      assert idle["p95_ms"] == 0
    end

    test "req_per_s and p95_ms unmetered: the -1 sentinel AND an absent key both read nil" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      # ARM 1 — the sentinel. Three of the five boxes in the field emit -1 here
      # today (probe unwired, or the instance predates the request-stats route).
      # A 0 would make the least-instrumented box read as the fastest and the
      # quietest in the fleet.
      :ok = beat(bp, Map.merge(pre_vitals_report(), %{"req_per_s" => -1, "p95_ms" => -1}))

      sentinel = pressure_for(user, bp)
      assert sentinel["req_per_s"] == nil, "the -1 req/s sentinel must render unmetered"
      assert sentinel["p95_ms"] == nil, "the -1 p95 sentinel must render unmetered"

      # ARM 2 — the key is absent entirely (an agent predating the fields). The
      # key must still be PRESENT on the block so a consumer can destructure,
      # and its value must still be nil.
      :ok = beat(bp, pre_vitals_report())

      assert [%{type: "health", payload: payload} | _] = Registry.recent_events(bp, 5)
      refute Map.has_key?(payload, "req_per_s")
      refute Map.has_key?(payload, "p95_ms")

      absent = pressure_for(user, bp)

      for key <- ~w(req_per_s p95_ms) do
        assert Map.has_key?(absent, key), "the pressure block must always carry #{key}"

        assert absent[key] == nil,
               "#{key} must be unmetered (nil), got #{inspect(absent[key])}"
      end
    end

    test "a box that has NEVER beaten renders the all-unmetered block (no key, no zeros)" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      pressure = pressure_for(user, bp)

      assert pressure["reported_at"] == nil

      for key <- ~w(cpu_percent cpu_cores mem_used_percent load1 disk_used_percent
                    swap_used_percent swap_total_bytes beam_pss_bytes beam_swap_bytes) do
        assert Map.has_key?(pressure, key)
        assert pressure[key] == nil
      end
    end

    # ARITY-1 CALL SITE. POST /v1/fleet/supports serializes a row that BY
    # CONSTRUCTION has never beaten (it was created microseconds ago), which is
    # exactly why pressure is a PARAMETER: a lookup inside the serializer would
    # put a per-row query on this WRITE path for a guaranteed miss.
    test "POST /v1/fleet/supports (arity-1 serializer) renders unmetered, not zeros" do
      {user, team} = user_with_team()
      main = barkpark_fixture(team)
      {:ok, user_token} = Accounts.create_user_session_token(user)

      conn =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Support box", parent_id: main.id, host: "10.0.0.9"},
          user_token,
          team.id
        )

      assert conn.status == 201
      pressure = json_body(conn)["barkpark"]["pressure"]

      assert pressure["reported_at"] == nil

      for key <- ~w(cpu_percent cpu_cores mem_used_percent load1 disk_used_percent
                    swap_used_percent swap_total_bytes beam_pss_bytes beam_swap_bytes) do
        assert pressure[key] == nil
      end
    end

    # THE N+1 GUARD. `Registry.recent_events/2` is single-barkpark, so mapping it
    # over the page is a query per row — the same N+1 this domain already found
    # and fixed once (Usage.latest_samples_by_barkpark/1). One DISTINCT ON query
    # serves the whole page; this asserts the count, so a future "just look it up
    # per row" refactor fails here instead of on a production page.
    test "N boxes cost exactly ONE agent_events query for the whole page" do
      {user, team} = user_with_team()

      for i <- 1..4 do
        bp = barkpark_fixture(team, %{slug: "pressure-n1-#{i}"})
        :ok = beat(bp, Map.put(pre_vitals_report(), "cpu_percent", 10 * i))
      end

      {:ok, user_token} = Accounts.create_user_session_token(user)

      queries =
        capture_repo_sql(fn ->
          conn = call(:get, "/v1/barkparks", nil, user_token)
          assert conn.status == 200
          assert length(json_body(conn)["barkparks"]) == 4
        end)

      agent_event_queries = Enum.filter(queries, &String.contains?(&1, ~s(FROM "agent_events")))

      assert length(agent_event_queries) == 1,
             """
             The fleet page must read agent_events ONCE for the whole page.
             Ran #{length(agent_event_queries)} for 4 boxes:

             #{Enum.join(agent_event_queries, "\n\n")}
             """

      assert hd(agent_event_queries) =~ "DISTINCT ON",
             "the one query must be the DISTINCT ON latest-per-box read: #{hd(agent_event_queries)}"
    end

    # Capture the SQL this TEST PROCESS runs inside `fun`. The `self() == test`
    # guard is load-bearing: telemetry handlers are global and the suite is
    # async, so without it a concurrent test's queries would be counted here.
    defp capture_repo_sql(fun) do
      test = self()
      id = {:dr_w4_s4_pressure_sql, make_ref()}

      :telemetry.attach(
        id,
        [:barkpark_cloud, :repo, :query],
        fn _event, _measure, meta, _cfg ->
          if self() == test, do: send(test, {:dr_w4_s4_sql, meta.query})
        end,
        nil
      )

      try do
        fun.()
      after
        :telemetry.detach(id)
      end

      drain_repo_sql([])
    end

    defp drain_repo_sql(acc) do
      receive do
        {:dr_w4_s4_sql, sql} -> drain_repo_sql([sql | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end
end
