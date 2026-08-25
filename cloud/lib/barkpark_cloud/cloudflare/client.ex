defmodule BarkparkCloud.Cloudflare.Client do
  @moduledoc """
  The Cloudflare SEAM (cf-w2). Every call the control plane makes to the
  Cloudflare platform API goes through this behaviour, so the
  `BarkparkCloud.Cloudflare` context never talks to `api.cloudflare.com`
  directly. The concrete client is selected from config
  (`Cloudflare.client/0`), exactly like the `GitHub.Client` and `Vercel.Client`
  seams it mirrors:

    * `Cloudflare.Fake` in dev/test — an in-memory, deterministic, inspectable
      double (no network, no API token, no cost).
    * `Cloudflare.Real` in prod ONCE a human wires an API token — builds the
      Cloudflare v4 REST call shapes and sends them over the verified-TLS
      `Billing.HttpClient` transport seam (the same `:httpc`, `autoredirect:
      false` transport Stripe/GitHub/Vercel use — no new dependency).

  ## The capability-provider law

  Cloudflare is the FREE-superpower primary in the "connect a cloud account only
  ever ADDS capability" doctrine: with no token wired, Barkpark still serves
  everything standalone; wiring a token layers Cloudflare's free wildcard TLS,
  DNS, and unlimited-bandwidth global CDN ON TOP, and disconnecting degrades
  gracefully back to standalone. The `capabilities/0` menu this seam exposes is
  `[:dns, :tls, :cdn]` (tunnel + storage are backlog).

  ## Callbacks — ONE fat behaviour (D15)

  Following the `GitHub.Client` precedent (six callbacks in ONE behaviour, NOT
  split per-capability), every Cloudflare-in-front operation lives here:

    * `verify_token/1` — the connect-time credential check (like `Azure.verify/1`):
      given the token the user just pasted, confirm it is live and active
      (`GET /user/tokens/verify`) BEFORE it is stored. Returns
      `{:ok, %{status: "active"}}` for a good token, `{:error, term}` otherwise.
    * `upsert_dns_record/3` — create-or-update a DNS record in a zone (point the
      custom domain at the origin), authenticating with the threaded `token`.
      Returns `{:ok, %{record_id:, name:}}`.
    * `delete_dns_record/3` — delete a DNS record by id, authenticating with the
      threaded `token`. THE ORPHAN-CLEANUP VERB (cch orphan-fix, #14039's
      sibling on the cloud/ side): a record upserted at a box origin outlives
      that box the instant the box is deprovisioned mid-write, and no box-keyed
      backstop anywhere in this app can reach it (Cloudflare zones are
      per-team BYOA — there is no `SweepOrphans` equivalent here). Without this
      verb the write site had NO way to undo its own write; the router's
      `do_bind_cloudflare` calls it on the re-check-after-write edge, exactly
      like `AttachDomainWith` calls `DeleteRecord` on the Go worker side.
      Returns `{:ok, %{deleted: true}}`.
    * `ensure_zone_proxied/3` — flip a DNS record to PROXIED (the orange cloud),
      so traffic rides Cloudflare's CDN + DDoS shield instead of hitting the
      origin directly, authenticating with the threaded `token`. Returns
      `{:ok, %{proxied: true}}`.
    * `create_origin_ca_cert/2` — mint a Cloudflare Origin CA certificate for a
      set of hostnames from a CSR, so the origin can present a cert Cloudflare
      trusts end-to-end (Full/Strict TLS). Returns `{:ok, %{id:, certificate:}}`.

  Every callback returns `{:ok, _} | {:error, term}` so call sites pattern-match
  rather than rescue.
  """

  @typedoc "A Cloudflare API token (scoped, secret — the per-instance credential)."
  @type token :: String.t()

  @typedoc "A Cloudflare zone id (the stable handle for a delegated domain)."
  @type zone_id :: String.t()

  @typedoc """
  A DNS record spec. `:type`/`:name`/`:content` are required for a create; an
  `:id` (when present) turns the upsert into an update of that record. `:proxied`
  and `:ttl` are optional (default unproxied, automatic TTL).
  """
  @type dns_record :: %{
          optional(:id) => String.t(),
          required(:type) => String.t(),
          required(:name) => String.t(),
          required(:content) => String.t(),
          optional(:proxied) => boolean(),
          optional(:ttl) => integer()
        }

  @doc """
  Confirm the API `token` is live and active — the connect-time validation
  primitive. Returns `{:ok, %{status: "active"}}` for a good token,
  `{:error, term}` for an invalid/revoked one. This is how the connect endpoint
  proves the token the browser handed back actually works BEFORE storing it.
  """
  @callback verify_token(token) :: {:ok, %{status: String.t()}} | {:error, term}

  @doc """
  Create-or-update a DNS `record` in `zone_id`, authenticating with `token`.
  When `record` carries an `:id` it updates that record; otherwise it creates
  one. Returns `{:ok, %{record_id: id, name: name}}` or `{:error, term}`.

  The `token` is THREADED as the first argument (D52) rather than read from
  global config: a per-team credential is resolved at call time and passed in,
  so concurrent deploys for different teams can never race over a shared
  `Application.put_env`.
  """
  @callback upsert_dns_record(token, zone_id, dns_record) ::
              {:ok, %{record_id: String.t(), name: String.t()}} | {:error, term}

  @doc """
  Delete the DNS record `record_id` in `zone_id`, authenticating with `token`.
  Returns `{:ok, %{deleted: true}}` or `{:error, term}`. `token` is threaded as
  the first argument (D52) for the same per-team-credential reason as
  `upsert_dns_record/3`.

  This is the cleanup half of the orphan guard: a record written for a box that
  is deprovisioned mid-write has NO other path to deletion — Cloudflare zones
  are per-team accounts, so there is no fleet-wide sweep that could ever reach
  them by box label the way `SweepOrphans` reaches Hetzner-zone records.
  """
  @callback delete_dns_record(token, zone_id, record_id :: String.t()) ::
              {:ok, %{deleted: true}} | {:error, term}

  @doc """
  Flip the DNS record `record_id` in `zone_id` to PROXIED (orange cloud),
  authenticating with `token`, so traffic rides Cloudflare's CDN + DDoS shield.
  Returns `{:ok, %{proxied: true}}` or `{:error, term}`. `token` is threaded as
  the first argument (D52) for the same per-team-credential reason as
  `upsert_dns_record/3`.
  """
  @callback ensure_zone_proxied(token, zone_id, record_id :: String.t()) ::
              {:ok, %{proxied: boolean()}} | {:error, term}

  @doc """
  Mint a Cloudflare Origin CA certificate for `hostnames` from the PEM `csr`.
  Returns `{:ok, %{id: id, certificate: pem}}` or `{:error, term}`.
  """
  @callback create_origin_ca_cert(hostnames :: [String.t()], csr :: String.t()) ::
              {:ok, %{id: String.t(), certificate: String.t()}} | {:error, term}
end
