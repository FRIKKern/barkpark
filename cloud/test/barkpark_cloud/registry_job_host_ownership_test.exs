defmodule BarkparkCloud.RegistryJobHostOwnershipTest do
  @moduledoc """
  task-0cf611238d4ad597 CQ7c (owner ruling #36): the jobs that SSH to a
  barkpark's host as root re-check host ownership when the worker claims them.

  `POST /v1/fleet/supports` refuses a host another team has ALREADY recorded
  (#21131), but only at registration. A host can still end up pointing at
  someone else's box later: the row's host changes, the row changes team, or
  another team's barkpark records the same address after this one did. The
  agent-key, attach-domain and enable-apply jobs used to run regardless. Now the
  claim fails such a job with the reason and hands the worker the next one.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{AgentKeyStash, Barkpark, ProvisionJob}

  @kinds [
    {"push_agent_key", &Registry.enqueue_agent_key_push_job/1,
     &Registry.claim_next_agent_key_job/1},
    {"attach_domain", &Registry.enqueue_attach_domain_job/1,
     &Registry.claim_next_attach_domain_job/1},
    {"enable_apply", &Registry.enqueue_enable_apply_job/1,
     &Registry.claim_next_enable_apply_job/1}
  ]

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_barkpark(team, host) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp |> Ecto.Changeset.change(host: host) |> Repo.update!()
  end

  # A distinct IPv4 per call, so tests never share a host by accident.
  defp host do
    n = System.unique_integer([:positive])
    "10.#{rem(div(n, 65_536), 256)}.#{rem(div(n, 256), 256)}.#{rem(n, 256)}"
  end

  defp claim_token, do: "claim-#{System.unique_integer([:positive])}"

  for {kind, enqueue, claim} <- @kinds do
    describe "#{kind} claim" do
      @enqueue enqueue
      @claim claim

      test "LEGIT: an unchanged row on its own host is claimed, with the snapshot recorded" do
        team = team_fixture()
        h = host()
        bp = live_barkpark(team, h)

        {:ok, job} = @enqueue.(bp)
        assert job.enqueued_team_id == team.id
        assert job.enqueued_host == h

        assert {%ProvisionJob{id: id, status: "claimed"}, %Barkpark{id: bp_id}} =
                 @claim.(claim_token())

        assert id == job.id
        assert bp_id == bp.id
      end

      test "LEGIT: a host shared with a sibling row of the SAME team is still claimed" do
        team = team_fixture()
        h = host()
        bp = live_barkpark(team, h)
        _sibling = live_barkpark(team, h)

        {:ok, job} = @enqueue.(bp)
        assert {%ProvisionJob{id: id}, _} = @claim.(claim_token())
        assert id == job.id
      end

      test "HOLE: the row's host changed after enqueue → failed, never handed out" do
        team = team_fixture()
        bp = live_barkpark(team, host())
        {:ok, job} = @enqueue.(bp)

        bp |> Ecto.Changeset.change(host: host()) |> Repo.update!()

        assert @claim.(claim_token()) == nil
        failed = Repo.get!(ProvisionJob, job.id)
        assert failed.status == "failed"
        assert failed.error =~ "host changed"
        assert is_nil(failed.claim_token)
      end

      test "HOLE: the row moved to another team after enqueue → failed" do
        team = team_fixture()
        bp = live_barkpark(team, host())
        {:ok, job} = @enqueue.(bp)

        bp |> Ecto.Changeset.change(team_id: team_fixture().id) |> Repo.update!()

        assert @claim.(claim_token()) == nil
        failed = Repo.get!(ProvisionJob, job.id)
        assert failed.status == "failed"
        assert failed.error =~ "another team"
      end

      test "HOLE: another team's barkpark now records the same host → failed" do
        h = host()
        bp = live_barkpark(team_fixture(), h)
        {:ok, job} = @enqueue.(bp)

        _victim = live_barkpark(team_fixture(), h)

        assert @claim.(claim_token()) == nil
        failed = Repo.get!(ProvisionJob, job.id)
        assert failed.status == "failed"
        assert failed.error =~ "recorded on another team's barkpark"
      end

      test "a refused job does not block the next claimable one" do
        h = host()
        refused_bp = live_barkpark(team_fixture(), h)
        {:ok, refused} = @enqueue.(refused_bp)
        _victim = live_barkpark(team_fixture(), h)

        good_bp = live_barkpark(team_fixture(), host())
        {:ok, good} = @enqueue.(good_bp)

        assert {%ProvisionJob{id: id}, _} = @claim.(claim_token())
        assert id == good.id
        assert Repo.get!(ProvisionJob, refused.id).status == "failed"
      end

      test "TOLERANT: a job enqueued before the snapshot columns runs the live check only" do
        team = team_fixture()
        h = host()
        bp = live_barkpark(team, h)

        legacy =
          Repo.insert!(%ProvisionJob{barkpark_id: bp.id, kind: unquote(kind), status: "pending"})

        assert is_nil(legacy.enqueued_team_id) and is_nil(legacy.enqueued_host)
        assert {%ProvisionJob{id: id}, _} = @claim.(claim_token())
        assert id == legacy.id

        # …and the live other-team check still applies to such a row.
        h2 = host()
        bp2 = live_barkpark(team_fixture(), h2)

        legacy2 =
          Repo.insert!(%ProvisionJob{barkpark_id: bp2.id, kind: unquote(kind), status: "pending"})

        _victim = live_barkpark(team_fixture(), h2)
        assert @claim.(claim_token()) == nil
        assert Repo.get!(ProvisionJob, legacy2.id).status == "failed"
      end
    end
  end

  test "a refused key push drops its stashed key instead of keeping it for the TTL" do
    h = host()
    bp = live_barkpark(team_fixture(), h)
    {:ok, job} = Registry.enqueue_agent_key_push_job(bp)
    :ok = AgentKeyStash.put(job.id, "ANTHROPIC_API_KEY", "sk-test-not-real")

    _victim = live_barkpark(team_fixture(), h)

    assert Registry.claim_next_agent_key_job(claim_token()) == nil
    assert AgentKeyStash.take(job.id) == :error
  end

  test "kinds that do not SSH to the host are not re-checked" do
    refute "provision" in Registry.ownership_checked_kinds()
    refute "deprovision" in Registry.ownership_checked_kinds()

    assert Enum.sort(Registry.ownership_checked_kinds()) ==
             Enum.sort(Enum.map(@kinds, &elem(&1, 0)))
  end
end
