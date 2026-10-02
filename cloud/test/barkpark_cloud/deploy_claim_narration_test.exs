defmodule BarkparkCloud.DeployClaimNarrationTest do
  @moduledoc """
  dwb-18 — A BUILDER CLAIM NARRATES ITSELF ONTO THE DEPLOYMENT CONSOLE.

  `deployments.console` is the append-only build narration the site-detail deploy
  row renders (`deployment_json/1`'s `console` key → `app.js`'s build console).
  Before this slice it only ever filled from the OUTSIDE — the builder POSTing
  lines through `Registry.append_deployment_console/2`. The transition the
  CONTROL PLANE itself performs, `queued -> building` at claim, wrote nothing.

  So a container deploy minted by a GitHub push and then claimed by a builder
  showed an empty console panel beside a spinning pill for the whole gap between
  the claim and the builder's first line: the silent spinner dwb-18 names.

  Both container claim paths are covered — `claim_next_deployment/1` (fleet-wide)
  and `claim_queued_deployment_for_barkpark/2` (box-scoped) — because the wording
  is shared and a drift between them is exactly the failure a single-path test
  would not see.

  THE CONTROL is the static driver's claim, `claim_deployment/2`. It is NOT
  narrated here on purpose: a static deploy is driven by `Sites.Deploy`, which
  appends its OWN six-stage console entries through `console_entry/1`, so a
  second entry written at claim would double-narrate the same moment. The control
  is what keeps this slice from quietly spreading into the pipeline that already
  narrates.

  Every assertion reads a row by the id this test created — never a table-wide
  query — so a peer agent's rows in the shared test database cannot colour the
  result. `async: true` is safe: every write is inside this test's Sandbox
  transaction.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment

  defp setup_site(kind) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    attrs = %{name: "S #{n}", slug: "s-#{n}", kind: kind}
    attrs = if kind == "static", do: Map.put(attrs, :framework, "static"), else: attrs

    {:ok, site} = Registry.create_site(bp, attrs)

    {bp, site}
  end

  defp queued(site) do
    {:ok, d} = Registry.create_deployment(site, %{artifact_url: "https://example.test/a.tar.gz"})
    d
  end

  defp lines(%Deployment{console: console}) do
    Enum.map(console || [], &Map.get(&1, "line"))
  end

  describe "container claim narration (the arm)" do
    test "claim_next_deployment/1 appends ONE control-plane entry naming the worker" do
      {_bp, site} = setup_site("container")
      d = queued(site)
      assert d.console in [nil, []]

      {:ok, returned} = Registry.claim_next_deployment("builder-alpha")
      assert returned.id == d.id
      claimed = Repo.get!(Deployment, d.id)

      assert claimed.status == "building"
      assert claimed.claim_worker == "builder-alpha"

      # The ARM: revert `console: narrate_transition(...)` in
      # `claim_next_deployment/1` and this is [] — the silent-spinner state.
      assert [entry] = claimed.console
      assert entry["line"] =~ "claimed by builder builder-alpha"
      assert entry["source"] == "control-plane"

      # The timestamp is the SERVER clock, not a worker's, and parses.
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(entry["at"])
    end

    test "claim_queued_deployment_for_barkpark/2 narrates the same wording" do
      {bp, site} = setup_site("container")
      d = queued(site)

      {:ok, b} = Registry.claim_queued_deployment_for_barkpark(bp, "builder-beta")
      assert b.id == d.id
      claimed = Repo.get!(Deployment, d.id)

      assert [entry] = claimed.console
      assert entry["line"] =~ "claimed by builder builder-beta"
      assert entry["source"] == "control-plane"
    end

    test "the claim entry is APPENDED after lines the builder already reported" do
      {_bp, site} = setup_site("container")
      d = queued(site)

      {:ok, _} = Registry.append_deployment_console(d.id, "an earlier line")
      {:ok, g} = Registry.claim_next_deployment("builder-gamma")
      assert g.id == d.id

      assert ["an earlier line", claim_line] = lines(Repo.get!(Deployment, d.id))
      assert claim_line =~ "claimed by builder builder-gamma"
    end

    test "the array stays BOUNDED — a console already at the cap does not grow" do
      {_bp, site} = setup_site("container")
      d = queued(site)

      # Fill past the cap so the claim's append must drop, not grow.
      filled =
        Enum.map(1..400, fn i ->
          %{"line" => "filler #{i}", "at" => DateTime.to_iso8601(DateTime.utc_now())}
        end)

      {:ok, _} =
        d
        |> Deployment.transition_changeset(%{console: filled})
        |> Repo.update()

      {:ok, dl} = Registry.claim_next_deployment("builder-delta")
      assert dl.id == d.id
      claimed = Repo.get!(Deployment, d.id)

      # Bounded: never more than the pre-claim length, and the claim line is last.
      assert length(claimed.console) <= 400
      assert List.last(lines(claimed)) =~ "claimed by builder builder-delta"
      # The drop discloses itself rather than silently shortening the record.
      assert is_integer(hd(claimed.console)["dropped_before"])
    end
  end

  describe "the control" do
    test "the STATIC driver's claim stays UNnarrated (Sites.Deploy owns that console)" do
      {_bp, site} = setup_site("static")
      d = queued(site)

      {:ok, _} = Registry.claim_deployment(d.id, "static-driver")
      claimed = Repo.get!(Deployment, d.id)

      assert claimed.status == "building"
      assert claimed.stage == "PLAN"

      # QUIET: if this ever reds, the container-claim narration has spread into
      # the pipeline that already writes its own six-stage entries.
      assert claimed.console in [nil, []]
    end
  end
end
