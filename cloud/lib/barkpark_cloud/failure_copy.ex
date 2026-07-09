defmodule BarkparkCloud.FailureCopy do
  @moduledoc """
  Server-side humanization of raw internal deploy/provision failure strings —
  the Elixir twin of `app.js` `failureCopy()` (#939), which mapped *builder*-set
  `failure_reason` values in the browser.

  #939 only covered the builder-reported subset. The deploy reaper
  (`Registry.reap_stale_deployments/0`) and the provision path
  (`Registry.fail_job/3`, `Registry.claim_next_job/1`,
  `Registry.reap_stale_provision_jobs/0`) write an adjacent, unmapped subset of
  the SAME class of jargon (e.g. `"exceeded max deploy claim attempts (stale
  builder lease)"`, `"exceeded max provision attempts (3)"`). Those surface
  verbatim in the dashboard's deploy-fail row and provision banner, and in the
  `bp` CLI's `sites` output.

  This maps that jargon to human copy at the JSON serialization boundary
  (`Web.Router.deployment_json/1` and `merge_job_status/4`), so:

    * the stored `failure_reason` / `error` stays RAW — logs, ops, and the
      `provision_failed` email alert keep the honest internal reason;
    * every read surface (dashboard + CLI) renders human copy with NO client
      change;
    * unrecognized reasons pass through unchanged (graceful fallback — never
      drop information).

  Substring match on the RAW reason, mirroring `failureCopy()`. The two strings
  #939 already humanizes client-side are mapped here too so the CLI matches the
  dashboard, and because the client pass is idempotent over this output (a
  humanized "…no build source…" re-maps to the identical string; the rest pass
  through).

  ## Provider-error classes (coherence arc D58)

  The Hetzner/provisioner layer emits raw provider jargon
  (`SERVER_LIMIT_EXCEEDED`, `resource_unavailable`, `unauthorized`, DNS
  `zone create` failures, `connection refused`, …) that reached the dashboard
  and CLI verbatim. Those are folded into four human classes — capacity, auth,
  dns, network — matched case-insensitively (provider casing is inconsistent) so
  no surface ever renders an ALL_CAPS code. The stored value stays RAW: only the
  JSON boundary humanizes, so the timeline's forensic fold and the
  `provision_failed` email keep the honest reason. The DNS class is checked
  BEFORE the generic capacity class because a "dns zone quota" failure is a
  domain problem, not a server-capacity one. All output copy is idempotent under
  a second `humanize` pass (none of it re-matches a class token).
  """

  @doc """
  Map a raw internal deploy/provision failure string to human-facing copy.
  Passes `nil` and unrecognized/non-binary reasons through unchanged.
  """
  @spec humanize(term()) :: term()
  def humanize(nil), do: nil

  def humanize(reason) when is_binary(reason) do
    # Provider casing is inconsistent (`SERVER_LIMIT_EXCEEDED` vs
    # `resource_unavailable`); the provider-class clauses match this lowered
    # copy. The internal-jargon clauses above keep matching the raw `reason`
    # (their exact strings are known) so their behavior is unchanged.
    down = String.downcase(reason)

    cond do
      # dwb-webhook fail-fast interim: a GitHub push was recorded as a
      # born-`failed` deployment because source builds need the GitHub App
      # integration (gh-1, human-gated). Blocked-tone, names the workaround.
      # Checked FIRST — the raw reason is a known exact string; its output does
      # not re-match any clause (no "github push builds" token), so a second
      # client-side `failureCopy()` pass is idempotent.
      String.contains?(down, "github push builds") ->
        "GitHub pushes are recorded but can't be built yet — deploy this commit with bp deploy. Automatic GitHub builds are coming."

      String.contains?(reason, "no build source") ->
        "This site has no build source yet. Connect a repo or run bp deploy."

      String.contains?(reason, "artifact_url is empty") or
          String.contains?(reason, "unsupported artifact scheme") ->
        "The build source couldn't be fetched."

      # Deploy reaper: an over-budget "building" row that never finished within
      # its lease. Checked before the generic "exceeded max … attempts" clause,
      # which this string also matches.
      String.contains?(reason, "stale builder lease") or
          String.contains?(reason, "deploy claim attempts") ->
        "The build didn't finish after several attempts and was stopped. Deploy again to retry."

      # Provision / deprovision claim + reaper: "exceeded max provision attempts (3)",
      # "exceeded max deprovision attempts (3)".
      String.contains?(reason, "exceeded max") and String.contains?(reason, "attempts") ->
        "This didn't finish after several attempts. Try again in a moment."

      # ── Azure provider classes (provider-neutral hosting) ──
      # Matched on Azure-specific tokens so they never collide with the Hetzner
      # classes below (e.g. Azure's "QuotaExceeded" is caught here, while
      # Hetzner's spaced "account quota exceeded" falls through to the generic
      # capacity class). Each names the EXACT Azure Portal fix. All three are
      # idempotent under a second pass (their output re-maps to itself or misses
      # every class).

      # Missing RBAC role: the service principal authenticated but lacks the role
      # to act on the subscription (`AuthorizationFailed`, "does not have
      # authorization/permission"). Checked before the generic auth class.
      String.contains?(down, "authorizationfailed") or
        String.contains?(down, "does not have authorization") or
          String.contains?(down, "does not have permission") ->
        "Your Azure service principal is missing a role. In the Azure Portal → Subscriptions → your subscription → Access control (IAM) → Add role assignment, grant it the Contributor role, then reconnect."

      # Quota exceeded per VM family: the subscription's vCPU quota for a specific
      # size family is exhausted (`QuotaExceeded`, quota + family/vcpu). Checked
      # before the generic capacity class.
      String.contains?(down, "quotaexceeded") or
          (String.contains?(down, "quota") and
             (String.contains?(down, "family") or String.contains?(down, "vcpu"))) ->
        "Your Azure subscription's vCPU quota for this VM family is exhausted. In the Azure Portal → Subscriptions → your subscription → Usage + quotas, filter to the family and choose Request increase, then retry."

      # Region capacity: the region/zone has no capacity for the requested size
      # right now (`SkuNotAvailable`, `AllocationFailed`, `ZonalAllocationFailed`).
      String.contains?(down, "skunotavailable") or
        String.contains?(down, "allocationfailed") or
          String.contains?(down, "zonalallocationfailed") ->
        "This Azure region has no capacity for this VM size right now. In the Azure Portal → Virtual machines, pick another region or size — or retry shortly, since capacity is transient per region and size."

      # DNS: a domain/zone step failed on the provider. Checked BEFORE capacity
      # so a "dns zone quota" failure reads as a domain problem, not a
      # server-capacity one.
      String.contains?(down, "zone create") or
          (String.contains?(down, "dns") and
             (String.contains?(down, "quota") or String.contains?(down, "failed"))) ->
        "Securing the domain failed on the provider side."

      # Capacity / quota: Hetzner has no server of this type free, or the account
      # hit a resource ceiling (`SERVER_LIMIT_EXCEEDED`, `resource_unavailable`).
      String.contains?(down, "quota") or
        String.contains?(down, "server_limit_exceeded") or
          String.contains?(down, "resource_unavailable") ->
        "Hetzner ran out of server capacity for this size. Try again shortly or contact support."

      # Auth / token: the provider rejected our stored credentials.
      String.contains?(down, "unauthorized") or String.contains?(down, "invalid token") ->
        "The hosting provider rejected our credentials. We're on it — try again shortly."

      # Network / timeout: a transient network step failed; a retry usually clears it.
      String.contains?(down, "timeout") or String.contains?(down, "connection refused") ->
        "A network step timed out. Retry usually fixes this."

      true ->
        reason
    end
  end

  def humanize(other), do: other

  @doc """
  The per-kind remediation copy the connect endpoint returns when the
  verify-before-save preflight can't authenticate a provider credential. Names
  the EXACT console/portal fix so the user can act without a support round-trip.
  Falls back to a provider-agnostic line for an unknown kind.
  """
  @spec connect_remediation(String.t()) :: String.t()
  def connect_remediation("hetzner") do
    "We couldn't reach Hetzner with that API token. Create a fresh Read & Write token in the Hetzner Cloud Console → your project → Security → API tokens, then paste it here."
  end

  def connect_remediation("azure") do
    "We couldn't authenticate to Azure with those details. In the Azure Portal → App registrations → your app, re-check the Directory (tenant) ID, Application (client) ID and Subscription ID, and that the client secret under Certificates & secrets hasn't expired — then reconnect."
  end

  def connect_remediation(_kind) do
    "We couldn't verify those credentials with the provider. Double-check them and try again."
  end
end
