defmodule BarkparkCloud.RegistryTest do
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry

  alias BarkparkCloud.Registry.{
    AgentEvent,
    AgentToken,
    Barkpark,
    Deployment,
    Provider,
    ProvisionJob,
    Site
  }

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

      assert "is already taken by another Barkpark on this team" in errors_on(changeset).slug

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

  describe "health honesty — a row is never green before anything reported (cch-w34-s2)" do
    test "adopt_barkpark/3 lands health_status \"unknown\", not \"up\"" do
      team = team_fixture()

      assert {:ok, bp} =
               Registry.adopt_barkpark(team, %{
                 name: "Adopted",
                 slug: "adopted-#{System.unique_integer([:positive])}",
                 host: "203.0.113.77"
               })

      assert bp.host == "203.0.113.77"
      # Adoption is an operator's intent, not a measurement: no agent report has
      # arrived, so there is nothing to call healthy.
      assert bp.health_status == "unknown"
      assert is_nil(bp.last_seen_at)

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "unknown"
      assert is_nil(reloaded.last_seen_at)
    end

    test "succeed_job/2 lands health_status \"unknown\", not \"up\"" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      assert {:ok, _job} = Registry.succeed_job(job.id, "203.0.113.51")

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.host == "203.0.113.51"
      # A successful provision means the machine was CREATED — not that anything
      # answered. The row goes green on the first agent report.
      assert reloaded.health_status == "unknown"
      assert reloaded.agent_status == "offline"
      assert is_nil(reloaded.last_seen_at)
    end

    test "the first agent report is what turns the row green" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.succeed_job(job.id, "203.0.113.52")

      seen = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, _} =
               Registry.record_agent_report(Registry.get_barkpark(bp.id), %{
                 health_status: "up",
                 agent_status: "online",
                 last_seen_at: seen
               })

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "up"
      refute is_nil(reloaded.last_seen_at)
    end
  end

  describe "agent_status \"online\" always co-writes last_seen_at (cch-w34-s2 guard)" do
    # The never-reported arm of stale_online_barkparks/1 was unreachable for as
    # long as the query ALSO required agent_status == "online", because no
    # cloud/lib path can produce `online AND last_seen_at IS NULL`: the sole
    # producer is the POST /v1/agent/report handler, which stamps last_seen_at in
    # the same changeset. That invariant is now load-bearing in the OTHER
    # direction (the arm is keyed on last_seen_at alone), so pin it: a new writer
    # of "online" that forgets last_seen_at would resurrect a row the sweep can
    # never see going stale.
    @lib_root Path.expand("../../lib/barkpark_cloud", __DIR__)

    test "every cloud/lib write of agent_status \"online\" co-writes last_seen_at" do
      offenders =
        @lib_root
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          source = File.read!(path)

          source
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _n} ->
            String.contains?(line, ~s(agent_status: "online")) or
              String.contains?(line, ~s("agent_status" => "online"))
          end)
          |> Enum.reject(fn {_line, n} -> co_writes_last_seen_at?(source, n) end)
          |> Enum.map(fn {line, n} ->
            "#{Path.relative_to(path, @lib_root)}:#{n}: #{String.trim(line)}"
          end)
        end)

      assert offenders == [],
             """
             A cloud/lib path writes agent_status "online" without co-writing
             last_seen_at in the same map. That makes `online AND last_seen_at IS
             NULL` producible again — a row the staleness sweep's went-silent arm
             will never flip, because it has no heartbeat to age out.

             #{Enum.join(offenders, "\n")}
             """
    end

    # `last_seen_at` counts as co-written when it appears within the same map
    # literal — in practice within a few lines either side of the online write.
    defp co_writes_last_seen_at?(source, line_no) do
      lines = String.split(source, "\n")
      window = Enum.slice(lines, max(line_no - 8, 0), 16)
      Enum.any?(window, &String.contains?(&1, "last_seen_at"))
    end
  end

  describe "record_event/3 + recent_events/2" do
    test "appends events and returns them newest-first" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      # Three DIFFERENT real types, so this proves ordering across the mixed
      # stream and not just within one kind. It used to write "backup" and
      # "tls", which no producer has ever written and which @types no longer
      # declares (cch-w51-bl) — a fixture manufacturing traffic the plane
      # cannot produce is how a dead branch comes to look exercised.
      assert {:ok, %AgentEvent{}} = Registry.record_event(bp, "health", %{"cpu" => 0.2})
      assert {:ok, _} = Registry.record_event(bp, "space", %{"root_used_bytes" => 1024})
      assert {:ok, last} = Registry.record_event(bp, "verify", %{"reachable" => true})

      events = Registry.recent_events(bp, 10)
      assert length(events) == 3
      # Newest first.
      assert hd(events).id == last.id
      assert hd(events).type == "verify"
      assert hd(events).payload == %{"reachable" => true}
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

    test "re-minting supersedes the prior same-scope token (double-claim leaves exactly one active)" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      # First claim mints the box's report token.
      {:ok, first_pt, first} = Registry.mint_agent_token(bp, "report")
      # A stale-reclaim mints a fresh one — the old MUST be revoked in the same txn.
      {:ok, second_pt, second} = Registry.mint_agent_token(bp, "report")

      # Exactly one active "report" token survives — the newest.
      active_report =
        from(t in AgentToken,
          where: t.barkpark_id == ^bp.id and t.scope == "report" and is_nil(t.revoked_at)
        )
        |> Repo.all()

      assert [%AgentToken{id: only_id}] = active_report
      assert only_id == second.id

      # The superseded token is revoked and no longer verifies; the fresh one does.
      assert Repo.get(AgentToken, first.id).revoked_at
      assert is_nil(Registry.verify_agent_token(first_pt))
      assert %Barkpark{id: bid} = Registry.verify_agent_token(second_pt)
      assert bid == bp.id
    end

    test "re-mint only supersedes the SAME scope — other scopes stay live" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      {:ok, other_pt, _other} = Registry.mint_agent_token(bp, "report:health")
      {:ok, _pt1, _} = Registry.mint_agent_token(bp, "report")
      {:ok, _pt2, _} = Registry.mint_agent_token(bp, "report")

      # The different-scope token is untouched by the "report" re-mint churn.
      assert Registry.verify_agent_token(other_pt)
    end

    # task-940e49f7300a8d1b — the RECORDED RULING (see the docs above
    # mint_agent_token/3 and verify_agent_token/1): scope is deliberately NOT
    # an authorization boundary today. This is a TRIPWIRE, not a feature test —
    # it pins the CURRENT scope-blind behavior on purpose, so a future patch
    # that starts filtering by scope has to consciously touch this test
    # (and, per the ruling, update its doc) rather than silently narrowing
    # what a token can reach.
    test "TRIPWIRE (task-940e49f7300a8d1b): verify_agent_token ignores scope — any live scope opens the barkpark" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      {:ok, weird_pt, _} = Registry.mint_agent_token(bp, "an-utterly-invented-scope")

      assert %Barkpark{id: bid} = Registry.verify_agent_token(weird_pt)
      assert bid == bp.id
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

    # Full public identity for supports: register_support_barkpark/2 runs the
    # SAME reservation dance (shared insert_with_url_reservation/4) — clean
    # first, suffix on a cross-role/cross-team collision. The deep support
    # coverage lives in FleetSupportsTest; this pins the shared-helper contract
    # next to the mains' tests it mirrors.
    test "a SUPPORT reservation runs the same dance — clean first, suffix on collision" do
      t1 = team_fixture()
      t2 = team_fixture()

      assert {:ok, main1} = Registry.register_managed_barkpark(t1, "Gyldendal", "gyldendal")
      assert main1.url == "https://gyldendal.barkpark.cloud"

      {:ok, parent} = Registry.register_managed_barkpark(t2, "Parent", "parent")

      assert {:ok, support} =
               Registry.register_support_barkpark(t2, %{
                 name: "Gyldendal",
                 slug: "gyldendal",
                 parent_id: parent.id,
                 token_id: nil
               })

      # The clean label was taken by t1's MAIN → the support lands suffixed.
      assert support.url == Barkpark.provisioning_url({"gyldendal", t2.id})
      assert support.fleet_role == "support"
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

    # cch-w69-bl / D865 — subdomain_from_url/1 self-normalises (trim |> downcase)
    # so the DNS label / Hetzner box name the worker mints never depends on
    # upstream cleanliness. Each hostile spelling below (the D852 classes) must
    # fold to the SAME clean label. RED ON PRE-FIX BYTES: without the fold, a
    # leading space defeats the case-sensitive replace_prefix (yielding
    # " https://gyldendal" or a whole dirty host), an uppercase scheme passes
    # through unstripped ("HTTPS://gyldendal.barkpark.cloud"), and a mixed-case
    # host escapes the lowercase suffix strip ("Gyldendal.BARKPARK.CLOUD").
    test "subdomain_from_url self-normalises the D852 hostile spellings to the clean label" do
      base = %Barkpark{slug: "x", team_id: Ecto.UUID.generate()}
      clean = "gyldendal"

      hostile = [
        # leading / trailing whitespace
        "  https://gyldendal.barkpark.cloud",
        "https://gyldendal.barkpark.cloud  ",
        "\thttps://gyldendal.barkpark.cloud\n",
        # uppercase / mixed-case scheme
        "HTTPS://gyldendal.barkpark.cloud",
        "HtTpS://gyldendal.barkpark.cloud",
        # mixed-case host + zone
        "https://Gyldendal.barkpark.cloud",
        "https://gyldendal.BARKPARK.CLOUD",
        "https://GYLDENDAL.Barkpark.Cloud",
        # the compound worst case: space + uppercase scheme + mixed host
        "  HTTPS://Gyldendal.Barkpark.Cloud  "
      ]

      for url <- hostile do
        assert Barkpark.subdomain_from_url(%{base | url: url}) == clean,
               "expected #{inspect(url)} to fold to #{inspect(clean)}"
      end

      # The suffixed (team-disambiguated) shape survives the fold too — a
      # mixed-case suffixed url still yields the correct suffixed label.
      assert Barkpark.subdomain_from_url(%{
               base
               | url: "  HTTPS://Gyldendal-71069EAA.Barkpark.Cloud"
             }) ==
               "gyldendal-71069eaa"

      # DIVERGENCE NOTE (fourth normaliser spelling): DomainStatus.platform_host/1
      # (cloud/lib/barkpark_cloud/domain_status.ex) trims but does NOT downcase
      # and additionally splits path/port — it is a private helper on a separate
      # backlog row (cch-w71-bl-platform-host-fourth-normaliser-spelling). It is
      # intentionally NOT converged here; convergence is tracked there.
    end

    test "subdomain_from_url falls back to provisioning_subdomain when url is nil" do
      bp = %Barkpark{slug: "gyldendal", team_id: Ecto.UUID.generate(), url: nil}
      assert Barkpark.subdomain_from_url(bp) == Barkpark.provisioning_subdomain(bp)
    end
  end

  describe "binary_id lookups guard non-UUID path params (no 500)" do
    test "get_site/1 returns nil for a non-UUID id instead of raising" do
      assert Registry.get_site("not-a-uuid") == nil
    end

    test "get_deployment/1 returns nil for a non-UUID id instead of raising" do
      assert Registry.get_deployment("not-a-uuid") == nil
    end

    test "get_team_site/2 returns nil for a non-UUID id instead of raising" do
      assert Registry.get_team_site(team_fixture(), "not-a-uuid") == nil
    end

    test "transition_deployment_fenced/4 returns :not_found for a non-UUID id instead of raising" do
      assert Registry.transition_deployment_fenced("not-a-uuid", "w1", 1, %{status: "building"}) ==
               {:error, :not_found}
    end

    test "transition_deployment_with_site_update/5 returns :not_found for a non-UUID id instead of raising" do
      assert Registry.transition_deployment_with_site_update("not-a-uuid", "w1", 1, %{}, %{}) ==
               {:error, :not_found}
    end
  end

  describe "append_provision_step/4 — capped append-only (dwb-14)" do
    test "oldest step entries drop past the 100-entry cap; last survives" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # Append cap + 10 valid step reports; only the last 100 survive, oldest
      # dropped, order kept — mirrors the console-line cap.
      for i <- 1..110 do
        detail = "n#{i}"
        {:ok, _} = Registry.append_provision_step(job.id, "create", "started", detail)
      end

      steps = Repo.get(ProvisionJob, job.id).steps
      assert length(steps) == 100
      # The oldest 10 were dropped, the newest report survived.
      assert List.first(steps)["detail"] == "n11"
      assert List.last(steps)["detail"] == "n110"
    end

    # C1: the golden-path `verify` step round-trips through the same append path
    # onto the field the row serializer (:provision_steps) reads.
    test "a verify probe entry round-trips onto the serialized steps list" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      {:ok, _} =
        Registry.append_provision_step(job.id, "verify", "started", "verify.login: 401 in 182ms")

      steps = Repo.get(ProvisionJob, job.id).steps

      assert [
               %{
                 "step" => "verify",
                 "status" => "started",
                 "detail" => "verify.login: 401 in 182ms"
               }
             ] =
               steps
    end
  end

  describe "create_site/2 — server-authoritative tenant identity" do
    test "derives barkpark_id/team_id from the box, not from caller attrs" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      {:ok, site} = Registry.create_site(bp, %{name: "S", slug: "s-auth"})

      assert site.barkpark_id == bp.id
      assert site.team_id == bp.team_id
    end

    test "HOSTILE attrs: a client-supplied barkpark_id/team_id cannot override the server value" do
      team = team_fixture()
      bp = barkpark_fixture(team)

      # Another team's box — the values an attacker would try to smuggle in.
      other_team = team_fixture()
      other_bp = barkpark_fixture(other_team)

      {:ok, site} =
        Registry.create_site(bp, %{
          name: "S",
          slug: "s-hostile",
          barkpark_id: other_bp.id,
          team_id: other_team.id
        })

      # The attrs lost: identity is the box's, never the caller's.
      assert site.barkpark_id == bp.id
      assert site.team_id == bp.team_id
      refute site.barkpark_id == other_bp.id
      refute site.team_id == other_team.id

      # Persisted authoritative (survives a refetch).
      persisted = Repo.get(Site, site.id)
      assert persisted.barkpark_id == bp.id
      assert persisted.team_id == bp.team_id
    end
  end

  describe "append_deployment_console/2 (gh-5)" do
    defp deployment_fixture(team) do
      bp = barkpark_fixture(team)
      n = System.unique_integer([:positive])
      {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
      {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
      d
    end

    test "appends a stamped line, preserving order + persisting" do
      d = deployment_fixture(team_fixture())

      {:ok, d} = Registry.append_deployment_console(d.id, "claim: deployment claimed")
      {:ok, d} = Registry.append_deployment_console(d.id, "build: nixpacks build starting")
      # a trailing newline is trimmed
      {:ok, d} = Registry.append_deployment_console(d.id, "artifact: image saved\n")

      assert [
               %{"line" => "claim: deployment claimed", "at" => at0},
               %{"line" => "build: nixpacks build starting"},
               %{"line" => "artifact: image saved"}
             ] = d.console

      assert {:ok, _, _} = DateTime.from_iso8601(at0)
      # Refetch proves it PERSISTED (survives a page refresh).
      assert length(Repo.get(Deployment, d.id).console) == 3
    end

    test "a blank/non-binary line → {:error, :invalid}, nothing persisted" do
      d = deployment_fixture(team_fixture())

      assert {:error, :invalid} = Registry.append_deployment_console(d.id, "   ")
      assert {:error, :invalid} = Registry.append_deployment_console(d.id, "")
      assert {:error, :invalid} = Registry.append_deployment_console(d.id, nil)
      assert {:error, :invalid} = Registry.append_deployment_console(d.id, 42)
      assert Repo.get(Deployment, d.id).console == []
    end

    test "an oversized line is truncated to 2 KB, not rejected" do
      d = deployment_fixture(team_fixture())
      {:ok, d} = Registry.append_deployment_console(d.id, String.duplicate("x", 5_000))
      assert [%{"line" => line}] = d.console
      assert String.length(line) == 2_000
    end

    test "an unknown / non-UUID deployment id → {:error, :not_found}" do
      assert {:error, :not_found} =
               Registry.append_deployment_console(Ecto.UUID.generate(), "hello")

      assert {:error, :not_found} = Registry.append_deployment_console("not-a-uuid", "hello")
    end

    test "CAPPED append-only: oldest lines drop past the 300-line cap" do
      d = deployment_fixture(team_fixture())

      for i <- 1..305 do
        {:ok, _} = Registry.append_deployment_console(d.id, "line #{i}")
      end

      console = Repo.get(Deployment, d.id).console
      assert length(console) == 300
      assert List.first(console)["line"] == "line 6"
      assert List.last(console)["line"] == "line 305"
    end

    # cch-w33-s3: BOTH bounds must DISCLOSE what they discarded. A console that
    # silently drops is indistinguishable from a complete one, and the panel
    # renders a bare line count as though it were the whole log.

    test "cch-w33-s3: a truncated line DISCLOSES its original length" do
      d = deployment_fixture(team_fixture())
      {:ok, d} = Registry.append_deployment_console(d.id, String.duplicate("x", 5_000))

      # The chop itself is unchanged (the line stays exactly 2 KB) — what is new
      # is that the entry says so.
      assert [%{"line" => line, "truncated_from" => 5_000}] = d.console
      assert String.length(line) == 2_000

      # …and it PERSISTS: this is a jsonb column, not a computed field.
      assert [%{"truncated_from" => 5_000}] = Repo.get(Deployment, d.id).console
    end

    test "cch-w33-s3: a line of EXACTLY 2 KB is untouched and carries NO marker" do
      d = deployment_fixture(team_fixture())
      {:ok, d} = Registry.append_deployment_console(d.id, String.duplicate("x", 2_000))

      assert [%{"line" => line} = entry] = d.console
      assert String.length(line) == 2_000
      refute Map.has_key?(entry, "truncated_from")
    end

    test "cch-w33-s3: the ring drop DISCLOSES its cumulative count on the oldest survivor" do
      d = deployment_fixture(team_fixture())

      for i <- 1..305 do
        {:ok, _} = Registry.append_deployment_console(d.id, "line #{i}")
      end

      console = Repo.get(Deployment, d.id).console
      assert length(console) == 300
      oldest = List.first(console)
      assert oldest["line"] == "line 6"
      assert oldest["dropped_before"] == 5

      # CUMULATIVE, not per-call: ten more lines drop ten more, and the count on
      # the new oldest survivor carries the running total forward.
      for i <- 306..315 do
        {:ok, _} = Registry.append_deployment_console(d.id, "line #{i}")
      end

      console = Repo.get(Deployment, d.id).console
      assert length(console) == 300
      assert List.first(console)["line"] == "line 16"
      assert List.first(console)["dropped_before"] == 15

      # The marker rides on the OLDEST survivor only — never on the newest line.
      refute Map.has_key?(List.last(console), "dropped_before")
    end

    test "cch-w33-s3: BELOW the cap nothing is dropped and the count reads 0" do
      d = deployment_fixture(team_fixture())

      for i <- 1..10 do
        {:ok, _} = Registry.append_deployment_console(d.id, "line #{i}")
      end

      console = Repo.get(Deployment, d.id).console
      assert length(console) == 10
      oldest = List.first(console)
      refute Map.has_key?(oldest, "dropped_before")
      assert Map.get(oldest, "dropped_before", 0) == 0
    end

    test "best-effort: a late line after the deploy is terminal still records" do
      d = deployment_fixture(team_fixture())
      {:ok, _} = Registry.transition_deployment(d, %{status: "failed", failure_reason: "boom"})

      assert {:ok, d} = Registry.append_deployment_console(d.id, "cleanup: build torn down")
      assert [%{"line" => "cleanup: build torn down"}] = d.console
      assert Repo.get(Deployment, d.id).status == "failed"
    end
  end

  describe "set_deployment_detail/2 (dwb-19)" do
    defp detail_deployment_fixture(team) do
      bp = barkpark_fixture(team)
      n = System.unique_integer([:positive])
      {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
      {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
      d
    end

    test "SETS the live caption latest-wins (single value, never appended) + persists" do
      d = detail_deployment_fixture(team_fixture())
      assert d.detail == nil

      {:ok, d} = Registry.set_deployment_detail(d.id, "Fetching your source…")
      assert d.detail == "Fetching your source…"

      # A second caption OVERWRITES (there is no array to grow).
      {:ok, d} = Registry.set_deployment_detail(d.id, "Building your site…")
      assert d.detail == "Building your site…"

      # It PERSISTED (survives a refresh).
      assert Repo.get(Deployment, d.id).detail == "Building your site…"
    end

    test "a blank/non-binary caption → {:error, :invalid}, nothing persisted" do
      d = detail_deployment_fixture(team_fixture())

      assert {:error, :invalid} = Registry.set_deployment_detail(d.id, "   ")
      assert {:error, :invalid} = Registry.set_deployment_detail(d.id, "")
      assert {:error, :invalid} = Registry.set_deployment_detail(d.id, nil)
      assert {:error, :invalid} = Registry.set_deployment_detail(d.id, 42)
      assert Repo.get(Deployment, d.id).detail == nil
    end

    test "an unknown / non-UUID deployment id → {:error, :not_found}" do
      assert {:error, :not_found} =
               Registry.set_deployment_detail(Ecto.UUID.generate(), "hello")

      assert {:error, :not_found} = Registry.set_deployment_detail("not-a-uuid", "hello")
    end

    # cch-w33-s3: the THIRD consumer of validate_console_line/1. `detail` is a
    # bare string column, so it can carry no marker — which is exactly why the
    # validator kept its {:ok, binary} return shape and the console disclosure
    # rides in a separate `console_line_meta/1` sibling. Changing the /1 return
    # shape would have broken this with-chain silently.
    test "cch-w33-s3: a caption at the column limit round-trips through the shared validator" do
      d = detail_deployment_fixture(team_fixture())

      assert {:ok, d} = Registry.set_deployment_detail(d.id, String.duplicate("y", 255))
      assert String.length(d.detail) == 255
      assert Repo.get(Deployment, d.id).detail == d.detail
    end

    # cch-w34-s5: the replacement the pinning test asked for. Its predecessor
    # ("a caption ABOVE the column limit currently RAISES") certified the defect:
    # the shared validator truncated at 2 KB while the column was varchar(255),
    # so 256..2_000 chars raised Postgrex.Error 22001 inside Repo.update — out of
    # a function whose @doc promises telemetry that never affects the build's
    # outcome. `modify :detail, :text` (migration 20260806110000) makes the 2 KB
    # validator the ONLY bound, so the same input now TRUNCATES AND STORES.
    test "cch-w34-s5: a caption above the shared 2 KB cap truncates and STORES rather than raising" do
      d = detail_deployment_fixture(team_fixture())

      assert {:ok, d} = Registry.set_deployment_detail(d.id, String.duplicate("y", 5_000))
      assert String.length(d.detail) == 2_000
      assert Repo.get(Deployment, d.id).detail == d.detail
    end

    # cch-w34-s5: the band the old column silently owned — 256..2_000 — is now
    # stored WHOLE, not truncated at 255 and not raised. This is the assertion a
    # detail-specific 255 cap would have failed, which is why the remedy was the
    # column and not a second cap.
    test "cch-w34-s5: a caption between the old column width and the shared cap round-trips WHOLE" do
      d = detail_deployment_fixture(team_fixture())

      caption = String.duplicate("z", 300)
      assert {:ok, d} = Registry.set_deployment_detail(d.id, caption)
      assert d.detail == caption
      assert Repo.get(Deployment, d.id).detail == caption
    end
  end

  describe "add_site_domain/2 — cross-team collision / takeover guard" do
    defp site_fixture(team, slug) do
      bp = barkpark_fixture(team)
      {:ok, site} = Registry.create_site(bp, %{name: "S #{slug}", slug: slug})
      site
    end

    test "a domain owned by ANOTHER team's site is rejected with :domain_taken" do
      site_a = site_fixture(team_fixture(), "a1")
      site_b = site_fixture(team_fixture(), "b1")

      assert {:ok, _} = Registry.add_site_domain(site_a, "example.com")
      # Team B cannot claim the domain team A points DNS at.
      assert {:error, :domain_taken} = Registry.add_site_domain(site_b, "example.com")

      # ...and it never landed on B's array.
      assert Repo.get(Site, site_b.id).domains == []
    end

    test "the SAME site re-adding its own domain is an idempotent no-op" do
      site = site_fixture(team_fixture(), "idem")

      {:ok, site} = Registry.add_site_domain(site, "example.com")
      assert site.domains == ["example.com"]

      # Re-add (verbatim and with different casing) — both no-ops, no error.
      assert {:ok, again} = Registry.add_site_domain(site, "example.com")
      assert again.domains == ["example.com"]
      assert {:ok, again2} = Registry.add_site_domain(site, "EXAMPLE.com")
      assert again2.domains == ["example.com"]
    end

    test "case-folded collision: Example.com collides with an existing example.com" do
      site_a = site_fixture(team_fixture(), "cf-a")
      site_b = site_fixture(team_fixture(), "cf-b")

      assert {:ok, _} = Registry.add_site_domain(site_a, "example.com")
      # Mixed-case on a different team's site must still be caught.
      assert {:error, :domain_taken} = Registry.add_site_domain(site_b, "Example.COM")
      # A trailing dot (FQDN form) normalizes to the same name and collides too.
      assert {:error, :domain_taken} = Registry.add_site_domain(site_b, "example.com.")
    end

    test "apex and subdomain are DISTINCT names — not over-collapsed" do
      site_a = site_fixture(team_fixture(), "apex-a")
      site_b = site_fixture(team_fixture(), "apex-b")

      assert {:ok, _} = Registry.add_site_domain(site_a, "example.com")
      # www.example.com is a different hostname; team B may own it.
      assert {:ok, b} = Registry.add_site_domain(site_b, "www.example.com")
      assert "www.example.com" in b.domains
    end

    test "a domain freed by one site can later be claimed by another" do
      site_a = site_fixture(team_fixture(), "free-a")
      site_b = site_fixture(team_fixture(), "free-b")

      {:ok, site_a} = Registry.add_site_domain(site_a, "example.com")
      assert {:error, :domain_taken} = Registry.add_site_domain(site_b, "example.com")

      {:ok, _} = Registry.remove_site_domain(site_a, "example.com")
      # Now that A released it, B can claim it.
      assert {:ok, b} = Registry.add_site_domain(site_b, "example.com")
      assert "example.com" in b.domains
    end

    test "ask-gate: a registered domain resolves to EXACTLY ONE owning site (no foreign owner)" do
      site_a = site_fixture(team_fixture(), "gate-a")
      site_b = site_fixture(team_fixture(), "gate-b")

      {:ok, site_a} = Registry.add_site_domain(site_a, "example.com")
      # B's attempt to register the same domain is refused, so the gate can never
      # be tricked into 200-ing for a second (foreign) owner.
      assert {:error, :domain_taken} = Registry.add_site_domain(site_b, "example.com")

      owner = Registry.domain_owner_site("example.com")
      assert owner.id == site_a.id
      # Case-folded lookup resolves to the same single owner.
      assert Registry.domain_owner_site("EXAMPLE.com").id == site_a.id
      # And the boolean ask-gate case-folds consistently.
      assert Registry.domain_registered?("Example.com")
      refute Registry.domain_registered?("notregistered.example.org")
    end

    test "DB trigger is the race backstop: a direct colliding write raises unique_violation" do
      site_a = site_fixture(team_fixture(), "trig-a")
      site_b = site_fixture(team_fixture(), "trig-b")

      {:ok, _} = Registry.add_site_domain(site_a, "example.com")

      # Bypass the app-level check and write straight through Ecto — the DB-level
      # trigger must still reject the cross-site duplicate. (Last assertion in the
      # test: the raise aborts the sandbox transaction, which ExUnit rolls back.)
      cs = Site.changeset(site_b, %{domains: ["example.com"]})
      assert_raise Postgrex.Error, fn -> Repo.update!(cs) end
    end
  end

  # deploy-reliability W1 s4: the content-webhook registrar must send the box's
  # `types` DOC-TYPE FILTER. Every site-autodeploy row on guerrilla carried the
  # empty array — the box's MATCH-EVERYTHING sentinel — so all five spawned sites
  # rebuilt on every mutation in a shared dataset, 90.3% of which were `task`
  # writes from this repo's own bp ledger.
  describe "content-webhook registration: doc-type filter (deploy-reliability W1 s4)" do
    alias BarkparkCloud.StudioLinkFakeHttpClient
    alias BarkparkCloud.Registry.Vault

    defp live_bp(team) do
      n = System.unique_integer([:positive])
      {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

      bp
      |> Ecto.Changeset.change(
        url: "https://acme.barkpark.cloud",
        git_commit: "abc123",
        admin_token_encrypted: Vault.encrypt("instance-admin-token")
      )
      |> Repo.update!()
    end

    defp bound_site(bp, attrs \\ %{}) do
      n = System.unique_integer([:positive])

      {:ok, site} =
        Registry.create_site(
          bp,
          Enum.into(attrs, %{
            name: "Blog #{n}",
            slug: "blog-#{n}",
            kind: "static",
            framework: "astro",
            bootstrap_workspace: "acme",
            bootstrap_project: "blog",
            bootstrap_dataset: "production",
            read_token: "bpt_read_#{n}"
          })
        )

      site
    end

    defp webhook_write(method) do
      StudioLinkFakeHttpClient.requests()
      |> Enum.find(fn r ->
        r.method == method and String.contains?(r.url, "/v1/webhooks/production")
      end)
    end

    test "the CREATE registration carries the site's own doc_type as the box `types` filter" do
      bp = team_fixture() |> live_bp()
      StudioLinkFakeHttpClient.program([])

      site = bound_site(bp, %{doc_type: "paper"})
      assert site.doc_type == "paper"

      post = webhook_write(:post)
      assert post, "expected a POST /v1/webhooks/production registration call"

      payload = Jason.decode!(post.body)

      # THE DEFECT: this key was absent entirely, so the box stored `{}` and the
      # row matched every document type in the dataset.
      assert payload["types"] == ["paper"],
             "the registration must filter to the type this site's build actually reads"
    end

    test "the RECONCILE (PUT) body carries types too — a later doc_type change REPAIRS the stale array" do
      bp = team_fixture() |> live_bp()
      StudioLinkFakeHttpClient.program([])

      site = bound_site(bp, %{doc_type: "paper"})
      hook_id = Ecto.UUID.generate()

      # The operator re-points the site at a different type between deploys.
      {:ok, site} = Registry.update_site_settings(site, %{doc_type: "post"})

      # Second pass: the box now reports the row this site already registered, so
      # the reconciler takes the PUT branch.
      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/production" =>
          {:ok,
           %{
             status: 200,
             body:
               Jason.encode!(%{
                 "webhooks" => [%{"id" => hook_id, "name" => "site-autodeploy-#{site.id}"}]
               })
           }},
        "/v1/webhooks/production/#{hook_id}" => {:ok, %{status: 200, body: "{}"}}
      })

      assert :ok = Registry.ensure_content_webhook(bp, site)

      put = webhook_write(:put)
      assert put, "expected a PUT update of the EXISTING webhook row"

      # `Webhooks.update_webhook/2` on the box casts only the keys PRESENT in the
      # body: a types omitted here survives untouched, which would leave this row
      # filtered on "paper" forever. The filter lives in the SHARED body for
      # exactly this reason.
      assert Jason.decode!(put.body)["types"] == ["post"],
             "reconciliation must REPAIR a stale types array, not only seed it"
    end

    test "a site with a blank doc_type registers `[]` — the box's match-everything sentinel, never a wrong filter" do
      bp = team_fixture() |> live_bp()
      StudioLinkFakeHttpClient.program([])

      site = bound_site(bp)
      # A row with no usable binding (the column is NOT NULL, so blank is the
      # only shape this takes). Filtering such a site to a guessed type would
      # silently stop its real rebuilds, so the fallback is today's unfiltered
      # behaviour — the box's own match-everything sentinel.
      site = site |> Ecto.Changeset.change(doc_type: "") |> Repo.update!()

      hook_id = Ecto.UUID.generate()

      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/production" =>
          {:ok,
           %{
             status: 200,
             body:
               Jason.encode!(%{
                 "webhooks" => [%{"id" => hook_id, "name" => "site-autodeploy-#{site.id}"}]
               })
           }},
        "/v1/webhooks/production/#{hook_id}" => {:ok, %{status: 200, body: "{}"}}
      })

      assert :ok = Registry.ensure_content_webhook(bp, site)
      assert Jason.decode!(webhook_write(:put).body)["types"] == []
    end

    test "the filter FILTERS: under the box's own selection predicate, `paper` matches and `task` does not" do
      bp = team_fixture() |> live_bp()
      StudioLinkFakeHttpClient.program([])

      _site = bound_site(bp, %{doc_type: "paper"})
      types = Jason.decode!(webhook_write(:post).body)["types"]

      # This is the box's selection predicate verbatim from
      # api/lib/barkpark/webhooks.ex:197 (`active_webhooks_for/4`):
      #
      #   fragment("? = '{}' OR ? @> ARRAY[?]::varchar[]", w.types, w.types, ^type)
      #
      # evaluated in Postgres against the array THIS registrar sends. It answers
      # the only question the control plane controls: does the value we register
      # select a paper mutation and reject a task mutation? (The box-side
      # dispatch itself is covered by api/test/barkpark/webhooks_test.exs.)
      selects? = fn type ->
        %{rows: [[result]]} =
          Repo.query!(
            "SELECT ($1::varchar[] = '{}') OR ($1::varchar[] @> ARRAY[$2]::varchar[])",
            [types, type]
          )

        result
      end

      assert selects?.("paper"), "a paper mutation must still rebuild the site"

      refute selects?.("task"),
             "a task mutation must NOT rebuild the site — 90.3% of deliveries were task writes"

      refute selects?.("post")
    end
  end
end
