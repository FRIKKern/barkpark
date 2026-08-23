defmodule BarkparkCloud.CloudflareStandaloneDegradeTest do
  @moduledoc """
  The standalone-degrade CAPSTONE for the Cloudflare-in-front capability (cf-w2,
  charter D58). Cloudflare is a FREE-superpower provider layered ON TOP of a
  complete standalone box — the same "connect a cloud account only ADDS
  capability, and disconnecting degrades gracefully" law Barkpark plugins obey.
  This case proves the DEGRADED half of that law: with **no Cloudflare provider
  connected**, everything works exactly as today — the box serves its own
  content over its own origin, and nothing on any live serving/control path
  reaches into `BarkparkCloud.Cloudflare`.

  It mirrors `api/test/barkpark/plugin_free_boot_test.exs`'s positive-assertion +
  no-coupling pattern, but LIGHTER: the Cloudflare seam supervises NO children
  (it is a call-time-config context, not an OTP tree), so there is no
  application stop/restart — the invariants are all provable in a pure unit case.

  Five proof obligations, all POSITIVE assertions (a green here means the RIGHT
  thing produced it, never absence-of-error):

    1. `Cloudflare.configured?/0` FAIL-CLOSES on an absent/blank token — `false`
       unless a non-empty token is wired (with a present-token positive control
       so the assertion can never be vacuously green).
    2. NO `Cloudflare.Client` capability fn executes on the standalone decision
       path. Proven TWO ways: (a) a RAISING client is installed as the seam and
       the standalone decision (`configured?/0`) answers without tripping it —
       the trap is provably ARMED (`client/0 == RaisingClient`), so a no-raise is
       load-bearing; (b) the real in-memory `Fake` records ZERO calls
       (`verified/records/proxied/certs` all `[]`) across the standalone surface.
    3. The SSRF guard on the shared `Billing.HttpClient` transport CF rides holds
       — a Cloudflare request map (built by the real client's PURE builders)
       maps to an `:httpc` option shape carrying `verify: :verify_peer` +
       `autoredirect: false` + the https hostname-match fun. This is the transport
       Cloudflare.Real delegates to in prod; the guard is asserted on the CF
       request shapes themselves, not a synthetic one.
    4. NO live serving/control-plane module binds a disconnected provider outside
       a reviewed allowlist. AST sweep (real `__aliases__` references, not text —
       a docstring mention is not a coupling) over `lib/barkpark_cloud`, excluding
       the provider trees themselves. The detected `{provider, host_file}` set
       must EQUAL `@sanctioned_provider_coupling`; a NEW reference reds. Cloudflare
       coupling (wired in W6: connect + DNS deploy) must stay CONFINED to the
       allowlist — each entry reviewed as a credential-gated provider path, never
       the box's standalone serving path — asserted separately (non-vacuously) so
       a NEW CF-on-a-serving-path reach reds immediately.

  ## Sibling-slice contract (`resolve_cloudflare_credential`, `serving_mode`)

  The named credential resolver `resolve_cloudflare_credential/1` (→
  `{:error, :no_cloudflare_provider}` with no provider connected) and the site
  `serving_mode`/`tls_mode` defaults ("direct"/"on_demand") are OTHER cf-w2
  slices' surfaces; they are not present in this file's worktree, so the LETTER
  of that contract is validated by the merged-suite Cloud gate (this case's
  merge-gated criterion), while its SPIRIT — "no CF binding, credential source
  empty" — is proven HERE unconditionally by obligation 1 (the credential source
  `configured?/0` is `false`) and obligation 4 (no serving-path binds CF).

  Run:

      cd cloud && CC=clang mix test test/barkpark_cloud/cloudflare_standalone_degrade_test.exs
  """

  # async: true (hg-w1-async-seam-process-scope-followup) — the config-sensitive
  # cases (installing a raising stub, clearing/setting the token) now install
  # their override in THIS TEST'S process dictionary via
  # `Cloudflare.put_process_config/1` rather than mutating the node-global
  # `:barkpark_cloud, BarkparkCloud.Cloudflare` env, so a concurrent CF case
  # never sees another test's override. See Cloudflare's moduledoc
  # "Process-scoped config override".
  use ExUnit.Case, async: true

  alias BarkparkCloud.Billing.HttpClient
  alias BarkparkCloud.Cloudflare
  alias BarkparkCloud.Cloudflare.{Fake, Real}

  # A `Cloudflare.Client` whose every callback RAISES. Installed as the seam so
  # that a standalone decision which reaches the client would CRASH the test —
  # making "no crash" a load-bearing proof of "no dispatch", never a vacuous
  # absence-of-error.
  defmodule RaisingClient do
    @behaviour BarkparkCloud.Cloudflare.Client

    @impl true
    def verify_token(_token),
      do: raise("Cloudflare.Client.verify_token/1 ran on the standalone path")

    @impl true
    def upsert_dns_record(_zone, _rec),
      do: raise("Cloudflare.Client.upsert_dns_record/2 ran on the standalone path")

    @impl true
    def ensure_zone_proxied(_zone, _rec),
      do: raise("Cloudflare.Client.ensure_zone_proxied/2 ran on the standalone path")

    @impl true
    def create_origin_ca_cert(_hosts, _csr),
      do: raise("Cloudflare.Client.create_origin_ca_cert/2 ran on the standalone path")
  end

  # ── Reviewed allowlist: live control-plane code that names a provider ────────
  #
  # Baseline measured 2026-07-14 by AST scan of every `.ex` under
  # lib/barkpark_cloud (excluding the provider trees lib/barkpark_cloud/vercel*
  # + lib/barkpark_cloud/cloudflare*) for a REAL `__aliases__` reference to
  # `BarkparkCloud.Vercel` / `BarkparkCloud.Cloudflare` (both the fully-qualified
  # form and the short alias the `alias BarkparkCloud.{Vercel, …}` multi-alias
  # leaves in code — matching only the full path silently MISSES the router and
  # is a vacuous-green trap).
  #
  # The detected set must EQUAL this allowlist:
  #
  #   * router.ex → BarkparkCloud.Vercel — the control-plane HTTP endpoint
  #     `POST /v1/barkparks/:id/vercel-deploy` (+ the `vercel: Vercel.state(bp)`
  #     dashboard field). It is gated behind `Vercel.configured?()` and 503s
  #     `feature_not_configured` when absent — it runs on the CONTROL PLANE, never
  #     on the standalone box's own site-serving path, and degrades to the classic
  #     copy-block handoff. Legitimate.
  #
  #   * router.ex → BarkparkCloud.Cloudflare — wired in W6: verify_token (connect
  #     preflight, `POST /v1/providers`) + upsert_dns_record/ensure_zone_proxied
  #     (the `--via cloudflare` deploy path, which requires a stored CF credential
  #     and 422s `cloudflare_credential_unreadable` when absent). Both run ONLY on
  #     the control-plane provider path, never the box's standalone serving path;
  #     with no CF connected neither executes. Legitimate + credential-gated.
  #
  # A NEW, unreviewed CF reference on any serving path reds this gate.
  @sanctioned_provider_coupling [
    {"BarkparkCloud.Vercel", "lib/barkpark_cloud/web/router.ex"},
    # W6 wired Cloudflare end-to-end (connect + DNS deploy). Both couplings live
    # ONLY on control-plane provider-operation paths that require a user-supplied
    # token: verify_token runs during `POST /v1/providers` (connect), and
    # upsert_dns_record/ensure_zone_proxied run only when a stored CF credential
    # is present (`cloudflare_credential_unreadable` otherwise). With no CF
    # connected, neither path executes and the box serves directly — the degrade
    # law holds. Reviewed + sanctioned.
    {"BarkparkCloud.Cloudflare", "lib/barkpark_cloud/web/router.ex"}
  ]

  # Merge Cloudflare config for one test, scoped to THIS test's process only —
  # no on_exit needed, the override dies with the test process.
  defp put_cf_config(kw) do
    base = Cloudflare.resolved_config()
    Cloudflare.put_process_config(Keyword.merge(base, kw))
  end

  # ── Obligation 1: configured?/0 fail-closes on an absent/blank token ─────────

  describe "no Cloudflare provider connected → configured?/0 fail-closes" do
    test "an absent token (nil) is unconfigured" do
      put_cf_config(token: nil)
      refute Cloudflare.configured?()
    end

    test "an empty-string token is unconfigured" do
      put_cf_config(token: "")
      refute Cloudflare.configured?()
    end

    test "positive control: a real token flips configured? true (assertion is not vacuous)" do
      put_cf_config(token: "cf_present_token")
      assert Cloudflare.configured?()
    end
  end

  # ── Obligation 2: no Cloudflare.Client capability fn runs on the standalone path

  describe "the standalone decision never dispatches to Cloudflare.Client" do
    test "with a RAISING client armed, configured?/0 answers false WITHOUT invoking it" do
      put_cf_config(client: RaisingClient, token: nil)

      # The trap is provably ARMED — the seam resolves to the raising stub, so a
      # no-raise below is load-bearing, not vacuous.
      assert Cloudflare.client() == RaisingClient

      # The standalone "should we engage Cloudflare?" decision. It must answer
      # from config alone and NEVER reach the client (else RaisingClient crashes).
      refute Cloudflare.configured?()

      # The capability MENU is pure metadata — also no dispatch.
      assert Cloudflare.capabilities() == [:dns, :tls, :cdn]
    end

    test "the Fake records ZERO capability calls across the standalone surface" do
      put_cf_config(client: Fake, token: nil)

      # Exercise every standalone-relevant query. None is a capability call, so
      # the Fake's per-process recorders must all stay empty.
      refute Cloudflare.configured?()
      assert Cloudflare.capabilities() == [:dns, :tls, :cdn]
      assert Cloudflare.client() == Fake

      assert Fake.verified() == [], "a token was verified on the standalone path"
      assert Fake.records() == [], "a DNS record was upserted on the standalone path"
      assert Fake.proxied() == [], "a zone was proxied on the standalone path"
      assert Fake.certs() == [], "an Origin CA cert was minted on the standalone path"
    end
  end

  # ── Obligation 3: SSRF guard on the transport Cloudflare rides ───────────────

  describe "SSRF guard holds on the shared Billing.HttpClient transport CF uses" do
    test "Cloudflare request shapes map to verify_peer + autoredirect:false option shape" do
      # The exact request maps Cloudflare.Real builds for the connect + DNS-write
      # flows (its PURE builders — no network). ensure_zone_proxied is :patch,
      # whose transport clause lands in the live-wiring slice, so it is excluded
      # here; the GET (verify) + POST (dns upsert) shapes cover the guard.
      cf_requests = [
        Real.verify_token_request("cf_tok"),
        Real.upsert_dns_record_request("cf_tok", "zone123", %{
          type: "A",
          name: "www.example.com",
          content: "203.0.113.10"
        })
      ]

      for req <- cf_requests do
        {_request_arg, http_opts, _opts} = HttpClient.to_httpc(req)

        assert Keyword.get(http_opts, :autoredirect) == false,
               "autoredirect MUST be false (blind-redirect SSRF guard) for #{inspect(req.method)} #{req.url}"

        ssl = Keyword.fetch!(http_opts, :ssl)

        assert Keyword.get(ssl, :verify) == :verify_peer,
               "TLS MUST verify_peer for #{inspect(req.method)} #{req.url}"

        assert is_list(Keyword.get(ssl, :cacerts)),
               "verify_peer MUST carry an OS-trust-store cacerts list"

        assert Keyword.has_key?(ssl, :customize_hostname_check),
               "verify_peer MUST pin the https hostname-match fun"
      end
    end
  end

  # ── Obligation 4: no live serving/control code binds a disconnected provider ─

  describe "no live serving-path code binds a disconnected provider (AST sweep)" do
    test "detected provider coupling equals the reviewed allowlist" do
      detected = detect_provider_couplings()
      allowed = MapSet.new(@sanctioned_provider_coupling)

      new_couplings = MapSet.difference(detected, allowed) |> Enum.sort()
      stale_entries = MapSet.difference(allowed, detected) |> Enum.sort()

      assert new_couplings == [],
             """
             NEW control-plane→provider coupling outside the allowlist. A module \
             on a live path now names a disconnected provider — the standalone \
             box must degrade to serving directly, so this coupling has to be \
             either (a) gated behind `<Provider>.configured?()` on the control \
             plane and reviewed into @sanctioned_provider_coupling WITH a \
             justification, or (b) removed if it runs on the box's own \
             site-serving path.
               #{format_couplings(new_couplings)}
             """

      assert stale_entries == [],
             """
             Stale @sanctioned_provider_coupling entries — no longer present in \
             control-plane code. Prune them so the allowlist stays an accurate \
             map of real coupling.
               #{format_couplings(stale_entries)}
             """
    end

    test "every Cloudflare host coupling is confined to the reviewed allowlist" do
      # W6 wired Cloudflare end-to-end, so the scaffold is no longer decoupled —
      # but every coupling must stay CONFINED to @sanctioned_provider_coupling
      # (each entry reviewed as running only on a credential-gated provider path,
      # never the box's standalone serving path). A NEW, unreviewed CF coupling
      # reds here.
      cf_couplings =
        detect_provider_couplings()
        |> Enum.filter(fn {module, _file} -> module == "BarkparkCloud.Cloudflare" end)
        |> Enum.sort()

      sanctioned_cf =
        @sanctioned_provider_coupling
        |> Enum.filter(fn {module, _file} -> module == "BarkparkCloud.Cloudflare" end)
        |> Enum.sort()

      # There MUST be at least one (the wave wired CF) — a vacuous pass would mean
      # the sweep stopped detecting couplings and this guard went blind.
      assert cf_couplings != [],
             "the CF sweep detected zero couplings — the AST guard has gone blind"

      assert cf_couplings == sanctioned_cf,
             """
             Cloudflare host coupling drifted from the reviewed allowlist. A live \
             path now binds BarkparkCloud.Cloudflare outside \
             @sanctioned_provider_coupling — gate it behind a stored-credential / \
             `Cloudflare.configured?()` check (so the box degrades to standalone \
             when no CF is connected), then add it to the allowlist WITH a \
             justification.
               detected:   #{format_couplings(cf_couplings)}
               sanctioned: #{format_couplings(sanctioned_cf)}
             """
    end
  end

  # ── Obligation 1 (spirit) / sibling-slice forward check ──────────────────────

  describe "credential source is empty with no provider connected" do
    test "configured?/0 is the fail-closed credential source; the named resolver is merge-gated" do
      # The standalone ground truth underpinning any resolver that returns
      # {:error, :no_cloudflare_provider}: with nothing wired, the credential
      # source is empty. The named `resolve_cloudflare_credential/1` is a sibling
      # slice — when it lands (merged suite), assert its exact fail-closed tuple;
      # here, prove the invariant it rests on.
      put_cf_config(token: nil)
      refute Cloudflare.configured?()

      if function_exported?(Cloudflare, :resolve_cloudflare_credential, 0) do
        assert apply(Cloudflare, :resolve_cloudflare_credential, []) ==
                 {:error, :no_cloudflare_provider}
      end
    end
  end

  # ── AST sweep helpers (mirrors plugin_free_boot_test's tier-5) ───────────────

  # Set of `{provider_module_string, host_file}` couplings — a REAL compile-time
  # `__aliases__` node, not a docstring/comment mention. The provider trees
  # (lib/barkpark_cloud/vercel* + /cloudflare*) are their own definition sites
  # and excluded; only downstream host/control-plane code is swept.
  defp detect_provider_couplings do
    host_files =
      "lib/barkpark_cloud/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&provider_tree?/1)

    for path <- host_files,
        module <- file_provider_refs(path),
        into: MapSet.new() do
      {module, path}
    end
  end

  defp provider_tree?(path) do
    String.contains?(path, "/cloudflare.ex") or String.contains?(path, "/cloudflare/") or
      String.contains?(path, "/vercel.ex") or String.contains?(path, "/vercel/")
  end

  # Real provider references in one file. Parses to AST (so text inside
  # strings/`@moduledoc`/comments is never matched) and folds every matching
  # `__aliases__` to its canonical provider module. Matches BOTH the
  # fully-qualified `BarkparkCloud.Vercel` AND the short `Vercel` alias that the
  # `alias BarkparkCloud.{Vercel, …}` multi-alias leaves at each call site.
  defp file_provider_refs(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_ast, refs} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _meta, parts} = node, acc when is_list(parts) ->
          case canonical_provider(parts) do
            nil -> {node, acc}
            module -> {node, [module | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(refs)
  end

  defp canonical_provider([:BarkparkCloud, :Cloudflare | _]), do: "BarkparkCloud.Cloudflare"
  defp canonical_provider([:BarkparkCloud, :Vercel | _]), do: "BarkparkCloud.Vercel"
  defp canonical_provider([:Cloudflare | _]), do: "BarkparkCloud.Cloudflare"
  defp canonical_provider([:Vercel | _]), do: "BarkparkCloud.Vercel"
  defp canonical_provider(_), do: nil

  defp format_couplings([]), do: "  (none)"

  defp format_couplings(pairs) do
    pairs
    |> Enum.map(fn {module, file} -> "  - #{module}  ←  #{file}" end)
    |> Enum.join("\n")
  end
end
