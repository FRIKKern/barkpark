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

  ## `on_upsert/1` — the orphan-race seam

  `upsert_dns_record/3` fires an optional 0-arity hook (installed with
  `on_upsert/1`) right after recording the write, before returning `{:ok, _}`
  to the caller. This is how a test lands a concurrent teardown IN THE GAP an
  upsert's network round trip stands for — e.g. deleting the Barkpark row the
  write is about to outlive — mirroring the Go sibling's `provider.onList`
  hook (`internal/provisioner/attach_domain_test.go`), which lands a
  deprovision between a job's pre-check and its DNS write the same way.
  """
  @behaviour BarkparkCloud.Cloudflare.Client

  @tokens_key :cloudflare_fake_verified
  @records_key :cloudflare_fake_records
  @proxied_key :cloudflare_fake_proxied
  @certs_key :cloudflare_fake_certs
  @deletes_key :cloudflare_fake_deletes
  @on_upsert_key :cloudflare_fake_on_upsert_hook
  @fail_deletes_key :cloudflare_fake_fail_deletes

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

        # Fire the installed race hook, if any, BEFORE returning — see the
        # moduledoc's "orphan-race seam" section. A caller re-checking liveness
        # right after this call observes whatever the hook just did (e.g. the
        # Barkpark row it was written for no longer existing).
        case Process.get(@on_upsert_key) do
          fun when is_function(fun, 0) -> fun.()
          _ -> :ok
        end

        {:ok, %{record_id: record_id, name: name}}
    end
  end

  @impl true
  def delete_dns_record(token, zone_id, record_id)
      when is_binary(token) and is_binary(zone_id) and is_binary(record_id) do
    cond do
      # The honesty-edge seam: force every delete to fail regardless of
      # token/zone validity, for a test proving the caller names the orphan
      # when NOTHING can clean it up (the record's box AND its own delete both
      # gone). See `fail_deletes/1`.
      Process.get(@fail_deletes_key, false) ->
        {:error, :delete_failed}

      fail?(token) ->
        {:error, :invalid_token}

      fail?(zone_id) ->
        {:error, :delete_failed}

      true ->
        # Models a ZONE, not a call log: the record (and any proxy flip on it)
        # is REMOVED, so a caller asking "does the zone still hold this?" after
        # a delete gets the true answer — the same shift the Go sibling's DNS
        # fake made (upsert adds, delete removes) because the orphan hazard is
        # a record that SURVIVES, not a call count.
        Process.put(
          @records_key,
          Enum.reject(Process.get(@records_key, []), &(&1.record_id == record_id))
        )

        Process.put(
          @proxied_key,
          Enum.reject(Process.get(@proxied_key, []), &(&1.record_id == record_id))
        )

        record(@deletes_key, %{zone_id: zone_id, record_id: record_id})

        {:ok, %{deleted: true}}
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

  @doc """
  The DNS records CURRENTLY in the zone in THIS process (for test assertions).
  A deleted record is gone from this list — see the moduledoc: this models a
  zone, not an append-only call log.
  """
  @spec records() :: [map()]
  def records, do: Process.get(@records_key, [])

  @doc "The DNS record deletes issued in THIS process (for test assertions)."
  @spec deletes() :: [map()]
  def deletes, do: Process.get(@deletes_key, [])

  @doc """
  TEST-ONLY seam: install a 0-arity callback `upsert_dns_record/3` invokes
  right after recording a write, before returning `{:ok, _}` — see the
  moduledoc's "orphan-race seam" section. Pass `nil` to clear (usually
  unnecessary; the process dictionary dies with the test process).
  """
  @spec on_upsert((-> any()) | nil) :: (-> any()) | nil
  def on_upsert(fun) when is_function(fun, 0) or is_nil(fun) do
    Process.put(@on_upsert_key, fun)
  end

  @doc """
  TEST-ONLY seam: force every subsequent `delete_dns_record/3` call in THIS
  process to fail with `{:error, :delete_failed}`, regardless of token/zone
  validity — the honesty-edge seam. `false` clears it.
  """
  @spec fail_deletes(boolean()) :: boolean()
  def fail_deletes(bool) when is_boolean(bool) do
    Process.put(@fail_deletes_key, bool)
  end

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
