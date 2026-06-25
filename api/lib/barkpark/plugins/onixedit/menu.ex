defmodule Barkpark.Plugins.OnixEdit.Menu do
  @moduledoc """
  Studio navigation surfaces OnixEdit contributes — the top-menu tab and
  the Structure-pane desk items. Grouped here because both describe where
  "Bokbasen" appears in the Studio chrome and both point at the staleness
  console.

  Extracted verbatim from `Barkpark.Plugins.OnixEdit.top_menu_entries/0`
  and `desk_items/1` behind the plugin facade — the callbacks delegate to
  `top_menu_entries/0` and `desk_items/1` here. The returned lists are
  byte-identical to before.
  """

  @doc """
  Plugin-contributed top-menu tab — surfaces "Bokbasen" in the Studio
  topbar next to Structure / Media / API. Points at the existing
  staleness console which lives at `/admin/onixedit/staleness` (the
  console is admin-gated; the tab is rendered to everyone but the
  route enforces). Active for any path that begins with
  `/admin/onixedit/`.

  Returned unchanged from the former `OnixEdit.top_menu_entries/0` body.
  """
  @spec top_menu_entries() :: [map()]
  def top_menu_entries do
    [
      %{
        label: "Bokbasen",
        path: "/admin/onixedit/staleness",
        icon: "send",
        order: 50,
        active_when: "/admin/onixedit/"
      }
    ]
  end

  @doc """
  Plugin-contributed desk items — appended after the host's auto-
  generated schema items in the root Structure pane. Two entries:

    * A divider labelled "Bokbasen" that visually anchors the group.
    * A `:link` row that jumps to the staleness console.

  `:document_list` / `:nested` shapes are accepted by the host
  PaneBuilder (see `BarkparkWeb.Studio.PaneBuilder`) but OnixEdit
  v1 only contributes the simpler two — the `book` schema already
  appears via the standard schema-discovery path, and adding extra
  pre-filtered views from the plugin side would duplicate it.

  Returned unchanged from the former `OnixEdit.desk_items/1` body (which
  ignored its `dataset` arg).
  """
  @spec desk_items(String.t()) :: [map()]
  def desk_items(_dataset) do
    # `requires_schema: "book"` gates these on the ONIX `book` type being
    # registered in the (workspace-scoped) desk — Bokbasen publishing is
    # meaningless without book documents, so a workspace that never registered
    # the book schema gets neither the divider nor the staleness link. The host
    # honours the tag in `Barkpark.Structure.scope_plugin_nodes/4`; an unscoped
    # (Default) desk ignores it, preserving prior behaviour.
    [
      %{type: :divider, label: "Bokbasen", requires_schema: "book"},
      %{
        type: :link,
        label: "Pending submissions",
        path: "/admin/onixedit/staleness",
        icon: "clock",
        requires_schema: "book"
      }
    ]
  end
end
