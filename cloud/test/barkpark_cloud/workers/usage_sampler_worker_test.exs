defmodule BarkparkCloud.Workers.UsageSamplerWorkerTest do
  @moduledoc """
  cloud-console wave 3 — the `UsageSamplerWorker` tick. Proves it caches one
  `Usage.Sample` row per CHECKABLE instance every tick, over the isu-6
  `StudioLinkFakeHttpClient` seam (the same seam the live `/usage` gather uses):

    * a healthy instance → a row whose envelope carries the REAL fanned counts
      (documents/datasets/webhooks) and whose admin token never lands in the row
    * a DOWN box → a row is STILL written: instance meters degrade to
      "unmetered" (never a fake zero), the control-plane seats meter is real, and
      `measured_at` is a real timestamp
    * only checkable boxes are sampled (host set, not suspended)
    * per-instance isolation: every checkable box gets its own row in one sweep
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient, as: Fake
  alias BarkparkCloud.Usage.Sample
  alias BarkparkCloud.Workers.UsageSamplerWorker

  import Ecto.Query

  @admin_token "instance-admin-token-plaintext-XYZ"

  # A team with ONE member, so the seats meter is a real positive count (never
  # the "unmetered" degrade) — distinguishing an honest control-plane read from a
  # failed one.
  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _} = Accounts.add_member(team, user, "owner")
    team
  end

  # A LIVE checkable instance (host + url + admin token) so the gather fans out
  # over the fake transport. url is per-instance unique (barkparks_url_unique_idx).
  defp live_instance(team, overrides \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          host: "203.0.113.#{rem(n, 250) + 1}",
          url: "https://bp-#{n}.barkpark.cloud",
          admin_token_encrypted: Vault.encrypt(@admin_token)
        },
        overrides
      )
    )
    |> Repo.update!()
  end

  defp ok_json(status, body), do: {:ok, %{status: status, body: body}}

  @ds_path "/api/workspaces/default/projects/default/datasets"
  defp analytics_path(slug), do: "/v1/data/analytics/#{slug}"
  defp webhooks_path(slug), do: "/v1/webhooks/#{slug}"

  # A single-production-dataset healthy instance with the given doc/webhook count.
  defp program_simple(docs, webhooks) do
    Fake.program(%{
      @ds_path => ok_json(200, ~s({"datasets":[{"slug":"production"}]})),
      analytics_path("production") => ok_json(200, Jason.encode!(%{total_documents: docs})),
      webhooks_path("production") =>
        ok_json(200, Jason.encode!(%{webhooks: List.duplicate(%{id: "wh"}, webhooks)}))
    })
  end

  defp samples_for(bp) do
    from(s in Sample, where: s.barkpark_id == ^bp.id) |> Repo.all()
  end

  defp tick, do: perform_job(UsageSamplerWorker, %{})

  test "caches a row with the REAL fanned counts for a healthy instance" do
    team = team_fixture()
    bp = live_instance(team)
    program_simple(137, 3)

    assert tick() == :ok

    assert [sample] = samples_for(bp)
    meters = sample.envelope["meters"]
    assert meters["documents"]["value"] == 137
    assert meters["datasets"]["value"] == 1
    assert meters["webhooks"]["value"] == 3
    assert meters["seats"]["value"] == 1
    assert %DateTime{} = sample.measured_at

    # The admin token never lands in the persisted envelope.
    refute Jason.encode!(sample.envelope) =~ @admin_token
  end

  test "writes a row EVEN for a down box — instance meters unmetered, seats real" do
    team = team_fixture()
    # Checkable (host set) but not live (no url) → nothing to fan out.
    bp = live_instance(team, %{url: nil, admin_token_encrypted: nil})
    Fake.program([])

    assert tick() == :ok

    assert [sample] = samples_for(bp)
    meters = sample.envelope["meters"]
    # Instance-sourced meters degrade honestly, never a fake zero.
    assert meters["documents"]["value"] == "unmetered"
    assert meters["datasets"]["value"] == "unmetered"
    assert meters["webhooks"]["value"] == "unmetered"
    # ...but the control-plane meter is real, and the sample is timestamped.
    assert meters["seats"]["value"] == 1
    assert %DateTime{} = sample.measured_at
    # A not-live box never called upstream.
    assert Fake.requests() == []
  end

  test "does NOT sample a hostless or suspended box" do
    team = team_fixture()
    hostless = live_instance(team, %{host: nil})
    suspended = live_instance(team, %{suspended: true})
    program_simple(1, 1)

    assert tick() == :ok

    assert samples_for(hostless) == []
    assert samples_for(suspended) == []
  end

  test "per-instance isolation: every checkable box gets its own row in one sweep" do
    team = team_fixture()
    a = live_instance(team)
    b = live_instance(team)
    program_simple(2, 0)

    assert tick() == :ok

    assert [_] = samples_for(a)
    assert [_] = samples_for(b)
  end

  test "a degrading box does not sink the sweep — healthy peers are still sampled" do
    team = team_fixture()
    # A live box the fake will serve, and a not-live box that degrades to
    # unmetered inside gather. The per-instance rescue means one box's trouble
    # cannot stop the other from being sampled.
    healthy = live_instance(team)
    down = live_instance(team, %{url: nil, admin_token_encrypted: nil})
    program_simple(9, 0)

    assert tick() == :ok

    assert [healthy_sample] = samples_for(healthy)
    assert healthy_sample.envelope["meters"]["documents"]["value"] == 9

    assert [down_sample] = samples_for(down)
    assert down_sample.envelope["meters"]["documents"]["value"] == "unmetered"
  end

  test "idempotent-ish: a second tick appends a second row (latest wins downstream)" do
    team = team_fixture()
    bp = live_instance(team)
    program_simple(1, 1)

    assert tick() == :ok
    assert tick() == :ok

    assert length(samples_for(bp)) == 2
  end
end
