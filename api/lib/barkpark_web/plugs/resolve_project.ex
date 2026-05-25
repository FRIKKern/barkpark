defmodule BarkparkWeb.Plugs.ResolveProject do
  @moduledoc """
  Resolves the `:project_slug` path param into `conn.assigns[:current_project]`,
  scoped to the already-resolved `:current_workspace`.

  Pipeline: must run AFTER `BarkparkWeb.Plugs.ResolveWorkspace` so
  `conn.assigns[:current_workspace]` is set and membership has been enforced.
  Looks the project up by workspace slug + project slug via
  `Barkpark.Tenancy.get_project/2`; a project that does not exist OR exists in
  a different workspace yields 404 (envelope) — the workspace-scoped lookup is
  what keeps a project in workspace A from resolving under workspace B.
  """

  import Plug.Conn

  alias Barkpark.Tenancy

  def init(opts), do: opts

  def call(conn, _opts) do
    ws_slug = conn.path_params["workspace_slug"]
    project_slug = conn.path_params["project_slug"]

    case ws_slug && project_slug && Tenancy.get_project(ws_slug, project_slug) do
      %Tenancy.Project{} = project ->
        assign(conn, :current_project, project)

      _ ->
        halt_envelope(conn, {:error, :not_found})
    end
  end

  defp halt_envelope(conn, reason) do
    env = Barkpark.Content.Errors.to_envelope(reason, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
