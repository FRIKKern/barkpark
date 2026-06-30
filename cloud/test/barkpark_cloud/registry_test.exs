defmodule BarkparkCloud.RegistryTest do
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.{AgentEvent, AgentToken, Barkpark, Provider, ProvisionJob}
  alias BarkparkCloud.Repo

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, barkpark} =
      Registry.register_barkpark(
        team,
        Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"})
      )

    barkpark
  end

  describe "register_barkpark/2 + list_barkparks/1" do
    test "registers a Barkpark scoped to its team" do
      team = team_fixture()

      assert {:ok, %Barkpark{} = bp} =
               Registry.register_barkpark(team, %{
                 name: "Production",
                 slug: "prod",
                 url: "https://prod.example.com",
                 host: "10.0.0.7",
                 mode: "managed"
               })

      assert bp.team_id == team.id
      assert bp.slug == "prod"
      # Status axes default until the agent reports.
      assert bp.health_status == "unknown"
      assert bp.agent_status == "offline"
    end

    test "validates mode / health_status / agent_status against their enums" do
      team = team_fixture()

      assert {:error, changeset} =
               Registry.register_barkpark(team, %{name: "X", slug: "x", mode: "bogus"})

      assert "is invalid" in errors_on(changeset).mode
    end

    test "team A cannot see team B's Barkparks" do
      team_a = team_fixture()
      team_b = team_fixture()

      a1 = barkpark_fixture(team_a, %{slug: "a-one"})
      _b1 = barkpark_fixture(team_b, %{slug: "b-one"})

      list_a = Registry.list_barkparks(team_a)
      assert Enum.map(list_a, & &1.id) == [a1.id]
      # B's barkpark is not in A's list.
      refute Enum.any?(list_a, &(&1.team_id == team_b.id))

      assert [_] = Registry.list_barkparks(team_b)
    end

    test "slug is unique per team, but two teams may share a slug" do
      team_a = team_fixture()
      team_b = team_fixture()

      assert {:ok, _} = Registry.register_barkpark(team_a, %{name: "Prod", slug: "prod"})

      # Same slug, same team → collision.
      assert {:error, changeset} =
               Registry.register_barkpark(team_a, %{name: "Prod 2", slug: "prod"})

      assert "a Barkpark with this slug already exists in this team" in errors_on(changeset).team_id

      # Same slug, DIFFERENT team → fine.
      assert {:ok, _} = Registry.register_barkpark(team_b, %{name: "Prod", slug: "prod"})
    end
  end

  describe "upsert_barkpark/2" do
    test "creates then updates the same (team, slug) row" do
      team = team_fixture()

      assert {:ok, created} =
               Registry.upsert_barkpark(team, %{name: "Prod", slug: "prod", version: "1.0.0"})

      assert {:ok, updated} =
               Registry.upsert_barkpark(team, %{name: "Prod", slug: "prod", version: "1.1.0"})

      # Same row, updated in place — not a second insert.
      assert updated.id == created.id
      assert updated.version == "1.1.0"
      assert [_only_one] = Registry.list_barkparks(team)
    end
  end

  describe "provisioning_subdomain / fqdn / url (globally-unique provisioning identity)" do
    test "subdomain is <slug>-<team_short_id>, suffixed with the team short id" do
      team = team_fixture()
      bp = barkpark_fixture(team, %{slug: "prod"})

      short = Barkpark.team_short_id(team.id)
      assert short == team.id |> String.replace("-", "") |> String.slice(0, 8)
      assert Barkpark.provisioning_subdomain(bp) == "prod-#{short}"
    end

    test "two teams sharing a slug get DISTINCT subdomains (the cross-tenant fix)" do
      team_a = team_fixture()
      team_b = team_fixture()
      a = barkpark_fixture(team_a, %{slug: "prod"})
      b = barkpark_fixture(team_b, %{slug: "prod"})

      assert a.slug == b.slug
      assert Barkpark.provisioning_subdomain(a) != Barkpark.provisioning_subdomain(b)
    end

    test "fqdn and url compose the subdomain with the base domain" do
      team = team_fixture()
      bp = barkpark_fixture(team, %{slug: "blog"})
      sub = Barkpark.provisioning_subdomain(bp)

      assert Barkpark.base_domain() == "barkpark.cloud"
      assert Barkpark.provisioning_fqdn(bp) == "#{sub}.barkpark.cloud"
      assert Barkpark.provisioning_url(bp) == "https://#{sub}.barkpark.cloud"
    end

    test "the customer-facing FQDN equals the provisioned label (no divergence)" do
      team = team_fixture()
      bp = barkpark_fixture(team, %{slug: "shop"})

      # The label sent to the worker (provisioning_subdomain) is exactly the label
      # inside the stored/displayed url — they cannot diverge.
      assert Barkpark.provisioning_url(bp) ==
               "https://#{Barkpark.provisioning_subdomain(bp)}.barkpark.cloud"
    end

    test "label is capped at 63 chars: the slug is truncated, the team short id survives" do
      team = team_fixture()
      long_slug = String.duplicate("a", 80)
      # register_barkpark caps slug at 63, so build the subdomain from a raw pair
      # to exercise the truncation path directly.
      sub = Barkpark.provisioning_subdomain({long_slug, team.id})
      short = Barkpark.team_short_id(team.id)

      assert String.length(sub) <= 63
      # team_short_id always survives intact → global uniqueness preserved.
      assert String.ends_with?(sub, "-" <> short)
      # No trailing hyphen on the (truncated) slug part before the join.
      refute String.contains?(sub, "--")
    end

    test "team_short_id is lowercase 0-9a-f (a valid DNS label charset)" do
      team = team_fixture()
      short = Barkpark.team_short_id(team.id)
      assert short =~ ~r/^[0-9a-f]+$/
    end

    test "an empty slug yields NO leading hyphen (invalid-DNS-label edge)" do
      team = team_fixture()
      short = Barkpark.team_short_id(team.id)

      # An empty (or all-hyphen) slug must not produce "-<short>" — a leading
      # hyphen is an invalid DNS label. The assembled label is trimmed of leading
      # and trailing hyphens, so it collapses to the bare team short id.
      assert Barkpark.provisioning_subdomain({"", team.id}) == short
      assert Barkpark.provisioning_subdomain({"---", team.id}) == short

      refute String.starts_with?(Barkpark.provisioning_subdomain({"", team.id}), "-")
      refute String.starts_with?(Barkpark.provisioning_subdomain({"---", team.id}), "-")
    end
  end

  describe "url global unique constraint (defense in depth)" do
    test "two rows cannot share the same resolved FQDN, even across teams" do
      team_a = team_fixture()
      team_b = team_fixture()
      fqdn = "https://collision.barkpark.cloud"

      assert {:ok, _} =
               Registry.register_barkpark(team_a, %{name: "A", slug: "a", url: fqdn})

      assert {:error, changeset} =
               Registry.register_barkpark(team_b, %{name: "B", slug: "b", url: fqdn})

      assert "is already provisioned" in errors_on(changeset).url
    end

    test "a nil url is allowed for many rows (self-hosted / not-yet-provisioned)" do
      team = team_fixture()
      assert {:ok, _} = Registry.register_barkpark(team, %{name: "X", slug: "x"})
      assert {:ok, _} = Registry.register_barkpark(team, %{name: "Y", slug: "y"})
    end
  end

  describe "upsert_health/2" do
    test "lands an agent health report onto the row" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      seen = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, updated} =
               Registry.upsert_health(bp, %{
                 health_status: "up",
                 agent_status: "online",
                 version: "2.0.0",
                 git_commit: "abc123",
                 last_seen_at: seen
               })

      assert updated.health_status == "up"
      assert updated.agent_status == "online"
      assert updated.version == "2.0.0"
      assert updated.git_commit == "abc123"

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "up"
      assert reloaded.agent_status == "online"
    end

    test "rejects an invalid health_status" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      assert {:error, changeset} = Registry.upsert_health(bp, %{health_status: "exploded"})
      assert "is invalid" in errors_on(changeset).health_status
    end
  end

  describe "record_event/3 + recent_events/2" do
    test "appends events and returns them newest-first" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      assert {:ok, %AgentEvent{}} = Registry.record_event(bp, "health", %{"cpu" => 0.2})
      assert {:ok, _} = Registry.record_event(bp, "backup", %{"size" => 1024})
      assert {:ok, last} = Registry.record_event(bp, "tls", %{"renewed" => true})

      events = Registry.recent_events(bp, 10)
      assert length(events) == 3
      # Newest first.
      assert hd(events).id == last.id
      assert hd(events).type == "tls"
      assert hd(events).payload == %{"renewed" => true}
    end

    test "honors the limit" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      for _ <- 1..5, do: Registry.record_event(bp, "health", %{})

      assert length(Registry.recent_events(bp, 2)) == 2
    end

    test "rejects an unknown event type" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      assert {:error, changeset} = Registry.record_event(bp, "meltdown", %{})
      assert "is invalid" in errors_on(changeset).type
    end
  end

  describe "connect_provider/3 — encrypted at rest" do
    test "stores the token encrypted (stored value != plaintext) yet decrypts back" do
      team = team_fixture()
      plaintext = "hetzner-secret-api-token-xyz"

      assert {:ok, %Provider{} = provider} =
               Registry.connect_provider(team, "hetzner", plaintext, label: "main")

      assert provider.kind == "hetzner"
      assert provider.label == "main"

      # The stored column is NOT the plaintext.
      assert provider.encrypted_token != plaintext
      refute provider.encrypted_token =~ plaintext

      # Reload from the DB and confirm the column on disk is ciphertext too.
      reloaded = Repo.get(Provider, provider.id)
      assert reloaded.encrypted_token != plaintext
      refute reloaded.encrypted_token =~ plaintext

      # …but it round-trips back to the original plaintext.
      assert {:ok, ^plaintext} = Registry.reveal_provider_token(reloaded)
    end

    test "list_providers/1 is team-scoped" do
      team_a = team_fixture()
      team_b = team_fixture()

      {:ok, _} = Registry.connect_provider(team_a, "hetzner", "tok-a")
      {:ok, _} = Registry.connect_provider(team_b, "hetzner", "tok-b")

      assert [pa] = Registry.list_providers(team_a)
      assert {:ok, "tok-a"} = Registry.reveal_provider_token(pa)
      refute Enum.any?(Registry.list_providers(team_a), &(&1.team_id == team_b.id))
    end

    test "rejects an unknown provider kind" do
      team = team_fixture()
      assert {:error, changeset} = Registry.connect_provider(team, "vultr", "tok")
      assert "is invalid" in errors_on(changeset).kind
    end
  end

  describe "agent tokens — mint / verify / revoke / expiry" do
    test "mint returns the plaintext once and stores only the hash" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      assert {:ok, plaintext, %AgentToken{} = token} =
               Registry.mint_agent_token(bp, "report:health")

      assert is_binary(plaintext)
      assert token.scope == "report:health"
      # Only the hash is stored — never the plaintext.
      assert token.token_hash == AgentToken.hash_token(plaintext)
      assert token.token_hash != plaintext

      stored = Repo.get(AgentToken, token.id)
      refute stored.token_hash == plaintext
    end

    test "a freshly minted token verifies to its Barkpark" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      {:ok, plaintext, _token} = Registry.mint_agent_token(bp, "report:health")

      assert %Barkpark{} = verified = Registry.verify_agent_token(plaintext)
      assert verified.id == bp.id
    end

    test "a garbage token does not verify" do
      assert is_nil(Registry.verify_agent_token("not-a-real-token"))
    end

    test "a revoked token no longer verifies" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      {:ok, plaintext, token} = Registry.mint_agent_token(bp, "report:health")
      assert Registry.verify_agent_token(plaintext)

      assert {:ok, revoked} = Registry.revoke_agent_token(token)
      assert revoked.revoked_at
      assert is_nil(Registry.verify_agent_token(plaintext))
    end

    test "revoke by plaintext works too" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      {:ok, plaintext, _token} = Registry.mint_agent_token(bp, "report:health")
      assert {:ok, _} = Registry.revoke_agent_token(plaintext)
      assert is_nil(Registry.verify_agent_token(plaintext))
      assert {:error, :not_found} = Registry.revoke_agent_token("never-minted")
    end

    test "an expired token does not verify" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      {:ok, plaintext, _token} =
        Registry.mint_agent_token(bp, "report:health", expires_at: past)

      assert is_nil(Registry.verify_agent_token(plaintext))
    end

    test "a token with a future expiry still verifies" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      future =
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

      {:ok, plaintext, _token} =
        Registry.mint_agent_token(bp, "report:health", expires_at: future)

      assert %Barkpark{} = Registry.verify_agent_token(plaintext)
    end
  end

  describe "deprovision jobs" do
    defp live_barkpark(team, attrs \\ %{}) do
      barkpark_fixture(team, Enum.into(attrs, %{host: "203.0.113.10", health_status: "up"}))
    end

    test "enqueue_deprovision_job/1 inserts a pending job with kind:deprovision" do
      team = team_fixture()
      bp = live_barkpark(team)

      assert {:ok, %ProvisionJob{} = job} = Registry.enqueue_deprovision_job(bp)
      assert job.kind == "deprovision"
      assert job.status == "pending"
      assert job.barkpark_id == bp.id
    end

    test "enqueue_deprovision_job/1 twice → {:error, :already_deprovisioning}" do
      team = team_fixture()
      bp = live_barkpark(team)

      assert {:ok, _} = Registry.enqueue_deprovision_job(bp)
      assert {:error, :already_deprovisioning} = Registry.enqueue_deprovision_job(bp)
    end

    test "claim_next_deprovision_job claims ONLY deprovision jobs" do
      team = team_fixture()
      prov_bp = barkpark_fixture(team, %{slug: "prov"})
      deprov_bp = live_barkpark(team, %{slug: "deprov"})

      {:ok, _prov} = Registry.enqueue_provision_job(prov_bp)
      {:ok, deprov} = Registry.enqueue_deprovision_job(deprov_bp)

      assert {%ProvisionJob{} = claimed, %Barkpark{} = bp} =
               Registry.claim_next_deprovision_job("ct-d")

      assert claimed.id == deprov.id
      assert claimed.kind == "deprovision"
      assert claimed.status == "claimed"
      assert bp.id == deprov_bp.id
    end

    test "claim_next_job (provision) does NOT take a deprovision job, and vice-versa" do
      team = team_fixture()
      prov_bp = barkpark_fixture(team, %{slug: "prov-only"})
      deprov_bp = live_barkpark(team, %{slug: "deprov-only"})

      {:ok, prov} = Registry.enqueue_provision_job(prov_bp)
      {:ok, deprov} = Registry.enqueue_deprovision_job(deprov_bp)

      # The provision claimer takes the provision job only.
      assert {%ProvisionJob{kind: "provision"} = c1, _} = Registry.claim_next_job("ct-prov")
      assert c1.id == prov.id
      # No provision job left.
      assert Registry.claim_next_job("ct-prov-2") == nil

      # The deprovision claimer takes the deprovision job only.
      assert {%ProvisionJob{kind: "deprovision"} = c2, _} =
               Registry.claim_next_deprovision_job("ct-deprov")

      assert c2.id == deprov.id
      assert Registry.claim_next_deprovision_job("ct-deprov-2") == nil
    end

    test "succeed_deprovision_job deletes the barkpark and cascades its jobs" do
      team = team_fixture()
      bp = live_barkpark(team)
      {:ok, job} = Registry.enqueue_deprovision_job(bp)

      assert {:ok, :deleted} = Registry.succeed_deprovision_job(job.id)
      assert Repo.get(Barkpark, bp.id) == nil
      # The job cascaded away with its barkpark.
      assert Repo.get(ProvisionJob, job.id) == nil
    end

    test "succeed_deprovision_job on an already-gone job → {:ok, :already_gone}" do
      assert {:ok, :already_gone} = Registry.succeed_deprovision_job(Ecto.UUID.generate())
      assert {:ok, :already_gone} = Registry.succeed_deprovision_job("not-a-uuid")
    end

    test "succeed_deprovision_job on a failed job → {:error, :conflict}" do
      team = team_fixture()
      bp = live_barkpark(team)
      {:ok, job} = Registry.enqueue_deprovision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")

      assert {:error, :conflict} = Registry.succeed_deprovision_job(job.id)
      # The barkpark is left intact on a conflict.
      assert %Barkpark{} = Repo.get(Barkpark, bp.id)
    end

    test "latest_provision_status_map ignores deprovision jobs; latest_deprovision_status_map returns them" do
      team = team_fixture()
      bp = live_barkpark(team)

      {:ok, _prov} = Registry.enqueue_provision_job(bp)
      {:ok, _deprov} = Registry.enqueue_deprovision_job(bp)

      pmap = Registry.latest_provision_status_map([bp.id])
      dmap = Registry.latest_deprovision_status_map([bp.id])

      assert %{status: "pending"} = pmap[bp.id]
      assert %{status: "pending"} = dmap[bp.id]

      # And the deprovision map is empty for a barkpark with only a provision job.
      bp2 = barkpark_fixture(team, %{slug: "only-prov"})
      {:ok, _} = Registry.enqueue_provision_job(bp2)
      assert Registry.latest_deprovision_status_map([bp2.id]) == %{}
    end
  end

  describe "active_provision_job?/1" do
    test "true for a pending provision job" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, _job} = Registry.enqueue_provision_job(bp)

      assert Registry.active_provision_job?(bp)
    end

    test "true for a claimed provision job" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, _job} = Registry.enqueue_provision_job(bp)
      assert {%ProvisionJob{status: "claimed"}, _} = Registry.claim_next_job("ct-active")

      assert Registry.active_provision_job?(bp)
    end

    test "false for a succeeded provision job" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.succeed_job(job.id, "203.0.113.50")

      refute Registry.active_provision_job?(bp)
    end

    test "false for a failed provision job" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")

      refute Registry.active_provision_job?(bp)
    end

    test "false when only a deprovision job exists" do
      team = team_fixture()
      bp = live_barkpark(team)
      {:ok, _} = Registry.enqueue_deprovision_job(bp)

      refute Registry.active_provision_job?(bp)
    end

    test "false for a barkpark with no jobs" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      refute Registry.active_provision_job?(bp)
    end
  end

  describe "register_managed_barkpark/3 — clean-first subdomain reservation" do
    test "assigns the CLEAN <slug>.barkpark.cloud when free and not reserved" do
      team = team_fixture()

      assert {:ok, %Barkpark{} = bp} =
               Registry.register_managed_barkpark(team, "Gyldendal", "gyldendal")

      assert bp.url == "https://gyldendal.barkpark.cloud"
      assert Barkpark.subdomain_from_url(bp) == "gyldendal"
    end

    test "falls back to the suffixed FQDN when the clean label is claimed by another team" do
      t1 = team_fixture()
      t2 = team_fixture()

      assert {:ok, bp1} = Registry.register_managed_barkpark(t1, "Gyldendal", "gyldendal")
      assert bp1.url == "https://gyldendal.barkpark.cloud"

      assert {:ok, bp2} = Registry.register_managed_barkpark(t2, "Gyldendal", "gyldendal")
      refute bp2.url == "https://gyldendal.barkpark.cloud"
      assert bp2.url == Barkpark.provisioning_url({"gyldendal", t2.id})
      assert String.starts_with?(Barkpark.subdomain_from_url(bp2), "gyldendal-")
    end

    test "a reserved slug is forced onto the suffixed FQDN (never claims the clean label)" do
      team = team_fixture()

      assert {:ok, bp} = Registry.register_managed_barkpark(team, "API", "api")
      refute bp.url == "https://api.barkpark.cloud"
      assert bp.url == Barkpark.provisioning_url({"api", team.id})
    end

    test "two reserved-name go-lives in different teams get distinct suffixed FQDNs" do
      t1 = team_fixture()
      t2 = team_fixture()

      assert {:ok, b1} = Registry.register_managed_barkpark(t1, "api", "api")
      assert {:ok, b2} = Registry.register_managed_barkpark(t2, "api", "api")
      refute b1.url == b2.url
    end
  end

  describe "Barkpark subdomain helpers" do
    test "reserved? flags system labels, case-insensitively" do
      assert Barkpark.reserved?("api")
      assert Barkpark.reserved?("WWW")
      refute Barkpark.reserved?("gyldendal")
    end

    test "clean_url builds the unsuffixed FQDN url" do
      assert Barkpark.clean_url("gyldendal") == "https://gyldendal.barkpark.cloud"
    end

    test "subdomain_from_url extracts the label from clean and suffixed urls" do
      clean = %Barkpark{
        slug: "x",
        team_id: Ecto.UUID.generate(),
        url: "https://gyldendal.barkpark.cloud"
      }

      assert Barkpark.subdomain_from_url(clean) == "gyldendal"

      suff = %Barkpark{
        slug: "x",
        team_id: Ecto.UUID.generate(),
        url: "https://gyldendal-71069eaa.barkpark.cloud"
      }

      assert Barkpark.subdomain_from_url(suff) == "gyldendal-71069eaa"
    end

    test "subdomain_from_url falls back to provisioning_subdomain when url is nil" do
      bp = %Barkpark{slug: "gyldendal", team_id: Ecto.UUID.generate(), url: nil}
      assert Barkpark.subdomain_from_url(bp) == Barkpark.provisioning_subdomain(bp)
    end
  end
end
