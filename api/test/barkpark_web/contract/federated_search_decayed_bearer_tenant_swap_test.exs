defmodule BarkparkWeb.Contract.FederatedSearchDecayedBearerTenantSwapTest do
  @moduledoc """
  TENANT SWAP BY CREDENTIAL DECAY on the FLAT `GET /v1/search/:dataset`
  (`FederatedSearchController`) — task-f7230d4a500fffb6.

  THE DEFECT, as measured before the fix:

      REVOKED workspace-B bearer -> 200, ["swap-default-row"]   <- DEFAULT's row
      ANON    (no bearer)        -> 200, ["swap-default-row"]

      conn assigns, which name the mechanism directly:
        revoked B -> current_workspace.slug == "default", api_token == nil
        anon      -> current_workspace.slug == "default", api_token == nil

  MECHANISM. The flat route rides BARE `:api` (the "Federated discovery" scope
  in `BarkparkWeb.Router`), which runs
  `OptionalToken -> DeriveWorkspaceFromToken -> AssignDefaultScope`.
  `Auth.verify_token/1` folds revoked/expired/unknown into one
  `{:error, :unauthorized}`; `OptionalToken`'s DEFAULT fail-soft arm swallows
  it, so `:api_token` is never assigned, `DeriveWorkspaceFromToken` (which
  requires `%ApiToken{}` in assigns) no-ops, and `AssignDefaultScope` stamps
  the seeded **Default** workspace. The caller believes it read tenant B and
  silently read Default.

  WHY THE SHIPPED SIBLING FIX DOES NOT REACH HERE. PR #14318 mounts
  `OptionalToken, strict_on_presented: true` on `:api_grant_read`, which layers
  only on the flat `/v1/data` READ scope. `/v1/search/:dataset` never touches
  that pipeline. The remedy here is the SAME plug with the SAME opt, mounted on
  a thin `:api_strict_bearer` pipeline layered onto the one-route Federated
  discovery scope.

  ## SEVERITY — MEASURED, NOT ASSUMED: INTEGRITY / MISLEAD, **NOT**
  ## CONFIDENTIALITY

  The wrong-tenant target is the seeded Default workspace, whose PUBLISHED,
  PUBLIC-visibility rows are anonymous-readable by design. The decayed bearer
  is byte-for-byte equivalent to sending no `Authorization` header at all — it
  gains NOTHING over dropping the header. `severity: the decayed bearer reads
  exactly the anonymous corpus and not one row more` below proves that by
  seeding a PRIVATE-visibility type in Default and showing neither the revoked
  bearer nor the anonymous caller can see it.

  The harm is that a caller, cache, instrument or site build that TRUSTS the
  credential it presented will attribute Default's corpus to workspace B.

  ## THE CAVEAT THAT STOPS THIS FILE PROVING TOO MUCH

  A **VALID** workspace-B bearer ALSO returns `[]` on this route, for a
  SEPARATE, unrelated reason: `DeriveWorkspaceFromToken` sets the workspace but
  deliberately NOT the project, and `Content.search_documents/3` returns zero
  for a workspace-ONLY scope (while `Content.list_documents/2` honours it).
  That is a THIRD defect, not claimed or fixed here.

  So "B's rows are absent" is TRUE IN A CASE THAT IS NOT THE DEFECT, and no
  assertion in this file may rest on it. Every RED assertion below is stated as
  **DEFAULT's rows are PRESENT** — a positive, which an empty/mis-scoped
  fixture cannot satisfy vacuously.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}

  @dataset "production"
  @public_type "swappost"
  @private_type "swapsecret"
  @probe "aardvarkswap"
  @url "/v1/search/#{@dataset}?q=#{@probe}&surfaces=documents"

  setup do
    # ── DEFAULT scope: the wrong tenant the decayed bearer gets swapped into ──
    {default_ws, default_proj} = ensure_default_scope!()
    default_scope = [workspace_id: default_ws.id, project_id: default_proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @public_type, "title" => "SwapPost", "visibility" => "public", "fields" => []},
        @dataset,
        default_scope
      )

    {:ok, _} =
      Content.create_document(
        @public_type,
        %{"_id" => "swap-default-row", "title" => "#{@probe} Default Tenant Row"},
        @dataset,
        default_scope
      )

    {:ok, _} = Content.publish_document("swap-default-row", @public_type, @dataset, default_scope)

    # A PRIVATE-visibility row in Default. The severity measurement hangs on
    # this: if the decayed bearer could see it, the finding would be
    # confidentiality rather than integrity.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @private_type,
          "title" => "SwapSecret",
          "visibility" => "private",
          "fields" => []
        },
        @dataset,
        default_scope
      )

    {:ok, _} =
      Content.create_document(
        @private_type,
        %{"_id" => "swap-default-secret", "title" => "#{@probe} Default Tenant Secret"},
        @dataset,
        default_scope
      )

    {:ok, _} =
      Content.publish_document("swap-default-secret", @private_type, @dataset, default_scope)

    # ── WORKSPACE B: a real, separate tenant with its own row and two tokens ──
    ws_b = create_workspace!("swapb")
    proj_b = create_project!(ws_b, "swapb")
    b_scope = [workspace_id: ws_b.id, project_id: proj_b.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @public_type, "title" => "SwapPost", "visibility" => "public", "fields" => []},
        @dataset,
        b_scope
      )

    {:ok, _} =
      Content.create_document(
        @public_type,
        %{"_id" => "swap-b-row", "title" => "#{@probe} Workspace B Row"},
        @dataset,
        b_scope
      )

    {:ok, _} = Content.publish_document("swap-b-row", @public_type, @dataset, b_scope)

    live_raw = "swap-live-#{System.unique_integer([:positive])}"
    dead_raw = "swap-dead-#{System.unique_integer([:positive])}"

    {:ok, _live} = Auth.create_token(live_raw, "swap-live", @dataset, ["read"], ws_b.id)
    {:ok, dead} = Auth.create_token(dead_raw, "swap-dead", @dataset, ["read"], ws_b.id)
    {:ok, _} = Auth.revoke_token(dead)

    {:ok,
     default_ws: default_ws, ws_b: ws_b, proj_b: proj_b, live: live_raw, dead: dead_raw}
  end

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp ids(body), do: Enum.map(get_in(body, ["results", "documents", "hits"]) || [], & &1["_id"])

  # ── FIXTURE CONTROL ────────────────────────────────────────────────────────
  # Runs FIRST. Every assertion in this file is meaningless if the revocation
  # did not take, or if the live twin is not actually live.

  describe "fixture control (a null result here cannot be a fixture bug)" do
    test "the revoked token really fails to verify and its live twin really verifies", ctx do
      assert {:error, :unauthorized} = Auth.verify_token(ctx.dead)
      assert {:ok, _} = Auth.verify_token(ctx.live)
    end

    test "the Default row IS reachable on this route — the RED's positive is real", %{conn: conn} do
      body = conn |> get(@url) |> json_response(200)

      assert "swap-default-row" in ids(body),
             "the anonymous baseline does not see Default's row, so asserting the " <>
               "revoked bearer sees it would prove nothing. Got: #{inspect(ids(body))}"
    end
  end

  # ── THE DEFECT ─────────────────────────────────────────────────────────────

  describe "revoked workspace-B bearer on GET /v1/search/:dataset" do
    # THE RED. Before the fix this passed at 200 carrying Default's row; after
    # the fix the request is refused. Stated as a POSITIVE about DEFAULT's rows
    # — never as "B's rows are absent", which is also true for a VALID B bearer
    # (see the moduledoc caveat) and would therefore prove nothing.
    test "is refused, and does NOT get served Default's rows", ctx do
      resp = ctx.conn |> bearer(ctx.dead) |> get(@url)

      # CONCRETE OUTCOME, not a bare absence: the exact status AND the error
      # envelope. A 500, a 404, or an empty 200 would all be "not-RED" while
      # being the wrong reason.
      assert resp.status == 401,
             "a presented-but-unverifiable bearer must be refused on this route; got " <>
               "#{resp.status} with body #{resp.resp_body}"

      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "unauthorized"

      # And the refusal must actually WITHHOLD the wrong tenant's corpus — the
      # whole point. If Default's row appeared beside a 401 the fix would be
      # cosmetic.
      refute resp.resp_body =~ "swap-default-row",
             "the refusal still leaked Default's row into the body"
    end

    # THE MECHANISM, asserted on the conn rather than through the retriever —
    # the one assertion here that does not depend on the separate
    # search-scoping defect at all.
    #
    # HONEST ABOUT THE SHAPE OF THE FIX, because the alternative reading is
    # tempting and wrong: the remedy REFUSES the request, it does not un-stamp
    # the scope. `:api_strict_bearer` is layered AFTER `:api`, so
    # `AssignDefaultScope` has already written `current_workspace = default`
    # by the time the strict gate runs. That assign survives on the conn — but
    # on a HALTED conn that never reaches `FederatedSearchController`, so it is
    # inert. Pinned explicitly so a future reader does not "fix" a stale assign
    # that is by construction unreachable, and does not mistake this file for
    # claiming the derivation was corrected.
    test "the pipeline halts before the controller — the stamped Default scope is inert", ctx do
      resp = ctx.conn |> bearer(ctx.dead) |> get(@url)

      assert resp.halted, "the strict bearer gate must halt the pipeline"
      assert resp.status == 401

      # Pre-fix this conn carried api_token == nil AND served a body. The token
      # is still unassigned (the bearer really is unverifiable) — what changed
      # is that the request is now refused instead of answered.
      refute resp.assigns[:api_token],
             "a revoked bearer must never resolve to an :api_token"

      # The controller never ran: no search envelope was rendered.
      body = Jason.decode!(resp.resp_body)

      refute Map.has_key?(body, "results"),
             "FederatedSearchController rendered a result envelope despite the halt: " <>
               resp.resp_body

      # The upstream stamp is still on the conn, and that is EXPECTED — see the
      # comment above. Asserting it keeps the ordering fact on the record.
      assert match?(%{slug: "default"}, resp.assigns[:current_workspace]),
             "`:api` runs AssignDefaultScope before this overlay, so the stale " <>
               "Default stamp is expected to be present-but-unreachable. If this " <>
               "ever fails, the pipeline ORDER changed — re-read the fix."
    end
  end

  # ── CONTROLS: both must stay exactly as they are today ─────────────────────

  describe "controls (unchanged by the fix)" do
    test "ANONYMOUS (no bearer) still reads Default's published row at 200", %{conn: conn} do
      body = conn |> get(@url) |> json_response(200)

      # The anonymous public read is a SUPPORTED PRODUCT SURFACE. This fix is
      # emphatically not a blanket 401, and this control is what says so.
      assert "swap-default-row" in ids(body),
             "the anonymous surface regressed; got #{inspect(ids(body))}"
    end

    test "a VALID workspace-B bearer is NOT refused (200, as today)", ctx do
      resp = ctx.conn |> bearer(ctx.live) |> get(@url)

      # Deliberately asserts only the STATUS and the tenant binding. The hit
      # list is NOT asserted: a valid B bearer returns [] here because of the
      # separate search_documents workspace-only-scope defect described in the
      # moduledoc, which this row does not own or fix.
      assert resp.status == 200,
             "a valid bearer must pass the strict gate untouched; got #{resp.status}"

      assert resp.assigns[:api_token], "the valid bearer must still be assigned"

      assert resp.assigns[:current_workspace].id == ctx.ws_b.id,
             "the valid bearer must still derive workspace B, not Default"
    end

    test "a non-Bearer scheme is untouched (not refused)", %{conn: conn} do
      resp = conn |> put_req_header("authorization", "Preview something") |> get(@url)

      assert resp.status == 200,
             "only a presented BEARER may be refused; a non-Bearer scheme must fall " <>
               "through to the anonymous surface. Got #{resp.status}"
    end
  end

  # ── SEVERITY MEASUREMENT ───────────────────────────────────────────────────

  describe "severity: the decayed bearer reads exactly the anonymous corpus and not one row more" do
    test "a PRIVATE-visibility Default row is invisible to BOTH anonymous and the revoked bearer",
         ctx do
      # ANONYMOUS: the private row must not appear.
      anon_body = ctx.conn |> get(@url) |> json_response(200)

      assert "swap-default-row" in ids(anon_body),
             "positive control: the public Default row must be present, otherwise the " <>
               "refute below is vacuous. Got #{inspect(ids(anon_body))}"

      refute "swap-default-secret" in ids(anon_body),
             "a private-visibility row reached an anonymous caller — that would be a " <>
               "DIFFERENT and much worse finding than this row claims"

      # REVOKED BEARER: post-fix it is refused outright, so it can see strictly
      # LESS than anonymous. Either way it never sees the private row — which
      # is the measurement that entitles the integrity-not-confidentiality
      # verdict, and it holds on both sides of the fix.
      dead_resp = ctx.conn |> bearer(ctx.dead) |> get(@url)

      refute dead_resp.resp_body =~ "swap-default-secret",
             "the decayed bearer saw a private-visibility Default row — this finding " <>
               "would then be CONFIDENTIALITY, not integrity/mislead"
    end
  end
end
