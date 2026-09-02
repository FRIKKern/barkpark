defmodule BarkparkWeb.FlatAnalyticsGrantEnforcementTest do
  @moduledoc """
  task-633d94b5a598c0f7 — the FLAT `GET /v1/data/analytics/:dataset` must honour
  the caller's grant ladder, exactly as the flat `query`/`counts` reads already
  do.

  ## What #14445 closed, and what it did not

  #14445 added `|> maybe_scope_to_grants(opts)` to `document_stats/2`,
  `total_documents/2` and `recent_activity/2` — the three aggregates
  `AnalyticsController.index/2` calls — and pinned the SCOPED route
  (`/w/:ws/p/:proj/v1/data/analytics/:ds`) with
  `test/barkpark_web/integration/analytics_grant_narrowing_test.exs`.

  Those three lines were INERT on the FLAT route, and not because the key was
  unset: it was UNSETTABLE. `:grant_scoped` reaches the opts through exactly one
  path — `AssignGrantScope` assigns `:grant_scoped_read`, `ScopeHelpers` folds it
  into `scope_opts/1` — and `AssignGrantScope` is mounted ONLY by the
  `:api_grant_read` pipeline, which the flat token-required scope
  (`[:api, :require_token]`, holding listen/export/analytics/history/revision)
  never ran. `maybe_scope_to_grants/2` DEFAULTS the flag to false, so absence
  meant "do not narrow", not "narrow to nothing".

  ## Why the flat door is the WIDER one

  The scoped route's admitting principal is an INTERSECTION: `RequireToken` wants
  a Bearer and `ResolveWorkspace`'s grant arm wants a signed-in non-member USER,
  so a grantee needs her api token AND her login cookie. The flat route needs no
  such coincidence — `AssignGrantScope` resolves the user from the token's OWN
  `owner_user_id` via `ResolveTokenOwner`. One header. Every caller who can reach
  the narrowed flat `query` read could reach the UN-narrowed flat `analytics`
  read with the identical credential.

  `recent_activity/2` is the sharp end: its select carries `doc_id`, so the leak
  was identity and existence across a grant boundary, not merely volume.

  ## Shape of this suite

  Non-vacuity first (`describe "the subject exists"`): the grant, the OWNED token
  and the NON-membership are each asserted with a BOUND BOOLEAN and a message —
  never `assert %S{} = x, "msg"`, whose message ExUnit discards because the match
  raises `MatchError` before `assert/2` ever runs.

  Then the narrowing arms, and then the over-reach guards: a member, an unowned
  service token and an owned NON-grantee token must all still read the FULL
  census (grants only ADD access), and an anonymous caller must still be 401.
  The member arm doubles as the colliding-fixture proof — the out-of-grant row
  really is visible on this route, so the grantee's `refute`s refute something
  that genuinely exists.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccessFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  setup do
    {ws, project} = ensure_default_scope!()

    # A dataset and two type names unique to this run: the shared test database
    # is written by every other agent's suite, and a fixed dataset string would
    # let a committed neighbour row move `total_documents`.
    n = System.unique_integer([:positive])
    ds = "flatanalytics#{n}"
    in_type = "grantedMemo#{n}"
    out_type = "ledgerSecret#{n}"

    {:ok, _} = create_document_in!(ws, project, in_type, %{"title" => "in-scope"}, ds)
    {:ok, _} = create_document_in!(ws, project, out_type, %{"title" => "out-of-scope"}, ds)

    {:ok, ws: ws, project: project, ds: ds, in_type: in_type, out_type: out_type}
  end

  # ── principals ────────────────────────────────────────────────────────────

  defp register_user do
    email = "flat-analytics-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  # An api_token inserted DIRECTLY (never `Auth.create_token/5`, which would also
  # create a membership): `owner_user_id` set, `workspace_id` NULL, so the caller
  # is an owned token that is NOT a member of anything and whose flat read falls
  # to `AssignDefaultScope`'s Default workspace.
  defp insert_token!(attrs) do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(
        Map.merge(
          %{
            token_hash: ApiToken.hash_token(raw),
            label: "flat-analytics",
            dataset: "test",
            permissions: ["read"]
          },
          attrs
        )
      )
      |> Repo.insert()

    {raw, token}
  end

  defp owned_token(user), do: insert_token!(%{owner_user_id: user.id})
  defp unowned_token, do: insert_token!(%{})

  # A genuine MEMBER of the Default workspace — `Auth.create_token/5` inserts the
  # membership alongside the token.
  defp member_token!(ws) do
    raw = "flat-analytics-member-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "flat-analytics-member", "test", ["read"], ws.id)
    raw
  end

  defp grantee(ws, project, ds, type) do
    user = register_user()
    {raw, token} = owned_token(user)

    grant =
      bind_grant!(ws, user, %{
        project_id: project.id,
        dataset: ds,
        type: type,
        capabilities: ["read"]
      })

    %{user: user, raw: raw, token: token, grant: grant}
  end

  # ── HTTP ──────────────────────────────────────────────────────────────────

  defp analytics(conn, raw, ds) do
    conn
    |> put_req_header("authorization", "Bearer #{raw}")
    |> get("/v1/data/analytics/#{ds}")
  end

  defp types_in(body), do: body["types"] |> Enum.map(& &1["type"]) |> Enum.sort()

  # ── 0. NON-VACUITY — the scenario is what it claims to be ─────────────────

  describe "the subject exists" do
    test "the grantee is an OWNED token, a NON-member of Default, holding an ACTIVE grant",
         ctx do
      g = grantee(ctx.ws, ctx.project, ctx.ds, ctx.in_type)

      owned? = is_binary(g.token.owner_user_id) and g.token.owner_user_id == g.user.id

      assert owned?,
             "PRECONDITION: the caller's api_token must resolve to a user through " <>
               "owner_user_id — ResolveTokenOwner assigns nothing without it, and " <>
               "AssignGrantScope would then be a no-op for a reason unrelated to the fix"

      token_is_member? = TenancyAuth.authorize(g.token, ctx.ws.id, :read) == :ok

      refute token_is_member?,
             "PRECONDITION: the grantee's TOKEN must not be a member of Default — " <>
               "AssignGrantScope no-ops for members, so a membership here would make " <>
               "every narrowing assertion below vacuous"

      user_is_member? = TenancyAuth.authorize(g.user, ctx.ws.id, :read) == :ok

      refute user_is_member?,
             "PRECONDITION: the grantee USER must not be a member of Default — same " <>
               "no-op arm, same vacuity"

      grant_active? =
        is_nil(g.grant.revoked_at) and is_nil(g.grant.expires_at) and
          not is_nil(g.grant.claimed_at) and g.grant.workspace_id == ctx.ws.id and
          "read" in g.grant.capabilities

      assert grant_active?,
             "PRECONDITION: the grant must be claimed, unrevoked, unexpired, bound to " <>
               "the Default workspace and read-capable — CallerContext.from_user/2 " <>
               "filters the others in-query and the fold would never fire"
    end

    test "the grantee reaches AnalyticsController at all over the FLAT route", ctx do
      g = grantee(ctx.ws, ctx.project, ctx.ds, ctx.in_type)
      conn = analytics(build_conn(), g.raw, ctx.ds)

      assert conn.status == 200,
             "PRECONDITION FAILED: the owned-token grantee did not reach the flat " <>
               "analytics route (#{conn.status} #{conn.resp_body}). Every assertion " <>
               "below would then be vacuous."
    end
  end

  # ── 1. THE LEAK — bearer only, no cookie ──────────────────────────────────

  describe "owned-token grantee on the FLAT route — narrowed to the grant ladder" do
    test "document_stats names no type outside the grant ladder", ctx do
      g = grantee(ctx.ws, ctx.project, ctx.ds, ctx.in_type)
      body = build_conn() |> analytics(g.raw, ctx.ds) |> json_response(200)

      assert ctx.in_type in types_in(body),
             "the grant's OWN type must still be counted — narrowing must not blank " <>
               "the grantee's analytics"

      refute ctx.out_type in types_in(body),
             "LEAK: the flat analytics route named a document type outside the " <>
               "caller's grant, with its published/draft counts — a bearer-only read " <>
               "of the Default workspace census"
    end

    test "total_documents counts no row outside the grant ladder", ctx do
      g = grantee(ctx.ws, ctx.project, ctx.ds, ctx.in_type)
      body = build_conn() |> analytics(g.raw, ctx.ds) |> json_response(200)

      assert body["total_documents"] == 1,
             "LEAK: total_documents disclosed the VOLUME of the Default workspace " <>
               "(expected 1, the grantee's own row; got #{body["total_documents"]})"
    end

    test "recent_activity surfaces no doc_id outside the grant ladder", ctx do
      g = grantee(ctx.ws, ctx.project, ctx.ds, ctx.in_type)
      body = build_conn() |> analytics(g.raw, ctx.ds) |> json_response(200)

      leaked = Enum.filter(body["recent_activity"], &(&1["type"] == ctx.out_type))

      assert leaked == [],
             "LEAK: recent_activity surfaced the doc_ids of documents outside the " <>
               "caller's grant: #{inspect(Enum.map(leaked, & &1["doc_id"]))}"
    end

    test "fail-closed: a grant that covers the workspace but NOT this dataset yields no rows",
         ctx do
      # Same workspace, a ladder pinned to a dataset that does not exist here. A
      # fail-OPEN read would return the whole census; the fold must return none of it.
      g = grantee(ctx.ws, ctx.project, "flatanalytics-elsewhere", ctx.in_type)
      body = build_conn() |> analytics(g.raw, ctx.ds) |> json_response(200)

      assert body["total_documents"] == 0,
             "FAIL-OPEN: a grant whose ladder misses this dataset still counted rows"

      assert types_in(body) == [],
             "FAIL-OPEN: a grant whose ladder misses this dataset still named types"
    end
  end

  # ── 2. OVER-REACH GUARDS — everyone else is byte-identical ────────────────

  describe "grants only ADD access — every other principal is unchanged" do
    test "a Default MEMBER token still reads the full census", ctx do
      raw = member_token!(ctx.ws)
      body = build_conn() |> analytics(raw, ctx.ds) |> json_response(200)

      # Also the colliding-fixture proof: the out-of-grant row IS visible on this
      # route, so the grantee refutes above refute something that exists.
      assert ctx.in_type in types_in(body)

      assert ctx.out_type in types_in(body),
             "OVER-REACH: the clamp hid a type from a legitimate member"

      assert body["total_documents"] == 2

      assert Enum.any?(body["recent_activity"], &(&1["type"] == ctx.out_type)),
             "OVER-REACH: the clamp hid a member's own mutation events"
    end

    test "an unowned SERVICE token reads the full census, as before", ctx do
      {raw, _} = unowned_token()
      body = build_conn() |> analytics(raw, ctx.ds) |> json_response(200)

      assert ctx.out_type in types_in(body),
             "OVER-REACH: an unowned token resolves no user, so AssignGrantScope " <>
               "must no-op and the back-compat Default read must be untouched"

      assert body["total_documents"] == 2
    end

    test "an OWNED token whose owner holds NO covering grant is not narrowed", ctx do
      {raw, _} = owned_token(register_user())
      body = build_conn() |> analytics(raw, ctx.ds) |> json_response(200)

      assert ctx.out_type in types_in(body),
             "OVER-REACH: an owned token with no grant must keep its back-compat " <>
               "Default read"

      assert body["total_documents"] == 2
    end

    test "an anonymous caller is still 401 — the route stays token-required", ctx do
      conn = get(build_conn(), "/v1/data/analytics/#{ctx.ds}")

      assert conn.status == 401,
             "the grant overlay must layer AFTER :require_token — an anonymous " <>
               "caller must never reach AnalyticsController (got #{conn.status})"
    end
  end
end
