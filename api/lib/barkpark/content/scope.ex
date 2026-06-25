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
  def scope_to_workspace_or_global(query, nil, _project_id),
    do: scope_to_workspace_global(query)

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

  def scope_to_workspace_including_global(query, workspace_id, _project_id)
      when is_binary(workspace_id) do
    where(query, [x], x.workspace_id == ^workspace_id or is_nil(x.workspace_id))
  end
end
