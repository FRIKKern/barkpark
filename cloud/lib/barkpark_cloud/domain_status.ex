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

  ## The estate (the name the plane actually serves)

  Every instance has one PLATFORM domain — the host of its stored `url`, which
  is the name go-live reserved, the worker stood up, and TLS was issued for —
  and, when attached, one CUSTOM domain (`custom_host`, a scalar: 0 or 1). Each
  is checked against the instance's reported `host` (the box's actual address).

  `Barkpark.provisioning_fqdn/1` is NOT that name in general: it is always the
  suffixed `<slug>-<team_short_id>` form, while go-live prefers the clean
  `<slug>` form whenever the label is free. It remains the fallback for a row
  that has no `url` yet.

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
    4. `serving`     — a fully verified-TLS `:httpc` GET returns < 500 (the
       `Verify` doctrine: a 302/401/404 proves the DNS→TLS→routing→app chain —
       a healthy instance root REDIRECTS, so requiring 2xx would red-line every
       live box). Independent of `tls`: a valid cert with the app down is
       `tls: ok, serving: failed`.

  A stage DOWNSTREAM of a non-ok stage is `pending` (skipped, not probed) — the
  chain stops at the first blocker so the operator reads top-down to the cause.

  ## `unknown`: a check we could not MAKE is not a check that failed to pass

  A stage that was ATTEMPTED and could not be measured is `unknown` — the word
  this schema already ratified for exactly this condition (`Registry` health:
  `~w(unknown up down)`, and `mark_offline/1`'s "NOT `down` — we cannot probe").
  Today's only source is the resolver: a raise, an exit, a `{:error, _}` return
  or a nameserver-less box makes `resolve_all/2` unable to answer, and folding
  that into an empty address list would make the control plane say "no A/AAAA
  record has propagated yet" — a definite claim about the OPERATOR's DNS — with
  "give it a moment and re-check" attached, when the truth is "our lookup
  failed". Three rules make it honest:

    * ORDERING is `failed > unknown > pending > ok`, an explicit clause in
      `overall/1`. `pending` is a PROMISE (this will turn green on its own);
      `unknown` promises nothing, so it must OUTRANK pending — otherwise a
      domain with one unmeasurable rung still tells the person to wait.
    * CONTAINMENT: only a stage that actually RAN may be `unknown`. Stages
      skipped behind a blocker (`run_or_skip/5`) stay `pending`, so a normally
      waiting domain never flips.
    * NO REMEDIATION: `build_stage/5` returns `nil` for an `unknown` stage.
      `FailureCopy.domain_stage_remediation/2` is keyed on the STAGE and can only
      advise about the operator's own configuration; it structurally cannot say
      "we could not check". The honest copy lives in the EVIDENCE string, and the
      fix is the ABSENCE of advice.

  ## Two subjects: a Barkpark box, or a co-located Site

  `check/2` accepts either a `%Barkpark{}` (its platform FQDN + optional custom
  host) or a `%Site{}` (its `domains` array, each checked against the box it
  runs on — `site.barkpark.host`, read from the preloaded association). Both walk
  the identical four-stage chain; the only difference is the estate and the
  serving MODE.

  ## Serving mode (CF-in-front, charter D56)

  A Site carries a `serving_mode`, read STRAIGHT FROM THE RECORD, never inferred
  from a resolved IP:

    * `:direct` (the default, and every Barkpark) — the box is the origin, so
      `points_here` is the exact `addr == box` intersection.
    * `:cf_proxied` — the box sits behind Cloudflare's orange-cloud proxy, so the
      domain resolves to CF's anycast EDGE IPs, not the origin. An `addr == box`
      comparison would ALWAYS red (a false failure), so we never run it:
      `points_here` is classified `:proxied` — informational, not a failure — and
      TLS/serving (which probe THROUGH the CF edge) continue. The stronger
      CF→my-origin health probe is deferred (`cf-origin-health-rung-backlog`).

  Mode is read via `Map.get/2` with a `:direct` fallback, so an instance whose
  schema predates the `serving_mode` column degrades to today's exact
  standalone behaviour (fail-closed to `:direct`).

  ## Total over failure, bounded

  `check/2` NEVER raises. Every seam is bounded (the default transports carry
  ~5s connect/request timeouts) and the estate is at most two hosts, so the
  synchronous checklist can't wedge the route on a hung box — a timing-out probe
  is a first-class `pending` / `failed` stage, not a hang. All remediation copy
  is server-owned (`FailureCopy.domain_stage_remediation/2`) so the console and
  CLI render one voice and can never drift.
  """

  alias BarkparkCloud.FailureCopy
  alias BarkparkCloud.Registry.{Barkpark, Site}

  @dns_label "DNS resolves"
  @points_label "Points to this instance"
  @tls_label "TLS certificate"
  @serving_label "Serving traffic"

  # Server-generated evidence is bounded already; this is a belt-and-braces cap
  # so a pathological host string can never bloat the envelope.
  @max_evidence_bytes 240

  @type status :: :ok | :pending | :failed | :proxied | :unknown

  @type serving_mode :: :direct | :cf_proxied

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
  @spec check(Barkpark.t() | Site.t(), keyword()) :: result()
  def check(instance, opts \\ [])

  def check(%Barkpark{} = bp, opts) do
    seams = resolve_seams(opts)
    # The box IS the origin (mode is always :direct) — resolve its address once,
    # then compare every domain against it.
    expected = expected_addrs(bp.host, seams)

    domains =
      bp
      |> domain_estate()
      |> Enum.map(fn {host, kind} -> probe_domain(host, kind, :direct, expected, seams) end)

    envelope(bp.id, bp.host, domains)
  end

  # A co-located Site: check each of its `domains` against the box it runs on
  # (`site.barkpark.host`, from the preloaded association), in the site's own
  # serving mode. A :cf_proxied site never compares addr == box (see @moduledoc).
  def check(%Site{} = site, opts) do
    seams = resolve_seams(opts)
    mode = serving_mode(site)
    box = site_box_host(site)
    expected = expected_addrs(box, seams)

    domains =
      site
      |> site_estate()
      |> Enum.map(fn {host, kind} -> probe_domain(host, kind, mode, expected, seams) end)

    envelope(site.id, box, domains)
  end

  # The shared S13b response envelope. `ok` is true only when EVERY domain is
  # overall ok (an informational :proxied rung does not count against it).
  defp envelope(id, host, domains) do
    %{
      ok: Enum.all?(domains, &(&1.overall == "ok")),
      checked_at: DateTime.to_iso8601(DateTime.utc_now()),
      instance: %{id: id, host: host},
      domains: domains
    }
  end

  # ── estate ──

  # The platform domain always; the one custom host only when attached.
  #
  # The platform domain is the host of the STORED `url` — NOT
  # `Barkpark.provisioning_fqdn/1`. `provisioning_fqdn/1` is unconditionally the
  # SUFFIXED `<slug>-<team_short_id>` form, but go-live PREFERS the clean form
  # (`Registry.insert_with_url_reservation/4`: `if reserved?(slug), do: suffixed,
  # else: clean_url(slug)`) and the router hands the provisioner
  # `Barkpark.subdomain_from_url(bp)` — the url-derived label. So the name that
  # is actually stood up, issued a certificate, and sent to the customer is the
  # one in `url`, and checking the suffixed name instead left live instances
  # stuck at `dns_found: pending` ("give it a moment and re-check") for a
  # hostname nothing ever creates. `url` IS the domain of record; the suffixed
  # FQDN is only the fallback for pre-reservation rows that have no url yet.
  defp domain_estate(bp) do
    platform = {platform_host(bp), "platform"}

    case bp.custom_host do
      host when is_binary(host) and host != "" -> [platform, {host, "custom"}]
      _ -> [platform]
    end
  end

  # The hostname of the stored `url`: scheme stripped, path and any port
  # dropped. A row with no url (or a url that yields no host) falls back to
  # `provisioning_fqdn/1` — the pre-reservation shape, where the suffixed FQDN
  # genuinely IS the only name there is.
  #
  # Self-normalises `trim |> downcase` before stripping — the SAME fold as
  # `Barkpark.subdomain_from_url/1` and the write-side `normalize_url` (D865,
  # cch-w71-bl). This was the last divergent spelling of the url-to-host rule:
  # without the downcase, an uppercase scheme defeats the case-sensitive
  # `replace_prefix` and the "host" this yields is the SCHEME LABEL (`"HTTPS"`),
  # so the console would probe (and report remediation copy for) a name nothing
  # ever creates — for old rows, the pre-`normalize_url` write window, and any
  # changeset-bypassing write. DNS names are case-insensitive, so downcasing the
  # host is lossless for the probes this feeds.
  defp platform_host(%Barkpark{url: url} = bp) when is_binary(url) do
    host =
      url
      |> String.trim()
      |> String.downcase()
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("http://", "")
      |> String.split("/", parts: 2)
      |> hd()
      |> String.split(":", parts: 2)
      |> hd()

    if host == "", do: Barkpark.provisioning_fqdn(bp), else: host
  end

  defp platform_host(bp), do: Barkpark.provisioning_fqdn(bp)

  # A Site's estate is its custom domains array (the apex, www, and any attached
  # hostnames). Each is a "custom" domain for remediation-copy purposes. A site
  # with no domains yet has an empty estate (nothing to check → ok).
  defp site_estate(%Site{domains: domains}) when is_list(domains) do
    Enum.map(domains, fn host -> {host, "custom"} end)
  end

  defp site_estate(_), do: []

  # The box a Site runs on, from the preloaded `:barkpark` association. Absent /
  # not-loaded → nil, which makes points_here honestly pending ("no address
  # reported yet") rather than raising.
  defp site_box_host(%Site{barkpark: %Barkpark{host: host}}), do: host
  defp site_box_host(_), do: nil

  # The serving mode, read STRAIGHT FROM THE RECORD (never inferred from a
  # resolved IP). `Map.get/2` — not struct access — so a row whose schema
  # predates the `serving_mode` column degrades to :direct (fail-closed to pure
  # standalone). Accepts the Ecto.Enum atom or a raw string; anything else is
  # :direct.
  @spec serving_mode(Site.t()) :: serving_mode()
  defp serving_mode(site) do
    case Map.get(site, :serving_mode) do
      :cf_proxied -> :cf_proxied
      "cf_proxied" -> :cf_proxied
      _ -> :direct
    end
  end

  # ── per-domain stage chain ──

  # Walk the four stages in order; a stage downstream of a non-ok stage is
  # skipped into `pending` rather than probed, so we never render a red on a
  # check that couldn't meaningfully run yet.
  defp probe_domain(host, kind, mode, expected, seams) do
    {dns_status, dns_stage, addrs} = probe_dns(host, kind, seams)

    {points_status, points_stage} =
      run_or_skip(dns_status, :points_here, @points_label, kind, fn ->
        probe_points_here(host, kind, mode, expected, addrs)
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

  # Skipped behind an UNMEASURABLE stage. Its own status stays `pending` (it was
  # never attempted — containment), but it carries NO advice: the whole chain
  # below a check we could not make is un-diagnosed, and FailureCopy's
  # stage-keyed copy ("this domain resolves, but not to this instance's
  # address…") would be exactly the guess this fix removes one rung up. The
  # CONTROL-FLOW atom stays :unknown so the rest of the chain inherits the same
  # silence — the rendered status does not.
  defp run_or_skip(:unknown, stage, label, kind, _fun) do
    skipped =
      build_stage(
        stage,
        label,
        :pending,
        "Not checked yet — an earlier step couldn't be checked.",
        kind
      )

    {:unknown, %{skipped | remediation: nil}}
  end

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
    case resolve_all(host, seams.dns) do
      # The lookup itself could not be made — NOT a verdict on the operator's
      # records. Say so, and attach no advice (build_stage nils it).
      {:error, reason} ->
        {:unknown,
         build_stage(
           :dns_found,
           @dns_label,
           :unknown,
           "Could not check whether #{host} resolves — this control plane's DNS lookup failed (#{describe(reason)}). This is not a verdict on your records.",
           kind
         ), []}

      {:ok, []} ->
        {:pending,
         build_stage(
           :dns_found,
           @dns_label,
           :pending,
           "No A/AAAA record for #{host} has propagated yet.",
           kind
         ), []}

      {:ok, addrs} ->
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

  # points_here (:cf_proxied): the domain is served THROUGH Cloudflare's
  # orange-cloud proxy, so it resolves to CF's anycast edge IPs, NOT the box
  # origin. An addr == box comparison would always red (a false failure), so we
  # never run it — the mode is read from the Site record, never inferred from the
  # resolved IP. Classify it :proxied (informational, no remediation) and return
  # a control-flow :ok so TLS/serving still probe through the CF edge. The
  # stronger CF→origin health probe is deferred (cf-origin-health-rung-backlog).
  defp probe_points_here(host, kind, :cf_proxied, _expected, addrs) do
    {:ok,
     build_stage(
       :points_here,
       @points_label,
       :proxied,
       proxied_evidence(host, addrs),
       kind
     )}
  end

  # points_here (:direct): do the resolved addresses include the box's own
  # address? An empty box address (still provisioning) is pending; resolving
  # elsewhere is failed.
  defp probe_points_here(host, kind, :direct, expected, addrs) do
    case expected do
      # The box's OWN address is a name we could not resolve — the second lie
      # from the same collapse. "This instance hasn't reported an address yet"
      # would be false (it reported a hostname); we simply could not look it up.
      {:error, reason} ->
        {:unknown,
         build_stage(
           :points_here,
           @points_label,
           :unknown,
           "Could not check where #{host} points — looking up this instance's own address failed (#{describe(reason)}). This is not a verdict on your records.",
           kind
         )}

      {:ok, []} ->
        {:pending,
         build_stage(
           :points_here,
           @points_label,
           :pending,
           "This instance hasn't reported an address yet.",
           kind
         )}

      {:ok, expected} ->
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

  # Informational evidence for a CF-proxied domain — states plainly that origin
  # pointing is Cloudflare's to manage and is deliberately NOT compared here.
  defp proxied_evidence(host, []) do
    "#{host} is proxied through Cloudflare — its DNS points at Cloudflare's edge, not this box, so origin pointing is managed by Cloudflare (not compared here)."
  end

  defp proxied_evidence(host, addrs) do
    "#{host} resolves to Cloudflare's edge (#{Enum.join(addrs, ", ")}); it is proxied, so origin pointing is managed by Cloudflare, not compared to the box."
  end

  # The box's address set: a literal IP host is itself the target (round-tripped
  # through parse+ntoa so a non-canonical stored IPv6 like "2001:0db8::1" still
  # matches the resolver's canonical form); a hostname host is resolved (so a
  # CNAME-style box still compares honestly). An empty/nil host is `{:ok, []}`
  # (genuinely nothing reported → pending); a resolver that could not answer for
  # the box host is `{:error, reason}` (→ points_here unknown), NEVER an empty
  # set — "hasn't reported an address yet" would be a different, false claim.
  defp expected_addrs(host, _seams) when not is_binary(host) or host == "", do: {:ok, []}

  defp expected_addrs(host, seams) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, addr} -> {:ok, [ip_to_string(addr)]}
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

  # serving: a fully verified-TLS GET must return < 500. This is the Verify
  # doctrine (`< 500` proves the whole request→TLS→routing→app chain): a live
  # instance's root REDIRECTS (302 → login/studio, proven on prod), so a strict
  # 2xx here would mark every healthy box serving:failed. 5xx = the domain and
  # cert work but the app behind them is broken.
  defp probe_serving(host, kind, seams) do
    url = "https://" <> host

    case safe_call(fn -> seams.http.(url) end) do
      {:ok, status} when is_integer(status) and status >= 200 and status < 500 ->
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

  # Severity ordering: failed > unknown > pending > ok. The `unknown` clause is
  # EXPLICIT and sits ABOVE both `pending` and the terminal `ok` on purpose —
  # without it a rung nobody could measure either reads as a promise ("pending",
  # it'll turn green on its own) or, with no pending rungs left, lets the
  # envelope seal `ok: true` over an unmeasured rung.
  defp overall(stages) do
    cond do
      Enum.any?(stages, &(&1.status == "failed")) -> "failed"
      Enum.any?(stages, &(&1.status == "unknown")) -> "unknown"
      Enum.any?(stages, &(&1.status == "pending")) -> "pending"
      true -> "ok"
    end
  end

  # Build one stage map. A healthy stage (:ok, or the informational :proxied)
  # carries no remediation, and neither does an :unknown one — FailureCopy is
  # keyed on the STAGE and can only advise about the operator's configuration, so
  # attaching it to a check we could not MAKE turns "we could not look" into
  # "your DNS hasn't propagated, give it a moment". The honest copy is the
  # evidence string; the fix is the ABSENCE of advice. Every actionable non-ok
  # stage (:pending / :failed) still gets server-owned copy from FailureCopy
  # (which has a terminal default clause, so no such stage is ever reason-less).
  defp build_stage(stage, label, status, evidence, kind) do
    stage_name = to_string(stage)

    %{
      stage: stage_name,
      label: label,
      status: to_string(status),
      evidence: truncate(evidence),
      remediation:
        if status in [:ok, :proxied, :unknown] do
          nil
        else
          FailureCopy.domain_stage_remediation(kind, stage_name)
        end
    }
  end

  # ── outbound plumbing ──

  # Resolve a host over inet + inet6 (the SafeUrl.resolve_and_check/1 idiom) and
  # return de-duplicated address STRINGS — DISCRIMINATED, never collapsed:
  #
  #   * `{:ok, addrs}` — at least one family answered with addresses.
  #   * `{:ok, []}`    — every family answered, and the answer was empty (an
  #     empty list, or an authoritative `:nxdomain`). This is a MEASUREMENT: the
  #     record genuinely hasn't propagated.
  #   * `{:error, reason}` — nothing answered and at least one family faulted
  #     (a raise, an exit, a timeout, a nameserver-less box, or an off-contract
  #     return value). This is the ABSENCE of a measurement.
  #
  # A fault on ONE family while the other answers is still `{:ok, addrs}` — we
  # measured the thing we needed to measure. Never raises (`safe_call/1`).
  #
  # `:nxdomain` IS AN ANSWER, NOT A FAULT — decided at review, superseding the
  # letter of charter D332 (which listed it among the faults). The builder
  # measured the transport and filed the contradiction rather than deciding it
  # (task-3fbfff8c97b50c8f): `:inet.getaddrs(~c"no-such-host.example", :inet)`
  # and the same on `:inet6` BOTH return `{:error, :nxdomain}`, re-measured at
  # review on this host. That is exactly what a freshly-attached, still-
  # propagating domain looks like through the real resolver — so classifying it
  # as a fault would turn the MOST COMMON waiting state into "we could not
  # check", strip its propagation advice, and replace one lie with another in
  # the same rung this slice exists to make honest. `{:ok, []}` would otherwise
  # be a shape only the test fakes can produce, which is the wave's own fourth
  # standing clause (a fixture that cannot produce the production condition).
  #
  # NXDOMAIN means the resolver ANSWERED: this name does not exist. That is a
  # measurement, and its honest rendering is `pending` + "hasn't propagated
  # yet". A FAULT is the absence of an answer: a raise, an exit, a timeout, a
  # nameserver-less box, an off-contract return.
  @answered_empty [:nxdomain]

  defp resolve_all(host, dns_fun) do
    charlist = to_charlist(host)

    results =
      Enum.map([:inet, :inet6], fn family ->
        case safe_call(fn -> dns_fun.(charlist, family) end) do
          {:ok, list} when is_list(list) -> {:ok, list}
          {:error, reason} when reason in @answered_empty -> {:ok, []}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_resolver_result, other}}
        end
      end)

    addrs =
      results
      |> Enum.flat_map(fn
        {:ok, list} -> list
        {:error, _} -> []
      end)
      |> Enum.map(&ip_to_string/1)
      |> Enum.uniq()

    case {addrs, Enum.find(results, &match?({:error, _}, &1))} do
      {[], {:error, reason}} -> {:error, reason}
      {addrs, _} -> {:ok, addrs}
    end
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
  defp describe(:no_nameservers), do: "no nameservers configured"
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
