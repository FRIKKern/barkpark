defmodule BarkparkCloud.Sites.ArtifactReaperTest do
  @moduledoc """
  ssw9-bl-artifact-retention-quota, criteria 0 and 2.

  ## What is measured, and where

  EVERY assertion below reads STORED STATE — `Repo.get(SiteArtifact, id)` or a
  `Repo.aggregate` over the table — never the reaper's return value. A reaper
  that returned `{:ok, %{rows: 1}}` and deleted nothing would pass a
  return-value test and fail every test in this file. The summary is asserted
  only where it is the SUBJECT (the byte total it reports), and never as the
  proof that a row went away.

  ## The terminal-path set, and how it was derived

  Not from the call sites and not from prose: from
  `Registry.Deployment.transitions/0`, the legal from → to graph the schema
  already publishes. A status is TERMINAL iff its outgoing edge list is empty.
  Today that is `cancelled failed live deferred`; the first test pins the
  derivation itself, so adding a fifth terminal status to the graph without
  teaching the reaper about it is impossible — the reaper reads the same
  function.

  `Sites.Deploy` drops artifacts on exactly two of those four, and only from
  INSIDE the deploy driver (`settled_live/1`, `fail/…`). The abandoned-mint test
  below runs the REAL `Workers.StaleDeploymentReaper` over an uploaded-then-
  abandoned row: that reaper terminates the row with a bulk `Repo.update_all`,
  which no in-driver `drop_artifact/1` can observe — the leak this sweep exists
  to close.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, Registry, Repo, Sites}
  alias BarkparkCloud.Registry.{Deployment, SiteArtifact}
  alias BarkparkCloud.Sites.ArtifactReaper
  alias BarkparkCloud.Workers.StaleDeploymentReaper

  ## Fixtures

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp site_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{
          name: "S #{n}",
          slug: "s-#{n}",
          kind: "static",
          framework: "astro",
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production"
        })
      )

    {:ok, site} = Registry.update_site_settings(site, %{prebuilt_enabled: true})
    site
  end

  defp deployment_fixture(site, attrs \\ %{}) do
    {:ok, d} =
      Registry.create_deployment(site, Enum.into(attrs, %{trigger: "manual", source: "prebuilt"}))

    d
  end

  # An artifact bound to `deployment`, stored through the SAME writer the upload
  # route uses — so this test can never pass over a shape the route never mints.
  defp store(deployment, bytes) do
    sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    {:ok, _stamped} = Sites.Deploy.store_artifact(deployment, bytes, sha)
    Repo.one!(from(a in SiteArtifact, where: a.deployment_id == ^deployment.id))
  end

  # Force a status WITHOUT going through the driver — which is the whole point:
  # the driver is exactly what is missing on the paths this sweep covers.
  defp force_status(deployment, status) do
    Repo.update_all(
      from(d in Deployment, where: d.id == ^deployment.id),
      set: [status: status]
    )

    Repo.get!(Deployment, deployment.id)
  end

  defp age_row(deployment, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    Repo.update_all(
      from(d in Deployment, where: d.id == ^deployment.id),
      set: [inserted_at: at, updated_at: at]
    )
  end

  ## The derivation

  describe "terminal_statuses/0" do
    test "is DERIVED from the transition graph, not enumerated" do
      derived =
        Deployment.transitions()
        |> Enum.filter(fn {_status, outgoing} -> outgoing == [] end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert ArtifactReaper.terminal_statuses() == derived

      # And the graph today really does have four sinks. If this line ever needs
      # editing, the reaper has ALREADY followed the graph — that is the design.
      assert derived == ~w(cancelled deferred failed live)
    end
  end

  ## Criterion 0 — every terminal path

  describe "reap/0 on each terminal status" do
    for status <- ~w(live failed cancelled deferred) do
      test "deletes the stored artifact of a #{status} deployment", %{} do
        status = unquote(status)
        site = site_fixture(team_fixture())
        d = deployment_fixture(site)
        artifact = store(d, "bytes-for-#{status}")

        # PRECONDITION, asserted rather than assumed: the row is really there
        # before the sweep, so a green cannot come from a store that failed.
        assert Repo.get(SiteArtifact, artifact.id)

        force_status(d, status)
        {:ok, summary} = ArtifactReaper.reap()

        # THE MEASUREMENT IS THE STORE. Not `summary.rows`.
        assert Repo.get(SiteArtifact, artifact.id) == nil
        assert summary.bytes >= byte_size("bytes-for-#{status}")
      end
    end

    test "leaves an IN-FLIGHT deployment's artifact alone (the control)" do
      site = site_fixture(team_fixture())
      d = deployment_fixture(site)
      artifact = store(d, "still-deploying")

      # `queued` has outgoing edges — not terminal, the box may still need these
      # bytes. A sweep that deleted this would break every prebuilt deploy.
      assert d.status == "queued"
      {:ok, _} = ArtifactReaper.reap()

      assert Repo.get(SiteArtifact, artifact.id).bytes == "still-deploying"
    end
  end

  ## Criterion 0 — the case the in-driver drops structurally cannot reach

  describe "a deployment that is minted, uploaded and then ABANDONED" do
    test "the stale-deployment reaper terminates it and its bytes are reaped" do
      site = site_fixture(team_fixture())
      d = deployment_fixture(site)
      artifact = store(d, String.duplicate("z", 4096))

      # The shape pass (0c) owns: `queued`, never claimed, past the spawn budget,
      # and NOT awaiting its upload (the digest is stamped, so the bytes landed).
      assert Repo.get!(Deployment, d.id).artifact_sha256
      age_row(d, 30 * 24 * 60 * 60)

      # The REAL reaper, not a stand-in. Its writes are bulk `Repo.update_all`s —
      # no `Sites.Deploy.drop_artifact/1` runs anywhere on this path.
      assert {:ok, _counts} = perform_job(StaleDeploymentReaper, %{})
      assert Repo.get!(Deployment, d.id).status == "failed"

      # THE LEAK, before the sweep: terminal row, bytes still on cloud_pgdata.
      assert Repo.get(SiteArtifact, artifact.id)

      {:ok, _} = ArtifactReaper.reap()
      assert Repo.get(SiteArtifact, artifact.id) == nil
    end
  end

  ## The orphan arm — rows the retired site-scoped route left behind

  describe "artifacts bound to NO deployment" do
    test "an aged orphan is reaped; a fresh one is not" do
      site = site_fixture(team_fixture())

      insert_orphan = fn bytes, age_seconds ->
        at = DateTime.add(DateTime.utc_now(), -age_seconds, :second)

        Repo.insert!(%SiteArtifact{
          site_id: site.id,
          deployment_id: nil,
          sha256: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
          byte_size: byte_size(bytes),
          bytes: bytes,
          inserted_at: at,
          updated_at: at
        })
      end

      old = insert_orphan.("legacy", 2 * 24 * 60 * 60)
      fresh = insert_orphan.("just-now", 60)

      {:ok, _} = ArtifactReaper.reap()

      assert Repo.get(SiteArtifact, old.id) == nil
      assert Repo.get(SiteArtifact, fresh.id)
    end
  end

  ## Criterion 2 — the Oban entry point deletes too

  describe "perform/1" do
    test "the cron job itself deletes the row (measured on the store)" do
      site = site_fixture(team_fixture())
      d = deployment_fixture(site)
      artifact = store(d, "cron-path")
      force_status(d, "failed")

      assert :ok = perform_job(ArtifactReaper, %{})
      assert Repo.get(SiteArtifact, artifact.id) == nil
    end
  end
end
