defmodule BarkparkWeb.Contract.ErrorCodeCoverageTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Errors

  # ── Served error vocabulary must be a SUPERSET of what the wire emits ────────
  #
  # `Content.Errors.known_codes/0` is the single source for the OpenAPI
  # `Error.code` enum (openapi.ex) and docs/api-v1.md §9. A separate test pins
  # enum == known_codes. But controllers/plugs that write error envelopes INLINE
  # (bypassing `Errors.build/1`) can add a code the enum never declared — a
  # spec-generated SDK then deserializes `error.code` into the enum, meets an
  # undeclared variant, and throws or drops the response (e.g. a client can't
  # branch on an `mfa_required` / `invalid_grant` challenge it was never told
  # exists). This guard makes that drift fail CI: every error code emitted on a
  # PUBLIC v1 endpoint must be in `known_codes/0` (or on the documented off-spec
  # exclusion list below).
  #
  # HOW "emitted" is bounded (robustness): we scan ONLY the directories that
  # write error envelopes to the wire — web controllers, web plugs, the endpoint
  # error handler, and plugin web controllers — and extract static `code: "..."`
  # / `"code" => "..."` literals. This deliberately excludes non-error `code:`
  # fields that live elsewhere (e.g. the media codelist VALUES in
  # plugins/media/codelists.ex, or the per-violation `"code" => "legacy"` in
  # error_envelope.ex), so the guard cannot false-positive on them.

  @emitter_globs [
    "lib/barkpark_web/controllers/**/*.ex",
    "lib/barkpark_web/plugs/**/*.ex",
    "lib/barkpark_web/endpoint.ex",
    # plugin web controllers (e.g. Sheets ops API)
    "lib/barkpark/plugins/**/web/**/*.ex"
  ]

  # Codes DELIBERATELY excluded from the public `Error.code` enum. Each is
  # emitted only on an OPERATIONAL endpoint that is NOT part of the public v1
  # content contract — not a capability-manifest command, never consumed by a
  # generated content SDK — so documenting it as a public v1 code would be
  # misleading noise. They are recorded here (not silently missing) so the guard
  # stays green AND a future reader knows the omission is intentional. Promote a
  # code out of this list into known_codes the day its endpoint joins the public
  # SDK surface.
  @offspec_codes MapSet.new([
                   # Instance self-update — admin ops trigger POST /v1/self-update
                   # (git-pull/rebuild subprocess state, not a content operation).
                   "already_running",
                   "feature_not_configured",
                   "runner_start_failed",
                   # Site deploy — the site's SOURCE could not be materialized,
                   # so the build never started (POST /v1/admin/site-deploy,
                   # same admin-ops family as the three codes above). Split out
                   # of runner_start_failed by deploy-reliability D26 so a
                   # provision failure names itself instead of vanishing into a
                   # Logger line.
                   "site_provision_failed",
                   # Site deploy — the box's ONE fleet build slot is already
                   # taken by another site's build, so the deploy is refused at
                   # the door instead of queueing inside its unit for 900s
                   # (same admin-ops endpoint, deploy-reliability wave 4).
                   "box_at_capacity",
                   # Self-update W6 rollback preflight — same admin-ops
                   # endpoint family as the three codes above (fail-closed
                   # 500 when preflight can't clear the rollback).
                   "rollback_preflight_failed",
                   # Status-page incident admin — POST /v1/status/incidents.
                   "invalid_incident",
                   # Pulse telemetry beacon ingest — /v1/pulse (internal analytics).
                   "invalid_event",
                   # Inbound GitHub webhook RECEIVER — github calls us
                   # (server-to-server), not a client-facing API.
                   "inbound_failed",
                   "intake_failed",
                   # pull_request merge event → merge-gate autostamp reconcile
                   # (same github-webhook receiver family; fail-closed 500 when
                   # the reconcile raises).
                   "merge_reconcile_failed",
                   # github-adopt operational bridge — `bp github adopt`.
                   "adopt_failed",
                   "not_intake",
                   # ONIX export — GET /v1/plugins/onixedit/export/:dataset/:id,
                   # mounted on the host's :require_admin pipeline and answering
                   # application/onix+xml, not the JSON content contract. Both
                   # codes previously rode an `error.type` key instead of
                   # `error.code`, so this guard could not see them AT ALL (its
                   # scan reads `code:` literals); routing them through
                   # ErrorResponse is what surfaced them here. Promote both into
                   # known_codes/0 the day the ONIX export joins the public SDK
                   # surface — that also needs a §9 line in docs/api-v1.md.
                   "xsd_invalid",
                   "invalid_onix_code"
                 ])

  # `code:` / `"code" =>` string literals that are NOT error codes but live
  # inside an emitter dir (kept tiny + explicit so it can't mask real drift).
  @non_error_code_literals MapSet.new([
                             # per-violation severity code in the validation
                             # envelope, not the top-level Error.code
                             "legacy"
                           ])

  defp emitted_codes do
    @emitter_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      body = File.read!(path)

      Regex.scan(~r/(?:code:\s*"|"code"\s*=>\s*")([a-z_]+)"/, body)
      |> Enum.map(fn [_, code] -> code end)
    end)
    |> MapSet.new()
    |> MapSet.difference(@non_error_code_literals)
  end

  test "emitter dirs exist (guard is actually scanning something)" do
    files = @emitter_globs |> Enum.flat_map(&Path.wildcard/1)
    assert length(files) > 5, "emitter globs matched too few files — did a path move?"
  end

  test "every error code emitted on a public v1 endpoint is in known_codes/0" do
    emitted = emitted_codes()
    allowed = MapSet.union(Errors.known_codes(), @offspec_codes)

    undeclared =
      emitted
      |> MapSet.difference(allowed)
      |> Enum.sort()

    assert undeclared == [],
           """
           These error codes reach the wire on public v1 endpoints but are NOT in
           Content.Errors.known_codes/0 and NOT on the off-spec exclusion list — so
           the served OpenAPI Error.code enum + api-v1.md §9 under-report reality and
           a spec-generated SDK will meet an undeclared variant:

               #{inspect(undeclared)}

           Fix: register each PUBLIC code in Content.Errors (@public_inline_codes, or
           a @hints entry if build/1 emits it), OR — if it is emitted only on an
           operational, off-contract endpoint — add it to @offspec_codes here with a
           one-line justification. Never leave it silently absent.
           """
  end
end
