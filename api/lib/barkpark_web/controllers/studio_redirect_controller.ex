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
  the principal is a member of it — so following a flat link keeps you in the
  workspace you came from instead of teleporting you to your first membership;
  then (2) the principal's first slug-ordered membership, with the seeded
  Default demoted for an account session (anonymous → Default). The principal
  is EITHER the request's api token OR the account session's user — see
  `ScopeResolver.principal/1` and the ScopeResolver moduledoc.

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
    target = "/w/#{ws}/p/#{proj}/d/#{dataset}/studio#{path_tail(Map.get(params, "path", []))}"
    redirect(conn, to: with_query(target, conn.query_string))
  end

  @doc """
  Resolve the scoped Studio target for this conn's token. Shared with
  `PageController.redirect_to_studio` (bare `/` + `/studio`, dataset nil)
  and `LegacyRedirectController` (retargeted deep links).
  """
  def scoped_studio_target(conn, dataset, path_segments \\ []) do
    # The principal is derived by `ScopeResolver.principal/1`, never read off a
    # single assign: an account session lives in `:current_user`, so reading
    # `:api_token` here handed the resolver `nil` and 302'd every signed-in
    # account into the seeded Default workspace (field report #34).
    case ScopeResolver.resolve_scope(conn, ScopeResolver.principal(conn)) do
      {:ok, ws, project} ->
        ds = ScopeResolver.resolve_dataset(project, dataset)

        {:ok, "/w/#{ws.slug}/p/#{project.slug}/d/#{ds}/studio#{path_tail(path_segments)}"}

      :error ->
        :error
    end
  end

  # The `/*path` tail, rebuilt from the router glob — and ONLY from a shape the
  # glob can actually produce.
  #
  # Both actions are mounted twice: on `/*path`, where `"path"` is a
  # path_param and is always a list of binaries, and on the scope's bare `/`,
  # where the router binds no `"path"` at all. Phoenix merges path_params OVER
  # the query params, so on the bare-slash route there is no key to override an
  # attacker-chosen `?path=` and it reaches `params` verbatim. `Enum.join/2`
  # then raises for anything that is not a list of binaries — a bare string
  # (`Enumerable` for `BitString`), a map (`String.Chars` for `Tuple`), a
  # nested list — and the crash is reachable with NO credential on either arm:
  # `:browser` and `:soft_token` (OptionalSessionToken) coerce nothing, and
  # `protect_from_forgery` does not gate GET.
  #
  # A caller-forged `?path=` is not a path segment list, so it contributes no
  # tail. The raw value is still visible to the target — `with_query/2`
  # preserves the query string untouched — it just no longer decides the
  # redirect's shape. Matches the guard `AdminStudioRedirectController`'s
  # `plugin_tail/1` already carries for its own optional URL tail.
  defp path_tail([]), do: ""

  defp path_tail(segments) when is_list(segments) do
    if Enum.all?(segments, &is_binary/1), do: "/" <> Enum.join(segments, "/"), else: ""
  end

  defp path_tail(_not_a_path), do: ""

  defp with_query(target, ""), do: target
  defp with_query(target, nil), do: target
  defp with_query(target, qs), do: target <> "?" <> qs
end
