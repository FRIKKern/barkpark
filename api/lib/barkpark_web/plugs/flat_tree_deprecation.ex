defmodule BarkparkWeb.Plugs.FlatTreeDeprecation do
  @moduledoc """
  Marks the flat `/v1/*` tree deprecated in favour of the scoped
  `/w/:workspace_slug/p/:project_slug/v1/*` tree (Barkspark phase 3,
  task-0bb1b96ae30cb4a4).

  A response on a flat route that has a scoped mirror carries:

      deprecation: true
      link: </w/<ws>/p/<proj>/v1/...>; rel="successor-version"

  and no `sunset` header. The orchestrator ruling of 2026-09-25T12:43Z holds
  the Sunset date back until the owner picks one (owner item 55): a date is a
  public removal promise on routes `bp` and the SDKs still call.

  ## Which routes

  The plug is mounted in every pipeline a flat route rides, and those same
  pipelines also carry routes that must stay unmarked. So it decides per
  request, from the route the router actually matched
  (`Phoenix.Router.route_info/4`), never from the request path text:

    * the matched route template starts with `/v1`, and
    * the router declares the same verb at
      `/w/:workspace_slug/p/:project_slug` + that template.

  Scoped routes, legacy `/api/*` routes (`Plugs.LegacyDeprecation` owns
  those, with their own Sunset) and flat routes with no scoped mirror pass
  through unchanged. `flat_tree_deprecation_test.exs` walks the router and
  names every flat route with no mirror.

  ## The successor URL

  The link names the concrete scoped URL for this request: the matched
  route's path parameters are substituted back into the scoped template, and
  the workspace and project slugs come from the scope the flat request
  resolved to (`:current_workspace` / `:current_project`, set by
  `DeriveWorkspaceFromToken` + `AssignDefaultScope`). A caller on the seeded
  default scope gets `/w/default/p/default/v1/...`.

  When a slug did not resolve, its `:workspace_slug` / `:project_slug`
  placeholder stays in the link. That happens when the request halts before
  scope resolution (a 401 from `RequireToken`) and when a token bound to a
  non-Default workspace calls a flat route: `AssignDefaultScope` gives such a
  request no project, so there is no project to name. The query string is
  never copied into the link.

  The route is matched when the plug runs; the headers are written in a
  `register_before_send/2` callback, so halted responses (401, 403, 429)
  carry them too and the slugs are read from the final assigns. Mount the
  plug FIRST in a pipeline so no earlier plug can halt past it.
  """

  import Plug.Conn

  @scoped_prefix "/w/:workspace_slug/p/:project_slug"

  def init(opts), do: opts

  # The route is matched here, while `path_info` is still the router's own; the
  # headers are written at send time, when the scope assigns are final.
  def call(conn, _opts) do
    case successor_template(conn) do
      nil -> conn
      template -> register_before_send(conn, &put_headers(&1, successor_path(template, &1)))
    end
  end

  @doc """
  The scoped route template that succeeds the flat route `template` for HTTP
  `method` on `router`, or `nil` when `template` is not a flat `/v1` route or
  has no scoped mirror.
  """
  def successor_for(router, method, "/v1" <> _ = template) do
    scoped = @scoped_prefix <> template
    if {String.upcase(method), scoped} in scoped_routes(router), do: scoped
  end

  def successor_for(_router, _method, _template), do: nil

  defp successor_template(%{private: %{phoenix_router: router}} = conn) do
    path = Enum.map(conn.path_info, &URI.decode/1)

    case Phoenix.Router.route_info(router, conn.method, path, conn.host) do
      %{route: template} -> successor_for(router, conn.method, template)
      :error -> nil
    end
  end

  defp successor_template(_conn), do: nil

  defp scoped_routes(router) do
    key = {__MODULE__, router, router.module_info(:md5)}

    case :persistent_term.get(key, nil) do
      nil ->
        set =
          for %{verb: verb, path: @scoped_prefix <> _ = path} <- router.__routes__(),
              into: MapSet.new(),
              do: {verb |> to_string() |> String.upcase(), path}

        :persistent_term.put(key, set)
        set

      set ->
        set
    end
  end

  defp successor_path(template, conn) do
    params =
      conn.path_params
      |> Map.put("workspace_slug", slug(conn.assigns[:current_workspace]))
      |> Map.put("project_slug", slug(conn.assigns[:current_project]))

    template
    |> String.split("/")
    |> Enum.map_join("/", &segment(&1, params))
  end

  defp slug(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp slug(_), do: nil

  defp segment(":" <> name = placeholder, params), do: encode(params[name], placeholder)
  defp segment("*" <> name = placeholder, params), do: encode(params[name], placeholder)
  defp segment(literal, _params), do: literal

  defp encode(nil, placeholder), do: placeholder
  defp encode(value, _) when is_binary(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp encode(parts, placeholder) when is_list(parts),
    do: Enum.map_join(parts, "/", &encode(&1, placeholder))

  defp put_headers(conn, path) do
    link = "<#{path}>; rel=\"successor-version\""

    link =
      case get_resp_header(conn, "link") do
        [] -> link
        existing -> Enum.join(existing ++ [link], ", ")
      end

    conn
    |> put_resp_header("deprecation", "true")
    |> put_resp_header("link", link)
  end
end
