defmodule Barkpark.Content.Scope do
  @moduledoc """
  The single, centralized workspace/project query-scoping helper for the
  hard tenant boundary (Wave 1 retrofit).

  Every content read that must respect the tenant boundary pipes its base
  query through `scope_to_workspace/3`, which appends
  `where: x.workspace_id == ^workspace_id` (and `x.project_id == ^project_id`
  when a project is given). Centralizing the clause here is what keeps the
  filter from being silently forgotten on a new query site.

  This scoping is applied IN ADDITION TO the existing `dataset`-string filter
  — `dataset` stays the leaf discriminator in Wave 1; this adds the
  workspace/project envelope around it.

  ## Nil fails CLOSED (barkpark-s6t1)

  A `nil` `workspace_id` now FAILS CLOSED: the query is forced to return NO
  rows (`where: false`). Previously a `nil` workspace_id returned the query
  *untouched* — which meant any read site that accidentally dropped its scope
  resolved over EVERY tenant's rows (fail-OPEN). That was the common root
  behind multiple cross-workspace read leaks: a single forgotten `:workspace_id`
  silently widened a tenant-scoped read to all tenants.

  Production traffic is unaffected: scoped routes resolve a real workspace via
  `ResolveWorkspace` / `ResolveProject`, and the flat back-compat routes carry
  the seeded Default workspace via `AssignDefaultScope`. Both pass a binary
  workspace_id, so they take the scoped clause, not the fail-closed clause.

  ## Explicit global opt-in

  The genuinely global / cross-tenant reads (internal workers that resolve
  tenancy another way, studio LiveViews that are not yet path-scoped, plugin
  lifecycle, mix tasks) must OPT IN explicitly via `scope_to_workspace_global/1`,
  which returns the query untouched. This makes "I want all tenants' rows" a
  deliberate, greppable decision instead of the silent default. Sites that
  *should* scope but currently lack a resolved workspace use
  `scope_to_workspace_global/1` as a documented back-compat bridge — the
  difference from the old default is that the choice is now explicit at the
  call site, so a NEW tenant-scoped read that forgets its scope fails closed
  rather than leaking.
  """

  import Ecto.Query

  alias Barkpark.Access
  alias Barkpark.Access.Grant
  alias Barkpark.Content.CallerContext

  @doc """
  Row/ownership ACL (Phase 4, core-auth) — restrict a query to the rows a
  caller may read on an `owner_scoped: true` type.

  Applied IN ADDITION TO `scope_to_workspace_or_global/3`, by the read sites in
  `Barkpark.Content.Query` (gated on `Content.owner_scoped?/3`). The clause
  binds against the first named binding `[x]`, so it composes with the existing
  `Document` query.

  Decision table (the security contract — see Phase 4 INVARIANTS):

    * `is_admin` → query UNTOUCHED. Admins see all (admin api-token, or
      owner/admin user) — the intentional, explicit "see all" path.
    * `:api_token` principal → query UNTOUCHED. A token is a trusted backend
      credential; the INVARIANT is "admin/api-token sees all".
    * non-admin `:user` with a `user_id` → rows where `owner_id == user_id` OR
      `owner_id IS NULL` (their own rows plus the shared unowned base).
    * `:anonymous` (or a `:user` with no resolved id) → rows where
      `owner_id IS NULL` only. A hostile/unauthenticated reader can NEVER see an
      owned row — closing the "user A reads user B's docs" hole on the public
      read path.
    * `nil` caller_context → FAILS CLOSED (LOW-12): rows where `owner_id IS
      NULL` only, identical to `:anonymous`. Previously a nil caller returned
      the query UNTOUCHED (fail-OPEN) — mirroring `scope_to_workspace_or_global`'s
      nil→global contract — which meant any owner_scoped read that dropped its
      `caller_context` (e.g. the public papers-backlinks graph path that threads
      no context) silently widened to EVERY owner's rows. An absent caller is
      NOT trusted; a trusted internal caller must pass an admin / api_token
      `CallerContext` to see owned rows (the explicit bypass above), the same
      "opt in to global is deliberate" posture `scope_to_workspace/3` took for
      the tenant boundary.
  """
  @spec scope_to_owner(Ecto.Queryable.t(), CallerContext.t() | nil) :: Ecto.Queryable.t()
  def scope_to_owner(query, %CallerContext{is_admin: true}), do: query
  def scope_to_owner(query, %CallerContext{principal_type: :api_token}), do: query

  def scope_to_owner(query, %CallerContext{principal_type: :user, user_id: uid})
      when is_binary(uid) do
    where(query, [x], x.owner_id == ^uid or is_nil(x.owner_id))
  end

  # Fail CLOSED: an absent caller_context (nil) is treated like :anonymous —
  # unowned rows only, NEVER another owner's rows.
  def scope_to_owner(query, nil), do: where(query, [x], is_nil(x.owner_id))

  def scope_to_owner(query, %CallerContext{}),
    do: where(query, [x], is_nil(x.owner_id))

  @doc """
  Add the workspace (and optionally project) WHERE clause to an Ecto query.

  Binds against the FIRST named binding in the query (the `[x]` position), so
  it composes with `Document`, `SchemaDefinition`, and any other queryable that
  carries `workspace_id` / `project_id` columns.

    * `workspace_id == nil` → query forced to NO rows (`where: false`) —
      fail-CLOSED (barkpark-s6t1). Use `scope_to_workspace_global/1` for a
      deliberate cross-tenant read.
    * `workspace_id` set, `project_id == nil` → workspace-only scope.
    * both set → workspace + project scope.
  """
  @spec scope_to_workspace(Ecto.Queryable.t(), binary() | nil, binary() | nil) ::
          Ecto.Query.t()
  def scope_to_workspace(query, workspace_id, project_id \\ nil)

  # Fail CLOSED: a nil workspace_id yields zero rows rather than every tenant's
  # rows. `where: false` is the canonical empty-result clause and composes with
  # any further WHERE the caller adds.
  def scope_to_workspace(query, nil, _project_id), do: where(query, false)

  # ── The empty-scope sentinel (task-3e2a70930c6df723) ────────────────────────
  #
  # `:shared_only` is what `BarkparkWeb.ScopeHelpers.scope_opts/1` emits when a
  # REQUEST resolved no workspace. It means "the shared/global layer" —
  # `workspace_id IS NULL` — and never "every tenant".
  #
  # ADDITIVE, deliberately: `nil` keeps its existing meaning in every arm below,
  # so internal callers that pass nil (or omit the key) are untouched. Only a
  # request can produce this value, which is what separates "no tenant resolved"
  # from "an internal caller wants everything" — two intents that an absent key
  # could not distinguish, with the permissive one winning for both.
  #
  # ── THE SIGN-FLIP: "missing sentinel" HAS NO FIXED DIRECTION ────────────────
  #
  # A reader who assumes "absent `:workspace_id` = wider" is backwards half the
  # time, and so is the reader who assumes it is narrower. The direction is a
  # property of WHICH HELPER the consumer lands in, not of the value:
  #
  #   scope_to_workspace_or_global(q, nil, _)          -> query UNTOUCHED
  #                                                       = EVERY tenant  (WIDER)
  #   scope_to_workspace_or_global(q, :shared_only, _) -> delegates below
  #                                                       = workspace_id IS NULL
  #                                                         (NARROWER than nil)
  #   scope_to_workspace(q, nil, _)                    -> where(q, false)
  #                                                       = ZERO rows   (NARROWER)
  #   scope_to_workspace(q, :shared_only, _)           -> workspace_id IS NULL
  #                                                       (WIDER than nil)
  #
  # So an absent workspace_id WIDENS through `scope_to_workspace_or_global/3` and
  # NARROWS through `scope_to_workspace/3`, and adding the sentinel moves the two
  # helpers in OPPOSITE directions. Trace the helper your consumer actually
  # reaches — never assume the sign from the sentinel.
  #
  # This is not hypothetical. `Content.Query.base_query/4` reaches the PERMISSIVE
  # `scope_to_workspace_or_global/3`, so `Content.list_documents` /
  # `get_document` are on the WIDENING side; a comment in
  # `Barkpark.Plugins.Tickets.Thread.operator_scope/1` named the fail-CLOSED
  # `scope_to_workspace/3` for that same read and thereby inverted the sign of
  # exactly this question (corrected in PR #14009). The transport flips it too:
  # `BarkparkWeb.ScopeHelpers.scope_opts/1` emits `:shared_only` for a
  # `%Plug.Conn{}` and OMITS the key for a socket, so the same read is narrow
  # over HTTP and wide over a LiveView mount that resolved no workspace.
  def scope_to_workspace(query, :shared_only, _project_id),
    do: where(query, [x], is_nil(x.workspace_id))

  def scope_to_workspace(query, workspace_id, nil) when is_binary(workspace_id) do
    where(query, [x], x.workspace_id == ^workspace_id)
  end

  def scope_to_workspace(query, workspace_id, project_id)
      when is_binary(workspace_id) and is_binary(project_id) do
    where(query, [x], x.workspace_id == ^workspace_id and x.project_id == ^project_id)
  end

  @doc """
  EXPLICIT cross-tenant / unscoped read — returns the query untouched.

  This is the deliberate opt-in for the legitimately global callers documented
  in this module: internal workers and lifecycle that resolve tenancy by other
  means, studio surfaces not yet path-scoped, and mix tasks / single-tenant
  back-compat paths. Reach for it ONLY when an unscoped read is intended; an
  ordinary tenant-scoped read must pass a real `workspace_id` to
  `scope_to_workspace/3`, which now fails closed on nil.
  """
  @spec scope_to_workspace_global(Ecto.Queryable.t()) :: Ecto.Queryable.t()
  def scope_to_workspace_global(query), do: query

  @doc """
  Scope to `workspace_id` when present, else fall back to an EXPLICIT global
  read. The back-compat bridge for callers that pass scope through `opts`:
  a real workspace_id scopes the read; an absent one is a deliberate global
  read (legacy single-tenant / internal-resolved), NOT an accidental leak.

  Distinct from `scope_to_workspace/3` precisely because the global fallback is
  named and intentional here — a brand-new tenant-scoped read site that wants
  fail-closed-on-nil should call `scope_to_workspace/3` directly.
  """
  @spec scope_to_workspace_or_global(Ecto.Queryable.t(), binary() | nil, binary() | nil) ::
          Ecto.Queryable.t()
  # @canonical capability:tenancy-scope aka:scope_workspace,workspace_scope,scope_to_workspace doc:docs/contracts/tenancy.md
  def scope_to_workspace_or_global(query, nil, _project_id),
    do: scope_to_workspace_global(query)

  # NO `:shared_only` clause here, deliberately. This function's catch-all
  # below delegates to `scope_to_workspace/3`, which owns the sentinel arm —
  # so an explicit clause here is DEAD CODE. It was written, and removed after
  # a mutation could not make it fail: a clause no mutation can red is
  # decoration, not coverage.
  def scope_to_workspace_or_global(query, workspace_id, project_id),
    do: scope_to_workspace(query, workspace_id, project_id)

  @doc """
  Scope to a workspace's own rows PLUS shared global (nil-workspace) rows.

  Unlike `scope_to_workspace/3` (fail-closed, workspace-only) this INCLUDES
  rows with a NULL `workspace_id` — the deliberately-shared base layer. The
  Studio desk's schema list uses it so a workspace surfaces its own content
  types AND the shared/plugin schemas, without seeing OTHER workspaces' types.
  Project is intentionally not narrowed (a workspace's catalog spans its
  projects). A nil `workspace_id` still falls back to the all-tenants global
  read, matching `scope_to_workspace_or_global/3`.
  """
  @spec scope_to_workspace_including_global(Ecto.Queryable.t(), binary() | nil, binary() | nil) ::
          Ecto.Queryable.t()
  def scope_to_workspace_including_global(query, nil, _project_id),
    do: scope_to_workspace_global(query)

  # See the sentinel note above scope_to_workspace/3.
  def scope_to_workspace_including_global(query, :shared_only, _project_id),
    do: where(query, [x], is_nil(x.workspace_id))

  def scope_to_workspace_including_global(query, workspace_id, _project_id)
      when is_binary(workspace_id) do
    where(query, [x], x.workspace_id == ^workspace_id or is_nil(x.workspace_id))
  end

  @doc """
  Grant row-narrowing (airdrop-grants ag-enforcement, Layer 2 — the
  containment-critical clause). Restrict a query to the UNION of the caller's
  ACTIVE grants' scope ladders WITHIN `workspace_id`.

  Applied ONLY on a GRANT-DERIVED read — the `ResolveWorkspace` read gate admits
  a grant-only caller, flags `assigns[:grant_scoped_read]`, and `ScopeHelpers`
  threads `grant_scoped: true` into the `Content.Query` opts. A member NEVER
  carries the flag, so this clause never touches a member's read (grants only
  ADD access; members stay byte-identical).

  Only grants that CONFER READ contribute their ladder to the read-union: a
  grant must both cover `workspace_id` AND hold the `"read"` capability. A
  workspace-covering write-only grant (`["write"]`, no read) is EXCLUDED — write
  ⊅ read, so it can never widen a read (matching the read admission predicate
  `Access.validate(grant, :read, …)`).

  Fail-CLOSED, always: a nil caller_context, an empty grant set, or NO grant
  covering `workspace_id` (with read) all force `where: false` (zero rows) —
  never the whole workspace. Per grant, the ladder BELOW workspace (`project_id → dataset →
  type → doc_id`) is ANDed as equality on each non-NULL level, stopping at the
  first NULL (Grant's "null covers everything below" semantics, mirroring
  `Barkpark.Access.validate/3` — not reinvented). Grants OR together, so a
  caller with two grants sees the union of their scopes.
  """
  @spec scope_to_grants(Ecto.Queryable.t(), CallerContext.t() | nil, binary() | nil) ::
          Ecto.Query.t()
  def scope_to_grants(query, %CallerContext{grants: grants}, workspace_id)
      when is_binary(workspace_id) and is_list(grants) do
    case Enum.filter(grants, &covers_workspace_read?(&1, workspace_id)) do
      [] ->
        where(query, false)

      covering ->
        conditions =
          Enum.reduce(covering, dynamic(false), fn grant, acc ->
            dynamic([x], ^acc or ^grant_ladder_condition(grant))
          end)

        where(query, ^conditions)
    end
  end

  # Fail CLOSED: no caller_context, wrong shape, or nil workspace → zero rows.
  def scope_to_grants(query, _caller_context, _workspace_id), do: where(query, false)

  @doc """
  Opts-gated grant row-narrowing — the SINGLE owner of the `grant_scoped` gate.

  A NO-OP on every ordinary read: it applies `scope_to_grants/3` ONLY when
  `opts[:grant_scoped]` is true — the flag `ResolveWorkspace` / `AssignGrantScope`
  / `LiveScope` set when they admit a grant-only caller and
  `ScopeHelpers.scope_opts/1` threads through. Members, tokens, and anonymous
  reads carry no flag, so the query is byte-identical (grants only ADD access).

  When the flag IS present the read is restricted to the union of the caller's
  grant scopes, pulling `caller_context` + `workspace_id` off `opts` and FAILING
  CLOSED (`where: false`) if the caller_context is absent or carries no covering
  grant — a grant-derived caller can never fall through to the whole workspace.

  Every read that must honour a grant threads through here: the `Content.Query`
  read sites, the Postgres search `DocumentsRetriever` base query, the Indx
  hydration read, and the shared `Content.Graph` read helpers (`resolve_doc`,
  `scope_query`, `scoped_docs_query` — backlinks + the Studio graph pane).
  There is no private copy of the gate anywhere.
  """
  @spec maybe_scope_to_grants(Ecto.Queryable.t(), keyword()) :: Ecto.Queryable.t()
  def maybe_scope_to_grants(query, opts) do
    if Keyword.get(opts, :grant_scoped, false) do
      scope_to_grants(
        query,
        Keyword.get(opts, :caller_context),
        Keyword.get(opts, :workspace_id)
      )
    else
      query
    end
  end

  @doc """
  Grant narrowing for the SCHEMA CATALOG — the `type`-rung projection of
  `scope_to_grants/3` onto `schema_definitions` (task-8f8a3a2e05146984).

  `scope_to_grants/3` cannot be reused verbatim here: its ladder ANDs
  `project_id → dataset → type → doc_id` as `field(x, level)`, and a schema row
  has no `type` column and no `doc_id` at all — schemas are keyed by `name`. So
  the ladder binds to a schema query through exactly ONE rung, and this function
  is the only place that binding lives.

  Gate and failure mode are IDENTICAL to `maybe_scope_to_grants/2`: a no-op
  unless `opts[:grant_scoped]` is true (members, tokens and anonymous reads carry
  no flag and stay byte-identical — grants only ADD access), and fail-CLOSED
  (`where: false`, zero rows) on a nil `caller_context`, an empty grant set, or
  no grant covering `workspace_id` with READ. `covers_workspace_read?/2` — the
  same live-grant + read-capability + live-grantor predicate the document path
  uses — decides the covering set, so a revoked, expired, write-only, or
  dead-grantor grant can never contribute a type name.

  THE RUNG MAP, key by key, WITH THE SIGN of each:

    * `type` — PROJECTED, and the whole point. A covering grant naming a type
      admits the schema row of exactly that `name`. Grants OR together, so the
      caller sees the union of their named types. A covering grant with
      `type: nil` covers every type below it (Grant's null-covers-below
      semantics, the same halt `grant_ladder_condition/1` performs), so it
      WIDENS to the full catalog — correctly: that caller may read documents of
      every type in the workspace anyway.

    * `doc_id` — NOT PROJECTED, and the omission NARROWS nothing and WIDENS
      nothing. It sits BELOW `type`, and a doc-level grant necessarily names the
      doc's type on the rung above; the caller already knows that type name from
      its own grant.

    * `project_id` / `dataset` — NOT PROJECTED, deliberately. They sit ABOVE
      `type`, so skipping them can only WIDEN — and the widening discloses
      nothing the grant itself did not already tell the caller: the type name is
      printed on the grant. Projecting them would instead break the desk, because
      `Structure.build/2` reads workspace-global schemas (`include_global: true`,
      `project_id` NULL, and `:project_id` deliberately dropped from the read);
      an equality on a NULL column drops every shared type, blanking the desk of
      a project-scoped grantee. The dataset is already fixed by the caller's own
      `scope_schema_to_dataset/3`.

  Net: a grant-admitted non-member reads back the names of the types its grants
  name, and nothing else. What documents it may then READ of those types stays
  governed by the full ladder on the document path — this narrows a CATALOG, it
  is not a substitute for `maybe_scope_to_grants/2`.
  """
  @spec maybe_scope_schemas_to_grants(Ecto.Queryable.t(), keyword()) :: Ecto.Queryable.t()
  def maybe_scope_schemas_to_grants(query, opts) do
    if Keyword.get(opts, :grant_scoped, false) do
      scope_schemas_to_grants(
        query,
        Keyword.get(opts, :caller_context),
        Keyword.get(opts, :workspace_id)
      )
    else
      query
    end
  end

  @doc """
  The unconditional schema-catalog narrowing behind `maybe_scope_schemas_to_grants/2`.
  See that function for the rung map. Fails CLOSED on every shape it does not
  recognise.
  """
  @spec scope_schemas_to_grants(Ecto.Queryable.t(), CallerContext.t() | nil, binary() | nil) ::
          Ecto.Query.t()
  def scope_schemas_to_grants(query, %CallerContext{grants: grants}, workspace_id)
      when is_binary(workspace_id) and is_list(grants) do
    case Enum.filter(grants, &covers_workspace_read?(&1, workspace_id)) do
      [] ->
        where(query, false)

      covering ->
        # A covering grant with no `type` rung covers every type below it — the
        # catalog is not narrowed at all for that caller.
        if Enum.any?(covering, &is_nil(&1.type)) do
          query
        else
          names = covering |> Enum.map(& &1.type) |> Enum.uniq()
          where(query, [s], s.name in ^names)
        end
    end
  end

  # Fail CLOSED: no caller_context, wrong shape, or nil workspace → zero rows.
  def scope_schemas_to_grants(query, _caller_context, _workspace_id), do: where(query, false)

  # The READ-union covering set: a grant contributes its scope ladder to the
  # read narrowing ONLY when it (a) covers this workspace AND (b) actually
  # confers READ. A workspace-covering WRITE-ONLY grant (capabilities
  # `["write"]`, no `"read"`) must NEVER widen a read — write ⊅ read. The
  # read-cap check is LITERAL (`"read" in capabilities`), mirroring
  # `Barkpark.Access.action_allowed?/2` (admin does NOT imply read), and it
  # matches the read admission predicate `Access.validate(grant, :read, …)`.
  # So this is a PURE TIGHTENING: every grant a read caller was already
  # legitimately narrowed by confers read (it had to, to be admitted), and only
  # the erroneously-contributing non-read grants drop out of the union.
  #
  # LIVE grantor gate (finding ag-1): a grant contributes its ladder to the
  # read-union ONLY while its grantor still holds READ in this workspace — the
  # SAME `Access.grantor_authorizes?/2` predicate the per-action admission path
  # (`do_validate`) enforces, so the row-narrowing path can never widen a read
  # by a grant whose grantor lost authority (no bypass between the two paths).
  defp covers_workspace_read?(%Grant{workspace_id: ws, capabilities: caps} = grant, workspace_id)
       when is_list(caps),
       do:
         ws == workspace_id and "read" in caps and grant_live?(grant) and
           Access.grantor_authorizes?(grant, :read)

  defp covers_workspace_read?(_grant, _workspace_id), do: false

  # Defense-in-depth (ag-liveview-read-liveness). The read-union is fed a
  # CallerContext SNAPSHOT (`caller_context.grants`), loaded active-filtered at
  # mount / refresh time. This re-applies the grant's OWN `revoked_at` /
  # `expires_at` on the struct at read time, so if a refresh path is ever missed
  # a grant whose `expires_at` has since passed is STILL excluded from the union
  # (an expired grant behaves exactly like no grant — no cache leak).
  #
  # ASYMMETRY — why this cannot catch a mid-session REVOKE: a grant is snapshotted
  # while ACTIVE, so its struct carries `revoked_at: nil`; a revoke that lands
  # AFTER the snapshot loaded does NOT mutate that in-memory struct, so this
  # compare reads `nil` forever and the row would still serve. That is exactly
  # why revoke's truth is a fresh DB reload (`Access.revoke/2` broadcasts
  # `{:airdrop_revoked}` → `StudioLive` rebuilds `caller_context`), NOT a struct
  # compare. The `revoked_at` clause here only catches an already-revoked grant
  # that was somehow snapshotted (belt-and-suspenders), never a live revoke.
  defp grant_live?(%Grant{revoked_at: revoked, expires_at: expires}) do
    is_nil(revoked) and not grant_expired?(expires)
  end

  defp grant_expired?(nil), do: false
  defp grant_expired?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  # AND of the non-NULL ladder levels below workspace, stopping at the first
  # NULL (null-covers-below). An all-NULL-below grant (workspace-wide) yields
  # `dynamic(true)` → every row in the already-workspace-scoped query.
  defp grant_ladder_condition(%Grant{} = grant) do
    Enum.reduce_while([:project_id, :dataset, :type, :doc_id], dynamic(true), fn level, acc ->
      case Map.get(grant, level) do
        nil -> {:halt, acc}
        value -> {:cont, dynamic([x], ^acc and field(x, ^level) == ^value)}
      end
    end)
  end
end
