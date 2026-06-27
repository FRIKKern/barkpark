defmodule BarkparkWeb.StudioRedirectController do
  @moduledoc """
  The flat-Studio → scoped-Studio 302 funnel (P3 of Scoped-by-URL,
  design: `/papers/studio-url-architecture`).

  `/studio/:dataset`, `/studio/:dataset/*path` (and, via
  `PageController.redirect_to_studio`, bare `/` + `/studio`) redirect to
  the session-resolved canonical `/w/:ws/p/:proj/d/:ds/studio/...` with
  path and query string preserved. The pre-/d/ scoped form
  `/w/:ws/p/:proj/studio/:ds/...` 302s to the same canonical via
  `legacy_scoped/2` — a pure URL rewrite, no session resolution.

  ## Resolution rule (the formerly-invisible in-socket pick, made visible)

  1. **Workspace** — token → first slug-ordered membership workspace
     (`Tenancy.list_workspaces_for/1`, the exact rule StudioLive's
     `initial_workspace/1` applied silently); anonymous → the seeded
     Default workspace. Nothing resolvable → `/login`.
  2. **Project** — the Default project when it belongs to that workspace,
     else the workspace's first project (mirrors `initial_project/1`).
     Project-less workspace → `/login` (Studio cannot render there).
  3. **Dataset** — the requested leaf when the project owns a dataset row
     with that slug; else the project's default (`production`-preferred,
     else first); a project with NO dataset rows keeps the requested
     string (the string-seam stays authoritative — same invariant as
     `redirect_dataset_leaf`).

  Always **302** — the target depends on the session, so it must never be
  browser-cached (a 301 would misdeliver other users of a shared cache).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy

  def studio(conn, params) do
    dataset = params["dataset"]
    path = Map.get(params, "path", [])

    case scoped_studio_target(conn, dataset, path) do
      {:ok, target} -> redirect(conn, to: with_query(target, conn.query_string))
      :error -> redirect(conn, to: "/login")
    end
  end

  @doc """
  Old scoped form `/w/:ws/p/:proj/studio/:dataset[/*path]` → the `/d/`
  canonical. Every segment is already in the URL, so this is a pure
  rewrite — no session resolution; the canonical route authorizes.
  """
  def legacy_scoped(
        conn,
        %{
          "workspace_slug" => ws,
          "project_slug" => proj,
          "dataset" => dataset
        } = params
      ) do
    tail =
      case Map.get(params, "path", []) do
        [] -> ""
        segments -> "/" <> Enum.join(segments, "/")
      end

    target = "/w/#{ws}/p/#{proj}/d/#{dataset}/studio#{tail}"
    redirect(conn, to: with_query(target, conn.query_string))
  end

  @doc """
  Resolve the scoped Studio target for this conn's token. Shared with
  `PageController.redirect_to_studio` (bare `/` + `/studio`, dataset nil)
  and `LegacyRedirectController` (retargeted deep links).
  """
  def scoped_studio_target(conn, dataset, path_segments \\ []) do
    with %{} = ws <- resolve_workspace(conn.assigns[:api_token]),
         %{} = project <- resolve_project(ws) do
      ds = resolve_dataset(project, dataset)

      tail =
        case path_segments do
          [] -> ""
          segments -> "/" <> Enum.join(segments, "/")
        end

      {:ok, "/w/#{ws.slug}/p/#{project.slug}/d/#{ds}/studio#{tail}"}
    else
      _ -> :error
    end
  end

  defp resolve_workspace(nil), do: Tenancy.get_default_workspace()

  defp resolve_workspace(token) do
    case Tenancy.list_workspaces_for(token) do
      [ws | _] -> ws
      _ -> Tenancy.get_default_workspace()
    end
  end

  defp resolve_project(%{id: ws_id}) do
    default =
      case Tenancy.get_default_project() do
        %{workspace_id: ^ws_id} = proj -> proj
        _ -> nil
      end

    default || List.first(Tenancy.list_projects(ws_id))
  end

  defp resolve_dataset(project, requested) do
    datasets = Tenancy.list_datasets(project.id)
    slugs = Enum.map(datasets, & &1.slug)

    cond do
      is_binary(requested) and requested in slugs ->
        requested

      "production" in slugs ->
        "production"

      slugs != [] ->
        List.first(slugs)

      # No dataset rows (string-seam-only project): the requested string
      # stays authoritative; a bare /studio falls back to the configured
      # default dataset.
      is_binary(requested) and requested != "" ->
        requested

      true ->
        Barkpark.Content.default_dataset()
    end
  end

  defp with_query(target, ""), do: target
  defp with_query(target, nil), do: target
  defp with_query(target, qs), do: target <> "?" <> qs
end
