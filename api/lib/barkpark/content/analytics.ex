defmodule Barkpark.Content.Analytics do
  @moduledoc """
  Pure-read document analytics aggregates.

  Counts documents grouped by type (with published/draft breakdown), totals,
  and recent mutation activity. Leaf concern — read-only Ecto aggregates over
  `Document` / `MutationEvent`, scoped by dataset + tenancy.

  Extracted from `Barkpark.Content`, which keeps a thin delegating facade.

  Dataset scope mirrors `Barkpark.Content`'s private `scope_to_dataset/3`:
  resolved via the still-on-facade public `resolve_read_dataset_id/2` (concern
  K, not yet relocated), then the NULL-tolerant legacy-string OR. Workspace
  scope rides the shared `Barkpark.Content.Scope.scope_to_workspace_or_global/3`
  — and EVERY read here also threads
  `Barkpark.Content.Scope.maybe_scope_to_grants/2`, the single owner of the
  `:grant_scoped` gate, so a grant-derived caller's aggregates are narrowed to
  its grant ladder. All four are reachable by such a caller (task-59d79b4058a7a434);
  none may be left off the gate.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, MutationEvent}

  import Barkpark.Content.Scope,
    only: [
      scope_to_workspace_or_global: 3,
      scope_to_workspace_including_global: 3,
      maybe_scope_to_grants: 2
    ]

  @doc """
  Count documents grouped by `type`, scoped to MIRROR `Barkpark.Structure.build`'s
  schema scope for the …Rest census (studio-structure-polish charter, Decision 6).

  Same `group_by(:type)` shape as `document_stats/2` — selects ONLY `type` +
  the total count, so it leaks no content (field-visibility safe) — but the
  tenancy scope differs deliberately:

    * INCLUDE nil-workspace globals (`scope_to_workspace_including_global/3`), and
    * do NOT narrow by `project_id`.

  The stock `document_stats/2` scope (`scope_to_workspace_or_global/3`) narrows
  to a single project when `project_id` is present, which would MISREPORT the
  census versus the desk tree (the desk lists workspace-level types spanning
  every project). `total` counts ALL rows of the type — DRAFTS INCLUDED — so the
  …Rest counts are honest about the database.

  GRANT NARROWING (task-c6d2e34c64100678). The census also threads
  `maybe_scope_to_grants/2`, the single owner of the `:grant_scoped` gate, so a
  grant-derived caller's census is restricted to its grant ladder like every
  other document read. It used to read `:workspace_id` and nothing else, which
  made it the one document read that bypassed the gate — and because
  `maybe_scope_to_grants/2` DEFAULTS the flag to false, the absent key meant "do
  not narrow", not "narrow to nothing". `LiveScope` admits a signed-in
  NON-MEMBER on its grant arm, so a grantee scoped to one project or one type
  mounted the Studio desk and read back the NAME of every document type in the
  workspace plus the COUNT of each: existence and volume across a grant
  boundary. Narrowing here is a no-op for members, tokens and anonymous reads —
  none of them carries the flag — so the desk they see is byte-identical.

  Grant narrowing needs BOTH `:grant_scoped` and `:caller_context` on `opts`:
  `scope_to_grants/3` fails CLOSED on a missing context, so forwarding the flag
  without the context would blank a grantee's …Rest tier rather than narrow it.
  `Barkpark.Structure.census_opts/1` forwards both.

  OWNERSHIP NARROWING (task-188996c5008f4299, split out of the grant fix above).
  The census now also composes `maybe_scope_to_owner/4`, gated per type on
  `Content.owner_scoped?/3` exactly as `Content.Query.base_query/4` gates it, so
  an `owner_scoped: true` type's …Rest count is the caller's rows and not every
  owner's. A PER-TYPE predicate, not a whole-query clamp — see the helper below
  for why `maybe_scope_to_owner_any/4`'s fail-closed shape is wrong here.

  NOT ARMED in this repo today and that is deliberate framing, not a hedge:
  `owner_scoped` is a CONSUMER-SET schema flag and no plugin declares it, so
  this closes the boundary before a consumer POSTs a schema that opens it.
  NOT restored, also deliberately: the `Schema.visible_schemas/2` visibility
  clamp. This PR closes the OWNERSHIP boundary only.
  """
  @spec type_census(String.t(), keyword()) :: [%{type: String.t(), total: non_neg_integer()}]
  def type_census(dataset, opts \\ []) do
    base = census_base(dataset, opts)
    rows = census_rows(base)

    case maybe_scope_to_owner(base, census_types(rows), dataset, opts) do
      :unscoped -> rows
      {:scoped, narrowed} -> census_rows(narrowed)
    end
  end

  defp census_base(dataset, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)

    Document
    |> scope_to_dataset(dataset, workspace_id: workspace_id)
    |> scope_to_workspace_including_global(workspace_id, nil)
    |> maybe_scope_to_grants(opts)
  end

  defp census_rows(query) do
    query
    |> group_by([d], d.type)
    |> select([d], %{type: d.type, total: count(d.id)})
    |> order_by([d], asc: d.type)
    |> Repo.all()
  end

  defp census_types(rows), do: rows |> Enum.map(& &1.type) |> Enum.reject(&is_nil/1)

  # OWNERSHIP NARROWING (task-188996c5008f4299). The census is the LAST document
  # read that did not compose the row/ownership ACL. `Content.Query.base_query/4`
  # appends `scope_to_owner/2` whenever `Content.owner_scoped?/3` says the type
  # opted in; the census did not, so for an `owner_scoped: true` type the desk's
  # …Rest row rendered "type (N)" with N counting EVERY owner's documents while
  # the drill-down below it correctly showed only the caller's. Existence and
  # volume across an OWNERSHIP boundary — the same shape as the GRANT leak
  # task-c6d2e34c64100678 / PR #14079 closed one boundary over, and deliberately
  # left this one rather than restoring all four clamps reflexively.
  #
  # WHY IT IS NOT A ONE-LINER, and why this is not `maybe_scope_to_owner_any/4`.
  # `Content.Query`'s helpers narrow a query about ONE type (or fail closed
  # across a type LIST). The census is a `group_by(:type)` over EVERY type at
  # once, so clamping the whole query on "any member type is owner-scoped" would
  # silently narrow the counts of every NON-owner-scoped type beside it — a
  # widening bug traded for an under-counting one. The clamp is therefore a
  # PER-TYPE predicate: only rows whose `type` is owner-scoped face the ownership
  # clause; every other type's count is byte-identical.
  #
  # Two passes, and the second one runs only when it can change an answer: the
  # gate needs the census's own type list, and with NO owner-scoped type in
  # scope (every schema in this repo today) it returns `:unscoped` and the
  # single original query stands.
  #
  # The caller bypasses mirror `Content.Scope.scope_to_owner/2` exactly —
  # `is_admin` and `:api_token` see all; a non-admin user sees their own rows
  # plus the unowned base; anonymous AND a nil `caller_context` fail CLOSED to
  # unowned rows only. `Structure.census_opts/1` already forwards
  # `:caller_context`, so the desk path arrives with a principal.
  defp maybe_scope_to_owner(query, types, dataset, opts) do
    ctx = Keyword.get(opts, :caller_context)

    if owner_clamp_exempt?(ctx) do
      :unscoped
    else
      case Enum.filter(types, &Content.owner_scoped?(&1, dataset, opts)) do
        [] -> :unscoped
        owned -> {:scoped, scope_owned_types_to_owner(query, owned, ctx)}
      end
    end
  end

  defp owner_clamp_exempt?(%CallerContext{is_admin: true}), do: true
  defp owner_clamp_exempt?(%CallerContext{principal_type: :api_token}), do: true
  defp owner_clamp_exempt?(_), do: false

  defp scope_owned_types_to_owner(query, owned_types, %CallerContext{
         principal_type: :user,
         user_id: uid
       })
       when is_binary(uid) do
    where(
      query,
      [d],
      d.type not in ^owned_types or d.owner_id == ^uid or is_nil(d.owner_id)
    )
  end

  # Fail CLOSED — anonymous, a user with no resolved id, or NO caller_context at
  # all sees only the unowned base of an owner-scoped type, never another
  # owner's rows.
  defp scope_owned_types_to_owner(query, owned_types, _ctx),
    do: where(query, [d], d.type not in ^owned_types or is_nil(d.owner_id))

  @doc """
  Count documents grouped by type, with published/draft breakdown.

  GRANT NARROWING (task-59d79b4058a7a434). Threads `maybe_scope_to_grants/2`,
  the single owner of the `:grant_scoped` gate, for the same reason
  `type_census/2` above does — and this function needed it MORE, because it is
  one of the three `AnalyticsController.index/2` actually calls.

  The fix under task-c6d2e34c64100678 landed on `type_census/2` alone, on the
  reading that a grant-derived caller cannot reach a `:require_token` route.
  That is false: `RequireToken` wants a Bearer and `ResolveWorkspace`'s grant
  arm wants a signed-in non-member USER, and one caller satisfies both — on
  `:scoped_api` GET, `OptionalSessionToken` assigns `:current_user` from the
  session cookie regardless of the bearer, so a grantee holding her OWN
  workspace's token plus her login cookie passes the token gate as a
  non-member and is admitted through the grant arm. Pinned by
  `test/barkpark_web/integration/analytics_grant_narrowing_test.exs`.

  No-op for members, tokens and anonymous reads — none of them carries the
  flag — so their responses are byte-identical.
  """
  def document_stats(dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> maybe_scope_to_grants(opts)
    |> group_by([d], d.type)
    |> select([d], %{
      type: d.type,
      total: count(d.id),
      published: count(fragment("CASE WHEN ? NOT LIKE 'drafts.%' THEN 1 END", d.doc_id)),
      drafts: count(fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 END", d.doc_id))
    })
    |> order_by([d], asc: d.type)
    |> Repo.all()
  end

  @doc """
  Count total documents in a dataset.

  GRANT NARROWING (task-59d79b4058a7a434). Threads `maybe_scope_to_grants/2`,
  the single owner of the `:grant_scoped` gate, for the same reason
  `type_census/2` above does — and this function needed it MORE, because it is
  one of the three `AnalyticsController.index/2` actually calls.

  The fix under task-c6d2e34c64100678 landed on `type_census/2` alone, on the
  reading that a grant-derived caller cannot reach a `:require_token` route.
  That is false: `RequireToken` wants a Bearer and `ResolveWorkspace`'s grant
  arm wants a signed-in non-member USER, and one caller satisfies both — on
  `:scoped_api` GET, `OptionalSessionToken` assigns `:current_user` from the
  session cookie regardless of the bearer, so a grantee holding her OWN
  workspace's token plus her login cookie passes the token gate as a
  non-member and is admitted through the grant arm. Pinned by
  `test/barkpark_web/integration/analytics_grant_narrowing_test.exs`.

  No-op for members, tokens and anonymous reads — none of them carries the
  flag — so their responses are byte-identical.
  """
  def total_documents(dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> maybe_scope_to_grants(opts)
    |> select([d], count(d.id))
    |> Repo.one()
  end

  @doc """
  Recent mutation activity — last N events.

  GRANT NARROWING (task-59d79b4058a7a434). Threads `maybe_scope_to_grants/2`,
  the single owner of the `:grant_scoped` gate, for the same reason
  `type_census/2` above does — and this function needed it MORE, because it is
  one of the three `AnalyticsController.index/2` actually calls. `MutationEvent`
  carries the whole `workspace → project → dataset → type → doc_id` ladder, so
  `scope_to_grants/3` narrows it exactly as it narrows `Document` — and this one
  leaks doc_ids, not just counts.

  The fix under task-c6d2e34c64100678 landed on `type_census/2` alone, on the
  reading that a grant-derived caller cannot reach a `:require_token` route.
  That is false: `RequireToken` wants a Bearer and `ResolveWorkspace`'s grant
  arm wants a signed-in non-member USER, and one caller satisfies both — on
  `:scoped_api` GET, `OptionalSessionToken` assigns `:current_user` from the
  session cookie regardless of the bearer, so a grantee holding her OWN
  workspace's token plus her login cookie passes the token gate as a
  non-member and is admitted through the grant arm. Pinned by
  `test/barkpark_web/integration/analytics_grant_narrowing_test.exs`.

  No-op for members, tokens and anonymous reads — none of them carries the
  flag — so their responses are byte-identical.
  """
  def recent_activity(dataset, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    MutationEvent
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> maybe_scope_to_grants(opts)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> select([e], %{
      id: e.id,
      type: e.type,
      doc_id: e.doc_id,
      mutation: e.mutation,
      timestamp: e.inserted_at
    })
    |> Repo.all()
  end

  # Mirrors `Barkpark.Content`'s private `scope_to_dataset/3` (concern K, still
  # on the facade). Resolves the read dataset_id through the facade's public
  # `resolve_read_dataset_id/2`, then applies the NULL-tolerant legacy-string OR.
  defp scope_to_dataset(query, dataset, opts) do
    case Content.resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [x], x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset))

      _ ->
        where(query, [x], x.dataset == ^dataset)
    end
  end
end
