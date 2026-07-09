defmodule BarkparkCloud.Azure do
  @moduledoc """
  The Azure provider context — the config-selected client SEAM plus the thin
  wrappers the connect flow and the normalized-catalog route call. Every
  external Azure call runs through `client/0`, so nothing here touches
  `management.azure.com` in the suite (the in-memory `Azure.FakeClient` is the
  dev/test default via config).

  Azure is a first-class provider peer to Hetzner: the control plane verifies a
  service principal before it saves it, and serves the same NORMALIZED
  `{regions, server_types}` catalog for it that Hetzner gets. See
  `BarkparkCloud.Registry.AzureCatalog` for the mapping and
  `BarkparkCloud.FailureCopy` for the per-kind remediation copy.
  """

  @doc """
  The configured `Azure.Client`. Resolved at call time (config-at-call-time, so
  a runtime.exs override wins). Defaults to `Azure.RealClient` (prod); dev/test
  swaps in `Azure.FakeClient` via `config :barkpark_cloud, :azure_http_client`.
  """
  @spec client() :: module()
  def client do
    Application.get_env(:barkpark_cloud, :azure_http_client, BarkparkCloud.Azure.RealClient)
  end

  @doc """
  Connect-time preflight over the client seam: authenticate the service
  principal and confirm it can see its subscription. `{:ok, meta}` or
  `{:error, term}`.
  """
  @spec verify(map()) :: {:ok, map()} | {:error, term()}
  def verify(credentials) when is_map(credentials), do: client().verify(credentials)

  @doc """
  The raw regions + VM sizes for the normalized catalog, over the client seam.
  `{:ok, %{locations: […], vm_sizes: […]}}` or `{:error, term}`.
  """
  @spec list_catalog(map()) ::
          {:ok, %{locations: [map()], vm_sizes: [map()]}} | {:error, term()}
  def list_catalog(credentials) when is_map(credentials), do: client().list_catalog(credentials)
end
