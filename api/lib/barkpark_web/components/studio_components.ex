defmodule BarkparkWeb.StudioComponents do
  @moduledoc """
  Reusable components for the Barkpark Studio.

  This module is a thin **facade**. The component implementations live in
  family sub-modules under `studio_components/`:

    * `BarkparkWeb.StudioComponents.Panes`  — pane layout + doc-list rows
    * `BarkparkWeb.StudioComponents.Nav`    — chrome, tabs, topbar, shell
    * `BarkparkWeb.StudioComponents.Modals` — pickers + confirmation modals
    * `BarkparkWeb.StudioComponents.Editor` — editor shell, fields, actions
    * `BarkparkWeb.StudioComponents.EditorFields` — bulk/secondary/presence chrome

  Every public component is re-exported here via `defdelegate`, so the
  global `import BarkparkWeb.StudioComponents` (in `barkpark_web.ex`)
  keeps bringing every `<.component>` into scope unchanged, and the
  module-qualified call sites (`StudioComponents.schema_groups/1` etc.)
  resolve identically. Attr/slot compile-time validation lives in the
  sub-modules where the components are defined.
  """
  use Phoenix.Component

  alias BarkparkWeb.StudioComponents.{Panes, Nav, Modals, Editor, EditorFields}

  # ── Panes ───────────────────────────────────────────────────────────
  defdelegate status_badge(assigns), to: Panes
  defdelegate pane_layout(assigns), to: Panes
  defdelegate pane_column(assigns), to: Panes
  defdelegate document_preview(assigns), to: Panes
  defdelegate pane_empty(assigns), to: Panes
  defdelegate pane_section_header(assigns), to: Panes
  defdelegate pane_divider(assigns), to: Panes
  defdelegate pane_item(assigns), to: Panes
  defdelegate pane_doc_item(assigns), to: Panes

  # ── Nav / chrome ────────────────────────────────────────────────────
  defdelegate studio_flash(assigns), to: Nav
  defdelegate studio_signout_button(assigns), to: Nav
  defdelegate studio_theme_toggle(assigns), to: Nav
  defdelegate studio_tabs(assigns), to: Nav
  defdelegate plugin_tab_active?(tab, current_path), to: Nav
  defdelegate studio_topbar(assigns), to: Nav
  defdelegate studio_shell(assigns), to: Nav

  # ── Modals ──────────────────────────────────────────────────────────
  defdelegate image_picker_modal(assigns), to: Modals
  defdelegate shares_modal(assigns), to: Modals
  defdelegate item_share_popover(assigns), to: Modals
  defdelegate ref_picker_modal(assigns), to: Modals
  defdelegate history_modal(assigns), to: Modals
  defdelegate delete_modal(assigns), to: Modals
  defdelegate discard_modal(assigns), to: Modals
  defdelegate profile_modal(assigns), to: Modals
  defdelegate studio_modals(assigns), to: Modals

  # ── Editor ──────────────────────────────────────────────────────────
  defdelegate document_header(assigns), to: Editor
  defdelegate editor_field(assigns), to: Editor
  defdelegate onix_element(field), to: Editor
  defdelegate empty_editor(assigns), to: Editor
  defdelegate studio_field_renderer(assigns), to: Editor
  defdelegate studio_editor_shell(assigns), to: Editor
  defdelegate doc_action_button(assigns), to: Editor
  defdelegate cross_violations_banner(assigns), to: Editor
  defdelegate schema_groups(schema), to: Editor
  defdelegate visible_fields(fields, group_name), to: Editor
  defdelegate bulk_action_bar(assigns), to: EditorFields
  defdelegate secondary_editor_card(assigns), to: EditorFields
  defdelegate secondary_picker_modal(assigns), to: EditorFields
  defdelegate presence_nav(assigns), to: EditorFields
end
