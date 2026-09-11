defmodule BarkparkCloud.Cloudflare.OriginCA do
  @moduledoc """
  Provision a Cloudflare Origin CA certificate for a site and PERSIST the
  binding — the step that turns `Cloudflare.create_origin_ca_cert/2` from a
  reachable-but-unused callback into a capability with a row behind it.

  ## The round trip

      Site + hostnames
        → CSR.generate/2            (fresh RSA key + PKCS#10, no openssl)
        → Cloudflare.create_origin_ca_cert/2   (Fake in dev/test, Real in prod)
        → Registry.set_cf_binding/2 (tls_mode: "cf_origin_ca" + the two paths)

  `provision/3` returns the cert + key PEM MATERIAL to its caller and writes
  neither to the control plane's disk. That is deliberate, not an omission: the
  files belong on the ORIGIN BOX (`/etc/caddy/...`, mode 0600, owned by the
  caddy user), and the control plane has no filesystem there. What it persists
  are the PATHS the box will read them from, so the row and the box agree on
  where the material lives once a delivery channel carries it.

  ## Why this does NOT flip a live deploy by itself

  The box derives its Caddy TLS mode from `serving_mode` alone
  (`internal/runtime/runtime.go` `tlsModeForServing`); `tls_mode` is a control
  plane vocabulary the agent claim deliberately does not carry
  (`Web.Router.deployment_with_site_json/1`). And the Go renderer fails CLOSED:
  a site marked `origin_ca` without a readable cert/key pair is SKIPPED, never
  downgraded — so arming this inside the `via=cloudflare` deploy path BEFORE the
  material can reach the box would take sites OFFLINE. Persistence and delivery
  must land together; this module is the persistence half, and the caller that
  arms it ships with the delivery half.

  ## Path shape

  `cert_path`/`key_path` are derived from the site slug under a configurable
  base dir (`:origin_ca_dir`, default `#{inspect(~c"/etc/caddy/cloudflare")}`),
  so two sites on one box never collide and the paths are recomputable from the
  row rather than being free text a human typed once.
  """

  require Logger

  alias BarkparkCloud.Cloudflare
  alias BarkparkCloud.Cloudflare.CSR
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Site

  @default_dir "/etc/caddy/cloudflare"

  @typedoc """
  What a successful provision hands back: the persisted `site`, the two paths
  written to it, and the PEM `certificate` + `private_key` MATERIAL the delivery
  channel must place at those paths on the box (0600).
  """
  @type provisioned :: %{
          site: Site.t(),
          cert_id: String.t(),
          cert_path: String.t(),
          key_path: String.t(),
          certificate: String.t(),
          private_key: String.t()
        }

  @doc """
  Mint an Origin CA certificate covering `hostnames` for `site` and persist
  `tls_mode: "cf_origin_ca"` with the two on-box paths.

  Returns `{:ok, provisioned()}`, or `{:error, reason}` — and on ANY failure the
  site row is left EXACTLY as it was: the persist is the last step, after the
  CSR and the mint have both succeeded, so a site never carries `cf_origin_ca`
  with no certificate behind it.

  `opts`:

    * `:key_size` — forwarded to `CSR.generate/2`.
    * `:dir` — override the on-box base directory for this call.
  """
  @spec provision(Site.t(), [String.t()], keyword()) :: {:ok, provisioned()} | {:error, term()}
  def provision(%Site{} = site, hostnames, opts \\ []) when is_list(hostnames) do
    with {:ok, %{csr: csr, private_key: private_key}} <- CSR.generate(hostnames, opts),
         {:ok, %{id: cert_id, certificate: certificate}} <-
           Cloudflare.create_origin_ca_cert(hostnames, csr),
         paths = cert_paths(site, opts),
         {:ok, bound} <-
           Registry.set_cf_binding(site, %{
             tls_mode: "cf_origin_ca",
             cf_cert_path: paths.cert_path,
             cf_key_path: paths.key_path
           }) do
      {:ok,
       %{
         site: bound,
         cert_id: cert_id,
         cert_path: paths.cert_path,
         key_path: paths.key_path,
         certificate: certificate,
         private_key: private_key
       }}
    else
      {:error, reason} ->
        # The site row is untouched on this branch — say so, so an operator
        # reading the log does not go looking for a half-written binding.
        Logger.error(
          "cloudflare_origin_ca_provision_failed site=#{site.id} hostnames=#{inspect(hostnames)} " <>
            "reason=#{inspect(reason)} (binding NOT persisted; the site keeps its previous tls_mode)"
        )

        {:error, reason}
    end
  end

  @doc """
  The on-box cert/key paths for `site` — pure, so a caller (or the delivery
  channel) can recompute them from the row instead of storing a second copy.
  """
  @spec cert_paths(Site.t(), keyword()) :: %{cert_path: String.t(), key_path: String.t()}
  def cert_paths(%Site{slug: slug}, opts \\ []) do
    dir = Keyword.get(opts, :dir) || configured_dir()

    %{
      cert_path: Path.join(dir, "#{slug}.origin.crt"),
      key_path: Path.join(dir, "#{slug}.origin.key")
    }
  end

  @doc """
  Is the Origin CA credential wired? A SEPARATE question from
  `Cloudflare.configured?/0` (the scoped API token): a deployment can hold a
  perfectly good API token and still be unable to mint an origin certificate,
  and conflating the two is how a caller reaches `POST /certificates` with the
  wrong authority. Fail-closed: `false` unless a non-empty key is present.
  """
  @spec configured?() :: boolean()
  def configured? do
    case Cloudflare.resolved_config()[:origin_ca_key] do
      key when is_binary(key) and key != "" -> true
      _ -> false
    end
  end

  defp configured_dir do
    case Cloudflare.resolved_config()[:origin_ca_dir] do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> @default_dir
    end
  end
end
