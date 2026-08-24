defmodule BarkparkCloud.Web.FleetSupportsTest do
  @moduledoc """
  Personal Dev Fleet Wave C (PDF-D61) — the GROUP record. Exercises the three
  additive fleet columns end to end:

    * `Barkpark.fleet_changeset/2` — role inclusion + the parent invariant
      (required iff support, forbidden for main), including the REFUSAL cases.
    * `Registry.register_support_barkpark/2` — the transactional write + the
      self-FK guard.
    * `POST /v1/fleet/supports` — team-scoped create, cross-team parent refused,
      support-as-parent refused, auth gating.
    * `DELETE /v1/fleet/supports/:id` — support-only unbind, main/wrong-team
      refusals.
    * `GET /v1/barkparks` — the fleet fields are serialized.

  Mirrors RouterPatTest's DataCase + Plug.Test harness.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob, Vault}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  # The shared worker token the internal claim routes authorize against (test env).
  @worker_token "worker-token-test-fixed"

  ## Fixtures

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

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  # A user holding `role` in a fresh team, plus a live session token.
  # Returns {user, team, token}.
  defp user_with_role(role) do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  # A registered MAIN row (fleet_role stamped) — the intended FK target.
  defp main_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "Main #{n}", slug: "main-#{n}"}))

    {:ok, main} = bp |> Barkpark.fleet_changeset(%{fleet_role: "main"}) |> Repo.update()
    main
  end

  # A LIVE main: url + encrypted admin token + bootstrap workspace stored (what the
  # provision-succeed path writes). The provision_support claim payload's credential
  # spine — parent_url / parent_admin_token / workspace — reads off exactly these.
  defp live_main_fixture(team, attrs \\ %{}) do
    main = main_fixture(team, attrs)
    n = System.unique_integer([:positive])

    main
    |> Ecto.Changeset.change(
      url: "https://main-#{n}.barkpark.cloud",
      host: "203.0.113.5",
      admin_token_encrypted: Vault.encrypt("admin-secret-#{n}"),
      bootstrap_workspace: "acme"
    )
    |> Repo.update!()
  end

  # A LIVE support: the shape `provision_support` leaves behind (PDF-D83) — a
  # real box (`host`) and the public identity that box was given (`url`, whose
  # label IS the A record the worker published). Both are load-bearing for
  # task-688ebffc4b0aa50a: `host` is what makes the row LIVE, and `url` is the
  # only thing that still names the record to delete.
  defp live_support_fixture(team, main, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, support} =
      Registry.register_support_barkpark(
        team,
        Enum.into(attrs, %{
          name: "Live #{n}",
          slug: "live-#{n}",
          parent_id: main.id,
          token_id: "t"
        })
      )

    support
    |> Ecto.Changeset.change(
      url: "https://live-#{n}.barkpark.cloud",
      host: "203.0.113.#{rem(n, 200) + 10}"
    )
    |> Repo.update!()
  end

  # A support row already bound under a fresh in-team main, plus the team's user
  # holding `role`. Returns {user, team, support} — the credential-gating tests
  # mint their own PAT / session off the returned user + team.
  defp support_in_team(role) do
    {user, team, _session} = user_with_role(role)
    main = main_fixture(team)
    n = System.unique_integer([:positive])

    {:ok, support} =
      Registry.register_support_barkpark(team, %{
        name: "Bound #{n}",
        slug: "bound-#{n}",
        parent_id: main.id,
        token_id: "t"
      })

    {user, team, support}
  end

  ## Request helper

  defp call(method, path, body \\ nil, token \\ nil) do
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

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  ## Changeset invariants

  describe "Barkpark.fleet_changeset/2" do
    test "a support WITH a parent is valid" do
      cs =
        Barkpark.fleet_changeset(%Barkpark{}, %{
          fleet_role: "support",
          fleet_parent_id: Ecto.UUID.generate(),
          fleet_token_id: "tok_abc"
        })

      assert cs.valid?
    end

    test "a main WITHOUT a parent is valid" do
      cs = Barkpark.fleet_changeset(%Barkpark{}, %{fleet_role: "main"})
      assert cs.valid?
    end

    test "an unknown role is refused" do
      cs = Barkpark.fleet_changeset(%Barkpark{}, %{fleet_role: "worker"})
      refute cs.valid?
      assert %{fleet_role: ["is invalid"]} = errors_on(cs)
    end

    test "a support WITHOUT a parent is refused" do
      cs = Barkpark.fleet_changeset(%Barkpark{}, %{fleet_role: "support"})
      refute cs.valid?
      assert %{fleet_parent_id: ["is required for a support"]} = errors_on(cs)
    end

    test "a main WITH a parent is refused" do
      cs =
        Barkpark.fleet_changeset(%Barkpark{}, %{
          fleet_role: "main",
          fleet_parent_id: Ecto.UUID.generate()
        })

      refute cs.valid?
      assert %{fleet_parent_id: ["is forbidden for a main"]} = errors_on(cs)
    end

    test "a nil role (ungrouped) constrains neither parent — valid" do
      assert Barkpark.fleet_changeset(%Barkpark{}, %{}).valid?
      assert Barkpark.fleet_changeset(%Barkpark{}, %{fleet_token_id: "t"}).valid?
    end
  end

  ## Registry write + self-FK guard

  describe "Registry.register_support_barkpark/2" do
    test "creates a support row bound to the parent, carrying all three fleet fields" do
      team = team_fixture()
      main = main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Support A",
          slug: "support-a",
          host: "203.0.113.9",
          parent_id: main.id,
          token_id: "tok_opaque_1"
        })

      assert support.fleet_role == "support"
      assert support.fleet_parent_id == main.id
      assert support.fleet_token_id == "tok_opaque_1"
      assert support.team_id == team.id
      assert support.host == "203.0.113.9"
    end

    test "a parent id that names no row fails the self-FK — no orphan row is left" do
      team = team_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Registry.register_support_barkpark(team, %{
                 name: "Support Bogus",
                 slug: "support-bogus",
                 parent_id: Ecto.UUID.generate(),
                 token_id: "tok_x"
               })

      # The transaction rolled back — the base row was NOT left behind.
      refute Enum.any?(Registry.list_barkparks(team), &(&1.slug == "support-bogus"))
    end

    # Full public identity: a support's url is its reservation from birth, the
    # SAME clean-first dance mains run — mint_studio_link needs the url, and the
    # claim payload's slug (the worker's DNS label) derives from its first label.
    test "reserves the CLEAN <slug>.barkpark.cloud url at registration" do
      team = team_fixture()
      main = main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Support Url",
          slug: "support-url",
          parent_id: main.id,
          token_id: nil
        })

      assert support.url == "https://support-url.barkpark.cloud"
      assert Barkpark.subdomain_from_url(support) == "support-url"
    end

    test "falls back to the suffixed url when the clean label is claimed by any team" do
      t1 = team_fixture()
      t2 = team_fixture()

      # t1's MAIN claims the clean label first (the global url index decides).
      assert {:ok, main1} = Registry.register_managed_barkpark(t1, "Muscle", "muscle")
      assert main1.url == "https://muscle.barkpark.cloud"

      main2 = main_fixture(t2)

      {:ok, support} =
        Registry.register_support_barkpark(t2, %{
          name: "Muscle",
          slug: "muscle",
          parent_id: main2.id,
          token_id: nil
        })

      assert support.url == Barkpark.provisioning_url({"muscle", t2.id})
      assert String.starts_with?(Barkpark.subdomain_from_url(support), "muscle-")
    end

    test "a reserved slug is forced onto the suffixed url (never claims the clean label)" do
      team = team_fixture()
      main = main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "api",
          slug: "api",
          parent_id: main.id,
          token_id: nil
        })

      refute support.url == "https://api.barkpark.cloud"
      assert support.url == Barkpark.provisioning_url({"api", team.id})
    end
  end

  ## POST /v1/fleet/supports

  describe "POST /v1/fleet/supports" do
    test "201 creates a support bound to an in-team main (session admin)" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      conn =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Helper One", parent_id: main.id, host: "203.0.113.20", token_id: "tok_9"},
          token
        )

      assert conn.status == 201
      bp = decode(conn)["barkpark"]
      assert bp["fleet_role"] == "support"
      assert bp["fleet_parent_id"] == main.id
      assert bp["fleet_token_id"] == "tok_9"
      assert bp["team_id"] == team.id

      # The row is really persisted and bound.
      persisted = Registry.get_barkpark(bp["id"])
      assert persisted.fleet_parent_id == main.id
    end

    test "cross-team parent → 404 (no existence leak), nothing created" do
      {_u_a, _team_a, token_a} = user_with_role("owner")
      team_b = team_fixture()
      main_b = main_fixture(team_b)

      conn =
        call(:post, "/v1/fleet/supports", %{name: "Sneaky", parent_id: main_b.id}, token_a)

      assert conn.status == 404
      assert decode(conn)["error"] == "not_found"
    end

    test "a support cannot be a parent → 422 invalid_parent" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Existing Support",
          slug: "existing-support",
          parent_id: main.id,
          token_id: "t"
        })

      conn =
        call(:post, "/v1/fleet/supports", %{name: "Grandchild", parent_id: support.id}, token)

      assert conn.status == 422
      assert decode(conn)["error"] == "invalid_parent"
    end

    test "missing name → 422; missing parent_id → 422" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      no_name = call(:post, "/v1/fleet/supports", %{parent_id: main.id}, token)
      assert no_name.status == 422
      assert decode(no_name)["error"] == "invalid"

      no_parent = call(:post, "/v1/fleet/supports", %{name: "Orphan"}, token)
      assert no_parent.status == 422
      assert decode(no_parent)["error"] == "invalid"
    end

    test "a plain member is 403'd; no token is 401" do
      {_m, team_m, m_token} = user_with_role("member")
      main_m = main_fixture(team_m)

      denied = call(:post, "/v1/fleet/supports", %{name: "X", parent_id: main_m.id}, m_token)
      assert denied.status == 403
      assert decode(denied)["error"] == "forbidden"

      anon = call(:post, "/v1/fleet/supports", %{name: "X", parent_id: main_m.id})
      assert anon.status == 401
    end
  end

  ## DELETE /v1/fleet/supports/:id

  describe "DELETE /v1/fleet/supports/:id" do
    test "removes a support row → 200, the row is gone" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Doomed",
          slug: "doomed",
          parent_id: main.id,
          token_id: "t"
        })

      conn = call(:delete, "/v1/fleet/supports/#{support.id}", nil, token)

      assert conn.status == 200
      assert decode(conn)["status"] == "removed"
      assert Registry.get_barkpark(support.id) == nil
      # The main survives — only the support was unbound.
      assert Registry.get_barkpark(main.id) != nil
    end

    test "a main row is refused → 409 not_a_support, row kept" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      conn = call(:delete, "/v1/fleet/supports/#{main.id}", nil, token)

      assert conn.status == 409
      assert decode(conn)["error"] == "not_a_support"
      assert Registry.get_barkpark(main.id) != nil
    end

    test "wrong-team support → 404 (no existence leak), row untouched" do
      {_u_a, _team_a, token_a} = user_with_role("owner")
      team_b = team_fixture()
      main_b = main_fixture(team_b)

      {:ok, support_b} =
        Registry.register_support_barkpark(team_b, %{
          name: "Theirs",
          slug: "theirs",
          parent_id: main_b.id,
          token_id: "t"
        })

      conn = call(:delete, "/v1/fleet/supports/#{support_b.id}", nil, token_a)

      assert conn.status == 404
      assert Registry.get_barkpark(support_b.id) != nil
    end

    test "nonexistent / malformed id → 404" do
      {_u, _team, token} = user_with_role("owner")
      assert call(:delete, "/v1/fleet/supports/#{Ecto.UUID.generate()}", nil, token).status == 404
      assert call(:delete, "/v1/fleet/supports/not-a-uuid", nil, token).status == 404
    end
  end

  ## DELETE /v1/fleet/supports/:id — the DNS A record must die WITH the support
  ##
  ## task-688ebffc4b0aa50a. A provisioned support owns a real box AND an
  ## `A <label>.barkpark.cloud` record pointing at it. Deleting the row alone
  ## left that record dangling at an address Hetzner will later reassign — the
  ## abandoned hostname then resolves to a stranger's machine. The removal must
  ## therefore keep the row until the record is gone, because the row is the only
  ## thing that still names the record.

  describe "DELETE /v1/fleet/supports/:id — live support tears its DNS record down" do
    test "a LIVE support is NOT row-deleted: 202, row kept, one deprovision job enqueued" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)
      support = live_support_fixture(team, main)

      conn = call(:delete, "/v1/fleet/supports/#{support.id}", nil, token)

      assert conn.status == 202
      assert decode(conn)["status"] == "deprovisioning"

      # THE POINT: the row survives the request. It is the sole pointer to the
      # record — dropping it here would lose the name while the record stayed up.
      assert Registry.get_barkpark(support.id) != nil

      job = Repo.get_by(ProvisionJob, barkpark_id: support.id, kind: "deprovision")
      assert job != nil
      assert job.status == "pending"
    end

    test "the enqueued teardown names the A record: claim payload carries the label + zone" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)
      support = live_support_fixture(team, main)

      assert call(:delete, "/v1/fleet/supports/#{support.id}", nil, token).status == 202

      claim = call(:post, "/v1/internal/deprovision-jobs/claim", %{}, @worker_token)
      assert claim.status == 200
      body = decode(claim)

      # The worker is handed the box IP and the record's label + zone — enough to
      # delete the server and sweep the zone. A row deleted at request time would
      # have made this payload underivable.
      assert body["ip"] == support.host
      assert body["dns_label"] == Barkpark.subdomain_from_url(support)
      assert body["dns_zone"] == Barkpark.base_domain()
      refute body["dns_label"] in [nil, ""]
    end

    test "the row is dropped only AFTER the worker reports the box + record gone" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)
      support = live_support_fixture(team, main)

      assert call(:delete, "/v1/fleet/supports/#{support.id}", nil, token).status == 202
      assert Registry.get_barkpark(support.id) != nil

      claim = decode(call(:post, "/v1/internal/deprovision-jobs/claim", %{}, @worker_token))

      done =
        call(
          :post,
          "/v1/internal/deprovision-jobs/#{claim["job_id"]}/succeed",
          %{"claim_token" => claim["claim_token"]},
          @worker_token
        )

      assert done.status in [200, 204]
      assert Registry.get_barkpark(support.id) == nil
    end

    test "a FAILED teardown keeps the row — never unreachable AND live" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)
      support = live_support_fixture(team, main)

      assert call(:delete, "/v1/fleet/supports/#{support.id}", nil, token).status == 202
      claim = decode(call(:post, "/v1/internal/deprovision-jobs/claim", %{}, @worker_token))

      failed =
        call(
          :post,
          "/v1/internal/deprovision-jobs/#{claim["job_id"]}/fail",
          %{"error" => "dns: sweep failed", "claim_token" => claim["claim_token"]},
          @worker_token
        )

      assert failed.status in [200, 204]
      # The record may still be up, so the row that names it MUST still be here.
      assert Registry.get_barkpark(support.id) != nil
    end

    test "re-running the removal is safe: 202 again, still exactly one teardown job" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)
      support = live_support_fixture(team, main)

      assert call(:delete, "/v1/fleet/supports/#{support.id}", nil, token).status == 202
      assert call(:delete, "/v1/fleet/supports/#{support.id}", nil, token).status == 202

      jobs = Repo.all(from(j in ProvisionJob, where: j.barkpark_id == ^support.id))
      assert length(jobs) == 1
    end

    test "a support still PROVISIONING is refused 409 — the record has no name yet" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "InFlight",
          slug: "in-flight",
          parent_id: main.id,
          token_id: "t"
        })

      {:ok, _job} = Registry.enqueue_support_provision_job(support)

      conn = call(:delete, "/v1/fleet/supports/#{support.id}", nil, token)

      assert conn.status == 409
      assert decode(conn)["error"] == "provisioning_in_progress"
      # Deleting now would let the worker publish an A record nothing can see.
      assert Registry.get_barkpark(support.id) != nil
    end

    test "?mode=detach drops the row now — for a caller that already swept the zone" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)
      support = live_support_fixture(team, main)

      conn = call(:delete, "/v1/fleet/supports/#{support.id}?mode=detach", nil, token)

      assert conn.status == 200
      assert decode(conn)["status"] == "removed"
      assert decode(conn)["mode"] == "detach"
      assert Registry.get_barkpark(support.id) == nil
      # Detach is registry-only: it must NOT also enqueue a teardown.
      assert Repo.all(from(j in ProvisionJob, where: j.barkpark_id == ^support.id)) == []
    end

    test "an unrecognised mode is NOT detach — the safe path still wins" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)
      support = live_support_fixture(team, main)

      conn = call(:delete, "/v1/fleet/supports/#{support.id}?mode=yolo", nil, token)

      assert conn.status == 202
      assert Registry.get_barkpark(support.id) != nil
    end

    test "detach is still team-scoped: a wrong-team support is 404, row untouched" do
      {_u_a, _team_a, token_a} = user_with_role("owner")
      team_b = team_fixture()
      main_b = live_main_fixture(team_b)
      support_b = live_support_fixture(team_b, main_b)

      conn = call(:delete, "/v1/fleet/supports/#{support_b.id}?mode=detach", nil, token_a)

      assert conn.status == 404
      assert Registry.get_barkpark(support_b.id) != nil
    end

    test "Registry.active_support_provision_job?/1 sees the kind a support gets" do
      {_u, team, _token} = user_with_role("owner")
      main = live_main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Kinds",
          slug: "kinds",
          parent_id: main.id,
          token_id: "t"
        })

      refute Registry.active_support_provision_job?(support)
      {:ok, _} = Registry.enqueue_support_provision_job(support)
      assert Registry.active_support_provision_job?(support)

      # The pre-existing predicate only ever knew kind "provision", which a
      # support is NEVER enqueued under — that blind spot is why the guard above
      # needed its own function rather than a reuse.
      refute Registry.active_provision_job?(support)
    end
  end

  ## DELETE /v1/fleet/supports/:id — credential-aware gating (PAT symmetry)
  #
  # A credential that can BIND (POST) can UNBIND (DELETE): the endpoint now runs
  # require_user_or_pat + the deploy-ability cond, exactly like POST. Mirrors
  # RouterPatTest's B2 (a deploy PAT can go-live, a read PAT is 403'd) —
  # PATs minted via Accounts.create_personal_access_token/3.

  describe "DELETE /v1/fleet/supports/:id credential gating" do
    test "a deploy PAT removes the support → 200, the row is gone" do
      {user, team, support} = support_in_team("owner")

      {:ok, deploy_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "deploy-key",
          abilities: ["deploy"]
        })

      conn = call(:delete, "/v1/fleet/supports/#{support.id}", nil, deploy_token)

      assert conn.status == 200
      assert decode(conn)["status"] == "removed"
      assert Registry.get_barkpark(support.id) == nil
    end

    test "a read PAT is 403'd → the support survives" do
      {user, team, support} = support_in_team("owner")

      {:ok, read_token, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "read-key",
          abilities: ["read"]
        })

      conn = call(:delete, "/v1/fleet/supports/#{support.id}", nil, read_token)

      assert conn.status == 403
      assert decode(conn)["error"] == "forbidden"
      # The credential could not bind, so it could not unbind — row untouched.
      assert Registry.get_barkpark(support.id) != nil
    end

    test "a plain member session is 403'd → the support survives" do
      {member, _team, support} = support_in_team("member")
      {:ok, member_session} = Accounts.create_user_session_token(member)

      conn = call(:delete, "/v1/fleet/supports/#{support.id}", nil, member_session)

      assert conn.status == 403
      assert decode(conn)["error"] == "forbidden"
      assert Registry.get_barkpark(support.id) != nil
    end

    test "an anonymous request is 401'd → the support survives" do
      {_user, _team, support} = support_in_team("owner")

      conn = call(:delete, "/v1/fleet/supports/#{support.id}", nil)

      assert conn.status == 401
      assert Registry.get_barkpark(support.id) != nil
    end
  end

  ## GET /v1/barkparks serialization

  describe "GET /v1/barkparks serializes the fleet fields" do
    test "a support row carries fleet_role / fleet_parent_id / fleet_token_id" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Listed Support",
          slug: "listed-support",
          parent_id: main.id,
          token_id: "tok_listed"
        })

      conn = call(:get, "/v1/barkparks", nil, token)
      assert conn.status == 200

      rows = decode(conn)["barkparks"]
      row = Enum.find(rows, &(&1["id"] == support.id))

      assert row["fleet_role"] == "support"
      assert row["fleet_parent_id"] == main.id
      assert row["fleet_token_id"] == "tok_listed"

      # The main serializes its role too, and carries no parent.
      main_row = Enum.find(rows, &(&1["id"] == main.id))
      assert main_row["fleet_role"] == "main"
      assert main_row["fleet_parent_id"] == nil
    end
  end

  ## POST /v1/fleet/supports mode=provision (PDF-D83 — CP-provisioned add-support)

  defp support_jobs(barkpark_id) do
    Repo.all(from j in ProvisionJob, where: j.barkpark_id == ^barkpark_id)
  end

  describe "POST /v1/fleet/supports mode=provision" do
    test "registers a host-nil support row FIRST, then enqueues one provision_support job → 202" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)

      conn =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Helper", barkpark_id: main.id, mode: "provision"},
          token
        )

      assert conn.status == 202
      body = decode(conn)

      # The row was written FIRST, host NIL (the CP provisioner fills the box in).
      bp = body["barkpark"]
      assert bp["fleet_role"] == "support"
      assert bp["fleet_parent_id"] == main.id
      assert bp["host"] == nil
      assert is_binary(body["job_id"])

      support = Registry.get_barkpark(bp["id"])
      assert support.host == nil
      assert support.fleet_parent_id == main.id

      # EXACTLY one job, kind provision_support, matching the returned job_id.
      jobs = support_jobs(support.id)
      assert length(jobs) == 1
      [job] = jobs
      assert job.kind == "provision_support"
      assert job.status == "pending"
      assert job.id == body["job_id"]
    end

    test "server_type folds onto the support row so the claim carries the size" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)

      conn =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Big Helper", barkpark_id: main.id, mode: "provision", server_type: "cx32"},
          token
        )

      assert conn.status == 202
      support = Registry.get_barkpark(decode(conn)["barkpark"]["id"])
      assert support.server_type == "cx32"
    end

    test "a parent WITHOUT an admin token → 409 no_admin_token, nothing created" do
      {_u, team, token} = user_with_role("owner")
      # Plain main_fixture — no admin token stored.
      main = main_fixture(team)

      conn =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Helper", barkpark_id: main.id, mode: "provision"},
          token
        )

      assert conn.status == 409
      assert decode(conn)["error"] == "no_admin_token"

      # No support row and no job were created (refused at enqueue).
      refute Enum.any?(Registry.list_barkparks(team), &(&1.fleet_role == "support"))
    end

    test "a support as parent → 422 invalid_parent" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Existing",
          slug: "existing",
          parent_id: main.id,
          token_id: "t"
        })

      conn =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Grandchild", barkpark_id: support.id, mode: "provision"},
          token
        )

      assert conn.status == 422
      assert decode(conn)["error"] == "invalid_parent"
    end

    test "a cross-team parent → 404, nothing created" do
      {_u_a, _team_a, token_a} = user_with_role("owner")
      team_b = team_fixture()
      main_b = live_main_fixture(team_b)

      conn =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Sneaky", barkpark_id: main_b.id, mode: "provision"},
          token_a
        )

      assert conn.status == 404
    end

    test "register-only (no mode) is UNCHANGED — 201 and NO job enqueued" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      conn =
        call(:post, "/v1/fleet/supports", %{name: "Plain", parent_id: main.id}, token)

      assert conn.status == 201
      support = Registry.get_barkpark(decode(conn)["barkpark"]["id"])
      assert support_jobs(support.id) == []
    end
  end

  ## POST /v1/fleet/supports quota exemption at the HTTP layer (PDF-D86)

  describe "POST /v1/fleet/supports is quota-exempt" do
    test "at the trial ceiling, add-support still 202s while a 2nd main is blocked" do
      {_u, team, token} = user_with_role("owner")
      {:ok, _sub} = Billing.subscribe(team, "trial")
      # One live main saturates the trial ceiling (1).
      main = live_main_fixture(team)
      assert Billing.barkpark_limit_reached?(team)

      conn =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Helper", barkpark_id: main.id, mode: "provision"},
          token
        )

      assert conn.status == 202
      assert decode(conn)["barkpark"]["fleet_role"] == "support"

      # The main create path is still blocked — the bypass is support-only.
      assert {:error, :limit_reached} =
               Registry.register_barkpark(team, %{name: "second", slug: "second"})
    end
  end

  ## POST /v1/internal/support-jobs/claim (worker-token) — the pinned claim payload

  describe "POST /v1/internal/support-jobs/claim" do
    test "returns claim_json PLUS the pinned support map" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)

      # Enqueue via the real provision-mode route so the support row + job exist.
      created =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Helper Box", barkpark_id: main.id, mode: "provision"},
          token
        )

      job_id = decode(created)["job_id"]

      conn = call(:post, "/v1/internal/support-jobs/claim", %{}, @worker_token)
      assert conn.status == 200
      body = decode(conn)

      # The generic provision claim fields ride along (reused claim_json).
      assert body["job_id"] == job_id
      assert body["name"] == "Helper Box"

      # Full public identity: the top-level slug is the RESERVED url's first
      # label — the DNS record the worker stands up (<label>.barkpark.cloud),
      # no longer the pre-reservation provisioning_subdomain fallback.
      support_row = Registry.get_barkpark(decode(created)["barkpark"]["id"])
      assert support_row.url == "https://helper-box.barkpark.cloud"
      assert body["slug"] == "helper-box"
      assert body["slug"] == Barkpark.subdomain_from_url(support_row)

      # The PINNED support map — the Go slice binds against these exact keys.
      {:ok, expected_admin_token} = Vault.decrypt(main.admin_token_encrypted)
      support = body["support"]
      assert support["parent_url"] == main.url
      assert support["parent_admin_token"] == expected_admin_token
      assert support["dataset"] == "production"
      assert support["workspace"] == "acme"

      # task-314de6aa36248bea: support.name carries the SLUG, never the display
      # name — the Go worker uses it as its DNS-shaped worker identity, and
      # "Helper Box" (space, uppercase) would break it.
      assert support["name"] == "helper-box"
      refute support["name"] == "Helper Box"
    end

    test "a template-less parent (nil bootstrap_workspace) claims workspace \"default\"" do
      {_u, team, token} = user_with_role("owner")

      main =
        live_main_fixture(team)
        |> Ecto.Changeset.change(bootstrap_workspace: nil)
        |> Repo.update!()

      created =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Bare Helper", barkpark_id: main.id, mode: "provision"},
          token
        )

      assert created.status == 202

      conn = call(:post, "/v1/internal/support-jobs/claim", %{}, @worker_token)
      assert conn.status == 200

      # A nil bootstrap_workspace must never reach the Go slug fence as "" —
      # every other consumer of the column defaults it (Registry, bp CLI).
      assert decode(conn)["support"]["workspace"] == "default"
    end

    test "204 when no provision_support job is pending" do
      conn = call(:post, "/v1/internal/support-jobs/claim", %{}, @worker_token)
      assert conn.status == 204
    end

    test "a non-worker token is refused (401)" do
      {_u, _team, token} = user_with_role("owner")
      conn = call(:post, "/v1/internal/support-jobs/claim", %{}, token)
      assert conn.status == 401
    end
  end

  ## The succeed report closes the Open Studio custody chain: url reserved at
  ## register + admin_token stored encrypted at succeed = mint_studio_link has
  ## both halves it needs. The CP side was already role-agnostic
  ## (maybe_put_admin_token) — this pins that a SUPPORT succeed carrying the
  ## box's minted admin token actually lands in custody.

  describe "provision_support succeed carries the box admin token" do
    test "admin_token lands encrypted on the SUPPORT row — reveal works" do
      {_u, team, token} = user_with_role("owner")
      main = live_main_fixture(team)

      created =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Studio Helper", barkpark_id: main.id, mode: "provision"},
          token
        )

      assert created.status == 202
      support_id = decode(created)["barkpark"]["id"]

      claim = call(:post, "/v1/internal/support-jobs/claim", %{}, @worker_token)
      assert claim.status == 200
      body = decode(claim)

      conn =
        call(
          :post,
          "/v1/internal/provision-jobs/#{body["job_id"]}/succeed",
          %{
            ip: "203.0.113.77",
            token_id: "tid-9",
            admin_token: "sup-box-admin-tok",
            claim_token: body["claim_token"]
          },
          @worker_token
        )

      assert conn.status == 200

      support = Registry.get_barkpark(support_id)
      assert support.host == "203.0.113.77"
      assert support.fleet_token_id == "tid-9"
      # The url was reserved at registration and the admin token decrypts —
      # exactly what mint_studio_link/2 reads (no more :not_live 409).
      assert is_binary(support.url) and support.url != ""
      assert {:ok, "sup-box-admin-tok"} = Registry.reveal_admin_token(support)
    end
  end

  ## latest_provision_status_map widens to provision_support (PDF-D85)

  describe "latest_provision_status_map/1 includes provision_support jobs" do
    test "a support job's status/steps/console surface for GET /v1/barkparks" do
      team = team_fixture()
      main = live_main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Statused",
          slug: "statused",
          parent_id: main.id,
          token_id: nil
        })

      {:ok, job} = Registry.enqueue_support_provision_job(support)

      # Give the job a step + console line so the map proves it carries them.
      {:ok, _} =
        job
        |> ProvisionJob.changeset(%{
          steps: [%{"step" => "create", "status" => "done", "at" => "2026-07-24T00:00:00Z"}],
          console: [%{"line" => "creating support box", "at" => "2026-07-24T00:00:00Z"}]
        })
        |> Repo.update()

      map = Registry.latest_provision_status_map([support.id])

      assert %{status: "pending", steps: [step], console: [line]} = map[support.id]
      assert step["step"] == "create"
      assert line["line"] == "creating support box"
    end
  end
end
