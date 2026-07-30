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

  ## Typed refusals are NEVER humanized (site-spawner W11)

  `humanize/1` matches SUBSTRINGS and replaces the WHOLE string. That is safe
  over reaper/provider jargon (a closed set of strings we emit ourselves) and
  actively dangerous over a refusal that interpolates a PRODUCER-CONTROLLED
  name: nine of the prebuilt extractor's typed messages
  (`Barkpark.Sites.PrebuiltArtifact` — `E_ABSOLUTE_PATH`, `E_PATH_TRAVERSAL`,
  `E_BAD_NAME`, `E_UNSAFE_PARENT`, `E_WRITE_FAILED`) carry the offending tar
  entry name. Driven through the real deploy pipeline,

      the instance refused the deploy (HTTP 400): E_ABSOLUTE_PATH — entry
      "/quota/index.html" is an absolute path — refused

  matched the capacity clause and rendered as "Hetzner ran out of server
  capacity", and a `../timeout/` PATH TRAVERSAL — a security event — rendered as
  "A network step timed out." Eight of nine ordinary static-site slugs collide
  (`/quota`, `/timeout`, `/unauthorized`, `/dns/failed.html`, …), and the token
  list CANNOT be made safe: the tokens are single common English words and the
  input is user-authored paths.

  So `typed_refusal?/1` is checked FIRST and such a reason passes through
  VERBATIM. A reason is typed when it carries an `E_*` extractor code or the
  `box_refusal/2` prefix — in both cases the box has already said, precisely and
  in human words, what it refused and why; canned provider copy could only
  replace a true statement with a false one. This also keeps `failure_reason`
  and the raw `detail` in the same JSON payload from contradicting each other.
  """

  # An extractor refusal code: `E_` followed by SCREAMING_SNAKE. Anchored on a
  # word boundary so a provider code that merely ENDS in `…E_…`
  # (`SERVER_LIMIT_EXCEEDED`, `RESOURCE_UNAVAILABLE`) can't match — `_` is a word
  # character, so there is no boundary inside those.
  @typed_code ~r/\bE_[A-Z][A-Z0-9_]*\b/

  # `BarkparkCloud.Sites.Deploy.box_refusal/2`'s prefix: the box answered and said
  # no, in its own words.
  @box_refusal "the instance refused the deploy"

  @doc """
  Whether a raw failure reason already carries a typed refusal — an `E_*`
  extractor code or the box-refusal prefix — and therefore must reach the user
  unrewritten.
  """
  @spec typed_refusal?(term()) :: boolean()
  def typed_refusal?(reason) when is_binary(reason) do
    String.contains?(reason, @box_refusal) or Regex.match?(@typed_code, reason)
  end

  def typed_refusal?(_other), do: false

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
      # site-spawner W11: a typed refusal is already precise and already human —
      # and it interpolates a producer-controlled entry name, so any substring
      # clause below could replace a traversal refusal with unrelated provider
      # copy. Checked FIRST, before any token can see it. See the moduledoc.
      typed_refusal?(reason) ->
        reason

      # dwb-webhook fail-fast interim: a GitHub push was recorded as a
      # born-`failed` deployment because source builds need the GitHub App
      # integration (gh-1, human-gated). Blocked-tone, names the workaround.
      # Checked FIRST — the raw reason is a known exact string; its output does
      # not re-match any clause (no "github push builds" token), so a second
      # client-side `failureCopy()` pass is idempotent.
      String.contains?(down, "github push builds") ->
        "GitHub pushes are recorded but can't be built yet — deploy this commit with bp deploy. Automatic GitHub builds are coming."

      # site-spawner D28: the STATIC twin of "no build source". A content-bound
      # site builds from a Barkpark dataset, so its missing build source is a
      # missing CONTENT BINDING — telling its owner to "connect a repo or run bp
      # deploy" would name neither the cause nor the cure. Checked BEFORE the
      # generic clause below (whose "no build source" token this string does not
      # carry, but the ordering keeps the intent explicit). The output re-matches
      # no clause, so a second client-side `failureCopy()` pass is idempotent.
      String.contains?(reason, "no content binding") ->
        "This site isn't bound to any content yet. Create it with --dataset <workspace>/<project>/<dataset>."

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

  def connect_remediation("cloudflare") do
    "We couldn't reach Cloudflare with that API token. Create a token with Zone · DNS · Edit (and DNS · Read) permissions in the Cloudflare dashboard → My Profile → API Tokens → Create Token, then paste it here."
  end

  def connect_remediation(_kind) do
    "We couldn't verify those credentials with the provider. Double-check them and try again."
  end

  @doc """
  The per-kind remediation copy `POST /v1/launch` returns when a launch names a
  provider the team hasn't connected yet (provider-neutral hosting, charter
  Decision 4/9). Azure PROVISIONS from the team's connected service-principal, so a
  launch without one is a dead end unless we point the user at Providers → connect
  first — failing at the button, never mid-provision. Falls back to a
  provider-agnostic line for an unknown kind.
  """
  @spec provider_not_connected_remediation(String.t()) :: String.t()
  def provider_not_connected_remediation("azure") do
    "Connect your Azure account first. In Barkpark Cloud → Providers → Azure, add your service-principal details (tenant, client, secret, subscription) — we verify them before saving — then launch again."
  end

  def provider_not_connected_remediation(_kind) do
    "Connect this provider under Barkpark Cloud → Providers first, then launch again."
  end

  @doc """
  The server-owned reason a provider LACKS a capability — the honest-degradation
  copy the fleet/console and CLI render next to a disabled action so a missing
  capability is visible WITH a reason, never a dead button or fake parity (the
  wish's "degrade visibly with a reason"; charter Decision 8/16). Keyed on
  `(kind, capability)`; the terminal default clause GUARANTEES every false
  capability in `providers_capabilities.json` has a reason — no gap can reach a
  surface reason-less, even for a capability key added later (S9's facet split).

  Ownership lives HERE, not in the SPA or CLI, so both surfaces read one copy
  through the `GET /v1/providers/capabilities` conduit and can never drift.
  """
  @spec capability_gap_reason(String.t(), String.t()) :: String.t()

  # Azure lifecycle facets. Azure now honours archive (S14b: the PORTABLE
  # bp-bundle-v1 — no snapshot substrate needed), resurrect (S14d: a bundle
  # archived on Hetzner or Azure restores onto a fresh Azure box), decommission
  # and audit. Its ONE remaining gap is ADOPT (a snapshot-based clone-swap),
  # named specifically so the console can say WHY, not just "no". The dead
  # archive/resurrect gap clauses are gone: live capabilities never degrade.
  def capability_gap_reason("azure", "adopt") do
    "Adopt is a snapshot-based clone-swap on Hetzner; Azure has no equivalent yet, so the same verb would quietly mean something different."
  end

  # Hetzner pause: a stopped Hetzner server still bills for its resources, so we
  # don't offer a pause that lies about cost — archive releases it instead.
  def capability_gap_reason("hetzner", "pause") do
    "Hetzner boxes can't be paused — a stopped server still bills. Archive it to stop paying and resurrect it later."
  end

  # Catalog: the provider doesn't publish a normalized size-and-region catalog
  # here, so provisioning falls back to fixed defaults (generic across kinds).
  def capability_gap_reason(_kind, "catalog") do
    "This provider doesn't publish a size-and-region catalog here yet, so provisioning uses fixed defaults."
  end

  # Generic per-capability fallbacks — reached by any (kind, capability) pair
  # not named above, so a new provider or a newly-false capability still degrades
  # with human copy.
  def capability_gap_reason(_kind, "lifecycle") do
    "Lifecycle actions (archive, decommission, resurrect, adopt) aren't available on this provider yet."
  end

  def capability_gap_reason(_kind, "pause") do
    "Pausing isn't available on this provider yet."
  end

  def capability_gap_reason(_kind, "labels") do
    "Labels aren't available on this provider yet."
  end

  def capability_gap_reason(_kind, "core") do
    "Core provisioning isn't available on this provider yet."
  end

  def capability_gap_reason(_kind, capability) when is_binary(capability) do
    "The #{capability} capability isn't available on this provider yet."
  end

  @doc """
  The server-owned remediation for a non-ok domain-status stage (charter S13 —
  `BarkparkCloud.DomainStatus`). Keyed on `(kind, stage)` where `kind` is
  `"platform"` (the provisioning FQDN) or `"custom"` (an attached `custom_host`)
  and `stage` is one of `"dns_found"`, `"points_here"`, `"tls"`, `"serving"`.

  The cert story genuinely differs by kind: the PLATFORM FQDN's certificate is
  issued and renewed by the provision-time Caddy automatically, while a CUSTOM
  host's certificate is requested on demand by the attach step
  (`/v1/tls/ask` — `registry.ex` `domain_registered?/1` deliberately excludes the
  platform FQDN), so the two `pending` stories point the operator at different
  things. Every OTHER stage's copy is kind-agnostic. The terminal default clause
  GUARANTEES no non-ok stage is ever reason-less — the console (S13b) and CLI
  read this one copy through the domain-status envelope, so they can't drift.
  """
  @spec domain_stage_remediation(String.t(), String.t()) :: String.t()

  def domain_stage_remediation(_kind, "dns_found") do
    "This domain isn't resolving publicly yet. If you just launched or attached it, DNS records take up to a minute to propagate — give it a moment and re-check."
  end

  def domain_stage_remediation(_kind, "points_here") do
    "This domain resolves, but not to this instance's address. It's pointed automatically when the instance is provisioned; if it persists, re-attach the domain or contact support."
  end

  # PLATFORM cert: provision-time Caddy issues + renews it automatically.
  def domain_stage_remediation("platform", "tls") do
    "The TLS certificate for this domain is issued and renewed automatically by the platform. If it isn't ready, it's usually still being issued on first HTTPS request — give it ~60s and re-check."
  end

  # CUSTOM cert: requested on demand by the attach step (/v1/tls/ask).
  def domain_stage_remediation("custom", "tls") do
    "The certificate for your custom domain is requested on demand when it's attached. If it isn't ready, give it ~60s and re-check; if it persists, re-attach the domain."
  end

  def domain_stage_remediation(_kind, "serving") do
    "The domain and certificate check out, but this instance isn't returning a healthy response yet. If it just launched it may still be booting — check the instance status, then re-check."
  end

  # Terminal default: any stage (including a skipped, still-pending one) gets a
  # reason so no non-ok stage is ever rendered reason-less.
  def domain_stage_remediation(_kind, _stage) do
    "This check hasn't passed yet. It runs after the earlier steps succeed — resolve those first, then re-check."
  end
end
