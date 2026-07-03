defmodule BarkparkCloud.Verify do
  @moduledoc """
  On-demand golden-path VERIFY (C8 / charter D53) — readiness as a re-runnable
  proof.

  The Go provisioner runs a birth-certificate probe gate BEFORE it ever declares
  a box `ready` (`internal/provisioner/verify.go`, C2/D45): a box that would 500
  the moment its session/auth stack is exercised (the #957 32-byte
  SECRET_KEY_BASE class) is never called live. This module is the SAME suite,
  re-issuable on demand from the console (`POST /v1/barkparks/:id/verify`) and
  the CLI (`bp cloud verify`) — a ping tells you the box answers TCP; this tells
  you the golden path still works.

  ## The suite (one vocabulary, two executors — the D32 discipline)

  The probe VOCABULARY (names / labels / pass-rules) is committed as a shared
  fixture, `priv/static/__fixtures__/verify_probes.json`, asserted from BOTH
  this executor (`probes/0` deep-equals it) AND the Go gate's compiled probe
  order (`internal/provisioner/verify_fixture_test.go`). Two hand-written probe
  lists WILL drift; one fixture with two asserters can't.

    * `verify.api`    GET  `/v1/capabilities` (stored admin token) → `200`
    * `verify.login`  POST `/v1/auth/login` (deliberately-wrong sentinel creds)
      → status `< 500` — a 401/422 proves the whole request→session→auth
      pipeline ran and cleanly rejected the creds; ANY 5xx is the #957
      dead-on-arrival class.
    * `verify.studio` GET `/studio`, following the scoped-login redirect ≤3 hops
      → final status `< 500`.

  ## Token custody (D46)

  The per-instance admin bearer is decrypted server-side via
  `Registry.reveal_admin_token/1` and sent ONLY on the `verify.api` probe's
  `Authorization` header. It is NEVER logged, NEVER placed in a result field or
  evidence string, and NEVER in an error tuple. `verify.login` /
  `verify.studio` are anonymous/sentinel — they carry no secret. The route test
  scans every result byte to prove absence.

  ## Total over failure

  `run/1` NEVER raises and NEVER returns a bare transport error to the caller.
  An unreachable box is a first-class FAILED result: every probe reports
  `reachable: false`, `ok: false`, `status: nil`, and the envelope's `ok` /
  `reachable` are `false`. A hung box is bounded by the transport's per-request
  timeout (`BarkparkCloud.Verify.HttpClient`), so the whole synchronous suite is
  bounded (~15s worst case). The verdict is derived only from the probe
  outcomes.
  """

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Barkpark

  # The deliberately-invalid sentinel credentials the login probe POSTs. Its ONLY
  # job is to make the auth/session stack ANSWER (401/422 = alive; 5xx = #957
  # dead-on-arrival). It authenticates nothing and carries no real secret —
  # byte-for-byte the intent of the Go gate's `verifyLoginSentinel`.
  @login_sentinel Jason.encode!(%{
                    "email" => "barkpark-verify-probe@invalid.example",
                    "password" => "deliberately-invalid-verify-sentinel"
                  })

  # ≤200 bytes of a response body ride into a failing probe's evidence (D53). A
  # chatty error page can never bloat the result. The per-probe HTTP bound that
  # keeps the synchronous suite ~15s worst case lives on the transport
  # (`BarkparkCloud.Verify.HttpClient`'s timeouts).
  @max_evidence_bytes 200

  # verify.studio follows the instance's scoped-login redirect. ≤3 hops matches
  # the Go health gate's `CheckStudio`; a chain longer than this never renders
  # and FAILS.
  @max_studio_hops 3

  # The probe vocabulary, as data — the single source `probes/0` exposes and the
  # fixture pins. `pass_rule` is the human-readable contract asserted byte-equal
  # against the fixture; the ACTUAL pass logic lives in `pass?/2` and is
  # exercised by real green/red probe tests, so the strings are never merely
  # decorative. Order is the gate order (api → login → studio).
  @probes [
    %{name: "verify.api", label: "API answers", pass_rule: "status == 200"},
    %{name: "verify.login", label: "Login responds", pass_rule: "status < 500"},
    %{
      name: "verify.studio",
      label: "Studio renders",
      pass_rule: "status < 500 after <= 3 redirect hops"
    }
  ]

  @type probe_result :: %{
          name: String.t(),
          ok: boolean(),
          reachable: boolean(),
          status: non_neg_integer() | nil,
          latency_ms: non_neg_integer(),
          evidence: String.t()
        }

  @type result :: %{
          ok: boolean(),
          reachable: boolean(),
          verified_at: String.t(),
          probes: [probe_result()]
        }

  @doc """
  The probe vocabulary (name / label / pass-rule), in gate order. The C8 test
  asserts this equals the decoded `verify_probes.json` fixture; the Go gate's
  compiled probe order is asserted against the same file.
  """
  @spec probes() :: [%{name: String.t(), label: String.t(), pass_rule: String.t()}]
  def probes, do: @probes

  @doc """
  Run the golden-path suite against a LIVE `barkpark` and return the result
  envelope.

    * `{:ok, result}` — the suite ran (all probes attempted). `result.ok` is the
      verdict; an unreachable box is a fully-populated `reachable: false`
      result, NOT an error.
    * `{:error, :not_live}` — no instance URL yet (still provisioning / a failed
      birth). Mirrors the instance-API proxy's liveness gate.
    * `{:error, :no_admin_token}` — the row never stored one (pre-feature box).
    * `{:error, :decrypt_failed}` — the stored ciphertext is tampered
      (fail-closed).

  The admin token never escapes this function.
  """
  @spec run(Barkpark.t()) ::
          {:ok, result()} | {:error, :not_live | :no_admin_token | :decrypt_failed}
  def run(%Barkpark{url: url} = bp) when is_binary(url) and url != "" do
    case Registry.reveal_admin_token(bp) do
      {:ok, nil} -> {:error, :no_admin_token}
      :error -> {:error, :decrypt_failed}
      {:ok, token} -> {:ok, execute(String.trim_trailing(url, "/"), token)}
    end
  end

  def run(_), do: {:error, :not_live}

  # Run the three probes in order and fold them into the envelope. Each probe is
  # self-contained (a transport error on one never aborts the others), so an
  # unreachable box yields three `reachable: false` probes rather than a raise.
  defp execute(base, token) do
    results = [
      probe_api(base, token),
      probe_login(base),
      probe_studio(base)
    ]

    %{
      ok: Enum.all?(results, & &1.ok),
      reachable: Enum.any?(results, & &1.reachable),
      verified_at: DateTime.to_iso8601(DateTime.utc_now()),
      probes: results
    }
  end

  # verify.api — authenticated GET /v1/capabilities must be 200. The admin token
  # rides ONLY here, and only in the request header (never the result).
  defp probe_api(base, token) do
    time_probe("verify.api", fn ->
      request(:get, base <> "/v1/capabilities", auth_headers(token), "")
    end)
    |> finish("verify.api", fn status -> status == 200 end, "GET /v1/capabilities → 200 (API up)")
  end

  # verify.login — sentinel wrong creds; PASS iff <500. A 401/422 proves the
  # auth stack answered; a 5xx is #957. Anonymous (no admin token).
  defp probe_login(base) do
    time_probe("verify.login", fn ->
      request(:post, base <> "/v1/auth/login", json_headers(), @login_sentinel)
    end)
    |> finish("verify.login", &(&1 < 500), fn status ->
      "POST /v1/auth/login → #{status} (auth stack answered; bad creds rejected)"
    end)
  end

  # verify.studio — GET /studio following the scoped-login redirect ≤3 hops;
  # final status <500 passes. Anonymous. Redirects are followed MANUALLY (the
  # transport does not auto-follow) so the ≤3-hop budget is enforced exactly,
  # matching the Go health gate's CheckStudio.
  defp probe_studio(base) do
    start = System.monotonic_time(:millisecond)
    outcome = follow_studio(base, base <> "/studio", @max_studio_hops)
    elapsed = System.monotonic_time(:millisecond) - start

    case outcome do
      {:ok, status, body} ->
        if status < 500 do
          probe("verify.studio", true, true, status, elapsed, "GET /studio → #{status} (renders)")
        else
          probe(
            "verify.studio",
            false,
            true,
            status,
            elapsed,
            "#{status} — #{body_snippet(body)}"
          )
        end

      :too_many_hops ->
        probe(
          "verify.studio",
          false,
          true,
          nil,
          elapsed,
          "redirect chain exceeded #{@max_studio_hops} hops (Studio never rendered)"
        )

      :unreachable ->
        unreachable_probe("verify.studio", elapsed)
    end
  end

  # Walk the redirect chain up to `hops` remaining. A 3xx with a Location is
  # followed (resolved relative to the current URL); anything else is the final
  # response. Running out of hops on a still-redirecting box FAILS.
  defp follow_studio(_base, _url, hops) when hops < 0, do: :too_many_hops

  defp follow_studio(base, url, hops) do
    case request(:get, url, [{"Accept", "text/html"}], "") do
      {:ok, %{status: status, body: body, headers: headers}} when status in 300..399 ->
        case redirect_location(headers) do
          nil ->
            {:ok, status, body}

          location ->
            follow_studio(base, resolve_url(base, url, location), hops - 1)
        end

      {:ok, %{status: status, body: body}} ->
        {:ok, status, body}

      {:error, _reason} ->
        :unreachable
    end
  end

  # ── probe plumbing ──

  # Time a single-request probe. Returns `{elapsed_ms, {:ok, resp} | {:error, _}}`.
  defp time_probe(_name, fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - start, result}
  end

  # Fold a single-request probe's `{elapsed, transport_result}` into a
  # probe_result via a pass predicate + a success-evidence builder (a string, or
  # a fun of the status). A transport error is the reachable:false path.
  defp finish({elapsed, {:ok, %{status: status, body: body}}}, name, pass?, success) do
    if pass?.(status) do
      probe(name, true, true, status, elapsed, evidence(success, status))
    else
      probe(name, false, true, status, elapsed, "#{status} — #{body_snippet(body)}")
    end
  end

  defp finish({elapsed, {:error, _reason}}, name, _pass?, _success) do
    unreachable_probe(name, elapsed)
  end

  defp evidence(success, _status) when is_binary(success), do: success
  defp evidence(success, status) when is_function(success, 1), do: success.(status)

  defp probe(name, ok, reachable, status, elapsed, evidence) do
    %{
      name: name,
      ok: ok,
      reachable: reachable,
      status: status,
      latency_ms: max(elapsed, 0),
      evidence: truncate(evidence)
    }
  end

  # A box that never answered TCP — a FAILED probe, never a raise. No status, no
  # transport reason string (reasons can carry host detail; the honest signal is
  # simply "unreachable").
  defp unreachable_probe(name, elapsed) do
    probe(name, false, false, nil, elapsed, "instance unreachable")
  end

  # ── HTTP + header helpers ──

  defp auth_headers(token) do
    [
      {"Authorization", "Bearer " <> token},
      {"Accept", "application/json"}
    ]
  end

  defp json_headers do
    [
      {"Accept", "application/json"},
      {"Content-Type", "application/json"}
    ]
  end

  defp request(method, url, headers, body) do
    http_client().request(%{method: method, url: url, headers: headers, body: body})
  end

  # Case-insensitive Location lookup; a blank value is treated as absent.
  defp redirect_location(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == "location" and is_binary(v) and String.trim(v) != "", do: v
    end)
  end

  # Resolve a redirect target: an absolute URL is used verbatim; an
  # absolute-path ("/w/…") is re-based onto the instance origin; anything else
  # rides the current URL's directory. Instance scoped-login redirects are
  # absolute paths, the common case.
  defp resolve_url(base, _current, location) do
    cond do
      String.starts_with?(location, "http://") or String.starts_with?(location, "https://") ->
        location

      String.starts_with?(location, "/") ->
        base <> location

      true ->
        base <> "/" <> location
    end
  end

  # ── evidence hygiene ──

  # Truncate to ≤@max_evidence_bytes, trimmed, dropping any trailing bytes that
  # would split a UTF-8 codepoint (so the result is always valid JSON).
  defp truncate(text) when is_binary(text) do
    text
    |> byte_slice(@max_evidence_bytes)
    |> String.trim()
  end

  defp truncate(_), do: ""

  defp body_snippet(body) when is_binary(body),
    do: body |> byte_slice(@max_evidence_bytes) |> String.trim()

  defp body_snippet(_), do: ""

  defp byte_slice(bin, max) when byte_size(bin) <= max, do: bin

  defp byte_slice(bin, max) do
    sliced = binary_part(bin, 0, max)
    # Walk back off any partial trailing codepoint so the slice stays valid UTF-8.
    drop_partial_tail(sliced)
  end

  defp drop_partial_tail(bin) do
    if String.valid?(bin) do
      bin
    else
      case bin do
        <<>> -> <<>>
        _ -> drop_partial_tail(binary_part(bin, 0, byte_size(bin) - 1))
      end
    end
  end

  # The transport seam. Default `BarkparkCloud.Verify.HttpClient` (verified TLS
  # :httpc, returns response HEADERS so verify.studio can walk the redirect
  # chain); tests wire a header-aware fake.
  defp http_client do
    Application.get_env(:barkpark_cloud, :verify_http_client, BarkparkCloud.Verify.HttpClient)
  end
