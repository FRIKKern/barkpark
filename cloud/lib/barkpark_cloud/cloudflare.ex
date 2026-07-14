defmodule BarkparkCloud.Cloudflare do
  @moduledoc """
  The Cloudflare platform context (cf-w2) — the FREE-superpower capability
  provider in the Barkpark Cloud site doctrine. Barkpark is a COMPLETE
  standalone box (it serves content + the site + its own TLS/DNS with no
  external account); connecting a Cloudflare account only ever ADDS capability
  ON TOP — free wildcard TLS, DNS, and unlimited-bandwidth global CDN + DDoS
  shield — and disconnecting degrades gracefully back to standalone. That is the
  same law Barkpark plugins obey.

  ## HUMAN-LAST / fail-closed

  No real Cloudflare token exists in the repo. `configured?/0` reports whether a
  token is wired (env, prod-only); every capability call routes through the
  `Cloudflare.Client` seam. In dev/test the client is the in-memory
  `Cloudflare.Fake`, so the whole connect/DNS/TLS path is provable at €0. The app
  BOOTS regardless; nothing here raises on a missing credential.

  ## The seam

  `client/0` resolves the concrete client from config AT CALL TIME (a
  `runtime.exs` override wins), defaulting to `Cloudflare.Fake` — a missing
  config is the safe in-memory double, never a real Cloudflare call. The
  capability functions (`verify_token/1`, `upsert_dns_record/3`,
  `ensure_zone_proxied/3`, `create_origin_ca_cert/2`) delegate through it,
  exactly like `Azure.verify/1` delegates to `Azure.client/0`.
  """

  alias BarkparkCloud.Cloudflare.Client

  @capabilities [:dns, :tls, :cdn]

  @doc """
  The configured `Cloudflare.Client`. Resolved at call time (config-at-call-time,
  so a runtime.exs override wins). Defaults to `Cloudflare.Fake` — a missing
  config is the safe in-memory double, never a real Cloudflare call.
  """
  @spec client() :: module()
  def client do
    config() |> Keyword.get(:client, BarkparkCloud.Cloudflare.Fake)
  end

  @doc """
  Is a Cloudflare API token wired to actually talk to Cloudflare right now?
  Fail-closed: `false` unless a non-empty token is present in config. Callers gate
  the "connect Cloudflare" superpowers on this — absent, the box stays fully
  standalone.
  """
  @spec configured?() :: boolean()
  def configured? do
    present?(config()[:token])
  end

  @doc """
  The capability menu this provider adds ON TOP of standalone: `[:dns, :tls,
  :cdn]`. (Tunnel + storage are backlog — see the epic.)
  """
  @spec capabilities() :: [atom()]
  def capabilities, do: @capabilities

  @doc "Connect-time credential check — verify the `token` is live and active."
  @spec verify_token(Client.token()) :: {:ok, %{status: String.t()}} | {:error, term}
  def verify_token(token), do: client().verify_token(token)

  @doc """
  Create-or-update a DNS `record` in `zone_id`, authenticating with the
  per-team `token` threaded in (D52 — never global config).
  """
  @spec upsert_dns_record(Client.token(), Client.zone_id(), Client.dns_record()) ::
          {:ok, %{record_id: String.t(), name: String.t()}} | {:error, term}
  def upsert_dns_record(token, zone_id, record),
    do: client().upsert_dns_record(token, zone_id, record)

  @doc """
  Flip the DNS record `record_id` in `zone_id` to proxied (orange cloud),
  authenticating with the per-team `token` threaded in (D52).
  """
  @spec ensure_zone_proxied(Client.token(), Client.zone_id(), String.t()) ::
          {:ok, %{proxied: boolean()}} | {:error, term}
  def ensure_zone_proxied(token, zone_id, record_id),
    do: client().ensure_zone_proxied(token, zone_id, record_id)

  @doc "Mint an Origin CA cert for `hostnames` from the PEM `csr`."
  @spec create_origin_ca_cert([String.t()], String.t()) ::
          {:ok, %{id: String.t(), certificate: String.t()}} | {:error, term}
  def create_origin_ca_cert(hostnames, csr),
    do: client().create_origin_ca_cert(hostnames, csr)

  ## Internals ───────────────────────────────────────────────────────────────

  defp present?(value), do: is_binary(value) and value != ""

  defp config, do: Application.get_env(:barkpark_cloud, __MODULE__, [])
end
