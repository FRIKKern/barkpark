defmodule BarkparkCloud.Cloudflare.Fake do
  @moduledoc """
  The in-memory `BarkparkCloud.Cloudflare.Client` — the default in dev/test. No
  network, no API token, no cost. Deterministic AND inspectable, mirroring
  `Vercel.Fake` / `GitHub.Fake`:

    * ids/certs are a pure function of their inputs (SHA-256, truncated), so
      tests assert exact values with nothing stored;
    * side effects (upserted records, minted certs) are recorded in the CALLING
      PROCESS's dictionary — async-safe under `async: true`, no global state to
      reset.

  ## Failure sentinels

  A token / zone id / hostname list starting with (or containing) `"fail-"`
  makes the corresponding callback return an `{:error, _}` — a known-bad path
  for every context branch without fixtures or a token. `invalid_record_id/0`
  is the record id `ensure_zone_proxied/2` always rejects as `:not_found`.
  """
  @behaviour BarkparkCloud.Cloudflare.Client

  @tokens_key :cloudflare_fake_verified
  @records_key :cloudflare_fake_records
  @proxied_key :cloudflare_fake_proxied
  @certs_key :cloudflare_fake_certs

  @doc "A sentinel record id the fake ALWAYS rejects as `:not_found`. For tests."
  @spec invalid_record_id() :: String.t()
  def invalid_record_id, do: "rec_invalid"

  @impl true
  def verify_token(token) when is_binary(token) do
    if fail?(token) do
      {:error, :invalid_token}
    else
      record(@tokens_key, %{token: token})
      {:ok, %{status: "active"}}
    end
  end

  @impl true
  def upsert_dns_record(token, zone_id, record)
      when is_binary(token) and is_binary(zone_id) and is_map(record) do
    name = record[:name] || record["name"]

    cond do
      fail?(token) ->
        {:error, :invalid_token}

      fail?(zone_id) ->
        {:error, :upsert_failed}

      is_nil(name) ->
        {:error, :invalid_record}

      true ->
        record_id =
          record[:id] || record["id"] || "rec_fake_" <> digest(zone_id <> to_string(name))

        record(@records_key, %{
          zone_id: zone_id,
          record_id: record_id,
          name: name,
          type: record[:type] || record["type"],
          proxied: record[:proxied] || record["proxied"] || false
        })

        {:ok, %{record_id: record_id, name: name}}
    end
  end

  @impl true
  def ensure_zone_proxied(token, zone_id, record_id)
      when is_binary(token) and is_binary(zone_id) and is_binary(record_id) do
    cond do
      fail?(token) ->
        {:error, :invalid_token}

      fail?(zone_id) ->
        {:error, :proxy_failed}

      record_id == invalid_record_id() ->
        {:error, :not_found}

      true ->
        record(@proxied_key, %{zone_id: zone_id, record_id: record_id, proxied: true})
        {:ok, %{proxied: true}}
    end
  end

  @impl true
  def create_origin_ca_cert(hostnames, csr) when is_list(hostnames) and is_binary(csr) do
    cond do
      hostnames == [] ->
        {:error, :no_hostnames}

      Enum.any?(hostnames, &fail?/1) ->
        {:error, :cert_failed}

      true ->
        id = "cert_fake_" <> digest(Enum.join(hostnames, ",") <> csr)
        record(@certs_key, %{id: id, hostnames: hostnames})

        {:ok,
         %{
           id: id,
           certificate:
             "-----BEGIN CERTIFICATE-----\nfake-" <> id <> "\n-----END CERTIFICATE-----"
         }}
    end
  end

  @doc "The tokens verified in THIS process (for test assertions)."
  @spec verified() :: [map()]
  def verified, do: Process.get(@tokens_key, [])

  @doc "The DNS records upserted in THIS process (for test assertions)."
  @spec records() :: [map()]
  def records, do: Process.get(@records_key, [])

  @doc "The proxy flips recorded in THIS process (for test assertions)."
  @spec proxied() :: [map()]
  def proxied, do: Process.get(@proxied_key, [])

  @doc "The Origin CA certs minted in THIS process (for test assertions)."
  @spec certs() :: [map()]
  def certs, do: Process.get(@certs_key, [])

  ## Internals ───────────────────────────────────────────────────────────────

  defp fail?(value) when is_binary(value), do: String.starts_with?(value, "fail-")
  defp fail?(_), do: false

  defp record(key, entry), do: Process.put(key, Process.get(key, []) ++ [entry])

  defp digest(input) do
    :crypto.hash(:sha256, to_string(input))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