end

defmodule BarkparkCloud.Verify.HttpClient do
  @moduledoc """
  Verify's HTTP transport — verified-TLS `:httpc`, like
  `BarkparkCloud.Billing.HttpClient`, but it RETURNS response headers so
  `BarkparkCloud.Verify` can walk the `verify.studio` redirect chain (the
  billing client deliberately drops headers). Redirects are NOT auto-followed
  (`autoredirect: false`) — Verify follows them manually to enforce the exact
  ≤3-hop budget and to keep the SSRF-safe posture of the shared client.

  `request/1` takes the same request map shape and returns
  `{:ok, %{status, body, headers}}` on a completed exchange (any status) or
  `{:error, {:http_client, reason}}` on a transport failure. Header names are
  lower-cased so a case-insensitive `Location` lookup is trivial.
  """

  @timeout 5_000
  @connect_timeout 5_000

  @spec request(map()) ::
          {:ok, %{status: non_neg_integer(), body: binary(), headers: [{String.t(), String.t()}]}}
          | {:error, term()}
  def request(%{method: method, url: url, headers: headers} = req) do
    body = Map.get(req, :body, "")
    request_arg = to_httpc(method, url, headers, body)

    case :httpc.request(method, request_arg, http_opts(), body_format: :binary) do
      {:ok, {{_v, status, _reason}, resp_headers, resp_body}} ->
        {:ok,
         %{status: status, body: to_string(resp_body), headers: normalize_headers(resp_headers)}}

      {:error, reason} ->
        {:error, {:http_client, reason}}
    end
  end

  # GET carries no body; the others pass content-type + body pulled out (the
  # :httpc 4-tuple), mirroring the billing client.
  defp to_httpc(:get, url, headers, _body) do
    {to_charlist(url), header_charlists(headers)}
  end

  defp to_httpc(_method, url, headers, body) do
    {content_type, rest} = pop_content_type(headers)

    {to_charlist(url), header_charlists(rest), to_charlist(content_type), to_string(body)}
  end

  defp pop_content_type(headers) do
    {ct, rest} = Enum.split_with(headers, fn {k, _v} -> String.downcase(k) == "content-type" end)

    content_type =
      case ct do
        [{_k, v} | _] -> v
        [] -> "application/json"
      end

    {content_type, rest}
  end

  defp header_charlists(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp normalize_headers(resp_headers) do
    Enum.map(resp_headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
  end

  # Verified TLS against the OS trust store; redirects returned, not followed;
  # bounded timeouts so a hung instance can't wedge the synchronous suite.
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
