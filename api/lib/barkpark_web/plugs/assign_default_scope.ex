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
  """

  import Plug.Conn

  alias Barkpark.Tenancy

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> maybe_assign(:current_workspace, &Tenancy.get_default_workspace/0)
    |> maybe_assign(:current_project, &Tenancy.get_default_project/0)
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
