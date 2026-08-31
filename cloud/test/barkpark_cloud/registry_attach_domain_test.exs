defmodule BarkparkCloud.RegistryAttachDomainTest do
  @moduledoc """
  Instance custom domains — the Registry half. Proves:

    * `set_custom_host/2` — the platform format gate (exactly ONE label under
      the platform zone), the V2 external-FQDN gate (any well-formed lowercase
      customer FQDN; the apex / bare-IP shapes / shell-hostile junk all die at
      validation), normalization (lowercase / trim / trailing dot), and the
      cross-surface taken check: a Site domain, another barkpark's custom_host
      (exact or, cross-team, as a parent of the new host), or ANOTHER row's
      provisioning FQDN each → `{:error, :taken}` (re-setting your OWN host,
      custom_host or url, is an idempotent no-op, not a conflict)
    * the attach_domain job queue — enqueue (one active per barkpark via the
      partial index), kind-filtered claim, succeed/fail with the
      deprovision-grade idempotency + claim-token fencing
    * the TLS ask-gate — `domain_registered?/1` approves an attached host with
      the same normalization the changeset stores
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}
  alias BarkparkCloud.Usage.Sample

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

  # A silence-only "ghost": url squats `host`, agent never phoned home, row is
  # older than the 7-day abandonment window, no jobs. This is the shape the
  # carve-out used to release on its own.
  defp ghost_row(team, host) do
    barkpark_fixture(team)
    |> Ecto.Changeset.change(
      url: "https://" <> host,
      inserted_at: DateTime.add(DateTime.utc_now(), -30, :day)
    )
    |> Repo.update!()
  end

  defp with_admin_credential(bp) do
    bp |> Ecto.Changeset.change(admin_token_encrypted: "ciphertext") |> Repo.update!()
  end

  defp with_usage_sample(bp, measured_at) do
    Repo.insert!(%Sample{
      barkpark_id: bp.id,
      envelope: %{"meters" => %{}},
      measured_at: measured_at
    })
  end

  defp with_active_subscription(team) do
    Repo.insert!(%Subscription{team_id: team.id, plan: "supporter", status: "active"})
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

    test "an ABANDONED row's provisioning FQDN stops holding the claim (ghost reclamation)" do
      # A provisioning ghost: url squats the name, agent NEVER phoned home
      # (last_seen_at nil), older than the abandonment window, no jobs. Seen
      # live 2026-07-08 — a pre-registry-era attempt held a name forever with
      # no owner able to release it.
      ghost = barkpark_fixture(team_fixture())

      {:ok, ghost} =
        ghost
        |> Ecto.Changeset.change(
          url: "https://reclaimed.barkpark.cloud",
          inserted_at: DateTime.add(DateTime.utc_now(), -8, :day)
        )
        |> BarkparkCloud.Repo.update()

      assert ghost.last_seen_at == nil

      claimer = barkpark_fixture(team_fixture())

      assert {:ok, %Barkpark{custom_host: "reclaimed.barkpark.cloud"}} =
               Registry.set_custom_host(claimer, "reclaimed.barkpark.cloud")
    end

    test "a LIVE row's provisioning FQDN keeps the claim even when old" do
      live = barkpark_fixture(team_fixture())

      {:ok, _live} =
        live
        |> Ecto.Changeset.change(
          url: "https://occupied.barkpark.cloud",
          inserted_at: DateTime.add(DateTime.utc_now(), -30, :day),
          last_seen_at: DateTime.utc_now()
        )
        |> BarkparkCloud.Repo.update()

      claimer = barkpark_fixture(team_fixture())

      assert {:error, :taken} = Registry.set_custom_host(claimer, "occupied.barkpark.cloud")
    end

    test "the LIVE shape (silent, old, no job, credential + sample + subscription) is NOT releasable" do
      # The exact shape measured on live data 2026-08-08: last_seen_at NULL,
      # inserted_at far past the abandonment cutoff, no active job — yet the
      # platform still holds a decryptable admin token for it, sampled it 5
      # minutes ago, and the owning team is on an ACTIVE subscription. The
      # silence-only carve-out released this name; three AND-legs now refuse.
      team = team_fixture()
      ghost = ghost_row(team, "still-dialled.barkpark.cloud")
      with_admin_credential(ghost)
      with_usage_sample(ghost, DateTime.add(DateTime.utc_now(), -5, :minute))
      with_active_subscription(team)

      assert {:held, :admin_credential, why} =
               Registry.provisioning_fqdn_claim("still-dialled.barkpark.cloud")

      assert why =~ "decryptable admin token"

      claimer = barkpark_fixture(team_fixture())

      assert {:error, :taken} = Registry.set_custom_host(claimer, "still-dialled.barkpark.cloud")
    end

    test "MUTATION per leg: dropping one leg at a time shows exactly which leg still refuses" do
      team = team_fixture()
      ghost = ghost_row(team, "mutate.barkpark.cloud")
      ghost = with_admin_credential(ghost)
      with_usage_sample(ghost, DateTime.add(DateTime.utc_now(), -5, :minute))
      with_active_subscription(team)

      host = "mutate.barkpark.cloud"

      # All three legs present → the credential leg (the hard block) refuses.
      assert {:held, :admin_credential, _} = Registry.provisioning_fqdn_claim(host)

      # Drop the credential → the recent-sample leg still refuses.
      ghost |> Ecto.Changeset.change(admin_token_encrypted: nil) |> Repo.update!()
      assert {:held, :recent_usage_sample, why} = Registry.provisioning_fqdn_claim(host)
      assert why =~ "sampled by the usage worker within the last 24h"

      # Drop the sample too → the billing leg still refuses.
      Repo.delete_all(from(s in "usage_samples"))
      assert {:held, :active_subscription, why} = Registry.provisioning_fqdn_claim(host)
      assert why =~ "live subscription"

      # Drop the subscription too → NOW it is a genuine ghost and releases.
      Repo.delete_all(from(s in Subscription, where: s.team_id == ^team.id))
      assert :free = Registry.provisioning_fqdn_claim(host)

      claimer = barkpark_fixture(team_fixture())
      assert {:ok, %Barkpark{custom_host: ^host}} = Registry.set_custom_host(claimer, host)
    end

    # The two boundary negatives that used to sit here (a usage sample older
    # than the window, a cancelled subscription) now live in the `:free` case of
    # registry_name_claim_census_test.exs, alongside the per-leg census that
    # pins the window and the live-status list themselves. The two tests KEPT
    # above earn their place: `the LIVE shape …` is the end-to-end path
    # (claim → set_custom_host → {:error, :taken}), and `MUTATION per leg …` is
    # the priority CASCADE across legs, which no single-leg case can express.

    test "a young silent row keeps the claim (still provisioning, not yet abandoned)" do
      young = barkpark_fixture(team_fixture())

      {:ok, _young} =
        young
        |> Ecto.Changeset.change(url: "https://fresh.barkpark.cloud")
        |> BarkparkCloud.Repo.update()

      claimer = barkpark_fixture(team_fixture())

      assert {:error, :taken} = Registry.set_custom_host(claimer, "fresh.barkpark.cloud")
    end

    test "platform format gate: anything under the zone but ONE label → {:error, changeset}" do
      bp = barkpark_fixture(team_fixture())

      for bad <- [
            # two labels under the zone — never claimable, we own that DNS
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

    test "V2 external FQDN: a well-formed customer domain persists, ask-gate approves, dns label is nil" do
      bp = barkpark_fixture(team_fixture())

      refute Registry.domain_registered?("barkpark.jarl.no")

      # The SAME normalization as platform hosts: case, whitespace, trailing dot.
      assert {:ok, %Barkpark{custom_host: "barkpark.jarl.no"} = bp} =
               Registry.set_custom_host(bp, "  Barkpark.Jarl.No. ")

      assert Registry.domain_registered?("barkpark.jarl.no")
      assert Registry.domain_registered?("BARKPARK.jarl.no.")

      # No platform DNS halves for an external host — the customer owns DNS.
      assert Barkpark.custom_host_label(bp) == nil
      refute Barkpark.platform_custom_host?(bp.custom_host)
      assert Barkpark.platform_custom_host?("gyldendal.barkpark.cloud")
    end

    test "V2 external format gate: malformed / hostile FQDNs → {:error, changeset}" do
      bp = barkpark_fixture(team_fixture())

      overlong =
        String.duplicate(String.duplicate("a", 63) <> ".", 4) |> String.trim_trailing(".")

      for bad <- [
            # a single label is not a customer FQDN
            "intranet",
            # bare-IP shape (numeric TLD) — never a Caddy vhost
            "203.0.113.9",
            # shell/Caddyfile-hostile junk
            "foo.bar;rm -rf",
            "$(x).evil.com",
            "`x`.evil.com",
            # unicode / uppercase-after-normalization is fine, raw punycode-less unicode is not
            "bärkpark.jarl.no",
            # malformed labels
            "-bad.jarl.no",
            "bad-.jarl.no",
            "a..no",
            "foo_bar.jarl.no",
            "foo bar.jarl.no",
            # over the 63-char label cap / the 253-char FQDN cap
            String.duplicate("a", 64) <> ".jarl.no",
            overlong <> ".no"
          ] do
        assert {:error, %Ecto.Changeset{}} = Registry.set_custom_host(bp, bad),
               "expected #{inspect(bad)} to be rejected"
      end

      assert Registry.get_barkpark(bp.id).custom_host == nil
    end

    test "V2 suffix guard: a host under a DIFFERENT team's custom host → :taken; under your own team's → ok" do
      owner_team = team_fixture()
      owner = barkpark_fixture(owner_team)
      assert {:ok, _} = Registry.set_custom_host(owner, "barkpark.jarl.no")

      # Another team cannot nest under jarl.no's attached host…
      intruder = barkpark_fixture(team_fixture())
      assert {:error, :taken} = Registry.set_custom_host(intruder, "sub.barkpark.jarl.no")

      # …but the SAME team can hang a second instance under its own host.
      sibling = barkpark_fixture(owner_team)
      assert {:ok, _} = Registry.set_custom_host(sibling, "sub2.barkpark.jarl.no")
    end

    test "V2 exact-match taken: another barkpark's external custom_host → :taken" do
      other = barkpark_fixture(team_fixture())
      assert {:ok, _} = Registry.set_custom_host(other, "barkpark.jarl.no")

      bp = barkpark_fixture(team_fixture())
      assert {:error, :taken} = Registry.set_custom_host(bp, "barkpark.jarl.no")
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

    test "taken by ANOTHER barkpark's provisioning FQDN (url) → {:error, :taken}; your OWN url is attachable" do
      # A clean go-live claims gyldendal.barkpark.cloud as its PRIMARY url.
      {:ok, live} = Registry.register_managed_barkpark(team_fixture(), "Gyldendal", "gyldendal")
      assert live.url == "https://" <> @domain

      bp = barkpark_fixture(team_fixture())
      assert {:error, :taken} = Registry.set_custom_host(bp, @domain)

      # But NOT its own: a row attaching the FQDN it already serves shadows
      # nobody, and refusing it would break a legitimate re-attach. Full
      # coverage of the url leg lives in registry_custom_host_test.exs.
      assert {:ok, %Barkpark{custom_host: @domain}} = Registry.set_custom_host(live, @domain)

      # Idempotent: the same self-attach again is still {:ok, …}, not a conflict.
      assert {:ok, %Barkpark{custom_host: @domain}} = Registry.set_custom_host(live, @domain)
    end
  end

  ## The REVERSE direction — the two Site claim doors
  #
  # `custom_host → site domain` has been checked since the guard landed. The
  # reverse — `site domain → custom_host` — was NOT, on EITHER door, so a plain
  # member could hand another team's live hostname to a site they controlled and
  # no route existed to take it back. The describe above asserts only the
  # reverse order, which is exactly why the gap survived every hardening commit.
  #
  # These drive the SAME four surfaces from the Site side, through BOTH doors:
  # attach (`add_site_domain/2`) and CREATE (`create_site/2`, which never calls
  # the attach function and therefore ran no collision test at all).

  describe "add_site_domain/2 — the hostname namespace, from the Site side" do
    test "a hostname held as ANOTHER team's instance custom_host → {:error, :domain_taken}" do
      victim = barkpark_fixture(team_fixture())
      assert {:ok, _} = Registry.set_custom_host(victim, "barkpark.jarl.no")

      grabber_bp = barkpark_fixture(team_fixture())
      {:ok, site} = Registry.create_site(grabber_bp, %{name: "Grab", slug: "grab"})

      assert {:error, :domain_taken} = Registry.add_site_domain(site, "barkpark.jarl.no")

      # The name never left its owner: no site resolves it, so the unauthenticated
      # ask-gate cannot hand the grabber a cert for it.
      assert Registry.domain_owner_site("barkpark.jarl.no") == nil
    end

    test "normalization is shared: a differently-CASED spelling of the same host still collides" do
      victim = barkpark_fixture(team_fixture())
      assert {:ok, _} = Registry.set_custom_host(victim, "barkpark.jarl.no")

      grabber_bp = barkpark_fixture(team_fixture())
      {:ok, site} = Registry.create_site(grabber_bp, %{name: "Grab", slug: "grab-case"})

      assert {:error, :domain_taken} = Registry.add_site_domain(site, "BarkPark.Jarl.No.")
    end

    test "a host UNDER a DIFFERENT team's attached domain → :domain_taken; under your OWN team's → ok" do
      owner_team = team_fixture()
      owner = barkpark_fixture(owner_team)
      assert {:ok, _} = Registry.set_custom_host(owner, "barkpark.jarl.no")

      intruder_bp = barkpark_fixture(team_fixture())
      {:ok, intruder_site} = Registry.create_site(intruder_bp, %{name: "Sub", slug: "sub"})

      assert {:error, :domain_taken} =
               Registry.add_site_domain(intruder_site, "sub.barkpark.jarl.no")

      # The legit edge the suffix rule exists to preserve: the SAME team may hang
      # a site under its own attached domain.
      sibling_bp = barkpark_fixture(owner_team)
      {:ok, sibling_site} = Registry.create_site(sibling_bp, %{name: "Own", slug: "own"})
      assert {:ok, _} = Registry.add_site_domain(sibling_site, "sub2.barkpark.jarl.no")
    end

    test "ANOTHER barkpark's live provisioning FQDN → {:error, :domain_taken}" do
      {:ok, live} = Registry.register_managed_barkpark(team_fixture(), "Gyldendal", "gyldendal")
      assert live.url == "https://" <> @domain

      bp = barkpark_fixture(team_fixture())
      {:ok, site} = Registry.create_site(bp, %{name: "Grab", slug: "grab-url"})

      assert {:error, :domain_taken} = Registry.add_site_domain(site, @domain)
    end

    test "site-vs-site is unchanged, and a released name is claimable again" do
      bp_a = barkpark_fixture(team_fixture())
      {:ok, site_a} = Registry.create_site(bp_a, %{name: "A", slug: "a-rel"})
      bp_b = barkpark_fixture(team_fixture())
      {:ok, site_b} = Registry.create_site(bp_b, %{name: "B", slug: "b-rel"})

      assert {:ok, site_a} = Registry.add_site_domain(site_a, "shared.example.com")
      assert {:error, :domain_taken} = Registry.add_site_domain(site_b, "shared.example.com")

      # Idempotent self re-add is still a no-op, not a conflict.
      assert {:ok, _} = Registry.add_site_domain(site_a, "shared.example.com")

      {:ok, _} = Registry.remove_site_domain(site_a, "shared.example.com")
      assert {:ok, _} = Registry.add_site_domain(site_b, "shared.example.com")
    end
  end

  describe "create_site/2 — the SECOND claim door" do
    test "a `domains` array naming another team's custom_host → {:error, :domain_taken}, no row" do
      victim = barkpark_fixture(team_fixture())
      assert {:ok, _} = Registry.set_custom_host(victim, "barkpark.jarl.no")

      before = Repo.aggregate(BarkparkCloud.Registry.Site, :count)
      grabber_bp = barkpark_fixture(team_fixture())

      assert {:error, :domain_taken} =
               Registry.create_site(grabber_bp, %{
                 name: "Grab",
                 slug: "grab-create",
                 domains: ["barkpark.jarl.no"]
               })

      # The whole create fails closed — a refused claim must not leave a site behind.
      assert Repo.aggregate(BarkparkCloud.Registry.Site, :count) == before
      assert Registry.domain_owner_site("barkpark.jarl.no") == nil
    end

    test "the create door also sees SITE domains (it saw nothing at all before)" do
      bp_a = barkpark_fixture(team_fixture())
      {:ok, site_a} = Registry.create_site(bp_a, %{name: "A", slug: "a-cd"})
      {:ok, _} = Registry.add_site_domain(site_a, "taken.example.com")

      bp_b = barkpark_fixture(team_fixture())

      assert {:error, :domain_taken} =
               Registry.create_site(bp_b, %{
                 name: "B",
                 slug: "b-cd",
                 domains: ["taken.example.com"]
               })
    end

    test "a free hostname still creates normally (the guard refuses claims, not creates)" do
      bp = barkpark_fixture(team_fixture())

      assert {:ok, site} =
               Registry.create_site(bp, %{
                 name: "Fine",
                 slug: "fine-cd",
                 domains: ["FREE.example.com"]
               })

      assert site.domains == ["free.example.com"]
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
