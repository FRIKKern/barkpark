defmodule BarkparkCloud.Azure.Client do
  @moduledoc """
  The Azure SEAM — every call the control plane makes to Azure on behalf of a
  team's connected service principal goes through this behaviour, so the
  `BarkparkCloud.Azure` context never talks to `management.azure.com` directly.
  The concrete client is selected from config (`Azure.client/0`), exactly like
  `GitHub.client/0` and the `:hetzner_http_client` / `:verify_http_client`
  transport seams:

    * `BarkparkCloud.Azure.FakeClient` in dev/test — an in-memory,
      deterministic, inspectable double (no network, no Azure tenant, no cost).
    * `BarkparkCloud.Azure.RealClient` in prod — does the OAuth2
      client-credentials token exchange, then a tagged resource list to prove
      the principal can actually see the subscription.

  This lets the whole verified-connect + normalized-catalog path be built and
  tested with ZERO real Azure credentials (HUMAN-LAST). No real Azure call is
  ever made in the suite.

  ## The identity every callback carries

  An azure credential is the four-field service-principal blob
  `%{"tenant_id" => …, "client_id" => …, "client_secret" => …,
  "subscription_id" => …}` (string keys — it round-trips through the vault as
  JSON). Every callback takes that map and resolves a fresh access token
  internally; the context never handles the token.

  ## Callbacks

    * `verify/1`       — the connect-time preflight. Exchange the principal for a
      token and list ONE tagged resource under its subscription. `{:ok, meta}`
      proves the credential authenticates AND can see the subscription;
      `{:error, reason}` (e.g. `:unauthorized`, `:subscription_not_found`) drives
      the per-kind remediation copy the connect endpoint returns instead of
      saving.
    * `list_catalog/1` — the raw regions + VM sizes the normalized provisioning
      catalog is built from. Returns `{:ok, %{locations: […], vm_sizes: […]}}`
      (raw Azure shapes) or `{:error, reason}`.
  """

  @typedoc "A service-principal credential blob (string keys, as stored in the vault)."
  @type credentials :: %{optional(String.t()) => String.t()}

  @doc """
  Connect-time preflight: authenticate the service principal and confirm it can
  see its subscription. `{:ok, meta}` on success, `{:error, term}` otherwise.
  """
  @callback verify(credentials) :: {:ok, map()} | {:error, term()}

  @doc """
  List the raw regions + VM sizes the normalized catalog maps. Returns
  `{:ok, %{locations: [map()], vm_sizes: [map()]}}` or `{:error, term}`.
  """
  @callback list_catalog(credentials) ::
              {:ok, %{locations: [map()], vm_sizes: [map()]}} | {:error, term()}
end

defmodule BarkparkCloud.Azure.FakeClient do
  @moduledoc """
  The in-memory `BarkparkCloud.Azure.Client` — the default in dev/test. No
  network, no service principal, no cost. Deterministic:

    * a well-formed credential blob whose `client_secret` is NOT the reject
      sentinel authenticates; `verify/1` echoes the subscription id and a stub
      resource count;
    * the sentinel `unauthorized_secret/0` always fails `:unauthorized`, so the
      connect endpoint's verify-before-save path has a known-bad credential
      without any tenant;
    * `list_catalog/1` returns a small, realistic ARM-first estate (two regions,
      three sizes) with a monthly USD price on each size, so the normalized
      catalog is provable at €0.
  """
  @behaviour BarkparkCloud.Azure.Client

  @required ~w(tenant_id client_id client_secret subscription_id)

  @doc "A client_secret the fake ALWAYS rejects as `:unauthorized`. For tests."
  @spec unauthorized_secret() :: String.t()
  def unauthorized_secret, do: "deny-this-secret"

  @impl true
  def verify(creds) when is_map(creds) do
    cond do
      not Enum.all?(@required, &present?(creds, &1)) ->
        {:error, :invalid_credentials}

      Map.get(creds, "client_secret") == unauthorized_secret() ->
        {:error, :unauthorized}

      true ->
        {:ok, %{subscription_id: Map.get(creds, "subscription_id"), resource_count: 1}}
    end
  end

  def verify(_), do: {:error, :invalid_credentials}

  @impl true
  def list_catalog(creds) when is_map(creds) do
    case verify(creds) do
      {:ok, _} -> {:ok, canned_catalog()}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_catalog(_), do: {:error, :invalid_credentials}

  @doc "The canned raw estate — exposed so tests can assert the normalized mapping."
  @spec canned_catalog() :: %{locations: [map()], vm_sizes: [map()]}
  def canned_catalog do
    %{
      locations: [
        %{"name" => "eastus", "displayName" => "East US"},
        %{"name" => "westeurope", "displayName" => "West Europe"}
      ],
      vm_sizes: [
        %{
          "name" => "Standard_D2ps_v5",
          "numberOfCores" => 2,
          "memoryInMB" => 8192,
          "resourceDiskSizeInMB" => 16384,
          "monthlyPriceUsd" => 70.08
        },
        %{
          "name" => "Standard_D4ps_v5",
          "numberOfCores" => 4,
          "memoryInMB" => 16384,
          "resourceDiskSizeInMB" => 32768,
          "monthlyPriceUsd" => 140.16
        },
        %{
          "name" => "Standard_B2ts_v2",
          "numberOfCores" => 2,
          "memoryInMB" => 1024,
          "resourceDiskSizeInMB" => 8192,
          "monthlyPriceUsd" => 8.03
        }
      ]
    }
  end

  defp present?(creds, key) do
    case Map.get(creds, key) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end
