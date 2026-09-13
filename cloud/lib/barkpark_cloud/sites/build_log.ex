defmodule BarkparkCloud.Sites.BuildLog do
  @moduledoc """
  deploy-reliability `dr-bl-recorder-http-read-path` — the TEAM-SCOPED read path
  for the black box recorder, addressed by DEPLOYMENT ID.

  It shipped operator-gated and `dr-w19-site-build-log-is-operator-only` re-pointed
  it: `:platform_admin_emails` is unset on prod and unsettable through any route,
  so the one deploy-health read carrying a failed build's own words was readable by
  zero accounts. The router now takes it through `with_team_site(conn, {:ability,
  "read"}, …)` — the SAME door `GET /v1/sites/:id/deployments/:dep_id` uses — and
  hands this module the already-team-scoped `site.id`. Nothing about WHAT crosses
  the boundary changed (see the raw-bytes and field-allowlist sections below);
  only who may ask.

  ## What this closes

  Wave 2 made a failed deploy's build output durable and addressable ON THE BOX:
  `Barkpark.Sites.DeployRunner.build_record/2` reads a per-build terminal record
  keyed on `{slug, build_id}`, and the box's admin door already serves it
  (`GET /v1/admin/site-deploy?slug=…&build_id=…&record=1`). Nothing in the control
  plane ever CALLED it. A team asking "why did deployment `<uuid>` fail?" had
  exactly two answers: the one-line `failure_reason` on the Deployment row, or an
  SSH session. This module is the third.

  ## Deployment id, never slug

  `bp sites logs <site>` is SLUG-keyed: it resolves the LATEST deployment and
  prints a pointer column. That is the wrong key by construction — the question is
  about ONE deployment, and a site that has deployed since has moved the latest
  pointer off it. The control plane holds `build_id` on the Deployment row
  (unique per `(site_id, build_id)`), so a deployment id resolves to exactly the
  `{slug, build_id}` pair the box records under. Days later, and regardless of what
  deployed after it.

  ## THREE ANSWERS, NEVER ONE 404

  The defect this module refuses to reproduce: on the box's poll door, a
  superseded build, a never-started one and a nonexistent slug all collapse into
  one 404, which `SiteDeployController.resolve_status_match/2` documents the
  control plane treats as KEEP WAITING. Reused here that would tell a reader
  "not yet" about a log that was deleted a week ago.

  So the states are separated BY STATUS CODE, not only by a body field — a client
  that reads nothing but the status still cannot conflate them:

    * **404 `not_found`** — no such deployment, not this site's, or not a site
      this caller's team owns (the router's `with_team_site/3` answers that one). Existence-leak
      parity with `GET /v1/sites/:id/deployments/:dep_id`, deliberately identical
      so this route leaks no deployment ids the sibling withholds.
    * **410 `build_log_evicted`** — a TOMBSTONE says so. The bytes existed and
      retention reclaimed them; `evicted_at` names when. Gone is the only honest
      status: the resource was here, it is not coming back, and retrying is
      pointless.
    * **200** — the box answered definitively about a deployment that exists.
      `log_state` names which definite answer: `available` (the bytes are on the
      box), `missing` (gone from disk with no tombstone — retention did NOT do
      this, and saying `evicted` would claim it did), or `never_recorded`
      (nothing was ever written for this build at all).

  `never_recorded` is a 200 ON PURPOSE and it is the whole point. The resource
  being fetched is THE BUILD-LOG RECORD FOR A DEPLOYMENT, and that record exists —
  the box gave a complete, definite answer. Answering 404 would put it back in the
  same bucket as "no such deployment", which is the exact lie the row was filed
  against.

  Two more, honestly separate from all three:

    * **409 `box_unbound`** — the site's instance row is gone. We cannot ask.
    * **502 `box_unreachable`** — the box could not be reached, or refused. This is
      "we do not know", and it is NOT `never_recorded`. Nothing is invented on the
      control-plane side (the `BoxRelay` moduledoc's own law).

  ## RAW BYTES ARE NOT SERVED HERE, AND THAT IS INHERITED, NOT CHOSEN

  The box's door refuses the raw log bytes and says why in
  `BarkparkWeb.SiteDeployController` (`render_build_record/1`): the build env file
  carries `BARKPARK_TOKEN=` in plaintext and the recorded log is the least-scrubbed
  artifact in the system. This module CANNOT serve bytes the box will not hand
  over, and it does not try. What it serves is the structured record — stages,
  exit code, honest failure reason, and `log_path` / `log_bytes` /
  `journal_command` naming where the bytes are — which carries no credential
  surface and is strictly more diagnostic than the one-line `failure_reason`.

  That refusal is load-bearing NOW that the audience is a whole team rather than
  an empty operator allowlist: the widening moved WHO may ask, never WHAT is
  served.

  Serving the bytes needs SCRUB-AT-WRITE on the box first (`strip_ansi |> scrub`,
  paid once at write). That is a `deploy/` + `api/` slice, not a control-plane one.

  ## THE FIELD LIST IS EXPLICIT, NEVER A PASS-THROUGH

  Same doctrine as the box door, for the same reason and one more: this end also
  crosses a trust boundary. The box's answer is a decoded JSON map from a REMOTE
  process; rendering it wholesale would mean the day the box grows a `log_tail`
  field is the day this route starts serving credentials to every member of the
  owning team. Naming each key means a new upstream field is invisible here
  until a human adds it on purpose.

  ## Not SSE-broadcast

  Pull-only, one deployment per request, team-scoped. The live console
  (`Deployment.console`) is the broadcast surface and it is a different, already
  worker-redacted stream. A recorded build log must never ride a fan-out channel:
  the audience of an SSE topic is everyone subscribed to it, which is not the
  audience this record is gated to.
  """

  require Logger

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Sites.BoxRelay

  @typedoc "The box's verdict, as `BoxRelay` hands it back."
  @type reply :: {:ok, non_neg_integer(), map()} | {:error, term()}

  @typedoc "`{http_status, json_body}` — what the router puts on the wire."
  @type wire :: {non_neg_integer(), map()}

  # The keys this route will render from the box's record. Anything the box adds
  # later is dropped until a human lists it here. `log_state` is read separately
  # (it decides the status code) and re-stated in the body so a logged response is
  # self-describing.
  # route_status/route_detail: the box has rendered these on the record door
  # since #17640 and this allowlist did not list them, so the box's route
  # verdict was dropped SILENTLY on the way to the operator reading a failed
  # build. Found by the lock in
  # cloud/test/barkpark_cloud/sites/box_status_payload_conformance_test.exs,
  # which compares this list to the producer's own key set through `wire/3`.
  @record_keys ~w(
    slug build_id record log_state log_path log_bytes exit_code failure_reason
    route_status route_detail
    stages unit_name journal_command mode runtime_target
    started_at finished_at evicted_at
  )

  # Defence in depth, not inheritance: the box door caps these too. An invariant
  # held somewhere else is exactly what this end must not rely on — a box running
  # older or newer code is precisely the case where the cap matters.
  @max_reason_bytes 4_000
  @max_stages 32
  @truncation_marker " …[truncated]"

  @doc """
  Resolve `{site_id, deployment_id}` to the wire answer — the whole route in one
  function, so the registry-shaped router carries ten lines and no policy.

  The site scoping is NOT decoration. `dep_id` alone would let a caller read
  any deployment through any site's URL, which makes an audit line about
  `/v1/sites/<a>/…` a lie about which site was read. A deployment that does not
  belong to THIS site is the same 404 as one that does not exist, matching
  `GET /v1/sites/:id/deployments/:dep_id` exactly.
  """
  @spec for_deployment(String.t() | nil, String.t() | nil) :: wire()
  def for_deployment(site_id, deployment_id)
      when is_binary(site_id) and is_binary(deployment_id) do
    with %Registry.Site{} = site <- Registry.get_site(site_id),
         %Registry.Deployment{site_id: sid} = deployment when sid == site.id <-
           Registry.get_deployment(deployment_id) do
      read(site, deployment)
    else
      _ -> not_found()
    end
  end

  def for_deployment(_site_id, _deployment_id), do: not_found()

  defp not_found, do: {404, %{error: "not_found"}}

  defp read(site, %Registry.Deployment{build_id: build_id} = deployment)
       when is_binary(build_id) and build_id != "" do
    case Registry.get_barkpark(site.barkpark_id) do
      nil ->
        unbound(deployment.id, build_id)

      bp ->
        bp
        |> BoxRelay.build_record(site.slug, build_id)
        |> wire(deployment.id, build_id)
    end
  end

  defp read(_site, deployment), do: unkeyed(deployment.id)

  @doc """
  Map the box's reply for a deployment onto `{status, body}`.

  `deployment_id` and `build_id` are echoed on EVERY answer including the
  refusals, so a caller holding a pile of responses can always say which
  deployment each one is about.
  """
  @spec wire(reply(), String.t(), String.t() | nil) :: wire()
  def wire(reply, deployment_id, build_id) do
    base = %{deployment_id: deployment_id, build_id: build_id}

    case reply do
      {:ok, status, body} when status in 200..299 and is_map(body) ->
        decide(body, base)

      # The box answered, and said no. Relayed as "we do not know", never as
      # "nothing was recorded" — a 404 from the box's own door is its
      # keep-waiting shape (charter D34) and means nothing about eviction.
      {:ok, status, body} when is_integer(status) ->
        {502,
         Map.merge(base, %{
           error: "box_unreachable",
           detail: "the box refused the record read",
           box_status: status,
           box_error: box_error(body)
         })}

      {:error, reason} ->
        # THE TERM IS LOGGED, NEVER ECHOED. `inspect/1` on a transport term is
        # how a credential reaches a client body (the `transport_reason/1` /
        # `cloudflare_reason/1` / `billing_reason/1` law, pinned by
        # `RouterTransportRedactionTest`): an `{:error, %Mint.TransportError{}}`
        # or a decrypt failure can carry a token in a nested struct. The operator
        # keeps the whole diagnostic in the log; the wire gets a bounded phrase.
        Logger.error("build log read failed for deployment #{deployment_id}: #{inspect(reason)}")

        {502,
         Map.merge(base, %{
           error: "box_unreachable",
           detail: "could not reach the box that recorded this build",
           reason: relay_reason(reason)
         })}
    end
  end

  @doc """
  The site has no instance row — there is no box to ask. Separate from
  `box_unreachable`: one is a control-plane fact, the other is a network verdict.
  """
  @spec unbound(String.t(), String.t() | nil) :: wire()
  def unbound(deployment_id, build_id) do
    {409,
     %{
       deployment_id: deployment_id,
       build_id: build_id,
       error: "box_unbound",
       detail: "this site is not bound to a live instance, so no box can be asked"
     }}
  end

  @doc """
  A pre-recorder deployment: the Deployment row carries no `build_id`, so there is
  no key to record under and there never was. Answered WITHOUT calling the box —
  a slug-only read would hand back some OTHER build's record, which is the
  wrong-key bug this row exists to remove.
  """
  @spec unkeyed(String.t()) :: wire()
  def unkeyed(deployment_id) do
    {200,
     %{
       deployment_id: deployment_id,
       build_id: nil,
       log_state: "never_recorded",
       available: false,
       detail:
         "this deployment carries no build_id (it predates build-keyed recording), so nothing was ever recorded under it"
     }}
  end

  ## ---------------------------------------------------------------------------

  # `log_state` decides the status. An absent or unrecognised one is NOT assumed
  # benign: a box that answered 200 with a shape we do not understand is a box we
  # cannot report on, and `unknown` is one of the recorder's own five states.
  defp decide(body, base) do
    case Map.get(body, "log_state") do
      "evicted" ->
        {410,
         base
         |> Map.merge(%{error: "build_log_evicted", available: false})
         |> Map.merge(record(body))}

      state when state in ["available", "missing", "never_recorded"] ->
        {200,
         base
         |> Map.put(:available, state == "available")
         |> Map.merge(record(body))}

      other ->
        {502,
         Map.merge(base, %{
           error: "box_unreachable",
           detail: "the box answered with a log_state this control plane does not understand",
           box_log_state: other
         })}
    end
  end

  defp record(body) do
    @record_keys
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.fetch(body, key) do
        {:ok, value} -> Map.put(acc, String.to_atom(key), value)
        :error -> acc
      end
    end)
    |> cap()
  end

  defp cap(record) do
    record
    |> Map.update(:failure_reason, nil, &cap_reason/1)
    |> Map.update(:stages, nil, &cap_stages/1)
  end

  # Truncation is VISIBLE, never silent — a caller that sees the marker knows the
  # reason was longer, and one that does not is looking at the whole thing.
  defp cap_reason(reason) when is_binary(reason) do
    if byte_size(reason) > @max_reason_bytes do
      binary_part(reason, 0, @max_reason_bytes) <> @truncation_marker
    else
      reason
    end
  end

  defp cap_reason(other), do: other

  defp cap_stages(stages) when is_list(stages), do: Enum.take(stages, @max_stages)
  defp cap_stages(other), do: other

  # A CLOSED vocabulary, fail-closed on the bare `_`. Each named atom is a
  # `BoxRelay.reply/0` error the caller can act on differently; anything else
  # collapses to one constant rather than reaching the wire raw.
  defp relay_reason(:not_live), do: "the box that recorded this build is not live"

  defp relay_reason(:no_admin_token),
    do: "this control plane holds no admin credential for that box"

  defp relay_reason(:identity_refused),
    do: "the box refused this control plane's stored admin credential"

  defp relay_reason(:decrypt_failed), do: "the stored admin credential could not be decrypted"
  defp relay_reason(_other), do: "the request could not be completed"

  defp box_error(body) when is_map(body), do: Map.get(body, "error") || Map.get(body, "code")
  defp box_error(_), do: nil
end
