defmodule BarkparkWeb.Studio.StudioLive.Paths do
  @moduledoc """
  THE Studio URL builder — the single owner of the Studio path grammar.

  Every Studio URL string is produced here, socket-free: each builder takes
  an explicit `scope_prefix` (the `/w/:ws/p/:proj` prefix on a scoped
  surface, or `""`/`nil` on a flat one) rather than reaching into a socket.

    * `studio_path_for/3` contributes the `/d/:dataset/studio[/...]` suffix.
    * `studio_path/4` prefixes `scope_prefix` in front of that suffix. It is
      the socket-free twin of the socket-aware choke point
      `BarkparkWeb.Studio.StudioLive.Shared.studio_path/4` — that function
      just reads `scope_prefix` off the socket and delegates straight here.
    * `scoped_root/3` / `flat_root/1` build the Studio root the chrome
      `push_navigate`s to — ONE owner each for the scoped and the
      deliberate-flat grammars.
    * `paper_path/2` builds the standalone paper reader URL.
    * `desk_chip_href/4` composes desk-chip hrefs; `plugin_link_href/2`
      canonicalises a plugin's flat `:plugin_link` href against the current
      scope — called at SOURCE in `PaneBuilder.list_items`, so no
      render-time shim survives.
  """

  @doc false
  def studio_path_for([], dataset, opts),
    do: append_desk_query("/d/#{dataset}/studio", opts)

  def studio_path_for(segments, dataset, opts),
    do:
      append_desk_query(
        "/d/#{dataset}/studio/" <> Enum.join(segments, "/"),
        opts
      )

  @doc """
  Full Studio path: `scope_prefix` + the `/d/:dataset/studio[/segments]`
  suffix. `scope_prefix` is the `/w/:ws/p/:proj` prefix on a scoped surface,
  or `""`/`nil` on a flat one. Every hand-interpolated `…/d/…/studio` call
  site routes through here.
  """
  def studio_path(scope_prefix, segments, dataset, opts \\ []) do
    (scope_prefix || "") <> studio_path_for(segments, dataset, opts)
  end

  @doc """
  The scoped Studio root — `/w/:ws/p/:proj/d/:dataset/studio`. The canonical
  destination the chrome `push_navigate`s to.
  """
  def scoped_root(ws_slug, proj_slug, dataset),
    do: "/w/#{ws_slug}/p/#{proj_slug}/d/#{dataset}/studio"

  @doc """
  The deliberate-flat Studio root — `/studio/:dataset`. Used on surfaces
  with no `/w/:ws/p/:proj` scope; these ride the flat→scoped 302 funnel,
  which re-resolves the workspace from the session. ONE owner for the flat
  grammar too.
  """
  def flat_root(dataset), do: "/studio/#{dataset}"

  @doc """
  The `/w/:ws/p/:proj` scope prefix, or `""` when either slug is absent
  (the flat surfaces that ride the flat→scoped funnel). ONE owner for the
  scope-prefix grammar the chat root composes over.
  """
  def scope_prefix(ws_slug, proj_slug)
      when is_binary(ws_slug) and is_binary(proj_slug),
      do: "/w/#{ws_slug}/p/#{proj_slug}"

  def scope_prefix(_ws_slug, _proj_slug), do: ""

  @doc """
  The Studio chat root — the flat `/studio/chat` singleton, or the scoped
  `scope_prefix <> "/studio/chat"`. ONE owner for the chat grammar so the
  scoped literal never gets hand-built at a call site.
  """
  def chat_root(scope_prefix \\ "")
  def chat_root(nil), do: "/studio/chat"
  def chat_root(scope_prefix) when is_binary(scope_prefix), do: scope_prefix <> "/studio/chat"

  @doc """
  Standalone paper reader URL — `scope_prefix` + `/papers/:slug`.
  """
  def paper_path(scope_prefix, slug), do: (scope_prefix || "") <> "/papers/#{slug}"

  @doc false
  def append_desk_query(path, opts) do
    case Keyword.get(opts, :desk) do
      nil -> path
      "" -> path
      desk -> path <> "?desk=" <> URI.encode_www_form(to_string(desk))
    end
  end

  # Render-side helper — the chip href shows the URL the user would
  # land on if they clicked. (The actual navigation goes through
  # `phx-click="select-desk"` → `push_patch`, so JS isn't required;
  # the href makes the chip bookmarkable + middle-clickable.)
  @doc false
  def desk_chip_href(scope_prefix, nav_path, dataset, desk) do
    (scope_prefix || "") <> studio_path_for(nav_path, dataset, desk: desk)
  end

  # Canonicalise a plugin `:plugin_link` href against the current scope.
  # Structure/PaneBuilder emit them in the legacy FLAT shape
  # `/studio/<ds>[/...]` — Structure has no scope knowledge, so the rewrite
  # happens at SOURCE, in `PaneBuilder.list_items`, where `scope_prefix` is
  # threaded in. On the scoped surface the flat shape would ride the
  # flat→scoped 302 funnel, which re-resolves the workspace from the
  # SESSION and can teleport the user out of the workspace they're on, so
  # rewrite to the `/d/` canonical instead. Empty prefix keeps the flat path
  # for callers without a canonical scope. The plugins-admin LV is scoped at
  # `/w/:ws/p/:proj/d/:dataset/studio/_plugins`; its legacy
  # `/studio/:dataset/_plugins` URL is only a 302 compatibility entry. This
  # empty-prefix branch mirrors
  # `StudioComponents.Nav.default_top_menu_entries/4`. Non-`/studio` hrefs
  # (e.g. a plugin's `/admin/...` console) pass through untouched.
  @doc false
  def plugin_link_href("", href), do: href

  def plugin_link_href(scope_prefix, "/studio/" <> rest) when is_binary(scope_prefix) do
    case String.split(rest, "/", parts: 2) do
      [ds, suffix] -> "#{scope_prefix}/d/#{ds}/studio/#{suffix}"
      [ds] -> "#{scope_prefix}/d/#{ds}/studio"
    end
  end

  def plugin_link_href(_scope_prefix, href), do: href
end
