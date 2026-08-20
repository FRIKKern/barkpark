defmodule BarkparkWeb.AdminStudioRedirectController do
  @moduledoc """
  The flat admin-Studio → scoped-Studio 302 funnel
  (bp-studio-deep-link, wave 1 slice `sdl-w1-admin-canonical`; charter
  Decision 4 — "admin family split by SUBSTANCE, not URL shape").

  Two admin surfaces are scoped-in-substance and now live under the
  canonical `/w/:ws/p/:proj/...` grammar; their old flat spellings 302
  here so bookmarks and hand-built links keep resolving:

    * `GET /studio/settings`
      → `/w/:ws/p/:proj/studio/settings` (workspace-level, dataset-less —
        `SettingsLive` edits ONE workspace's settings, so the flat route
        that pinned the seeded Default workspace was a substantive-scope
        teleport).
    * `GET /studio/:dataset/_plugins[/:plugin/settings]`
      → `/w/:ws/p/:proj/d/:dataset/studio/_plugins[/:plugin/settings]`
        (the dataset is already in the URL — only the workspace/project
        prefix is resolved here).

  Always **302** (never 301): the workspace/project resolution depends on
  the session, so a shared cache must never memoize one caller's scope.
  Path tail (the `/:plugin/settings` suffix) and query string are
  preserved.

  ## Scope resolution

  `resolve_scope/1` delegates to `BarkparkWeb.Studio.ScopeResolver`
  (sdl-w1-teleport) — the same brain behind the content-surface funnel:
  the Referer's membership-verified `/w/:ws/p/:proj` scope when present,
  else the principal's first slug-ordered membership workspace (anonymous →
  the seeded Default). So a flat admin link followed from inside a
  workspace keeps you in THAT workspace. The principal is an api token OR an
  account session's user (`ScopeResolver.principal/1`).
  """
  use BarkparkWeb, :controller

  alias BarkparkWeb.Studio.ScopeResolver

  @doc """
  `/studio/settings` → the workspace-level scoped settings canonical
  (dataset-less). The scoped route's `LiveScope`/`LiveAuth.:admin` chain
  authorizes; this controller only rewrites the address.
  """
  def settings(conn, _params) do
    case resolve_scope(conn) do
      {:ok, ws_slug, proj_slug} ->
        redirect(conn,
          to: with_query("/w/#{ws_slug}/p/#{proj_slug}/studio/settings", conn.query_string)
        )

      :error ->
        redirect(conn, to: "/login")
    end
  end

  @doc """
  `/studio/connectors` → the workspace-level scoped Connectors canonical
  (connectors D49). Identical substance argument to `settings/2`: a connector
  install belongs to ONE workspace, so a flat mount would carry no
  `current_workspace` and pin every install to the seeded Default. The flat
  spelling exists so a bookmark (and the flat-surface nav tab, which the
  nav-parity contract requires to be present everywhere) resolves.
  """
  def connectors(conn, _params) do
    case resolve_scope(conn) do
      {:ok, ws_slug, proj_slug} ->
        redirect(conn,
          to: with_query("/w/#{ws_slug}/p/#{proj_slug}/studio/connectors", conn.query_string)
        )

      :error ->
        redirect(conn, to: "/login")
    end
  end

  @doc """
  `/studio/:dataset/_plugins[/:plugin/settings]` → the dataset-scoped
  plugins-admin canonical, preserving the `/:plugin/settings` tail.
  """
  def plugins(conn, %{"dataset" => dataset} = params) do
    case resolve_scope(conn) do
      {:ok, ws_slug, proj_slug} ->
        target =
          "/w/#{ws_slug}/p/#{proj_slug}/d/#{dataset}/studio/_plugins#{plugin_tail(params)}"

        redirect(conn, to: with_query(target, conn.query_string))

      :error ->
        redirect(conn, to: "/login")
    end
  end

  # The optional `/:plugin/settings` suffix of the plugins-admin family.
  defp plugin_tail(%{"plugin" => plugin}) when is_binary(plugin) and plugin != "",
    do: "/#{plugin}/settings"

  defp plugin_tail(_params), do: ""

  # ── scope resolution — delegated to ScopeResolver (see @moduledoc) ──────
  # Returns {:ok, ws_slug, proj_slug} or :error when no workspace/project
  # can be resolved (an admin Studio cannot render without a project).
  defp resolve_scope(conn) do
    # Same principal seam as the content funnel: `principal/1` covers the
    # account session (`:current_user`) that reading `:api_token` alone missed.
    case ScopeResolver.resolve_scope(conn, ScopeResolver.principal(conn)) do
      {:ok, ws, project} -> {:ok, ws.slug, project.slug}
      :error -> :error
    end
  end

  defp with_query(target, ""), do: target
  defp with_query(target, nil), do: target
  defp with_query(target, qs), do: target <> "?" <> qs
end