end

defmodule BarkparkCloud.Azure.RealClient do
  @moduledoc """
  The real `BarkparkCloud.Azure.Client` — it builds the ACTUAL Azure request
  shapes (OAuth2 client-credentials token exchange → an ARM resource list) and
  sends them over the injected verified-TLS transport. Selected in prod. This is
  HUMAN-LAST: no real credential exists in the repo, so the module is exercised
  purely through its pure request builders in the suite — no byte ever reaches
  Azure.

  ## Token exchange — the OAuth2 client-credentials grant

  `POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token` with
  `grant_type=client_credentials`, the app's `client_id`/`client_secret`, and
  `scope=https://management.azure.com/.default`. The response's `access_token`
  is a Bearer for every ARM call.

  ## Injectable HTTP client — €0 in tests, no new dep

  Same seam as `GitHub.Real` / `Billing.StripeGateway`: `request/1` resolves a
  1-arity client fn from config
  (`config :barkpark_cloud, BarkparkCloud.Azure, http_client: &m.f/1`) and calls
  it with the `%{method, url, headers, body}` map. In prod that is
  `Billing.HttpClient` (Erlang `:httpc`, verified TLS). In dev/test there is no
  client, so any callback that would hit the wire returns
  `{:error, :http_client_not_configured}` — it can NEVER silently call Azure.
  """
  @behaviour BarkparkCloud.Azure.Client

  @login_base "https://login.microsoftonline.com"
  @arm_base "https://management.azure.com"
  @arm_scope "https://management.azure.com/.default"
  @arm_api_version "2021-04-01"
  @compute_api_version "2024-07-01"

  @impl true
  def verify(creds) when is_map(creds) do
    with {:ok, token} <- access_token(creds),
         sub when is_binary(sub) <- Map.get(creds, "subscription_id"),
         {:ok, _decoded} <- request(resource_groups_request(sub, token)) do
      {:ok, %{subscription_id: sub}}
    else
      nil -> {:error, :invalid_credentials}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_), do: {:error, :invalid_credentials}

  @impl true
  def list_catalog(creds) when is_map(creds) do
    with {:ok, token} <- access_token(creds),
         sub when is_binary(sub) <- Map.get(creds, "subscription_id"),
         {:ok, locations} <- request(locations_request(sub, token)),
         {:ok, vm_sizes} <- request(vm_sizes_request(sub, token)) do
      {:ok,
       %{
         locations: List.wrap(locations["value"]),
         vm_sizes: List.wrap(vm_sizes["value"])
       }}
    else
      nil -> {:error, :invalid_credentials}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_catalog(_), do: {:error, :invalid_credentials}

  ## Request builders (PURE — the assertion seam) ────────────────────────────

  @doc false
  def token_request(%{
        "tenant_id" => tenant,
        "client_id" => client_id,
        "client_secret" => secret
      }) do
    %{
      method: :post,
      url: "#{@login_base}/#{tenant}/oauth2/v2.0/token",
      headers: [{"Content-Type", "application/x-www-form-urlencoded"}],
      body:
        URI.encode_query(%{
          "grant_type" => "client_credentials",
          "client_id" => client_id,
          "client_secret" => secret,
          "scope" => @arm_scope
        })
    }
  end

  def token_request(_), do: nil

  @doc false
  def resource_groups_request(subscription_id, token) do
    %{
      method: :get,
      url:
        "#{@arm_base}/subscriptions/#{subscription_id}/resourcegroups?api-version=#{@arm_api_version}&$top=1",
      headers: bearer(token),
      body: ""
    }
  end

  @doc false
  def locations_request(subscription_id, token) do
    %{
      method: :get,
      url:
        "#{@arm_base}/subscriptions/#{subscription_id}/locations?api-version=#{@arm_api_version}",
      headers: bearer(token),
      body: ""
    }
  end

  @doc false
  def vm_sizes_request(subscription_id, token) do
    %{
      method: :get,
      url:
        "#{@arm_base}/subscriptions/#{subscription_id}/providers/Microsoft.Compute/skus?api-version=#{@compute_api_version}",
      headers: bearer(token),
      body: ""
    }
  end

  ## Internals ────────────────────────────────────────────────────────────────

  defp access_token(creds) do
    case token_request(creds) do
      nil ->
        {:error, :invalid_credentials}

      req ->
        case request(req) do
          {:ok, %{"access_token" => token}} when is_binary(token) -> {:ok, token}
          {:ok, _} -> {:error, :unexpected_response}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp bearer(token), do: [{"Authorization", "Bearer #{token}"}, {"Accept", "application/json"}]

  # Resolve the transport fn at call time (a runtime.exs override wins). Absent
  # → fail closed; a callback can NEVER silently reach Azure without a client.
  defp request(req) do
    case config()[:http_client] do
      fun when is_function(fun, 1) ->
        case fun.(req) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            decode(body)

          {:ok, %{status: 401}} ->
            {:error, :unauthorized}

          {:ok, %{status: 403}} ->
            {:error, :forbidden}

          {:ok, %{status: 404}} ->
            {:error, :subscription_not_found}

          {:ok, %{status: status}} ->
            {:error, {:http, status}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :http_client_not_configured}
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :bad_payload}
    end
  end

  defp decode(_), do: {:error, :bad_payload}

  defp config, do: Application.get_env(:barkpark_cloud, BarkparkCloud.Azure, [])
end
