defmodule BarkparkCloud.FailureCopyTest do
  @moduledoc """
  Pure unit cover for FailureCopy.humanize/1 — the server-side twin of app.js
  failureCopy() (#939). Asserts the reaper + provision jargon maps to human copy,
  #939's builder strings stay consistent across surfaces, and unknown reasons
  pass through unchanged (graceful fallback).
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.FailureCopy

  test "deploy reaper: no-build-source jargon → #939's exact copy (cross-surface parity)" do
    assert FailureCopy.humanize(
             "no build source (upload an artifact via `bp deploy` or connect a GitHub repo)"
           ) == "This site has no build source yet. Connect a repo or run bp deploy."
  end

  test "deploy reaper: exhausted stale builder lease → human retry copy" do
    assert FailureCopy.humanize("exceeded max deploy claim attempts (stale builder lease)") ==
             "The build didn't finish after several attempts and was stopped. Deploy again to retry."
  end

  test "provision claim/reaper: exceeded max attempts → human retry copy" do
    assert FailureCopy.humanize("exceeded max provision attempts (3)") ==
             "This didn't finish after several attempts. Try again in a moment."

    assert FailureCopy.humanize("exceeded max deprovision attempts (3)") ==
             "This didn't finish after several attempts. Try again in a moment."
  end

  test "mirrors #939's builder strings so the CLI matches the dashboard" do
    assert FailureCopy.humanize("artifact_url is empty (P6 bp deploy must populate it)") ==
             "The build source couldn't be fetched."

    assert FailureCopy.humanize("unsupported artifact scheme file://") ==
             "The build source couldn't be fetched."
  end

  test "output is idempotent under the client failureCopy() second pass" do
    once = FailureCopy.humanize("no build source (…)")
    assert FailureCopy.humanize(once) == once
  end

  # Provider-error classes (coherence arc D58) — quota/auth/dns/network jargon
  # never reaches a surface verbatim.

  test "capacity/quota jargon → human capacity copy (all casings)" do
    capacity =
      "Hetzner ran out of server capacity for this size. Try again shortly or contact support."

    assert FailureCopy.humanize("server type unavailable (SERVER_LIMIT_EXCEEDED)") == capacity
    assert FailureCopy.humanize("resource_unavailable: cx22 in fsn1") == capacity
    assert FailureCopy.humanize("account quota exceeded for servers") == capacity
    # lower-cased provider code still matches.
    assert FailureCopy.humanize("server_limit_exceeded") == capacity
  end

  test "auth/token jargon → human credentials copy" do
    auth = "The hosting provider rejected our credentials. We're on it — try again shortly."

    assert FailureCopy.humanize("hcloud: unauthorized (401)") == auth
    assert FailureCopy.humanize("provider returned invalid token") == auth
  end

  test "dns/zone jargon → human domain copy, checked before capacity" do
    dns = "Securing the domain failed on the provider side."

    assert FailureCopy.humanize("dns zone create failed for example.barkpark.cloud") == dns
    assert FailureCopy.humanize("dns record update failed") == dns
    # A dns+quota string is a DOMAIN problem, not a server-capacity one — the
    # ordering guarantees the domain copy wins over the capacity copy.
    assert FailureCopy.humanize("dns zone quota exceeded") == dns
  end

  test "network/timeout jargon → human network copy" do
    network = "A network step timed out. Retry usually fixes this."

    assert FailureCopy.humanize("dial tcp: i/o timeout") == network
    assert FailureCopy.humanize("connection refused") == network
  end

  test "provider-class copy is idempotent under a second pass (never re-matches a class)" do
    for raw <- [
          "server type unavailable (SERVER_LIMIT_EXCEEDED)",
          "hcloud: unauthorized (401)",
          "dns zone create failed",
          "dial tcp: i/o timeout"
        ] do
      once = FailureCopy.humanize(raw)
      assert FailureCopy.humanize(once) == once
    end
  end

  test "dwb-webhook fail-fast: github-push born-failed reason → blocked-tone human copy naming the workaround" do
    raw =
      "github push builds require the GitHub App integration (not yet available) — deploy an artifact via bp deploy"

    human =
      "GitHub pushes are recorded but can't be built yet — deploy this commit with bp deploy. Automatic GitHub builds are coming."

    assert FailureCopy.humanize(raw) == human
    # Idempotent under the client failureCopy() second pass (its output does not
    # re-match the "github push builds" token or any other class).
    assert FailureCopy.humanize(human) == human
  end

  test "unrecognized reason passes through unchanged (graceful fallback)" do
    assert FailureCopy.humanize("some brand new worker error") == "some brand new worker error"
    assert FailureCopy.humanize("docker load: no such image") == "docker load: no such image"
  end

  test "nil and non-binary reasons pass through unchanged" do
    assert FailureCopy.humanize(nil) == nil
    assert FailureCopy.humanize(:oops) == :oops
  end

  ## A TYPED REFUSAL IS NEVER HUMANIZED (site-spawner W11).
  ##
  ## humanize/1 matches SUBSTRINGS and replaces the WHOLE string. Nine of the
  ## prebuilt extractor's typed messages interpolate the offending tar entry name
  ## (`Barkpark.Sites.PrebuiltArtifact` — E_ABSOLUTE_PATH, E_PATH_TRAVERSAL,
  ## E_BAD_NAME, E_UNSAFE_PARENT x3, E_WRITE_FAILED x2), so a user-authored path
  ## carrying one common English word used to swallow the whole refusal: an
  ## absolute-path refusal on "/quota/index.html" rendered as "Hetzner ran out of
  ## server capacity", and a "../timeout/" TRAVERSAL — a security event — as "A
  ## network step timed out." The token list cannot be made safe (single common
  ## words vs user-authored paths), so the guard is on the TYPE of the reason.
  ##
  ## Delete the `typed_refusal?(reason) -> reason` clause and every test below
  ## goes red on canned provider copy.

  test "an E_ABSOLUTE_PATH refusal naming /quota/index.html is NOT rewritten as Hetzner capacity" do
    # Byte-for-byte the string `Sites.Deploy.box_refusal/2` composes from the
    # box's nested %{error: %{code, message}} (prebuilt_artifact.ex:626).
    raw =
      ~s|the instance refused the deploy (HTTP 400): E_ABSOLUTE_PATH — entry "/quota/index.html" is an absolute path — refused|

    assert FailureCopy.humanize(raw) == raw

    refute FailureCopy.humanize(raw) =~ "Hetzner ran out of server capacity"
  end

  test "a PATH TRAVERSAL through ../timeout/ is NOT rewritten as a network timeout" do
    raw =
      ~s|the instance refused the deploy (HTTP 400): E_PATH_TRAVERSAL — entry "../timeout/index.html" escapes the artifact root|

    assert FailureCopy.humanize(raw) == raw
    refute FailureCopy.humanize(raw) =~ "A network step timed out"
  end

  test "the colliding static-site slugs are pinned as a set, not one example" do
    # Ordinary static-site error pages and doc paths — `timeout.html` and
    # `unauthorized.html` are what a framework's error pages are CALLED, and
    # /quota, /dns/failed.html are ordinary content slugs.
    slugs = [
      {"E_ABSOLUTE_PATH", ~s(entry "/quota/index.html" is an absolute path — refused)},
      {"E_ABSOLUTE_PATH", ~s(entry "/timeout.html" is an absolute path — refused)},
      {"E_ABSOLUTE_PATH", ~s(entry "/unauthorized.html" is an absolute path — refused)},
      {"E_PATH_TRAVERSAL", ~s(entry "../dns/failed.html" escapes the artifact root)},
      {"E_BAD_NAME", ~s(entry "docs/quota/index.html" names the artifact root itself as a file)},
      {"E_UNSAFE_PARENT",
       ~s(the archive names "/srv/x/errors/unauthorized/index.html" more than once)}
    ]

    canned = [
      "Hetzner ran out of server capacity",
      "A network step timed out",
      "The hosting provider rejected our credentials",
      "Securing the domain failed"
    ]

    for {code, message} <- slugs do
      raw = "the instance refused the deploy (HTTP 400): #{code} — #{message}"
      out = FailureCopy.humanize(raw)

      assert out == raw, "#{code} was rewritten: #{out}"
      assert out =~ code
      assert out =~ message

      for copy <- canned do
        refute out =~ copy
      end
    end
  end

  test "a bare E_* code with no box-refusal prefix is still recognized as typed" do
    raw = ~s(E_UNKNOWN_TYPE — unsupported tar entry type "x")
    assert FailureCopy.humanize(raw) == raw
  end

  test "the box-refusal prefix alone is enough — the box already said no in its own words" do
    raw = "the instance refused the deploy (HTTP 502)"
    assert FailureCopy.humanize(raw) == raw
  end

  test "typed pass-through is idempotent (a second client-side pass changes nothing)" do
    raw =
      ~s|the instance refused the deploy (HTTP 400): E_PATH_TRAVERSAL — entry "../timeout/" escapes the artifact root|

    assert raw |> FailureCopy.humanize() |> FailureCopy.humanize() == raw
  end

  test "the guard is NOT a blanket bypass: untyped provider jargon is still humanized" do
    # The two clauses the colliding slugs above stole. A reason with no typed code
    # and no box-refusal prefix keeps the pre-W11 behaviour exactly.
    assert FailureCopy.humanize("account quota exceeded for servers") ==
             "Hetzner ran out of server capacity for this size. Try again shortly or contact support."

    assert FailureCopy.humanize("dial tcp: i/o timeout") ==
             "A network step timed out. Retry usually fixes this."

    # An ALL-CAPS provider code that merely ENDS in `E_…` must not read as typed:
    # `_` is a word character, so `\bE_` has no boundary to match inside it.
    refute FailureCopy.typed_refusal?("server type unavailable (SERVER_LIMIT_EXCEEDED)")
    refute FailureCopy.typed_refusal?("RESOURCE_UNAVAILABLE")
    refute FailureCopy.typed_refusal?(nil)
    assert FailureCopy.typed_refusal?("E_NO_INDEX — the archive has no index.html")
  end

  # ── Azure provider classes (provider-neutral hosting) — each names the exact
  # Azure Portal fix, and none collides with the Hetzner classes above.

  test "azure quota-exceeded-per-family → the vCPU-quota copy naming the portal fix" do
    quota =
      "Your Azure subscription's vCPU quota for this VM family is exhausted. In the Azure Portal → Subscriptions → your subscription → Usage + quotas, filter to the family and choose Request increase, then retry."

    assert FailureCopy.humanize(
             "QuotaExceeded: Operation results in exceeding approved standardDPSv5Family Cores quota"
           ) == quota

    assert FailureCopy.humanize("Compute quota (vCPU) exceeded") == quota
    # Idempotent — the copy re-maps to itself (it contains quota + vcpu + family).
    assert FailureCopy.humanize(quota) == quota
  end

  test "azure region-capacity → the region-capacity copy" do
    capacity =
      "This Azure region has no capacity for this VM size right now. In the Azure Portal → Virtual machines, pick another region or size — or retry shortly, since capacity is transient per region and size."

    assert FailureCopy.humanize("SkuNotAvailable: the requested size is not available") ==
             capacity

    assert FailureCopy.humanize("AllocationFailed: unable to allocate") == capacity
    assert FailureCopy.humanize("ZonalAllocationFailed in zone 2") == capacity
    assert FailureCopy.humanize(capacity) == capacity
  end

  test "azure missing-RBAC-role → the role-assignment copy, before the generic auth class" do
    rbac =
      "Your Azure service principal is missing a role. In the Azure Portal → Subscriptions → your subscription → Access control (IAM) → Add role assignment, grant it the Contributor role, then reconnect."

    assert FailureCopy.humanize(
             "AuthorizationFailed: The client does not have authorization to perform action"
           ) == rbac

    assert FailureCopy.humanize("does not have permission to write") == rbac
    assert FailureCopy.humanize(rbac) == rbac
  end

  test "the azure classes do not steal the Hetzner capacity string" do
    # Hetzner's spaced 'account quota exceeded' still reads as capacity, NOT the
    # azure family-quota copy (no 'quotaexceeded'/'family'/'vcpu' token).
    assert FailureCopy.humanize("account quota exceeded for servers") ==
             "Hetzner ran out of server capacity for this size. Try again shortly or contact support."
  end

  # ── connect_remediation/1 — verify-before-save copy naming the exact console.

  test "connect_remediation names the exact Hetzner + Azure console fix" do
    assert FailureCopy.connect_remediation("hetzner") =~ "Hetzner Cloud Console"
    assert FailureCopy.connect_remediation("hetzner") =~ "API tokens"
    assert FailureCopy.connect_remediation("azure") =~ "App registrations"
    assert FailureCopy.connect_remediation("azure") =~ "Certificates & secrets"
    # Unknown kind falls back to a provider-agnostic, actionable line.
    assert FailureCopy.connect_remediation("gcp") =~ "verify"
  end

  # ── provider_not_connected_remediation/1 — the launch-time "connect first" copy.

  test "provider_not_connected_remediation points azure launches at Providers → connect" do
    azure = FailureCopy.provider_not_connected_remediation("azure")
    assert azure =~ "Providers"
    assert azure =~ "Azure"
    # Unknown kind falls back to a provider-agnostic connect-first line.
    assert FailureCopy.provider_not_connected_remediation("gcp") =~ "Providers"
  end

  # ── capability_gap_reason/2 — the honest-degradation copy for a FALSE
  # capability, server-owned so the SPA + CLI read one reason (charter D8/D16).

  test "azure adopt is the ONE named gap; archive + resurrect are live capabilities (S14)" do
    assert FailureCopy.capability_gap_reason("azure", "adopt") =~ "clone-swap"

    # archive (S14b, portable bp-bundle-v1) and resurrect (S14d, bundle restore
    # target) are LIVE capabilities now, so their bespoke gap clauses are gone —
    # both fall through to the generic terminal clause, kept only as defensive
    # coverage, never advertised as a gap.
    refute FailureCopy.capability_gap_reason("azure", "archive") =~ "Azure has no archive"
    refute FailureCopy.capability_gap_reason("azure", "resurrect") =~ "Azure has no archives"
  end

  test "hetzner pause gap explains a stopped Hetzner box still bills → archive instead" do
    reason = FailureCopy.capability_gap_reason("hetzner", "pause")
    assert reason =~ "Hetzner"
    assert reason =~ "bill"
    assert reason =~ "Archive"
  end

  test "catalog gap is generic across kinds and names the fixed-defaults fallback" do
    for kind <- ["hetzner", "azure", "gcp"] do
      reason = FailureCopy.capability_gap_reason(kind, "catalog")
      assert reason =~ "catalog"
      assert reason =~ "fixed defaults"
    end
  end

  test "every capability key resolves to non-empty copy — no false capability is reason-less" do
    # The union of capability keys any provider row could carry today, plus a
    # made-up one to prove the terminal default clause covers a key added later
    # (S9's facet split) with zero FailureCopy change.
    for kind <- ["hetzner", "azure", "fake", "brand-new-provider"],
        capability <-
          ~w(core catalog archive resurrect decommission adopt audit pause labels some_future_facet) do
      reason = FailureCopy.capability_gap_reason(kind, capability)

      assert is_binary(reason) and reason != "",
             "no gap reason for #{kind}/#{capability}"
    end
  end

  test "the terminal default clause interpolates an unknown capability name" do
    assert FailureCopy.capability_gap_reason("gcp", "snapshots") =~ "snapshots"
  end
end
