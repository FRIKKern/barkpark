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
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
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
    test "marks the job succeeded with the ip and flips the barkpark to up at that host" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{health_status: "unknown", agent_status: "offline"})
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, %ProvisionJob{} = done} = Registry.succeed_job(job.id, "203.0.113.7")
      assert done.status == "succeeded"
      assert done.result_ip == "203.0.113.7"

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "up"
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
      assert reloaded.health_status == "up"
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
      assert bp_after_first.health_status == "up"
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

      long_error =
        "create \"bp-stopwatch\" failed on all 5 candidate type/locations: " <>
          String.duplicate("- cx23/fsn1: hcloud server create: server limit reached; ", 12)

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
      assert reloaded_bp.health_status == "up"
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

      # Per-probe narration rides the dwb-19 progress channel: the caption lands
      # in place on the in-flight `started` entry, never as a new array entry.
      {:ok, job} =
        Registry.append_provision_step(
          job.id,
          "verify",
          "progress",
          "verify.login: POST /v1/auth/login → 401 (auth stack answered) (63ms)"
        )

      assert [%{"step" => "verify", "status" => "started", "detail" => detail}] = job.steps
      assert detail =~ "verify.login"

      # A red probe appends a terminal failed entry with its evidence.
      {:ok, job} =
        Registry.append_provision_step(job.id, "verify", "failed", "verify.login: 500 — boom")

      assert [_started, %{"step" => "verify", "status" => "failed", "detail" => "verify.login: 500 — boom"}] =
               job.steps
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
    test "worker token + a pending job → 200 {job_id, name, slug, region, server_type}" do
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
      assert body["region"] == Registry.default_region()
      assert body["server_type"] == Registry.default_server_type()

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
    test "worker token + {ip} → 200 ok, job succeeded, barkpark up at ip" do
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
      assert reloaded.health_status == "up"
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
      assert Registry.get_barkpark(bp.id).health_status == "up"
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
end
