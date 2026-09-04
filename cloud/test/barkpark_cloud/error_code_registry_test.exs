defmodule BarkparkCloud.ErrorCodeRegistryTest do
  use ExUnit.Case, async: true

  @moduledoc """
  ssw8-bl — the CLOUD-SIDE sibling of
  `api/test/barkpark_web/contract/error_code_coverage_test.exs`.

  ## Why a sibling and not a reuse

  The api-side gate bounds itself with `@emitter_globs` that are all
  api-relative (`lib/barkpark_web/controllers/**`, `plugs/**`, `endpoint.ex`,
  `lib/barkpark/plugins/**/web/**`). Resolved from `api/`, ZERO of them reach
  `cloud/`, and the mismatch is structural, not an oversight: the two trees are
  separate Mix projects with separate test runs, so no glob written in `api/`
  can ever see a cloud emitter. The ENVELOPE differs too — cloud writes
  `json(conn, status, %{error: "code"})` while the API writes
  `%{error: %{code: "code"}}` — so the api gate's `code:` regex would not match
  a cloud refusal even if the paths lined up.

  Until this file existed, `grep -rln 'known_codes\\|error_code' cloud/lib cloud/test`
  returned NOTHING: every refusal code the control plane emits was unregistered,
  and renaming any of them broke no test. The console JS branches on these
  strings (e.g. `{error:"email_taken"}` -> "That email is already registered"),
  so a silent rename is a silently-dead client branch.

  ## What this gate pins

  A BIDIRECTIONAL equality between the emitted set and `@catalog`:

    * EMITTED -> DECLARED. A code that reaches the wire but is not in
      `@catalog` reds. This is what fires when someone ADDS a refusal code, or
      renames one TO a new name.
    * DECLARED -> EMITTED. A code in `@catalog` that no emitter writes any more
      reds. This is what fires when someone renames a code AWAY (or deletes the
      last emitter) — without this arm a rename would only red once and could be
      "fixed" by appending the new name while the dead one rots in the catalog.

  Either way the correct response is to EDIT `@catalog` deliberately, which is
  the point: the catalog is a review surface, so a wire-visible rename can no
  longer land unnoticed.

  ## How "emitted" is bounded

  Only `cloud/lib/barkpark_cloud/web/**` — the three modules that write response
  bodies (`router.ex`, `auth.ex`, `raw_body_reader.ex`). We extract STATIC
  `error: "..."` atom-key literals.

  Three deliberate scoping choices, each of which a naive grep gets wrong:

    * FULL-LINE `#` COMMENTS ARE STRIPPED FIRST. router.ex documents each
      endpoint's refusals in prose above it (`##   -> 429 {error: "rate_limited"}`).
      Un-stripped, 37 such lines join the scan and `internal_error` — a code
      NOTHING emits — enters the emitted set, reddening the DECLARED->EMITTED
      arm forever on a code that does not exist.
    * WE DO NOT REQUIRE `%{` ON THE SAME LINE. Many envelopes are multi-line
      maps whose `error:` key sits several lines below the `%{`. Requiring the
      brace looked like a tightening and was actually a 44-code BLIND SPOT — it
      dropped exactly the codes this task was filed about
      (`barkpark_required`, `content_binding_required`, `node_ports_exhausted`,
      ...), which is how a gate ends up green over the defect it was built for.
    * WE DO NOT SCAN THE STRING-KEY FORM `%{"error" => ...}`. In cloud/ every
      occurrence of that shape is a PATTERN MATCH on an upstream Barkpark API
      response (`{:ok, 503, %{"error" => %{"code" => "feature_not_configured"}}}`),
      i.e. a code this tree CONSUMES, not one it emits. Scanning it would pin
      the api's vocabulary into the cloud catalog.

  ## The gate's one blind spot, pinned

  `error: "\#{field}_invalid"` (router.ex) builds a code by interpolation, so no
  static scan can enumerate it. We cannot read it — but we CAN pin that the
  blind spot does not grow: `@dynamic_emitters` counts the interpolated sites
  and the test reds if a new one appears.
  """

  @emitter_globs ["lib/barkpark_cloud/web/**/*.ex"]

  # Interpolated `error:` sites a static scan cannot resolve. Currently ONE:
  # `%{error: "\#{field}_invalid", details: details}`. Raising this number means
  # a new un-enumerable refusal code shipped — either make it static, or bump
  # this with a one-line justification.
  @dynamic_emitters 1

  # Every refusal code emitted under cloud/lib/barkpark_cloud/web/**.
  # Enumerated fresh from main; ADD or REMOVE entries alongside the emitter
  # change that motivates them, never to make a red go away.
  @catalog MapSet.new([
                   "accept_failed",
                   "already_attached",
                   "already_attaching",
                   "already_delivering",
                   "already_invited",
                   "already_member",
                   "already_provisioning",
                   "app_token_unsupported",
                   "artifact_conflict",
                   "artifact_digest_mismatch",
                   "artifact_too_large",
                   "bad_action",
                   "bad_signature",
                   "barkpark_not_found",
                   "barkpark_required",
                   "billing_not_configured",
                   "billing_test_mode",
                   "build_in_progress",
                   "cancel_failed",
                   "catalog_unavailable",
                   "checkout_failed",
                   "claim_token_required",
                   "cloudflare_bind_failed",
                   "cloudflare_credential_unreadable",
                   "cloudflare_domain_required",
                   "cloudflare_orphan_cleanup_failed",
                   "cloudflare_zone_missing",
                   "conflict",
                   "content_binding_empty",
                   "content_binding_required",
                   "decrypt_failed",
                   "deliveries_required",
                   "deploy_ability_required",
                   "deploy_not_started",
                   "deployment_not_queued",
                   "domain_not_pointed",
                   "domain_required",
                   "domain_taken",
                   "email_invalid",
                   "email_mismatch",
                   "email_required",
                   "email_taken",
                   "empty_artifact",
                   "enqueue_failed",
                   "env_required",
                   "expired_or_invalid",
                   "feature_not_configured",
                   "forbidden",
                   "github_error",
                   "illegal_transition",
                   "installation_id_required",
                   "installation_not_found",
                   "instance_no_origin",
                   "instance_not_armed",
                   "instance_not_live",
                   "instance_rate_limited",
                   "instance_refused",
                   "instance_unreachable",
                   "invalid",
                   "invalid_bundle_ref",
                   "invalid_code",
                   "invalid_credentials",
                   "invalid_current_password",
                   "invalid_cursor",
                   "invalid_domain",
                   "invalid_name",
                   "invalid_or_expired",
                   "invalid_otp",
                   "invalid_parent",
                   "invalid_payload",
                   "invalid_provider",
                   "invalid_role",
                   "invalid_row",
                   "invalid_settings",
                   "invalid_signature",
                   "invalid_step",
                   "invalid_token",
                   "invalid_url",
                   "invalid_webhook",
                   "invalid_window",
                   "ip_required",
                   "last_owner",
                   "limit_reached",
                   "live_twin",
                   "locked",
                   "method_not_allowed",
                   "name_required",
                   "no_active_subscription",
                   "no_admin_token",
                   "no_archives",
                   "no_bootstrap",
                   "no_build_source",
                   "no_cloudflare_provider",
                   "no_content_binding",
                   "no_installation",
                   "no_pending",
                   "no_pending_email",
                   "no_provider",
                   "no_queued",
                   "no_recipient",
                   "no_subscription",
                   "no_team",
                   "no_webhook",
                   "node_ports_exhausted",
                   "not_a_support",
                   "not_deployable",
                   "not_enabled",
                   "not_enrolled",
                   "not_found",
                   "not_live",
                   "not_prebuilt",
                   "not_promotable",
                   "not_retryable",
                   "not_rollbackable",
                   "nothing_to_update",
                   "null_column",
                   "observed_epoch_required",
                   "password_invalid",
                   "plan_invalid",
                   "portal_failed",
                   "prebuilt_not_enabled",
                   "provider_not_connected",
                   "provider_not_enabled",
                   "provider_unverified",
                   "provision_failed",
                   "provisioning_in_progress",
                   "push_relay_unsupported",
                   "rate_limited",
                   "read_failed",
                   "read_token_mint_failed",
                   "recipient_not_member",
                   "record_failed",
                   "registration_not_removed",
                   "repo_exists",
                   "repo_full_name_required",
                   "repo_not_in_installation",
                   "repo_required",
                   "revoke_refused",
                   "revoke_unsupported",
                   "role_too_high",
                   "rollback_failed",
                   "secret_unreadable",
                   "send_failed",
                   "server_error",
                   "slow_down",
                   "stale_claim",
                   "stale_epoch",
                   "steps_incomplete",
                   "suspended",
                   "taken",
                   "team_id_required",
                   "teardown_failed",
                   "ticket_mint_failed",
                   "unauthorized",
                   "unavailable",
                   "unknown_kind",
                   "unknown_source",
                   "unknown_step",
                   "unknown_template",
                   "upload_failed",
                   "url_required",
                   "validation_failed",
                   "vercel_error",
                   "worker_id_required"
             ])

  defp emitted_codes do
    @emitter_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
      |> Enum.flat_map(fn line ->
        Regex.scan(~r/error:\s*"([a-zA-Z0-9_]+)"/, line)
        |> Enum.map(fn [_, code] -> code end)
      end)
    end)
    |> MapSet.new()
  end

  test "the emitter globs actually match cloud's response-writing modules" do
    files = @emitter_globs |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq()

    assert length(files) >= 3,
           "emitter globs matched #{length(files)} file(s) — did cloud/lib/barkpark_cloud/web/ move? " <>
             "A zero-file scan makes every arm below vacuously green."
  end

  test "the scan is not vacuous — it finds a three-figure vocabulary" do
    count = emitted_codes() |> MapSet.size()

    assert count >= 100,
           "scanned only #{count} error codes under #{inspect(@emitter_globs)}; the control " <>
             "plane emits well over a hundred, so a number this low means the regex or the " <>
             "comment-stripping broke and the gate has gone blind."
  end

  test "every refusal code cloud emits is declared in @catalog" do
    undeclared = emitted_codes() |> MapSet.difference(@catalog) |> Enum.sort()

    assert undeclared == [],
           """
           These refusal codes reach the wire from cloud/lib/barkpark_cloud/web/** but are
           NOT declared in @catalog:

               #{inspect(undeclared)}

           A console/CLI client branches on these exact strings. Add each one to @catalog
           in this file (alphabetically) as part of the change that introduced it.
           """
  end

  test "every code declared in @catalog is still emitted somewhere" do
    orphaned = @catalog |> MapSet.difference(emitted_codes()) |> Enum.sort()

    assert orphaned == [],
           """
           These codes are declared in @catalog but NO emitter under
           cloud/lib/barkpark_cloud/web/** writes them any more:

               #{inspect(orphaned)}

           Usually this means a code was RENAMED. Renaming a wire-visible refusal code is
           a client-breaking change: fix the client branch (console JS / bp CLI) FIRST,
           then remove the dead name here. If the endpoint was deleted, just remove it.
           """
  end

  test "the number of interpolation-built error codes has not grown" do
    dynamic =
      @emitter_globs
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
        |> Enum.filter(&Regex.match?(~r/error:\s*"[^"]*\#\{/, &1))
        |> Enum.map(&{path, String.trim(&1)})
      end)

    assert length(dynamic) == @dynamic_emitters,
           """
           Found #{length(dynamic)} interpolation-built `error:` site(s), expected
           #{@dynamic_emitters}. These codes are INVISIBLE to the catalog arms above, so
           each new one is a refusal code with no registry entry and no rename safety:

           #{Enum.map_join(dynamic, "\n", fn {p, l} -> "    #{p}: #{l}" end)}

           Prefer a static literal. If interpolation is genuinely required, bump
           @dynamic_emitters with a one-line justification.
           """
  end
end
