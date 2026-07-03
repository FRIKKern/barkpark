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
end
