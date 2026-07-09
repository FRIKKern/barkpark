defmodule BarkparkCloud.Registry.AzureCatalogTest do
  @moduledoc """
  The Azure catalog normalizer maps raw ARM regions + VM sizes into the
  provider-neutral `{regions, server_types}` shape — the SAME shape
  `HetznerCatalog.normalize/2` emits. Pure, fixture-fed, no tenant:

    * a location maps to `%{slug, name}` (name from displayName, slug fallback)
    * a VM size maps to `%{slug, cores, ram_gb, disk_gb, monthly_price}` with
      MB→GiB conversion and price threaded from monthlyPriceUsd
    * a size with no price still carries the `monthly_price` key (nil) so the
      shape is identical across providers
    * half-formed rows (no name) are dropped
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.AzureCatalog

  @locations [
    %{"name" => "eastus", "displayName" => "East US"},
    %{"name" => "westeurope", "displayName" => "West Europe"}
  ]

  @vm_sizes [
    %{
      "name" => "Standard_D2ps_v5",
      "numberOfCores" => 2,
      "memoryInMB" => 8192,
      "resourceDiskSizeInMB" => 16384,
      "monthlyPriceUsd" => 70.08
    },
    %{
      "name" => "Standard_B2ts_v2",
      "numberOfCores" => 2,
      "memoryInMB" => 1024,
      "resourceDiskSizeInMB" => 8192
      # no price
    }
  ]

  test "maps regions to {slug, name}" do
    %{regions: regions} = AzureCatalog.normalize(@locations, @vm_sizes)

    assert regions == [
             %{slug: "eastus", name: "East US"},
             %{slug: "westeurope", name: "West Europe"}
           ]
  end

  test "maps VM sizes to the neutral server_type shape with MB→GiB and threaded price" do
    %{server_types: [d2, b2]} = AzureCatalog.normalize(@locations, @vm_sizes)

    assert d2 == %{
             slug: "Standard_D2ps_v5",
             cores: 2,
             ram_gb: 8,
             disk_gb: 16,
             monthly_price: 70.08
           }

    # A price-less size still carries the key (nil) — shape parity across providers.
    assert b2 == %{
             slug: "Standard_B2ts_v2",
             cores: 2,
             ram_gb: 1,
             disk_gb: 8,
             monthly_price: nil
           }
  end

  test "every server_type carries exactly the neutral key set" do
    %{server_types: types} = AzureCatalog.normalize(@locations, @vm_sizes)

    for t <- types do
      assert Enum.sort(Map.keys(t)) == ~w(cores disk_gb monthly_price ram_gb slug)a
    end
  end

  test "the FakeClient's canned estate normalizes cleanly (the route's data source)" do
    %{locations: locs, vm_sizes: sizes} = BarkparkCloud.Azure.FakeClient.canned_catalog()
    %{regions: regions, server_types: types} = AzureCatalog.normalize(locs, sizes)

    assert length(regions) == 2
    assert length(types) == 3
    assert Enum.all?(types, &is_number(&1.monthly_price))
    assert Enum.all?(regions, &(is_binary(&1.slug) and is_binary(&1.name)))
  end

  test "half-formed rows (no name) are dropped, not emitted half-built" do
    locs = [%{"displayName" => "Nameless"} | @locations]
    sizes = [%{"numberOfCores" => 4} | @vm_sizes]

    %{regions: regions, server_types: types} = AzureCatalog.normalize(locs, sizes)

    assert length(regions) == length(@locations)
    assert length(types) == length(@vm_sizes)
  end
end
