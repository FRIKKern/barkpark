defmodule BarkparkWeb.Plugs.AssignDefaultScope do
  @moduledoc """
  Back-compat scope shim for the flat (`/v1/data/:dataset/*`, etc.) routes that
  pre-date path-based tenancy. The scoped `/w/:workspace_slug/p/:project_slug`
  routes resolve their tenant via `ResolveWorkspace` / `ResolveProject`; the
  flat routes have no slugs in the path, so they infer the seeded Default
  Workspace / Default Project here.

  Only assigns `:current_workspace` / `:current_project` when they are not
  already set — so it is harmless if it ever runs after a resolver. Never halts:
  when no Default has been seeded (a fresh DB before the backfill), it passes
  the conn through untouched and downstream code keeps its pre-tenancy shape.

  ## The Default PROJECT is only stamped under the Default WORKSPACE

  `DeriveWorkspaceFromToken` runs before this plug on the token-deriving flat
  pipelines (`:flat_admin_api`, `:media_mutate`, `:cycle_api`) and sets
  `:current_workspace` from the caller's token — but nothing sets
  `:current_project`, because a token carries no project binding. Falling back
  to the *Default Project* there would pair workspace A with a project owned by
  the DEFAULT workspace, and `Barkpark.Content.Scope.scope_to_workspace/3` ANDs
  the two: every scoped read matches zero rows, and every scoped write stamps a
  `project_id` belonging to another tenant. So the project fallback is
  conditional — it applies only when the resolved workspace IS the Default
  Workspace (or when no workspace resolved at all). A derived non-Default
  workspace is left project-less, which `scope_to_workspace/3` handles as a
  correct workspace-only filter.
  """

  import Plug.Conn

  alias Barkpark.Tenancy

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> maybe_assign(:current_workspace, &Tenancy.get_default_workspace/0)
    |> maybe_assign_default_project()
  end

  # The Default Project belongs to the Default Workspace — see the moduledoc.
  # Stamp it only when the resolved workspace is the one that owns it.
  defp maybe_assign_default_project(conn) do
    case conn.assigns do
      %{current_project: existing} when not is_nil(existing) ->
        conn

      %{current_workspace: %{id: ws_id}} when not is_nil(ws_id) ->
        case Tenancy.get_default_project() do
          %{workspace_id: ^ws_id} = project -> assign(conn, :current_project, project)
          _ -> conn
        end

      _ ->
        maybe_assign(conn, :current_project, &Tenancy.get_default_project/0)
    end
  end

  defp maybe_assign(conn, key, fetch) do
    case conn.assigns do
      %{^key => existing} when not is_nil(existing) ->
        conn

      _ ->
        case fetch.() do
          nil -> conn
          value -> assign(conn, key, value)
        end
    end
  end
end
