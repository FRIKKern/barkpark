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

  Back-compat: a `nil` `workspace_id` is the pre-tenancy ("unscoped") path —
  the query is returned untouched so internal callers and legacy single-tenant
  reads keep their prior behaviour. The flat back-compat routes carry the
  seeded Default workspace/project via `AssignDefaultScope`, so production
  single-tenant traffic is scoped to Default rather than running unscoped.
  """

  import Ecto.Query

  @doc """
  Add the workspace (and optionally project) WHERE clause to an Ecto query.

  Binds against the FIRST named binding in the query (the `[x]` position), so
  it composes with `Document`, `SchemaDefinition`, and any other queryable that
  carries `workspace_id` / `project_id` columns.

    * `workspace_id == nil` → query returned untouched (unscoped / pre-tenancy).
    * `workspace_id` set, `project_id == nil` → workspace-only scope.
    * both set → workspace + project scope.
  """
  @spec scope_to_workspace(Ecto.Queryable.t(), binary() | nil, binary() | nil) ::
          Ecto.Query.t() | Ecto.Queryable.t()
  def scope_to_workspace(query, workspace_id, project_id \\ nil)

  def scope_to_workspace(query, nil, _project_id), do: query

  def scope_to_workspace(query, workspace_id, nil) when is_binary(workspace_id) do
    where(query, [x], x.workspace_id == ^workspace_id)
  end

  def scope_to_workspace(query, workspace_id, project_id)
      when is_binary(workspace_id) and is_binary(project_id) do
    where(query, [x], x.workspace_id == ^workspace_id and x.project_id == ^project_id)
  end
end
