defmodule BarkparkWeb.Studio.StudioLive.Paths do
  @moduledoc """
  Pure Studio URL builders extracted from `BarkparkWeb.Studio.StudioLive`.
  `studio_path_for/3` contributes the `/d/:dataset/studio[/...]` suffix;
  `desk_chip_href/4` and `scoped_plugin_href/2` compose the scoped/flat hrefs
  the render template emits. No socket — the socket-aware `studio_path/4`
  choke point stays in StudioLive and prefixes `scope_prefix` before calling
  `studio_path_for/3`.
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

  # Render-side scoping for `:plugin_link` hrefs. Structure/PaneBuilder emit
  # them in the legacy FLAT shape `/studio/<ds>[/...]` — Structure has no
  # scope knowledge, so the rewrite happens here, where `@scope_prefix` is
  # in hand. On the scoped surface the flat shape would ride the
  # flat→scoped 302 funnel, which re-resolves the workspace from the
  # SESSION and can teleport the user out of the workspace they're on, so
  # rewrite to the /d/ canonical instead. Empty prefix (flat surfaces, e.g.
  # the /studio/:dataset/_plugins admin LV) keeps the flat path — mirrors
  # the branch in StudioComponents.default_top_menu_entries/2.
  @doc false
  def scoped_plugin_href("", href), do: href

  def scoped_plugin_href(scope_prefix, "/studio/" <> rest) when is_binary(scope_prefix) do
    case String.split(rest, "/", parts: 2) do
      [ds, suffix] -> "#{scope_prefix}/d/#{ds}/studio/#{suffix}"
      [ds] -> "#{scope_prefix}/d/#{ds}/studio"
    end
  end

  def scoped_plugin_href(_scope_prefix, href), do: href
end
