defmodule BarkparkWeb.WorkspaceController do
  @moduledoc """
  Membership-scoped LIST surface for the web workspace/project switcher.

    * `GET /api/workspaces` — the Workspaces the bearer token is a MEMBER of
      (via `workspace_memberships`). A workspace the caller has no membership
      row in is NEVER returned — the hard tenant boundary, enforced in the
      `Tenancy.list_workspaces_for/1` query, not here.

    * `GET /api/workspaces/:workspace_slug/projects` — the Projects under that
      workspace, but ONLY when the caller is a member. A non-member (and an
      unknown slug) both return 404 so the endpoint never leaks whether a
      workspace exists. `:require_token` already 401s an absent/invalid token.

    * `DELETE /api/workspaces/:workspace_slug` — permanently delete a workspace
      and everything scoped to it. This one is ADMIN-gated (the `:require_admin`
      pipeline), NOT membership-scoped — it is the destructive primitive eject /
      backup / abuse-isolation build on, so it needs the global `admin`
      permission, not mere membership.

  Token is assigned to `conn.assigns[:api_token]` by the `:require_token`
  pipeline. The JSON envelope mirrors the flat `/v1` controllers — a plain map
  rendered with `json/2`, no separate view module.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.WorkspaceBundle

  action_fallback BarkparkWeb.FallbackController

  def index(conn, _params) do
    token = conn.assigns[:api_token]
    workspaces = Tenancy.list_workspaces_for(token)
    json(conn, %{workspaces: Enum.map(workspaces, &render_workspace/1)})
  end

  @doc """
  POST /api/workspaces — create a Workspace owned by the bearer token.

  Any authenticated token may create a workspace; the creator is bound as an
  `"owner"` Membership in the same transaction, and a Default Project +
  "production" Dataset are bootstrapped so the workspace is immediately usable.
  201 + the created workspace; 422 (via FallbackController) on an invalid /
  duplicate slug.
  """
  def create(conn, params) do
    token = conn.assigns[:api_token]
    attrs = workspace_attrs(params)

    with {:ok, workspace} <- Tenancy.create_workspace_with_owner(attrs, token) do
      conn
      |> put_status(:created)
      |> json(%{workspace: render_workspace(workspace)})
    end
  end

  @doc """
  POST /api/workspaces/:workspace_slug/projects — create a Project (+ its
  "production" Dataset) under a workspace the caller is a MEMBER of.

  A non-member (and an unknown slug) both collapse to 404 — the same no-leak
  convention as the `projects` LIST action. 201 + the created project on
  success; 422 on an invalid / duplicate slug.
  """
  def create_project(conn, %{"workspace_slug" => slug} = params) do
    token = conn.assigns[:api_token]

    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         true <- TenancyAuth.member?(token, workspace.id),
         {:ok, project} <-
           Tenancy.create_project_with_dataset(workspace, project_attrs(params)) do
      conn
      |> put_status(:created)
      |> json(%{project: render_project(project)})
    else
      # A changeset error flows to the FallbackController (422). Anything else
      # (unknown slug / non-member) collapses to 404 — no existence leak.
      {:error, %Ecto.Changeset{}} = err -> err
      _ -> {:error, :not_found}
    end
  end

  @doc """
  DELETE /api/workspaces/:workspace_slug — permanently delete a Workspace and
  everything scoped to it.

  Admin-gated by the router's `:require_admin` pipeline (RequireToken +
  RequireAdmin — a caller without the global `admin` permission is refused 403
  before this action runs; NOT membership-scoped like the LIST/create surface).
  This is the HTTP primitive the destructive keystone consumers (eject, backup,
  abuse-isolation) assume; `Tenancy.delete_workspace/1` already exists and is
  tested but was unreachable over HTTP until now.

  Delegates to `Tenancy.delete_workspace/1`, which cascades inside a single
  transaction — media blobs (File.rm + CDN purge via `Media.delete_file/2`),
  documents (both draft and published variants, with plugin hooks), and every
  `workspace_id`-scoped table — rolling the whole thing back on any failure.

  Unknown slug → 404 (`{:error, :not_found}` via the FallbackController). On
  success → 200 echoing the deleted workspace so the caller has immediate,
  concrete confirmation of exactly what was removed.
  """
  def delete(conn, %{"workspace_slug" => slug}) do
    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         {:ok, deleted} <- Tenancy.delete_workspace(workspace) do
      json(conn, %{workspace: render_workspace(deleted), deleted: true})
    else
      # Unknown slug (get returns nil) OR delete_workspace resolving :not_found
      # both collapse to 404. A rollback term ({:error, reason}) flows to the
      # FallbackController, which maps it to the structured error envelope.
      nil -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  GET /api/workspaces/:workspace_slug/export — stream the complete bp-export-v1
  bundle for a workspace as an `application/x-tar` attachment (admin-gated).

  SYNC: `WorkspaceBundle.export/2` materializes the whole tar binary in memory,
  sent in one `send_resp/3`. An unknown slug collapses to 404 (no existence leak
  beyond the admin gate); the resolved workspace always carries a valid UUID, so
  the engine's fail-closed `:workspace_id_required` guard is never reached here.
  """
  def export(conn, %{"workspace_slug" => slug}) do
    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         {:ok, bundle} <- WorkspaceBundle.export(workspace.id) do
      conn
      |> put_resp_content_type("application/x-tar", nil)
      |> put_resp_header("content-disposition", "attachment; filename=#{workspace.slug}.tar")
      |> send_resp(200, bundle)
    else
      nil -> {:error, :not_found}
      # export/2 only errors on a nil/non-UUID id or a missing workspace — both
      # unreachable once get_workspace_by_slug returns a real %Workspace{} — but
      # fold any error into 404 rather than leak an engine tuple.
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  POST /api/workspaces/:workspace_slug/import — read the raw tar request body and
  re-import it via `WorkspaceBundle.import_bundle/2` (admin-gated).

  The bundle is SELF-DESCRIBING (its manifest carries the workspace identity and
  per-table import strategy); the string-keyed members re-import via INSERT ON
  CONFLICT DO NOTHING, so a re-import of the same bundle is a safe no-op. Returns
  the import stats — `{tables, total_rows}` — as JSON.
  """
  def import(conn, %{"workspace_slug" => _slug}) do
    {bundle, conn} = read_full_body(conn)
    {:ok, stats} = WorkspaceBundle.import_bundle(bundle)
    json(conn, %{tables: stats.tables, total_rows: stats.total_rows})
  end

  # Drain the entire raw request body (the tar bundle) — a POST body can arrive in
  # multiple chunks, so loop on `:more`. The `application/x-tar` content-type
  # matches no configured Plug.Parser (parsers pass `*/*` through unread), so the
  # bytes are still here to read. iolist accumulation avoids O(n^2) concatenation.
  defp read_full_body(conn, acc \\ []) do
    case Plug.Conn.read_body(conn, length: 100_000_000) do
      {:ok, chunk, conn} -> {IO.iodata_to_binary([acc, chunk]), conn}
      {:more, chunk, conn} -> read_full_body(conn, [acc, chunk])
    end
  end

  # Build the workspace create-attrs from the request body — only :name and an
  # optional :slug are honoured (slug derived from name when absent in the
  # context). Other body keys are ignored.
  defp workspace_attrs(params) do
    %{}
    |> maybe_put(:name, params["name"])
    |> maybe_put(:slug, params["slug"])
  end

  defp project_attrs(params) do
    %{}
    |> maybe_put(:name, params["name"])
    |> maybe_put(:slug, params["slug"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  def projects(conn, %{"workspace_slug" => slug}) do
    token = conn.assigns[:api_token]

    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(slug),
         true <- TenancyAuth.member?(token, workspace.id) do
      projects = Tenancy.list_projects(workspace)

      json(conn, %{
        workspace: render_workspace(workspace),
        projects: Enum.map(projects, &render_project/1)
      })
    else
      # Unknown slug OR a real workspace the caller is not a member of both
      # collapse to 404 — never confirm a workspace exists to a non-member.
      _ -> {:error, :not_found}
    end
  end

  def datasets(conn, %{"workspace_slug" => ws_slug, "project_slug" => proj_slug}) do
    token = conn.assigns[:api_token]

    with %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws_slug),
         true <- TenancyAuth.member?(token, workspace.id),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws_slug, proj_slug) do
      datasets = Tenancy.list_datasets(project)

      json(conn, %{
        workspace: render_workspace(workspace),
        project: render_project(project),
        datasets: Enum.map(datasets, &render_dataset/1)
      })
    else
      # Unknown workspace/project, or a non-member — collapse to 404, never
      # confirming existence to a caller who cannot see it.
      _ -> {:error, :not_found}
    end
  end

  defp render_workspace(%Tenancy.Workspace{} = ws) do
    %{id: ws.id, slug: ws.slug, name: ws.name}
  end

  defp render_project(%Tenancy.Project{} = project) do
    %{id: project.id, slug: project.slug, name: project.name}
  end

  defp render_dataset(%Tenancy.Dataset{} = dataset) do
    %{id: dataset.id, slug: dataset.slug, name: dataset.name}
  end
end
