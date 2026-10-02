defmodule BarkparkCloud.SitesDeployConsoleCapTest do
  @moduledoc """
  dwb-18 — THE SITES-DEPLOY STAGE WRITER WAS THE ONE CONSOLE WRITER WITH NO CAP.

  `deployments.console` has four writers. Three route through the canonical ring
  `Registry.cap_console/1`, which keeps the last `@max_console_lines` entries and
  DISCLOSES the drop on the oldest survivor as `"dropped_before"`. The fourth —
  `Sites.Deploy.record_stage/2`, which writes `console` inside the same fenced
  CAS as the stage transition — did not, on the recorded argument that its bound
  held by ARITHMETIC: at most one entry per {stage, status}, so eighteen entries
  against a cap of 300.

  The arithmetic is about what THIS writer appends, not about what the row
  already holds. A container-era or builder-relayed console arrives at the
  static driver already at the cap, and `(deployment.console || []) ++ [entry]`
  then pushed the row PAST it, silently — the array grew unbounded and the
  `dropped_before` disclosure was never written, so a console that had dropped
  its head became indistinguishable from a complete one. That is the exact
  defect class the cap exists to remove.

  Both arms below drive the REAL six-stage walk through `Sites.Deploy.run/1`
  against real Postgres rows; only the console the row starts from differs.

    * THE RED ARM — a row seeded AT the cap. Reverting
      `console: Registry.cap_console(...)` in `record_stage/2` back to the bare
      `++` reds `overflows`: the array lands at 306 and no entry carries
      `dropped_before`.
    * THE QUIET ARM — an ordinary deploy, far under the cap. It must stay green
      either way: nothing is dropped, no `dropped_before` key is written, and the
      six stages are still there in order. A cap that quietly truncated a normal
      narration would pass the red arm and be a worse bug than the one fixed.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.{Deployment, Vault}
  alias BarkparkCloud.Sites.Deploy
  alias BarkparkCloud.Sites.FakeBoxRelay

  @instance_url "https://acme.barkpark.cloud"

  ## Fixtures

  defp live_barkpark do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp setup_site do
    bp = live_barkpark()
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_public_read_xyz"
      })

    {bp, site}
  end

  # The cap is READ from the canonical writer rather than restated: append n+1
  # lines through `append_deployment_console/2` (which caps) and the array's own
  # length IS `@max_console_lines`. A test that hard-coded 300 would go quietly
  # vacuous the day the module constant moved.
  defp derived_cap(deployment) do
    Enum.reduce(1..301, deployment, fn i, dep ->
      {:ok, updated} = Registry.append_deployment_console(dep.id, "builder line #{i}")
      updated
    end)
    |> Map.fetch!(:console)
    |> length()
  end

  defp drive_full_walk(site, deployment) do
    FakeBoxRelay.program(
      polls: [FakeBoxRelay.walk(Deploy.stages(), url: "#{@instance_url}/sites/#{site.slug}/")]
    )

    assert {:ok, :live} = Deploy.run(deployment.id)
    Repo.get(Deployment, deployment.id)
  end

  defp dropped_before(console), do: Enum.filter(console, &Map.has_key?(&1, "dropped_before"))

  describe "the stage writer goes through the canonical cap" do
    test "a console already AT the cap stays capped, and the drop is disclosed" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      cap = derived_cap(d)
      assert cap > 0, "the canonical cap must be a real bound, read #{cap}"

      primed = Repo.get(Deployment, d.id)

      # THE PRECONDITION, asserted rather than assumed: the row really starts at
      # the cap. Without this the walk below would be under the bound and both
      # assertions would pass for the wrong reason.
      assert length(primed.console) == cap
      assert [%{"dropped_before" => primed_count}] = dropped_before(primed.console)

      final = drive_full_walk(site, primed)

      assert length(final.console) == cap,
             "six stages appended onto a full console must not push it past #{cap}, got #{length(final.console)}"

      # The head was dropped and SAYS so — a reader can tell this narration is a
      # tail. The count is cumulative, so it grew by the six stages appended.
      assert [%{"dropped_before" => count}] = dropped_before(final.console)
      assert count == primed_count + 6

      # Ordered and complete at the tail: the six stages this walk wrote are the
      # newest entries, in walk order.
      tail = final.console |> Enum.take(-6) |> Enum.map(& &1["stage"])
      assert tail == Deploy.stages()
    end

    test "an ordinary deploy is untouched — nothing dropped, no disclosure key" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      assert (d.console || []) == []

      final = drive_full_walk(site, d)

      assert Enum.map(final.console, & &1["stage"]) == Deploy.stages()

      assert dropped_before(final.console) == [],
             "a narration far under the cap must carry no drop disclosure"
    end
  end
end
