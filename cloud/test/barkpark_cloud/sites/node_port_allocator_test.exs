defmodule BarkparkCloud.Sites.NodePortAllocatorTest do
  @moduledoc """
  site-spawner W7 (charter D68): the per-site node-slot port allocator.

    * `allocate/0` returns the LOWEST-FREE EVEN base in [7002, 7998], scanning the
      `port_base` of every existing site so two node sites never collide.
    * `slot_ports/1` derives the blue/green pair (blue=base, green=base+1).
    * `target_slot_port/1` returns the IDLE slot for the next deploy (blue on the
      first deploy, then the slot NOT currently serving).
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Site
  alias BarkparkCloud.Sites.NodePortAllocator

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  # A persisted node site with an explicit port_base (what the create route folds
  # in through NodePortAllocator). port is optional (the live serving port).
  defp node_site_with_base(bp, base, port \\ nil) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Node #{n}",
        slug: "node-#{n}",
        kind: "node",
        framework: "nextjs",
        bootstrap_workspace: "acme",
        bootstrap_project: "web",
        bootstrap_dataset: "production"
      })

    site
    |> Ecto.Changeset.change(port_base: base, port: port)
    |> Repo.update!()
  end

  describe "allocate/0" do
    test "an empty fleet hands out the lowest even base (7002)" do
      assert {:ok, 7002} = NodePortAllocator.allocate()
    end

    test "skips taken bases and returns the lowest FREE even base" do
      bp = barkpark_fixture(team_fixture())
      node_site_with_base(bp, 7002)
      node_site_with_base(bp, 7004)

      # 7006 is the next free even base — the odd 7003/7005 (green slots) are never
      # candidates because allocate steps by 2 from an even floor.
      assert {:ok, 7006} = NodePortAllocator.allocate()
    end

    test "fills a HOLE — the lowest free base, not the highest+2" do
      bp = barkpark_fixture(team_fixture())
      node_site_with_base(bp, 7002)
      # 7004 intentionally left free (a retired site's base).
      node_site_with_base(bp, 7006)

      assert {:ok, 7004} = NodePortAllocator.allocate()
    end

    test "every base is even (never an odd green-slot port)" do
      {:ok, base} = NodePortAllocator.allocate()
      assert rem(base, 2) == 0
      # …and the whole window is even-floored.
      assert {7002, 7998} = NodePortAllocator.range()
    end

    test "collision avoidance: a base is never handed to two sites" do
      bp = barkpark_fixture(team_fixture())
      {:ok, first} = NodePortAllocator.allocate()
      node_site_with_base(bp, first)
      {:ok, second} = NodePortAllocator.allocate()

      refute second == first
      assert second > first
    end

    test "a static site's NULL port_base is ignored (does not consume a base)" do
      bp = barkpark_fixture(team_fixture())

      {:ok, _static} =
        Registry.create_site(bp, %{
          name: "Blog",
          slug: "blog",
          kind: "static",
          framework: "astro",
          bootstrap_dataset: "production",
          read_token: "bpt_x"
        })

      # No node site exists → the first even base is still free.
      assert {:ok, 7002} = NodePortAllocator.allocate()
    end
  end

  describe "slot_ports/1" do
    test "derives blue=base and green=base+1" do
      assert NodePortAllocator.slot_ports(7002) == %{blue: 7002, green: 7003}
    end
  end

  describe "target_slot_port/1 — the idle slot the next deploy boots on" do
    test "the FIRST deploy (no live port yet) targets blue (port_base)" do
      site = %Site{port_base: 7002, port: nil}
      assert NodePortAllocator.target_slot_port(site) == 7002
    end

    test "blue currently live → the next deploy targets green (base+1)" do
      site = %Site{port_base: 7002, port: 7002}
      assert NodePortAllocator.target_slot_port(site) == 7003
    end

    test "green currently live → the next deploy targets blue (base)" do
      site = %Site{port_base: 7002, port: 7003}
      assert NodePortAllocator.target_slot_port(site) == 7002
    end

    test "a non-node site (no base) has no target slot" do
      assert NodePortAllocator.target_slot_port(%Site{port_base: nil, port: nil}) == nil
    end
  end
end
