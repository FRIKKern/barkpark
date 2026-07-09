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

  Workspace + project + dataset resolution lives in
  `BarkparkWeb.Studio.ScopeResolver` (shared with `PageController` and
  `LegacyRedirectController`). A flat link under-determines the workspace, so
  the resolver prefers, in order: (1) the Referer's `/w/:ws/p/:proj` scope when
  the token is a member of it — so following a flat link keeps you in the
  workspace you came from instead of teleporting you to your first membership;
  then (2) the token's first slug-ordered membership (anonymous → the seeded
  Default). See the ScopeResolver moduledoc for the full order.

  Always **302** — the target depends on the token + Referer, so it must never
  be browser-cached (a 301 would misdeliver other users of a shared cache).
  """
  use BarkparkWeb, :controller

  alias BarkparkWeb.Studio.ScopeResolver

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
    case ScopeResolver.resolve_scope(conn, conn.assigns[:api_token]) do
      {:ok, ws, project} ->
        ds = ScopeResolver.resolve_dataset(project, dataset)

        tail =
          case path_segments do
            [] -> ""
            segments -> "/" <> Enum.join(segments, "/")
          end

        {:ok, "/w/#{ws.slug}/p/#{project.slug}/d/#{ds}/studio#{tail}"}

      :error ->
        :error
    end
  end

  defp with_query(target, ""), do: target
  defp with_query(target, nil), do: target
  defp with_query(target, qs), do: target <> "?" <> qs
end
