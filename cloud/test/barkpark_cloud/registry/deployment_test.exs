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

    test "status enum is unchanged — the six visible stages do NOT widen it" do
      # STAGE telemetry (PLAN/BUILD/STAGE/HEALTH/SWITCH/RETIRE) rides the nullable
      # `stage` column, never the coarse status lifecycle.
      assert Deployment.statuses() == ~w(queued building pushing live failed cancelled)
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

  test "two build_id-less deployments coexist (the partial index exempts NULLs)" do
    site = site_fixture()

    {:ok, _} = Registry.create_deployment(site, %{git_ref: "sha1"})
    # A second container-style deployment with no build_id must NOT collide.
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
