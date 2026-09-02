defmodule BarkparkCloud.SitesDeploySlotTruthTest do
  @moduledoc """
  site-spawner (node slot truth): the deployment row learns WHICH SLOT is
  serving it, WHICH PORT that slot answers on, and WHETHER its health gate ran.

  Two laws are under test, and both are load-bearing:

  ## 1. `health_exit_code` is NULLABLE end to end, and 0 is never invented

  A non-nullable integer cannot tell "the HEALTH stage never ran" from "it ran
  and exited 0" — and 0 IS SUCCESS, so the missing measurement renders as a
  pass. Every arm below therefore asserts the DISTINCTION, not merely a value: a
  box report with no health key leaves the column nil (and the serializer emits
  nil), a report that measured 0 stores 0, and a report that measured 14 stores
  14 ON A FAILED ROW — which is the row that needs it most, because
  `health_exit_code: 14` is how a reader tells "the gate caught it" from "it
  fell over somewhere else and nobody gated anything".

  ## 2. `slot` is the SERVED slot, never the intended one

  The box reports the port it read BACK out of its own Caddyfile after the flip.
  The control plane NAMES that port against the site's own `port_base` (charter
  D68: blue = base, green = base + 1), falling back to the box's own measured
  `a`/`b` token when the box is running a pair this control plane did not
  allocate — which is every real box today, because nothing in `api/` reads the
  `target_port` key `deploy_payload/4` sends. Both grounds are measurements of
  the upstream Caddy was FOUND on; neither is intent.

  The proof that this is state and not intent is the second test: the box
  reports the port of the slot the control plane did NOT target, and the row
  says what the box measured.

  And when the box could not place the served port at all — the D345
  prefix-sibling shape, where its marker-anchored read landed in another site's
  block, so `active_slot()` printed nothing — `slot` is nil while `port` stands.
  "We do not know which half" is a different sentence from "we did not look",
  and inventing a slot there is exactly the intent-wearing-state failure this
  row exists to close.
  """

  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.{Deployment, Vault}
  alias BarkparkCloud.Sites.Deploy
  alias BarkparkCloud.Sites.FakeBoxRelay

  @instance_url "https://acme.barkpark.cloud"

  # blue = port_base (even), green = port_base + 1 (charter D68).
  @port_base 7042
  @blue @port_base
  @green @port_base + 1

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

  # A node site with an ALLOCATED slot pair. `port_base` is set by the create
  # ROUTE in production (`Sites.NodePortAllocator.allocate/0`); stamped directly
  # here so this file tests the capture, not the allocator.
  defp node_site(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{
          name: "SSR #{n}",
          slug: "ssr-#{n}",
          kind: "node",
          framework: "nextjs",
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production",
          read_token: "bpt_public_read_xyz"
        })
      )

    site
    |> Ecto.Changeset.change(port_base: Map.get(attrs, :port_base, @port_base))
    |> Repo.update!()
  end

  # A box report: the six stages, plus whatever measurements this box chose to
  # send. `extra` is merged RAW so a test can withhold a key entirely — which is
  # the case that matters, since an absent key and a measured zero are the two
  # sentences this file exists to keep apart.
  defp succeeded(extra \\ %{}) do
    {:ok, 200, body} = FakeBoxRelay.walk(Deploy.stages())
    {:ok, 200, Map.merge(body, extra)}
  end

  defp failed_at_health(extra) do
    {:ok, 200, body} = FakeBoxRelay.failed_at("HEALTH", "bp-doc-id marker is empty")
    {:ok, 200, Map.merge(body, extra)}
  end

  describe "the served slot is captured from the box's own Caddy read" do
    test "a live node deploy records the SERVED port and names its slot off port_base" do
      bp = live_barkpark()
      site = node_site(bp)
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        polls: [
          succeeded(%{"served_port" => @green, "served_slot" => "b", "health_exit_code" => 0})
        ]
      )

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.port == @green
      assert final.slot == "green"
      assert final.health_exit_code == 0
    end

    test "the row says what the box MEASURED, not what the control plane targeted" do
      bp = live_barkpark()
      # `sites.port` is the currently-live serving port, so
      # `NodePortAllocator.target_slot_port/1` targets the OTHER slot (green).
      site = node_site(bp) |> Ecto.Changeset.change(port: @blue) |> Repo.update!()

      assert BarkparkCloud.Sites.NodePortAllocator.target_slot_port(site) == @green,
             "fixture guard: this test is only meaningful when intent and measurement DIFFER"

      {:ok, d} = Deploy.enqueue(site, bp)

      # The box says BLUE is what Caddy ended up serving — a flip that did not
      # take, or a rollback that beat this build to the upstream. Intent said
      # green. The row must say blue.
      FakeBoxRelay.program(polls: [succeeded(%{"served_port" => @blue, "served_slot" => "a"})])

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.port == @blue
      assert final.slot == "blue"
    end

    test "a port outside our allocation still names the slot from the box's OWN measured token" do
      bp = live_barkpark()
      site = node_site(bp)
      {:ok, d} = Deploy.enqueue(site, bp)

      # TODAY'S REAL BOX. Nothing in `api/` reads the `target_port` key
      # `deploy_payload/4` sends and no caller sets SITE_PORT_A/SITE_PORT_B, so
      # the engine runs on its own deterministic per-slug pair in the 8300
      # window while `sites.port_base` names one in [7002, 7998]. The port
      # therefore matches neither allocated slot — and `active_slot()` still
      # MEASURED which of the box's two slots that port is, so the field is
      # named from that rather than left permanently null.
      FakeBoxRelay.program(polls: [succeeded(%{"served_port" => 8342, "served_slot" => "b"})])

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.port == 8342
      assert final.slot == "green"
    end

    test "a port the box could not place AT ALL leaves `slot` nil and `port` standing" do
      bp = live_barkpark()
      site = node_site(bp)
      {:ok, d} = Deploy.enqueue(site, bp)

      # The D345 prefix-sibling shape: the box's marker-anchored read landed in
      # another site's block, so `active_slot()` matched neither of its own two
      # ports and printed nothing — the engine says `slot=none`. Neither ground
      # for naming a slot holds, and nothing is invented.
      FakeBoxRelay.program(polls: [succeeded(%{"served_port" => 8506})])

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.port == 8506
      refute final.slot, "an unplaceable port must not be NAMED as a slot — that is a guess"
    end

    test "a box that reports no slot at all (every static deploy) writes neither column" do
      bp = live_barkpark()
      site = node_site(bp)
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(polls: [succeeded()])

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      refute final.port
      refute final.slot
    end
  end

  describe "health_exit_code — nullable, and 0 is never invented" do
    test "a report with NO health key leaves the column nil, even on a live row" do
      bp = live_barkpark()
      site = node_site(bp)
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(polls: [succeeded(%{"served_port" => @blue})])

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)

      refute final.health_exit_code,
             "a box that measured no health code must leave the column NIL — a 0 here " <>
               "would certify a health gate that never ran, because 0 is the SUCCESS code"
    end

    test "a measured 0 is STORED as 0, and is therefore distinguishable from nil" do
      bp = live_barkpark()
      site = node_site(bp)
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(polls: [succeeded(%{"health_exit_code" => 0})])

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.health_exit_code == 0
    end

    test "a FAILED row carries the health code the gate exited with (14)" do
      bp = live_barkpark()
      site = node_site(bp)
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(polls: [failed_at_health(%{"health_exit_code" => 14})])

      assert {:ok, :failed} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "failed"

      assert final.health_exit_code == 14,
             "the failed row is the one that needs this most: 14 is how a reader tells " <>
               "'the HEALTH gate caught it' from 'it fell over and nobody gated anything'"
    end

    test "a failure the box did not health-measure leaves the column nil on the failed row" do
      bp = live_barkpark()
      site = node_site(bp)
      {:ok, d} = Deploy.enqueue(site, bp)

      {:ok, 200, body} = FakeBoxRelay.failed_at("BUILD", "npm ci exited 1")
      FakeBoxRelay.program(polls: [{:ok, 200, body}])

      assert {:ok, :failed} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "failed"

      refute final.health_exit_code,
             "the build died in BUILD — HEALTH never ran, so there is no code to report"
    end
  end

  describe "normalize_report/1 — the three measurements, tolerantly" do
    test "reads them when present, in either integer or string form" do
      report =
        Deploy.normalize_report(%{
          "state" => "succeeded",
          "served_port" => 7042,
          "served_slot" => "a",
          "health_exit_code" => "14"
        })

      assert report.served_port == 7042
      assert report.served_slot == "a"
      assert report.health_exit_code == 14
    end

    test "a missing, null, blank or negative value is nil — NEVER coerced to 0" do
      for body <- [
            %{},
            %{"health_exit_code" => nil, "served_port" => nil},
            %{"health_exit_code" => "", "served_port" => ""},
            %{"health_exit_code" => -1, "served_port" => -1},
            %{"health_exit_code" => "abc", "served_port" => "abc"}
          ] do
        report = Deploy.normalize_report(body)

        refute report.health_exit_code,
               "#{inspect(body)} must normalize to nil — 0 is the SUCCESS code, so " <>
                 "coercing an unreadable value to it manufactures a passing health gate"

        refute report.served_port
      end
    end

    test "the non-map clause answers the same shape (no key can be missing on a report)" do
      report = Deploy.normalize_report("not a map")

      assert report.served_port == nil
      assert report.served_slot == nil
      assert report.health_exit_code == nil
    end
  end
end
