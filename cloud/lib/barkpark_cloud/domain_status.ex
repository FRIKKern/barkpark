defmodule BarkparkCloud.DomainStatus do
  @moduledoc """
  Per-domain, per-stage domain/TLS truth — the control plane's honest answer to
  "why isn't my domain working?" (charter S13). The Elixir sibling of
  `BarkparkCloud.Verify`: a structured probe envelope, TOTAL over failure, with
  every outbound primitive behind a resolved-at-call-time injectable seam so the
  whole checklist is driven offline by fakes (no test touches the network).

  Where Verify proves the golden PATH answers over the wire, this proves the
  DOMAIN in front of it — DNS, the A/AAAA target, the certificate, and the
  serving response — one ordered stage at a time, so the console (S13b) and CLI
  can render a Vercel-grade "DNS found → points here → TLS issued → serving"
  checklist that says exactly where a domain is stuck AND what to do about it.

  ## The estate (never parse a URL ad hoc)

  Every instance has one PLATFORM domain — `Barkpark.provisioning_fqdn/1`, the
  same FQDN the warm-pool worker provisions — and, when attached, one CUSTOM
  domain (`custom_host`, a scalar: 0 or 1). Each is checked against the
  instance's reported `host` (the box's actual address).

  ## The four ordered stages

    1. `dns_found`   — the domain resolves publicly (`:inet.getaddrs` over inet +
       inet6, the `Notifications.SafeUrl` idiom). This is a PUBLIC resolution,
       NEVER a zone read — the control plane holds no DNS token. A miss is
       `pending` (records propagate for up to a minute), NEVER `failed`.
    2. `points_here` — the resolved addresses include the instance's `host`. An
       empty `host` (still provisioning) is `pending`; resolving to a DIFFERENT
       address is `failed` (a real misconfiguration).
    3. `tls`         — a certificate is served and structurally valid
       (`:ssl.connect` + `:ssl.peercert` + a dep-free `:public_key` validity /
       issuer decode). No cert / a temporary self-signed cert is `pending` (it's
       still being issued); an expired / not-yet-valid cert is `failed`.
    4. `serving`     — a fully verified-TLS `:httpc` GET returns 2xx. Independent
       of `tls`: a valid cert with the app down is `tls: ok, serving: failed`.

  A stage DOWNSTREAM of a non-ok stage is `pending` (skipped, not probed) — the
  chain stops at the first blocker so the operator reads top-down to the cause.

  ## Total over failure, bounded

  `check/2` NEVER raises. Every seam is bounded (the default transports carry
  ~5s connect/request timeouts) and the estate is at most two hosts, so the
  synchronous checklist can't wedge the route on a hung box — a timing-out probe
  is a first-class `pending` / `failed` stage, not a hang. All remediation copy
  is server-owned (`FailureCopy.domain_stage_remediation/2`) so the console and
  CLI render one voice and can never drift.
  """

  alias BarkparkCloud.FailureCopy
  alias BarkparkCloud.Registry.Barkpark

  @dns_label "DNS resolves"
  @points_label "Points to this instance"
  @tls_label "TLS certificate"
  @serving_label "Serving traffic"

  # Server-generated evidence is bounded already; this is a belt-and-braces cap
  # so a pathological host string can never bloat the envelope.
  @max_evidence_bytes 240

  @type status :: :ok | :pending | :failed

  @type stage :: %{
          stage: String.t(),
          label: String.t(),
          status: String.t(),
          evidence: String.t(),
          remediation: String.t() | nil
        }

  @type domain :: %{
          host: String.t(),
          kind: String.t(),
          overall: String.t(),
          stages: [stage()]
        }

  @type result :: %{
          ok: boolean(),
          checked_at: String.t(),
          instance: %{id: String.t(), host: String.t() | nil},
          domains: [domain()]
        }

  @doc """
  Probe the instance's whole domain estate and return the S13b response
  envelope. `opts` may override the three outbound seams (`:dns`, `:tls`,
  `:http`) per call; otherwise they resolve from config at call time, defaulting
  to the real transports. Never raises.
  """
  @spec check(Barkpark.t(), keyword()) :: result()
  def check(barkpark, opts \\ [])

  def check(%Barkpark{} = bp, opts) do
    seams = resolve_seams(opts)

    domains =
      bp
      |> domain_estate()
      |> Enum.map(fn {host, kind} -> probe_domain(bp, host, kind, seams) end)

    %{
      ok: Enum.all?(domains, &(&1.overall == "ok")),
      checked_at: DateTime.to_iso8601(DateTime.utc_now()),
      instance: %{id: bp.id, host: bp.host},
      domains: domains
    }
  end

  # ── estate ──

  # Platform FQDN always; the one custom host only when attached. Never parse the
  # stored url — provisioning_fqdn/1 is the single source the worker also uses.
  defp domain_estate(bp) do
    platform = {Barkpark.provisioning_fqdn(bp), "platform"}

    case bp.custom_host do
      host when is_binary(host) and host != "" -> [platform, {host, "custom"}]
      _ -> [platform]
    end
  end

  # ── per-domain stage chain ──

  # Walk the four stages in order; a stage downstream of a non-ok stage is
  # skipped into `pending` rather than probed, so we never render a red on a
  # check that couldn't meaningfully run yet.
  defp probe_domain(bp, host, kind, seams) do
    {dns_status, dns_stage, addrs} = probe_dns(host, kind, seams)

    {points_status, points_stage} =
      run_or_skip(dns_status, :points_here, @points_label, kind, fn ->
        probe_points_here(host, bp, kind, seams, addrs)
      end)

    {tls_status, tls_stage} =
      run_or_skip(points_status, :tls, @tls_label, kind, fn ->
        probe_tls(host, kind, seams)
      end)

    {_serving_status, serving_stage} =
      run_or_skip(tls_status, :serving, @serving_label, kind, fn ->
        probe_serving(host, kind, seams)
      end)

    stages = [dns_stage, points_stage, tls_stage, serving_stage]

    %{host: host, kind: kind, overall: overall(stages), stages: stages}
  end

  # Run the probe only when the upstream stage is ok; otherwise skip it into a
  # pending stage (still reason-bearing — every non-ok stage carries remediation).
  defp run_or_skip(:ok, _stage, _label, _kind, fun), do: fun.()

  defp run_or_skip(_blocked, stage, label, kind, _fun) do
    {:pending,
     build_stage(
       stage,
       label,
       :pending,
       "Not checked yet — an earlier step isn't passing.",
       kind
     )}
  end

  # dns_found: public resolution over both families (SafeUrl idiom). Empty is
  # pending (propagating), never failed. Carries the resolved address set forward
  # so points_here doesn't resolve twice.
  defp probe_dns(host, kind, seams) do
    addrs = resolve_all(host, seams.dns)

    if addrs == [] do
      {:pending,
       build_stage(
         :dns_found,
         @dns_label,
         :pending,
         "No A/AAAA record for #{host} has propagated yet.",
         kind
       ), addrs}
    else
      {:ok,
       build_stage(
         :dns_found,
         @dns_label,
         :ok,
         "Resolves to #{Enum.join(addrs, ", ")}.",
         kind
       ), addrs}
    end
  end

  # points_here: do the resolved addresses include the instance's host? An empty
  # host (still provisioning) is pending; resolving elsewhere is failed.
  defp probe_points_here(host, bp, kind, seams, addrs) do
    case expected_addrs(bp, seams) do
      [] ->
        {:pending,
         build_stage(
           :points_here,
           @points_label,
           :pending,
           "This instance hasn't reported an address yet.",
           kind
         )}

      expected ->
        case Enum.find(addrs, &(&1 in expected)) do
          nil ->
            {:failed,
             build_stage(
               :points_here,
               @points_label,
               :failed,
               "#{host} resolves to #{Enum.join(addrs, ", ")}, not this instance (#{Enum.join(expected, ", ")}).",
               kind
             )}

          match ->
            {:ok,
             build_stage(
               :points_here,
               @points_label,
               :ok,
               "#{host} resolves to #{match}, this instance's address.",
               kind
             )}
        end
    end
  end

  # The instance's address set: a literal IP host is itself the target; a
  # hostname host is resolved (so a CNAME-style box still compares honestly).
  defp expected_addrs(%Barkpark{host: host}, _seams) when not is_binary(host) or host == "",
    do: []

  defp expected_addrs(%Barkpark{host: host}, seams) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, _addr} -> [host]
      {:error, _} -> resolve_all(host, seams.dns)
    end
  end

  # tls: a served, structurally-valid certificate. No cert / self-signed is
  # pending (being issued); expired / not-yet-valid is failed. Trust itself is
  # enforced end-to-end by the serving stage's verify_peer GET.
  defp probe_tls(host, kind, seams) do
    case safe_call(fn -> seams.tls.(host, 443) end) do
      {:ok, %{} = cert} ->
        classify_cert(cert, kind)

      {:error, reason} ->
        {:pending,
         build_stage(
           :tls,
           @tls_label,
           :pending,
           "No certificate is being served yet (#{describe(reason)}).",
           kind
         )}
    end
  end

  defp classify_cert(cert, kind) do
    now = DateTime.utc_now()

    cond do
      DateTime.compare(now, cert.not_before) == :lt ->
        {:failed,
         build_stage(
           :tls,
           @tls_label,
           :failed,
           "Certificate isn't valid until #{iso(cert.not_before)} (issuer #{cert.issuer}).",
           kind
         )}

      DateTime.compare(now, cert.not_after) == :gt ->
        {:failed,
         build_stage(
           :tls,
           @tls_label,
           :failed,
           "Certificate expired on #{iso(cert.not_after)} (issuer #{cert.issuer}).",
           kind
         )}

      cert.self_signed? ->
        {:pending,
         build_stage(
           :tls,
           @tls_label,
           :pending,
           "A temporary self-signed certificate is being served while the trusted one is issued (issuer #{cert.issuer}).",
           kind
         )}

      true ->
        {:ok,
         build_stage(
           :tls,
           @tls_label,
           :ok,
           "Valid certificate from #{cert.issuer}, expires #{iso(cert.not_after)}.",
           kind
         )}
    end
  end

  # serving: a fully verified-TLS GET must return 2xx. Independent of tls.
  defp probe_serving(host, kind, seams) do
    url = "https://" <> host

    case safe_call(fn -> seams.http.(url) end) do
      {:ok, status} when is_integer(status) and status >= 200 and status < 300 ->
        {:ok, build_stage(:serving, @serving_label, :ok, "HTTPS GET #{url} → #{status}.", kind)}

      {:ok, status} when is_integer(status) ->
        {:failed,
         build_stage(:serving, @serving_label, :failed, "HTTPS GET #{url} → #{status}.", kind)}

      {:error, reason} ->
        {:failed,
         build_stage(
           :serving,
           @serving_label,
           :failed,
           "HTTPS GET #{url} failed (#{describe(reason)}).",
           kind
         )}
    end
  end

  # ── envelope helpers ──

  # A domain is failed if any stage failed, else pending if any stage is pending,
  # else ok. `ok` beats `pending` beats `failed` in severity ordering.
  defp overall(stages) do
    cond do
      Enum.any?(stages, &(&1.status == "failed")) -> "failed"
      Enum.any?(stages, &(&1.status == "pending")) -> "pending"
      true -> "ok"
    end
  end

  # Build one stage map. An ok stage carries no remediation; every non-ok stage
  # gets server-owned copy from FailureCopy (which has a terminal default clause,
  # so no non-ok stage is ever reason-less).
  defp build_stage(stage, label, status, evidence, kind) do
    stage_name = to_string(stage)

    %{
      stage: stage_name,
      label: label,
      status: to_string(status),
      evidence: truncate(evidence),
      remediation:
        if status == :ok do
          nil
        else
          FailureCopy.domain_stage_remediation(kind, stage_name)
        end
    }
  end

  # ── outbound plumbing ──

  # Resolve a host over inet + inet6 (the SafeUrl.resolve_and_check/1 idiom) and
  # return de-duplicated address STRINGS. A resolver error on either family is an
  # empty contribution, never a raise.
  defp resolve_all(host, dns_fun) do
    charlist = to_charlist(host)

    [:inet, :inet6]
    |> Enum.flat_map(fn family ->
      case safe_call(fn -> dns_fun.(charlist, family) end) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end
    end)
    |> Enum.map(&ip_to_string/1)
    |> Enum.uniq()
  end

  defp ip_to_string(addr) when is_tuple(addr), do: addr |> :inet.ntoa() |> to_string()
  defp ip_to_string(addr) when is_binary(addr), do: addr
  defp ip_to_string(addr), do: to_string(addr)

  # Never let a seam raise escape — total-over-failure: a raise becomes a
  # `{:error, ...}`, which every stage already handles as its non-ok path.
  defp safe_call(fun) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # ── seams ──

  # Resolved at CALL time: a per-call opts override wins, else config, else the
  # real transport. This is what lets fakes drive every stage combination offline.
  defp resolve_seams(opts) do
    %{
      dns:
        opts[:dns] ||
          Application.get_env(:barkpark_cloud, :domain_status_dns, &default_getaddrs/2),
      tls:
        opts[:tls] ||
          Application.get_env(
            :barkpark_cloud,
            :domain_status_tls,
            &BarkparkCloud.DomainStatus.TlsDialer.probe/2
          ),
      http:
        opts[:http] ||
          Application.get_env(
            :barkpark_cloud,
            :domain_status_http,
            &BarkparkCloud.DomainStatus.HttpClient.get_status/1
          )
    }
  end

  defp default_getaddrs(charlist, family), do: :inet.getaddrs(charlist, family)

  # ── copy / formatting ──

  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso(other), do: inspect(other)

  defp describe(:timeout), do: "timed out"
  defp describe(:econnrefused), do: "connection refused"
  defp describe(:closed), do: "connection closed"
  defp describe(:nxdomain), do: "no such host"
  defp describe({:tls_alert, _} = alert), do: inspect(alert)
  defp describe(reason) when is_atom(reason), do: to_string(reason)
  defp describe(reason), do: reason |> inspect() |> truncate()

  defp truncate(text) when is_binary(text) do
    if byte_size(text) <= @max_evidence_bytes do
      text
    else
      text |> binary_part(0, @max_evidence_bytes) |> valid_prefix() |> Kernel.<>("…")
    end
  end

  defp truncate(other), do: to_string(other)

  defp valid_prefix(bin) do
    if String.valid?(bin) do
      bin
    else
      case bin do
        <<>> -> <<>>
        _ -> valid_prefix(binary_part(bin, 0, byte_size(bin) - 1))
      end
    end
  end
