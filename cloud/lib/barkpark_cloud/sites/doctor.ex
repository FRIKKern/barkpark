defmodule BarkparkCloud.Sites.Doctor do
  @moduledoc """
  ssw8-site-doctor: read EVERY substrate a site occupies that the control plane
  can genuinely reach, and name the exact repair for each one that is missing.

  ## Why this module exists

  A spawned site occupies many substrates and exactly ONE of them (the CP row)
  had a real readback before this. When a spawn half-completes there is no way to
  see what exists without SSH. A live census on guerrilla found four distinct
  shapes of half-completion, and the worst of them is silent: `auto-proof` carries
  a `content_webhook_secret_encrypted` on the CP row and has NO webhook row on the
  box, so the control plane believes it is wired for auto-deploy and nothing will
  ever be delivered.

  ## THE THREE HONESTY LAWS

  1. **Three-valued, per substrate.** `present` / `absent` / `unknown` — plus
     `not_applicable` for a substrate this KIND of site legitimately does not
     have. A read that could not be PERFORMED is `unknown` WITH ITS REASON, never
     `absent`. Absent is a claim about the world; unknown is a claim about this
     doctor. Collapsing the second into the first is the exact defect this verb
     exists to prevent — it would let the doctor render a confident verdict from a
     failed read, which is worse than no doctor at all.

  2. **Branch on kind.** A node-kind site legitimately has NO `current` symlink:
     it uses the SLOT model (blue/green on `port_base`/`port_base+1`, flipped at
     the Caddy upstream). A naive current-pointer check reports six FALSE absences
     on today's fleet, so `current_release` is `not_applicable` on node.

  3. **Every absent or mismatched substrate names its EXACT repair verb, or says
     outright that none exists.** No repair is promised that this codebase cannot
     perform — every string in `repair_for/2` was checked against a real caller,
     and the ones with no caller say so instead of pointing at a dead function.

  ## What it reads, and what it deliberately does not

  READS (all of it CP-reachable — there is no box endpoint invented here):

    * the CP `sites` row and its binding fields;
    * the read token's LIVENESS, probed with `Registry.relay_as/4` over the SAME
      scoped query route the build itself fetches with;
    * the content-publish webhook, via `Registry.content_webhook_state/1` (the
      narrow public wrapper over `find_content_webhook/3`, whose
      `{:ok, id} | :absent | :unknown` shape is already exactly three-valued);
    * whether a content-publish SECRET exists on the row (a secret with no box row
      is `auto-proof`'s exact defect);
    * the deployments ledger and `current_deployment_id`;
    * the live URL, actually FETCHED.

  DOES NOT READ: the box filesystem (no `src`, no `releases/`, no `current`
  symlink, no systemd unit, no Caddy block). Those are real substrates and this
  doctor does not pretend to see them — a CP-side census of them is a separate
  slice with a box endpoint behind it.

  ## `ok`

  `ok` is TRUE when nothing is `absent`. An `unknown` never sinks it: an unknown
  is not a failure, it is an abstention, and a doctor that cried wolf on every
  box that was briefly down would be ignored — which is the failure mode the
  whole receipt exists to prevent. Unknowns are counted in `unknown_count` and
  named in `unreadable`, so a green report can never be mistaken for a
  fully-measured one.
  """

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.{Barkpark, Site}
  alias BarkparkCloud.DeployLedger
  alias BarkparkCloud.Sites.Deploy

  @present "present"
  @absent "absent"
  @unknown "unknown"
  @not_applicable "not_applicable"

  @content_bound_kinds ~w(static node)

  @doc """
  Build the per-substrate report for `site`. `site.barkpark` may be preloaded;
  when it is not, the instance is fetched once and reused for every probe.
  """
  @spec check(Site.t()) :: map()
  def check(%Site{} = site) do
    bp = barkpark_for(site)
    substrates = substrates(site, bp)

    %{
      ok: not Enum.any?(substrates, &(&1.state == @absent)),
      checked_at: DateTime.utc_now(),
      site: %{
        id: site.id,
        slug: site.slug,
        name: site.name,
        kind: site.kind,
        framework: site.framework,
        instance: bp && bp.slug
      },
      substrates: substrates,
      absent_count: Enum.count(substrates, &(&1.state == @absent)),
      unknown_count: Enum.count(substrates, &(&1.state == @unknown)),
      unreadable: substrates |> Enum.filter(&(&1.state == @unknown)) |> Enum.map(& &1.key)
    }
  end

  defp barkpark_for(%Site{barkpark: %Barkpark{} = bp}), do: bp
  defp barkpark_for(%Site{barkpark_id: id}), do: Registry.get_barkpark(id)

  defp substrates(site, bp) do
    token = read_token(site)

    [
      cp_row(site),
      instance(site, bp),
      content_binding(site),
      read_token_row(site, token),
      content_read(site, bp, token),
      content_webhook(site),
      webhook_secret(site),
      deployments(site),
      current_release(site),
      live_url(site, bp)
    ]
  end

  ## ── The substrates ────────────────────────────────────────────────────────

  # The one substrate that is present BY CONSTRUCTION: this report was built from
  # the row, so it cannot be anything else. It is listed anyway because a receipt
  # that silently omits what it DID read invites the reader to assume the rest was
  # read the same way.
  defp cp_row(site) do
    row(
      "cp_row",
      @present,
      "the control-plane `sites` row exists (id #{site.id}, slug #{site.slug}, kind #{site.kind})"
    )
  end

  defp instance(_site, %Barkpark{url: url} = bp) when is_binary(url) and url != "" do
    row("instance", @present, "#{bp.slug} is live at #{url}")
  end

  defp instance(_site, %Barkpark{} = bp) do
    row(
      "instance",
      @absent,
      "#{bp.slug} carries no URL — it has not finished provisioning, so every box-side read below is UNKNOWN rather than absent",
      "`bp cloud instance status #{bp.slug}` — wait for the launch to finish, or re-launch it"
    )
  end

  defp instance(site, nil) do
    row(
      "instance",
      @absent,
      "the row points at barkpark_id #{site.barkpark_id} and no such instance exists — this site is an orphan",
      "no repair verb exists for the pointer: `bp cloud site delete #{site.slug}` removes the row (the existing delete verb reaches it — the CP row is the truth)"
    )
  end

  defp content_binding(%Site{kind: kind}) when kind not in @content_bound_kinds do
    row(
      "content_binding",
      @not_applicable,
      "a #{kind} site builds from a repo or a prebuilt artifact, not from a dataset"
    )
  end

  defp content_binding(site) do
    triple = [site.bootstrap_workspace, site.bootstrap_project, site.bootstrap_dataset]

    if Enum.all?(triple, &(is_binary(&1) and &1 != "")) do
      row(
        "content_binding",
        @present,
        "bound to #{Enum.join(triple, "/")} (doc_type #{site.doc_type || "post"})"
      )
    else
      row(
        "content_binding",
        @absent,
        "the row carries no complete workspace/project/dataset triple, so this site would build from nothing",
        no_repair(
          "the dataset binding is immutable after create — PATCH /v1/sites/:id casts only theme, doc_type and prebuilt_enabled. " <>
            "`bp cloud site delete #{site.slug}` then re-create with `--dataset <ws>/<proj>/<ds>`"
        )
      )
    end
  end

  defp read_token_row(%Site{kind: kind}, _token) when kind not in @content_bound_kinds do
    row("read_token", @not_applicable, "a #{kind} site carries no public-read content token")
  end

  defp read_token_row(site, {:ok, token}) when is_binary(token) do
    row(
      "read_token",
      @present,
      "the row carries an encrypted public-read token (label site-read-#{site.slug}); its plaintext is never serialized"
    )
  end

  defp read_token_row(site, {:ok, nil}) do
    row(
      "read_token",
      @absent,
      "the row carries no public-read token, so the build has no credential to fetch content with",
      no_repair(
        "`Registry.mint_public_read_token/5` is called from POST /v1/sites only — there is no re-mint verb. " <>
          "`bp cloud site delete #{site.slug}` then re-create the site"
      )
    )
  end

  defp read_token_row(_site, :error) do
    row(
      "read_token",
      @unknown,
      "the row carries a read-token ciphertext that did NOT decrypt (Vault.decrypt/1 fails closed) — whether a usable token exists could not be determined",
      "check the control plane's CLOAK_KEY / vault key material; a key rotation that dropped the old key makes every site's ciphertext unreadable, which is a control-plane fault and not a site fault"
    )
  end

  # THE LIVENESS PROBE. The site's OWN credential over the build's OWN route
  # (`Sites.Deploy` scoped_api_url + BARKPARK_TOKEN), because an ADMIN relay reads
  # content the build's clamped token cannot see — a "verified" read over the admin
  # token would be a NEW false green, a green preflight followed by an empty site.
  defp content_read(%Site{kind: kind}, _bp, _token) when kind not in @content_bound_kinds do
    row("content_read", @not_applicable, "a #{kind} site reads no dataset")
  end

  defp content_read(site, bp, token) do
    ws = site.bootstrap_workspace
    proj = site.bootstrap_project
    ds = site.bootstrap_dataset
    type = site.doc_type || "post"

    cond do
      is_nil(bp) or not is_binary(bp.url) or bp.url == "" ->
        row(
          "content_read",
          @unknown,
          "the instance has no URL, so the read token could not be probed at all — this is NOT evidence the token is dead",
          "re-run `bp cloud site doctor #{site.slug}` once the instance is live; nothing was measured, so nothing needs repairing yet"
        )

      not Enum.all?([ws, proj, ds], &(is_binary(&1) and &1 != "")) ->
        row(
          "content_read",
          @unknown,
          "the site is not fully bound, so there was no scoped route to probe the token against",
          "repair `content_binding` first — the token's liveness cannot be separated from a missing dataset"
        )

      not match?({:ok, t} when is_binary(t) and t != "", token) ->
        row(
          "content_read",
          @unknown,
          "no usable plaintext read token, so no probe was made — see `read_token` for whether one exists at all",
          "repair `read_token` first"
        )

      true ->
        {:ok, plaintext} = token
        probe(site, bp, ws, proj, ds, type, plaintext)
    end
  end

  defp probe(site, bp, ws, proj, ds, type, plaintext) do
    path =
      "/w/#{URI.encode(ws)}/p/#{URI.encode(proj)}/v1/data/query/#{URI.encode(ds)}/#{URI.encode(type)}?limit=1&count=true"

    case Registry.relay_as(bp, :get, path, plaintext) do
      {:ok, status, _body} when status in 200..299 ->
        row(
          "content_read",
          @present,
          "#{bp.slug} answered the site's OWN read token HTTP #{status} on #{ds}/#{type} — the credential is live and the build's route is reachable"
        )

      {:ok, status, _body} when status in [401, 403] ->
        row(
          "content_read",
          @absent,
          "#{bp.slug} REJECTED the site's read token (HTTP #{status}) — it was revoked, or it never carried public-read on #{ds}",
          no_repair(
            "there is no re-mint and no standalone revoke verb: `Registry.revoke_site_read_token/1` runs only inside `delete_site/1`, " <>
              "and `Registry.mint_public_read_token/5` only inside POST /v1/sites. `bp cloud site delete #{site.slug}` then re-create it"
          )
        )

      {:ok, 404, _body} ->
        row(
          "content_read",
          @unknown,
          "#{bp.slug} answered 404 on #{ds}/#{type} — the token's liveness cannot be separated from a missing dataset or a non-public type, so this is NOT a verdict on the credential",
          "confirm the dataset and type exist on #{bp.slug}; a 404 here is byte-identical for a typo'd dataset, a typo'd type and a type no public-read token may see"
        )

      {:ok, status, _body} ->
        row(
          "content_read",
          @unknown,
          "#{bp.slug} answered HTTP #{status} — the read could not be interpreted, so the token's liveness is UNMEASURED",
          "re-run the doctor; a persistent non-2xx here is an instance fault, not a site fault"
        )

      {:error, reason} ->
        row(
          "content_read",
          @unknown,
          "the probe never reached #{bp.slug} (#{inspect(reason)}) — the token's liveness is UNMEASURED, not absent",
          "re-run `bp cloud site doctor #{site.slug}` when the instance answers"
        )
    end
  end

  # The wrapper preserves all three values. Collapsing :unknown into :absent here
  # would make the doctor say "this site has no publish trigger" about a box that
  # was merely down — and the named repair would then be a WRITE against a
  # substrate nobody read, which is precisely the duplicate-webhook hazard
  # `find_content_webhook/3`'s own docstring warns about.
  defp content_webhook(site) do
    case Registry.content_webhook_state(site) do
      {:ok, id} ->
        row(
          "content_webhook",
          @present,
          "the box carries this site's content-publish webhook (site-autodeploy-#{site.id}, box id #{id})"
        )

      :absent ->
        row(
          "content_webhook",
          @absent,
          "the box listed its webhooks for #{site.bootstrap_dataset} and this site's row (site-autodeploy-#{site.id}) is NOT among them — a content publish will never reach this site",
          webhook_repair(site)
        )

      :unknown ->
        row(
          "content_webhook",
          @unknown,
          "the box's webhook list could not be read, so whether the row exists is UNMEASURED — it is deliberately not reported absent, because the repair for absent is a WRITE and nobody looked",
          "re-run `bp cloud site doctor #{site.slug}` when the instance answers; do not arm a webhook on the strength of a failed read"
        )

      :not_applicable ->
        row(
          "content_webhook",
          @not_applicable,
          "a #{site.kind} site with no bound dataset receives no content-publish deliveries"
        )
    end
  end

  # THE HONEST SPLIT. `Registry.ensure_content_webhook/2` REVEALS a secret and
  # never MINTS one, so on a site with no secret it returns `:noop` — promising it
  # as the fix would be a repair the codebase cannot perform.
  defp webhook_repair(%Site{content_webhook_secret_encrypted: nil}) do
    no_repair(
      "`Registry.ensure_content_webhook/2` REVEALS a secret and never mints one, so it returns :noop for a site with none — it is not the fix. " <>
        "Mint the secret first with POST /v1/operator/sites/content-secrets/mint (OPERATOR-only; no team-reachable verb exists), " <>
        "after which the hourly ContentWebhookReconciler arms the hook"
    )
  end

  defp webhook_repair(_site) do
    "the hourly ContentWebhookReconciler calls `Registry.reconcile_content_webhooks/1`, which re-arms this row idempotently. " <>
      "There is NO on-demand verb, and a redeploy does NOT arm it — `ensure_content_webhook/2` has no caller in the deploy path"
  end

  defp webhook_secret(site) do
    case Registry.publish_trigger(site) do
      :present ->
        row(
          "webhook_secret",
          @present,
          "the row carries a content-publish secret, so the control plane can sign deliveries for this site"
        )

      :absent ->
        row(
          "webhook_secret",
          @absent,
          "the site is content-bound and carries NO content-publish secret, so no delivery can ever be signed for it",
          "POST /v1/operator/sites/content-secrets/mint — OPERATOR-only; there is no team-reachable verb that mints it"
        )

      :not_applicable ->
        row(
          "webhook_secret",
          @not_applicable,
          "a #{site.kind} site with no bound dataset needs no content-publish secret"
        )
    end
  end

  defp deployments(site) do
    case DeployLedger.list_page(site, limit: 1, environment: "production") do
      {:ok, %{deployments: []}} ->
        row(
          "deployments",
          @absent,
          "this site has never had a production deployment — it is a CP row (and possibly a bare directory) and nothing more",
          "`bp cloud site deploy #{site.slug}` (POST /v1/sites/:id/deploy) — a deploy re-provisions and re-arms the box side idempotently"
        )

      {:ok, %{deployments: [d | _]}} ->
        row(
          "deployments",
          @present,
          "the production ledger is non-empty; newest is #{d.id} (#{d.status})"
        )

      other ->
        row(
          "deployments",
          @unknown,
          "the deployment ledger could not be paged (#{inspect(other)}) — this site's build history is UNMEASURED",
          "re-run the doctor"
        )
    end
  end

  # HONESTY LAW 2. A node site has no `current` symlink AT ALL: it runs the slot
  # model (blue on `port_base`, green on `port_base + 1`, flipped at the Caddy
  # upstream), so a naive pointer check reports a false absence on every node site
  # on the fleet. This is not a cosmetic branch — it was measured at six.
  defp current_release(%Site{kind: "node"} = site) do
    row(
      "current_release",
      @not_applicable,
      "a node site has NO `current` symlink — it uses the slot model (blue #{site.port_base || "?"} / green #{(site.port_base && site.port_base + 1) || "?"}), " <>
        "flipped at the Caddy upstream. Live port is #{site.port || "unset"}"
    )
  end

  defp current_release(%Site{current_deployment_id: nil} = site) do
    row(
      "current_release",
      @absent,
      "no `current_deployment_id` on the row — nothing has ever been switched live, so the box's `current` symlink (if the directory exists at all) points at nothing this control plane knows",
      "`bp cloud site deploy #{site.slug}` — a successful build ends at SWITCH, which is what sets this pointer"
    )
  end

  defp current_release(site) do
    case Registry.get_deployment(site.current_deployment_id) do
      %Registry.Deployment{} = d ->
        row(
          "current_release",
          @present,
          "current_deployment_id #{d.id} resolves to a #{d.status} deployment — the box's `current` symlink should point at its release"
        )

      _ ->
        row(
          "current_release",
          @unknown,
          "current_deployment_id #{site.current_deployment_id} resolves to no deployment row — the pointer is dangling and what the box serves is UNMEASURED",
          "`bp cloud site deploy #{site.slug}` re-points it; do not conclude the box is empty from a dangling CP pointer"
        )
    end
  end

  # FETCHED, never reconstructed. A URL this doctor merely assembled from the row
  # is a claim about a string, not about a site.
  defp live_url(site, bp) do
    case bp && Deploy.site_url(site, bp) do
      url when is_binary(url) and url != "" ->
        fetch_live_url(site, url)

      _ ->
        row(
          "live_url",
          @unknown,
          "no live URL could be composed (the instance carries no URL), so nothing was fetched",
          "re-run the doctor once the instance is live"
        )
    end
  end

  defp fetch_live_url(site, url) do
    case http_client().request(%{method: :get, url: url, headers: [], body: ""}) do
      {:ok, %{status: status}} when status in 200..299 ->
        row("live_url", @present, "GET #{url} answered HTTP #{status} — this site is serving")

      {:ok, %{status: status}} when status in [404, 502, 503] ->
        row(
          "live_url",
          @absent,
          "GET #{url} answered HTTP #{status} — the hostname resolves to the box and the box has nothing to serve for it",
          "`bp cloud site deploy #{site.slug}` — a redeploy re-provisions the vhost and the release tree idempotently"
        )

      {:ok, %{status: status}} ->
        row(
          "live_url",
          @unknown,
          "GET #{url} answered HTTP #{status} — neither serving nor definitely empty, so this is UNMEASURED",
          "open #{url} by hand; an unexpected status is a control-plane blind spot, not a verdict on the site"
        )

      other ->
        row(
          "live_url",
          @unknown,
          "GET #{url} never completed (#{inspect(other)}) — whether this site serves is UNMEASURED, NOT absent",
          "re-run `bp cloud site doctor #{site.slug}`; a transport failure says nothing about the site"
        )
    end
  end

  ## ── helpers ───────────────────────────────────────────────────────────────

  defp read_token(%Site{kind: kind}) when kind not in @content_bound_kinds, do: {:ok, nil}
  defp read_token(%Site{} = site), do: Registry.reveal_site_read_token(site)

  defp row(key, state, detail), do: row(key, state, detail, nil)

  defp row(key, state, detail, repair) do
    %{key: key, state: state, detail: detail, repair: repair}
  end

  # The one phrasing for "the codebase genuinely cannot do this". It is a PREFIX,
  # not a substitute for naming the mechanism: a reader must be able to check the
  # claim, so the sentence after it always says which function has no caller.
  defp no_repair(why), do: "NO repair verb exists — " <> why

  # Same transport seam every other cross-host read in this tree uses, so a test
  # swaps ONE module and this doctor makes no network call.
  defp http_client do
    Application.get_env(
      :barkpark_cloud,
      :studio_link_http_client,
      BarkparkCloud.Billing.HttpClient
    )
  end
end
