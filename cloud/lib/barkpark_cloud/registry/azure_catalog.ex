defmodule BarkparkCloud.Registry.AzureCatalog do
  @moduledoc """
  Normalizes raw Azure regions + VM sizes into the PROVIDER-NEUTRAL provisioning
  catalog shape the control plane serves for every provider:

      %{
        regions: [%{slug: "eastus", name: "East US"}, …],
        server_types: [
          %{slug: "Standard_D2ps_v5", cores: 2, ram_gb: 8, disk_gb: 16,
            monthly_price: 70.08},
          …
        ]
      }

  This is the EXACT shape `Registry.HetznerCatalog.normalize/2` emits, so the
  dashboard and `bp` CLI render one menu regardless of provider. This module is
  deliberately PURE — no HTTP, no config — fed the raw Azure shapes the
  `Azure.Client` seam returns (`%{locations, vm_sizes}`), so the mapping is
  unit-testable off a fixture with no tenant.

  ## Raw Azure shapes it reads

    * a location: `%{"name" => "eastus", "displayName" => "East US"}`
    * a VM size: `%{"name" => "Standard_D2ps_v5", "numberOfCores" => 2,
      "memoryInMB" => 8192, "resourceDiskSizeInMB" => 16384,
      "monthlyPriceUsd" => 70.08}`

  Azure's compute list carries no price (retail pricing is a separate API), so
  `monthly_price` is threaded from `monthlyPriceUsd` when the caller has it and
  is `nil` otherwise — the key is ALWAYS present so the shape stays identical to
  Hetzner's.
  """

  @type region :: %{slug: String.t(), name: String.t()}
  @type server_type :: %{
          slug: String.t(),
          cores: non_neg_integer() | nil,
          ram_gb: number() | nil,
          disk_gb: number() | nil,
          monthly_price: number() | nil
        }

  @doc """
  Map raw Azure `locations` + `vm_sizes` lists into the neutral catalog. Rows
  missing a usable `name`/slug are dropped (never emitted half-formed). Carries
  `currency: "USD"` — Azure Retail prices are quoted in USD — so a side-by-side
  Azure-vs-Hetzner (EUR) price comparison is honest, not silently mixed.
  """
  @spec normalize([map()], [map()]) :: %{
          regions: [region()],
          server_types: [server_type()],
          currency: String.t()
        }
  def normalize(locations, vm_sizes) when is_list(locations) and is_list(vm_sizes) do
    %{
      regions: locations |> Enum.map(&region/1) |> Enum.reject(&is_nil/1),
      server_types: vm_sizes |> Enum.map(&server_type/1) |> Enum.reject(&is_nil/1),
      currency: "USD"
    }
  end

  defp region(%{"name" => name} = loc) when is_binary(name) and name != "" do
    %{slug: name, name: display_name(loc, name)}
  end

  defp region(_), do: nil

  defp display_name(loc, fallback) do
    case Map.get(loc, "displayName") do
      dn when is_binary(dn) and dn != "" -> dn
      _ -> fallback
    end
  end

  defp server_type(%{"name" => name} = size) when is_binary(name) and name != "" do
    %{
      slug: name,
      cores: int(Map.get(size, "numberOfCores")),
      ram_gb: gib(Map.get(size, "memoryInMB")),
      disk_gb: gib(Map.get(size, "resourceDiskSizeInMB")),
      monthly_price: price(Map.get(size, "monthlyPriceUsd"))
    }
  end

  defp server_type(_), do: nil

  defp int(n) when is_integer(n), do: n
  defp int(_), do: nil

  # MB → GiB, rounded to a whole number (Azure reports memory/disk in MB).
  defp gib(mb) when is_number(mb), do: round(mb / 1024)
  defp gib(_), do: nil

  defp price(p) when is_number(p), do: Float.round(p / 1, 2)
  defp price(_), do: nil
end