end

defmodule BarkparkCloud.DomainStatus.TlsDialer do
  @moduledoc """
  The default TLS probe seam for `BarkparkCloud.DomainStatus` — a dep-free
  `:ssl.connect` + `:ssl.peercert` + `:public_key` decode. It connects with
  `verify: :verify_none` so it always OBTAINS whatever certificate the host
  serves (trust is the serving stage's job, via a verify_peer GET); the decode
  extracts the validity window, the issuer common name, and whether the cert is
  self-signed (issuer == subject) so the caller can distinguish no-cert /
  self-signed / expired / valid.

  Returns `{:ok, %{not_before, not_after, issuer, self_signed?}}` on a served
  cert, or `{:error, reason}` when no cert is available (connection refused, a
  handshake that yields no peer cert, a timeout, …). Bounded by a ~5s connect
  timeout so it can never wedge the synchronous checklist. Tests inject a fake
  seam, so this real transport is never exercised offline (the
  `Verify.HttpClient` discipline).
  """

  require Record

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  @connect_timeout 5_000

  @spec probe(String.t(), :inet.port_number()) ::
          {:ok,
           %{
             not_before: DateTime.t(),
             not_after: DateTime.t(),
             issuer: String.t(),
             self_signed?: boolean()
           }}
          | {:error, term()}
  def probe(host, port) do
    host_cl = to_charlist(host)

    opts = [
      verify: :verify_none,
      server_name_indication: host_cl,
      active: false,
      depth: 3,
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]

    case :ssl.connect(host_cl, port, opts, @connect_timeout) do
      {:ok, socket} ->
        result = :ssl.peercert(socket)
        :ssl.close(socket)

        case result do
          {:ok, der} -> {:ok, decode(der)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp decode(der) do
    cert = :public_key.pkix_decode_cert(der, :otp)
    tbs = otp_certificate(cert, :tbsCertificate)
    {:Validity, not_before, not_after} = otp_tbs_certificate(tbs, :validity)
    issuer = otp_tbs_certificate(tbs, :issuer)
    subject = otp_tbs_certificate(tbs, :subject)

    %{
      not_before: asn1_to_datetime(not_before),
      not_after: asn1_to_datetime(not_after),
      issuer: common_name(issuer),
      self_signed?: issuer == subject
    }
  end

  # X.509 times are UTCTime (2-digit year, RFC 5280 windowing) or GeneralizedTime
  # (4-digit year). Both end in Z (UTC). Fall back to the unix epoch on anything
  # unparseable so classify never raises on an exotic encoding.
  defp asn1_to_datetime({:utcTime, chars}) do
    s = to_string(chars)
    yy = s |> String.slice(0, 2) |> String.to_integer()
    year = if yy >= 50, do: 1900 + yy, else: 2000 + yy
    from_parts(year, String.slice(s, 2, 12))
  end

  defp asn1_to_datetime({:generalTime, chars}) do
    s = to_string(chars)
    year = s |> String.slice(0, 4) |> String.to_integer()
    from_parts(year, String.slice(s, 4, 12))
  end

  defp asn1_to_datetime(_), do: DateTime.from_unix!(0)

  # `rest` is "MMDDHHMMSS" (+ trailing "Z"); build a UTC DateTime.
  defp from_parts(year, rest) do
    with month <- slice_int(rest, 0),
         day <- slice_int(rest, 2),
         hour <- slice_int(rest, 4),
         minute <- slice_int(rest, 6),
         second <- slice_int(rest, 8),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
      dt
    else
      _ -> DateTime.from_unix!(0)
    end
  end

  defp slice_int(s, offset), do: s |> String.slice(offset, 2) |> String.to_integer()

  # Pull the commonName (OID 2.5.4.3) out of an rdnSequence; "unknown" if absent.
  defp common_name({:rdnSequence, rdns}) do
    rdns
    |> List.flatten()
    |> Enum.find_value("unknown", fn
      {:AttributeTypeAndValue, {2, 5, 4, 3}, value} -> attr_string(value)
      _ -> nil
    end)
  end

  defp common_name(_), do: "unknown"

  defp attr_string({_type, value}), do: attr_string(value)
  defp attr_string(value) when is_binary(value), do: value
  defp attr_string(value) when is_list(value), do: to_string(value)
  defp attr_string(value), do: inspect(value)
end

defmodule BarkparkCloud.DomainStatus.HttpClient do
  @moduledoc """
  The default serving-probe seam for `BarkparkCloud.DomainStatus` — a
  verified-TLS `:httpc` GET (the `Verify.HttpClient` transport idiom) that
  returns just the HTTP status. Redirects are NOT auto-followed and the OS trust
  store verifies the peer, so a 2xx is an honest "serving over a trusted
  certificate" signal. Bounded by ~5s connect/request timeouts. Tests inject a
  fake, so this real transport is never exercised offline.
  """

  @timeout 5_000
  @connect_timeout 5_000

  @spec get_status(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_status(url) do
    case :httpc.request(:get, {to_charlist(url), []}, http_opts(), body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, _body}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp http_opts do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      autoredirect: false,
      timeout: @timeout,
      connect_timeout: @connect_timeout
    ]
  end
end
