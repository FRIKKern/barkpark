defmodule BarkparkCloud.Registry.DeploymentTest do
  @moduledoc """
  Pure, no-DB unit test over the Deployment status transition graph — the
  from-status legality the fenced writers enforce before `Repo.update`.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.Deployment

  describe "legal_transition?/2" do
    test "accepts every edge in the transition graph" do
      for {from, tos} <- Deployment.transitions(), to <- tos do
        assert Deployment.legal_transition?(from, to),
               "expected #{from} → #{to} to be legal"
      end
    end

    test "accepts a same-status write for every status (field-only updates)" do
      for status <- Deployment.statuses() do
        assert Deployment.legal_transition?(status, status)
      end
    end

    test "rejects resurrecting or skipping edges" do
      refute Deployment.legal_transition?("failed", "live")
      refute Deployment.legal_transition?("live", "building")
      refute Deployment.legal_transition?("cancelled", "pushing")
      refute Deployment.legal_transition?("queued", "live")
      refute Deployment.legal_transition?("queued", "pushing")
      refute Deployment.legal_transition?("building", "live")
    end

    test "terminal statuses have no outgoing (non-self) edges" do
      for terminal <- ~w(live failed cancelled) do
        assert Deployment.transitions()[terminal] == []

        for to <- Deployment.statuses(), to != terminal do
          refute Deployment.legal_transition?(terminal, to),
                 "expected terminal #{terminal} → #{to} to be illegal"
        end
      end
    end
  end

  # site-spawner W1 (charter D3): the content-bound static-build fields ride the
  # EXISTING deployment substrate — build_id + content_rev on create, stage on
  # the builder's transition, and the coarse status enum is NOT widened.
  describe "W1 static-build changeset fields" do
    @site_id "33333333-3333-3333-3333-333333333333"

    test "the six visible STAGES do NOT widen the status enum (only a real outcome does)" do
      # STAGE telemetry (PLAN/BUILD/STAGE/HEALTH/SWITCH/RETIRE) rides the nullable
      # `stage` column, never the coarse status lifecycle.
      #
      # deploy-truth W1 (charter D9) adds exactly ONE status, and it is an
      # OUTCOME, not a stage: `deferred` — the box was busy, this build did not
      # happen, and a rebuild has been re-queued. It exists because writing that
      # `failed` was the fleet's largest failure class (8,830 of 17,171 failed
      # rows) and made a transient refusal indistinguishable from a broken build.
      assert Deployment.statuses() ==
               ~w(queued building pushing live failed cancelled deferred)

      refute Enum.any?(Deployment.statuses(), &(&1 in BarkparkCloud.Sites.Deploy.stages()))
    end

    test "changeset casts build_id and content_rev on create" do
      cs =
        Deployment.changeset(%Deployment{}, %{
          site_id: @site_id,
          build_id: "b_abc123",
          content_rev: "rev_42"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :build_id) == "b_abc123"
      assert Ecto.Changeset.get_change(cs, :content_rev) == "rev_42"
    end

    test "the create changeset registers the (site_id, build_id) uniqueness constraint" do
      cs =
        Deployment.changeset(%Deployment{}, %{site_id: @site_id, build_id: "b_dup"})

      assert Enum.any?(cs.constraints, fn c ->
               c.constraint == "deployments_site_build_id_index"
             end),
             "expected the site+build_id unique constraint to be declared"
    end

    test "transition_changeset casts stage telemetry" do
      cs =
        Deployment.transition_changeset(%Deployment{}, %{status: "building", stage: "BUILD"})

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :stage) == "BUILD"
    end
  end
end

defmodule BarkparkCloud.Registry.DeploymentPersistenceTest do
  @moduledoc """
  site-spawner W1: the DB backstops for the static-build deployment fields —
  a duplicate (site_id, build_id) is REJECTED (PLAN idempotency), and a stage
  telemetry write persists across a reload.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment

  defp site_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    {:ok, site} =
      Registry.create_site(bp, %{name: "Site #{n}", slug: "site-#{n}", framework: "nextjs"})

    site
  end

  test "a duplicate (site_id, build_id) is rejected" do
    site = site_fixture()

    {:ok, _first} = Registry.create_deployment(site, %{build_id: "b_same", content_rev: "r1"})

    assert {:error, cs} =
             Registry.create_deployment(site, %{build_id: "b_same", content_rev: "r2"})

    assert %{build_id: [_ | _]} = errors_on(cs)
  end

  test "the same build_id on a DIFFERENT site is allowed (uniqueness is per-site)" do
    site_a = site_fixture()
    site_b = site_fixture()

    {:ok, _} = Registry.create_deployment(site_a, %{build_id: "b_shared"})
    assert {:ok, _} = Registry.create_deployment(site_b, %{build_id: "b_shared"})
  end

  # deploy-truth W1 (charter D10): this used to assert that two build_id-less
  # deployments COEXIST. They did — and that is precisely the hole the re-key
  # closed: the active index keyed on `git_ref` (NULL on 26,395 of 26,423
  # production rows), so two builds for one site were always allowed to race and
  # the box answered the second one 409. Two build_id-less rows still coexist
  # across the site's HISTORY; what is refused is two of them ACTIVE at once.
  test "two build_id-less deployments coexist across history, but never two ACTIVE at once" do
    site = site_fixture()

    {:ok, first} = Registry.create_deployment(site, %{git_ref: "sha1"})

    assert {:error, cs} = Registry.create_deployment(site, %{git_ref: "sha2"})
    assert {"is blocked — a build for this site is already in progress", _} = cs.errors[:git_ref]

    # Once the first build is settled the slot is free — the build_id partial
    # index still exempts NULLs, so a second build_id-less row inserts fine.
    {:ok, _} = Registry.transition_deployment(first, %{status: "failed"})
    assert {:ok, _} = Registry.create_deployment(site, %{git_ref: "sha2"})
  end

  test "a stage telemetry write persists across a reload" do
    site = site_fixture()
    {:ok, dep} = Registry.create_deployment(site, %{build_id: "b_stage"})
    assert dep.stage == nil

    {:ok, updated} =
      dep
      |> Deployment.transition_changeset(%{status: "building", stage: "HEALTH"})
      |> Repo.update()

    reloaded = Repo.get!(Deployment, updated.id)
    assert reloaded.stage == "HEALTH"
    assert reloaded.status == "building"
  end
end
