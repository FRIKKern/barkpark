defmodule BarkparkCloud.RegistryAttachDomainTest do
  @moduledoc """
  Instance custom domains — the Registry half. Proves:

    * `set_custom_host/2` — v1 format gate (exactly ONE label under the
      platform zone), normalization (lowercase / trim / trailing dot), and the
      cross-surface taken check: a Site domain, another barkpark's custom_host,
      or a provisioning FQDN each → `{:error, :taken}` (re-setting your OWN
      host is an idempotent no-op, not a conflict)
    * the attach_domain job queue — enqueue (one active per barkpark via the
      partial index), kind-filtered claim, succeed/fail with the
      deprovision-grade idempotency + claim-token fencing
    * the TLS ask-gate — `domain_registered?/1` approves an attached host with
      the same normalization the changeset stores
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}

  @domain "gyldendal.barkpark.cloud"

  ## Fixtures

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  ## set_custom_host/2

  describe "set_custom_host/2" do
    test "valid platform-zone host → persisted, normalized, and TLS-ask-gate approved" do
      bp = barkpark_fixture(team_fixture())

      refute Registry.domain_registered?(@domain)

      # Mixed case + surrounding whitespace + trailing dot all normalize away —
      # the SAME normalization domain_registered?/1 applies on lookup.
      assert {:ok, %Barkpark{custom_host: @domain}} =
               Registry.set_custom_host(bp, "  Gyldendal.Barkpark.Cloud. ")

      assert Registry.get_barkpark(bp.id).custom_host == @domain
      assert Registry.domain_registered?(@domain)
      assert Registry.domain_registered?("GYLDENDAL.barkpark.cloud.")
      refute Registry.domain_registered?("someone-else.barkpark.cloud")
    end

    test "v1 format gate: anything but ONE label under the platform zone → {:error, changeset}" do
      bp = barkpark_fixture(team_fixture())

      for bad <- [
            # foreign zone — arbitrary customer domains are a later wave
            "gyldendal.example.com",
            # two labels under the zone
            "a.b.barkpark.cloud",
            # the bare apex
            "barkpark.cloud",
            # malformed labels
            "-bad.barkpark.cloud",
            "bad-.barkpark.cloud",
            # over the 63-char label cap
            String.duplicate("a", 64) <> ".barkpark.cloud",
            # shell/Caddyfile-hostile junk must die at validation
            "evil;rm -rf /.barkpark.cloud",
            "sub domain.barkpark.cloud",
            ""
          ] do
        assert {:error, %Ecto.Changeset{}} = Registry.set_custom_host(bp, bad),
               "expected #{inspect(bad)} to be rejected"
      end

      assert Registry.get_barkpark(bp.id).custom_host == nil
    end

    test "taken by a Site domain → {:error, :taken}" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      other = barkpark_fixture(team)

      {:ok, site} = Registry.create_site(other, %{name: "Docs", slug: "docs"})
      {:ok, _} = Registry.add_site_domain(site, @domain)

      assert {:error, :taken} = Registry.set_custom_host(bp, @domain)
    end

    test "taken by ANOTHER barkpark's custom_host → {:error, :taken}; re-setting your OWN is a no-op" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      other = barkpark_fixture(team_fixture())

      assert {:ok, _} = Registry.set_custom_host(other, @domain)
      assert {:error, :taken} = Registry.set_custom_host(bp, @domain)

      # Idempotent self re-attach: the same host on the same row is not a conflict.
      assert {:ok, %Barkpark{custom_host: @domain}} = Registry.set_custom_host(other, @domain)
    end

    test "taken by a provisioning FQDN (any barkpark's url) → {:error, :taken}" do
      # A clean go-live claims gyldendal.barkpark.cloud as its PRIMARY url.
      {:ok, live} = Registry.register_managed_barkpark(team_fixture(), "Gyldendal", "gyldendal")
      assert live.url == "https://" <> @domain

      bp = barkpark_fixture(team_fixture())
      assert {:error, :taken} = Registry.set_custom_host(bp, @domain)

      # Including the instance's OWN primary FQDN — it never needs attaching.
      assert {:error, :taken} = Registry.set_custom_host(live, @domain)
    end
  end

  ## The attach_domain job queue

  describe "enqueue_attach_domain_job/1" do
    test "enqueues a pending attach_domain job; a second active one → :already_attaching" do
      bp = barkpark_fixture(team_fixture())

      assert {:ok, %ProvisionJob{kind: "attach_domain", status: "pending"} = job} =
               Registry.enqueue_attach_domain_job(bp)

      assert job.barkpark_id == bp.id
      assert {:error, :already_attaching} = Registry.enqueue_attach_domain_job(bp)
      assert Repo.aggregate(ProvisionJob, :count, :id) == 1
    end

    test "does not collide with the provision/deprovision kinds (per-kind partial index)" do
      bp = barkpark_fixture(team_fixture())

      assert {:ok, _} = Registry.enqueue_provision_job(bp)
      assert {:ok, _} = Registry.enqueue_attach_domain_job(bp)
      assert {:error, :already_attaching} = Registry.enqueue_attach_domain_job(bp)
    end

    test "a terminal job never blocks a legitimate re-attach" do
      bp = barkpark_fixture(team_fixture())

      {:ok, job} = Registry.enqueue_attach_domain_job(bp)
      {:ok, _} = Registry.fail_attach_domain_job(job.id, "dns upsert failed")

      assert {:ok, %ProvisionJob{status: "pending"}} = Registry.enqueue_attach_domain_job(bp)
    end
  end

  describe "claim / succeed / fail attach_domain jobs" do
    test "claim is kind-filtered and stamps the claim token; succeed flips the job (custom_host already persisted)" do
      bp = barkpark_fixture(team_fixture())
      {:ok, bp} = Registry.set_custom_host(bp, @domain)

      # A pending PROVISION job must never be grabbed by the attach loop.
      {:ok, _} = Registry.enqueue_provision_job(bp)
      assert Registry.claim_next_attach_domain_job("tok-1") == nil

      {:ok, enqueued} = Registry.enqueue_attach_domain_job(bp)

      assert {%ProvisionJob{} = job, %Barkpark{id: claimed_bp_id}} =
               Registry.claim_next_attach_domain_job("tok-1")

      assert job.id == enqueued.id
      assert job.status == "claimed"
      assert job.claim_token == "tok-1"
      assert job.attempts == 1
      assert claimed_bp_id == bp.id

      # Nothing else claimable on the attach queue.
      assert Registry.claim_next_attach_domain_job("tok-2") == nil

      assert {:ok, %ProvisionJob{status: "succeeded", result_ip: "203.0.113.9"}} =
               Registry.succeed_attach_domain_job(job.id, "203.0.113.9", claim_token: "tok-1")

      # The barkpark row is untouched by succeed — custom_host was persisted at
      # set time and stays.
      assert Registry.get_barkpark(bp.id).custom_host == @domain
    end

    test "succeed is idempotent; a straggler succeed on a FAILED job → :conflict" do
      bp = barkpark_fixture(team_fixture())
      {:ok, job} = Registry.enqueue_attach_domain_job(bp)
      {_claimed, _} = Registry.claim_next_attach_domain_job("tok")

      assert {:ok, _} = Registry.succeed_attach_domain_job(job.id, nil, claim_token: "tok")
      assert {:ok, _} = Registry.succeed_attach_domain_job(job.id, nil, claim_token: "tok")

      {:ok, job2} = Registry.enqueue_attach_domain_job(bp)
      {:ok, _} = Registry.fail_attach_domain_job(job2.id, "ssh unreachable")
      assert {:error, :conflict} = Registry.succeed_attach_domain_job(job2.id)
    end

    test "claim-fence: a stale worker's mismatched claim_token is rejected" do
      bp = barkpark_fixture(team_fixture())
      {:ok, job} = Registry.enqueue_attach_domain_job(bp)
      {_claimed, _} = Registry.claim_next_attach_domain_job("live-token")

      assert {:error, :stale_claim} =
               Registry.succeed_attach_domain_job(job.id, nil, claim_token: "stale-token")

      assert {:error, :stale_claim} =
               Registry.fail_attach_domain_job(job.id, "boom", claim_token: "stale-token")
    end

    test "fail marks the job failed and keeps the persisted custom_host (re-attach is the recovery)" do
      bp = barkpark_fixture(team_fixture())
      {:ok, bp} = Registry.set_custom_host(bp, @domain)
      {:ok, job} = Registry.enqueue_attach_domain_job(bp)

      assert {:ok, %ProvisionJob{status: "failed", error: "dns upsert failed"}} =
               Registry.fail_attach_domain_job(job.id, "dns upsert failed")

      assert Registry.get_barkpark(bp.id).custom_host == @domain
    end
  end
end
