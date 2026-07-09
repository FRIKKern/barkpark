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
end
