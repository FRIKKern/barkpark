defmodule BarkparkCloud.Registry.HetznerCatalogTest do
  @moduledoc """
  The Hetzner action catalog is the proxy's ALLOWLIST (charter decision 3), so
  these tests are about the allowlist's own integrity — pure, no DB, no HTTP:

    * every entry is well-formed: a valid tier, an exact "/"-rooted path with
      no traversal, a method matching its tier's semantics
    * (resource, verb) pairs are UNIQUE — exact-match lookup can never be
      ambiguous
    * the nine charter overview kinds are all present as :read entries, and
      reads are the ONLY tier served this wave
    * declared-but-not-routed mutations (reboot/poweron/poweroff/
      create_snapshot) are :mutate; every :destroy entry carries the "confirm"
      typed-name echo slot (charter decision 5)
    * fetch/2 is exact-match only — no strings, no prefixes, no near-misses
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.HetznerCatalog, as: Catalog

  @overview_kinds ~w(servers volumes networks firewalls load_balancers floating_ips primary_ips dns_zones backups)a

  describe "catalog/0 integrity" do
    test "every entry is well-formed data: atoms, a valid tier, a method, string params" do
      for entry <- Catalog.catalog() do
        assert is_atom(entry.resource)
        assert is_atom(entry.verb)
        assert entry.tier in [:read, :mutate, :destroy]
        assert entry.method in [:get, :post, :delete]
        assert is_list(entry.params)
        assert Enum.all?(entry.params, &is_binary/1)
      end
    end

    test ~s(every path is an exact "/"-rooted template with no traversal or query baked in) do
      for entry <- Catalog.catalog() do
        assert String.starts_with?(entry.path, "/"),
               "#{entry.resource}/#{entry.verb} path must start with /: #{entry.path}"

        refute entry.path =~ "..",
               "#{entry.resource}/#{entry.verb} path must not traverse: #{entry.path}"

        refute entry.path =~ "?", "query params belong in :params, not the path template"
        refute entry.path =~ " ", "no whitespace in a path template"
      end
    end

    test "(resource, verb) pairs are unique — exact-match lookup is never ambiguous" do
      pairs = Enum.map(Catalog.catalog(), &{&1.resource, &1.verb})
      assert pairs == Enum.uniq(pairs)
    end

    test "tier semantics match methods: reads GET, destroys DELETE, mutates POST" do
      for entry <- Catalog.catalog() do
        case entry.tier do
          :read -> assert entry.method == :get
          :mutate -> assert entry.method == :post
          :destroy -> assert entry.method == :delete
        end
      end
    end
  end

  describe "read_entries/0 — the only tier served this wave" do
    test "exactly the nine charter overview kinds, all tier :read" do
      entries = Catalog.read_entries()

      assert Enum.map(entries, & &1.resource) == @overview_kinds
      assert Enum.all?(entries, &(&1.tier == :read))
      assert Enum.all?(entries, &(&1.verb == :list))
    end

    test "read_entries is exactly the :read subset of catalog/0" do
      assert Catalog.read_entries() == Enum.filter(Catalog.catalog(), &(&1.tier == :read))
    end
  end

  describe "declared mutations and destroys (wave 3 — in the catalog, not routed)" do
    test "reboot/poweron/poweroff/create_snapshot are declared as :mutate on servers" do
      for verb <- [:reboot, :poweron, :poweroff, :create_snapshot] do
        assert {:ok, entry} = Catalog.fetch(:servers, verb)
        assert entry.tier == :mutate
        assert entry.method == :post
      end
    end

    test ~s(every :destroy entry carries the "confirm" typed-name echo slot) do
      destroys = Enum.filter(Catalog.catalog(), &(&1.tier == :destroy))

      # One delete per overview kind — nothing destroyable is left ungoverned.
      assert Enum.map(destroys, & &1.resource) |> Enum.sort() == Enum.sort(@overview_kinds)

      for entry <- destroys do
        assert "confirm" in entry.params,
               "#{entry.resource}/#{entry.verb} must demand the confirm name echo"
      end
    end
  end

  describe "fetch/2 — exact match only" do
    test "hits on an exact (resource, verb) atom pair" do
      assert {:ok, %{path: "/v1/servers", tier: :read}} = Catalog.fetch(:servers, :list)
      assert {:ok, %{path: "/v1/zones", tier: :read}} = Catalog.fetch(:dns_zones, :list)
      assert {:ok, %{tier: :destroy}} = Catalog.fetch(:volumes, :delete)
    end

    test "misses on anything else — unknown pairs, strings, near-misses" do
      assert :error = Catalog.fetch(:servers, :destroy_all)
      assert :error = Catalog.fetch(:snapshots, :list)
      # Strings never coerce — no user-controlled atom paths into the allowlist.
      assert :error = Catalog.fetch("servers", "list")
      # A verb valid for one resource doesn't leak onto another.
      assert :error = Catalog.fetch(:volumes, :reboot)
    end
  end
end
