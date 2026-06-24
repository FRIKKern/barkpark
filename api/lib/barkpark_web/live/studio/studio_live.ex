defmodule BarkparkWeb.Studio.StudioLive do
  @moduledoc """
  Multi-pane studio — mirrors the TUI's pane drill-down.
  Structure → Type → Documents → Editor

  ## Structure (post god-module decomposition)

  This module is the LiveView SHELL: `mount/3`, `handle_params/3`, `render/1`,
  and the THIN `handle_event/3` + `handle_info/2` routing heads (Phoenix
  dispatch). Each clause delegates its body to a per-domain handler under
  `StudioLive.Handlers.*`; the state-coupled helpers those handlers share live
  in `StudioLive.Shared`. The pure path/parse helpers stay here as public,
  test-facing delegations to `StudioLive.Path`.

  Handler domains (`StudioLive.Handlers.*`):

  - `Lifecycle` — handle_info/2 + `finish_handle_params/6`
  - `Scope` — pane nav, workspace/project/dataset switch, switcher create
  - `Fields` — new/save/autosave, editor toggles, ArrayField ops
  - `Media` — image picker + upload · `Refs` — reference picker
  - `History` — revision panel + restore + profile · `Delete` · `Discard`
  - `Doc` — publish/unpublish (blast-radius) + duplicate
  - `Shares` — network shares panel · `ItemShare` — per-doc share popover
  - `Schema` — schema-declared modal actions · `Secondary` — read-only 2nd pane
  - `Bulk` — list-pane multi-select publish · `Paper` — in-Studio block editor
  """
  use BarkparkWeb, :live_view

  alias BarkparkWeb.Studio.StudioLive.{Mount, Path, Shared}

  alias BarkparkWeb.Studio.StudioLive.Handlers.{
    Bulk,
    Delete,
    Discard,
    Doc,
    Fields,
    History,
    ItemShare,
    Lifecycle,
    Media,
    Paper,
    Refs,
    Schema,
    Scope,
    Secondary,
    Shares
  }

  # The in-Studio paper view + Studio shell function components live in
  # StudioLive.Components; importing it makes the `<.studio_paper_view ...>` /
  # `<.studio_live_shell ...>` call sites in render/1 resolve verbatim. The Beta
  # paper-editor cluster (paper_block_editor, editor_mode_toggle,
  # properties_panel, paper_block_fields) lives in Components.PaperEditor, which
  # Components itself imports — those components are rendered only from inside
  # Components' templates, so StudioLive does not import PaperEditor directly.
  import BarkparkWeb.Studio.StudioLive.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Mount.init(socket)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    dataset = params["dataset"] || default_dataset()
    path = Map.get(params, "path", [])
    desk = params["desk"]

    socket = Shared.ensure_tenancy_scope(socket)

    case Shared.redirect_dataset_leaf(socket, dataset) do
      {:redirect, slug} ->
        {:noreply, push_patch(socket, to: Shared.studio_path(socket, path, slug, desk: desk))}

      :ok ->
        Lifecycle.finish_handle_params(socket, dataset, path, desk, uri, params)
    end
  end

  # ── handle_info/2 routing heads ─────────────────────────────────────────────

  @impl true
  def handle_info({:doc_updated, msg}, socket), do: Lifecycle.doc_updated(msg, socket)
  def handle_info({:paper_block, frame}, socket), do: Lifecycle.paper_block(frame, socket)
  def handle_info({:paper_updated, msg}, socket), do: Lifecycle.paper_updated(msg, socket)
  def handle_info({:sheets_op, payload}, socket), do: Lifecycle.sheets_op(payload, socket)

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket),
    do: Lifecycle.presence_diff(topic, socket)

  def handle_info({:document_changed, msg}, socket), do: Lifecycle.document_changed(msg, socket)
  def handle_info({:autosave_form, form}, socket), do: Lifecycle.autosave_form(form, socket)
  def handle_info({:paper_op, %{"op" => _} = op}, socket), do: Lifecycle.paper_op(op, socket)

  def handle_info({:tree_codelist_change, msg}, socket),
    do: Lifecycle.tree_codelist_change(msg, socket)

  # ── handle_event/3 routing heads ────────────────────────────────────────────

  @impl true
  def handle_event("select", params, socket), do: Scope.select(params, socket)
  def handle_event("select-group", params, socket), do: Scope.select_group(params, socket)
  def handle_event("select-desk", params, socket), do: Scope.select_desk(params, socket)
  def handle_event("switch-workspace", params, socket), do: Scope.switch_workspace(params, socket)
  def handle_event("switch-project", params, socket), do: Scope.switch_project(params, socket)
  def handle_event("switch-dataset", params, socket), do: Scope.switch_dataset(params, socket)
  def handle_event("toggle-create", params, socket), do: Scope.toggle_create(params, socket)
  def handle_event("create-workspace", params, socket), do: Scope.create_workspace(params, socket)
  def handle_event("create-project", params, socket), do: Scope.create_project(params, socket)
  def handle_event("expand-pane", params, socket), do: Scope.expand_pane(params, socket)

  def handle_event("new-document", params, socket), do: Fields.new_document(params, socket)
  def handle_event("save", params, socket), do: Fields.save(params, socket)
  def handle_event("slug-generate", params, socket), do: Fields.slug_generate(params, socket)
  def handle_event("autosave", params, socket), do: Fields.autosave(params, socket)

  def handle_event("toggle-content-preview", _params, socket),
    do: Fields.toggle_content_preview(socket)

  def handle_event("toggle-diff", _params, socket), do: Fields.toggle_diff(socket)
  def handle_event("editor-set-mode", params, socket), do: Fields.editor_set_mode(params, socket)
  def handle_event("array_op", params, socket), do: Fields.array_op(params, socket)

  def handle_event("open-image-picker", params, socket),
    do: Media.open_image_picker(params, socket)

  def handle_event("close-image-picker", _params, socket), do: Media.close_image_picker(socket)
  def handle_event("select-media", params, socket), do: Media.select_media(params, socket)
  def handle_event("clear-image", params, socket), do: Media.clear_image(params, socket)
  def handle_event("validate-upload", _params, socket), do: Media.validate_upload(socket)
  def handle_event("upload-image", params, socket), do: Media.upload_image(params, socket)

  def handle_event("open-ref-picker", params, socket), do: Refs.open_ref_picker(params, socket)
  def handle_event("close-ref-picker", _params, socket), do: Refs.close_ref_picker(socket)
  def handle_event("ref-search", params, socket), do: Refs.ref_search(params, socket)
  def handle_event("select-ref", params, socket), do: Refs.select_ref(params, socket)
  def handle_event("clear-ref", params, socket), do: Refs.clear_ref(params, socket)

  def handle_event("show-history", _params, socket), do: History.show_history(socket)
  def handle_event("close-history", _params, socket), do: History.close_history(socket)

  def handle_event("restore-revision", params, socket),
    do: History.restore_revision(params, socket)

  def handle_event("show-profile", _params, socket), do: History.show_profile(socket)
  def handle_event("close-profile", _params, socket), do: History.close_profile(socket)
  def handle_event("preview-profile", params, socket), do: History.preview_profile(params, socket)
  def handle_event("save-profile", params, socket), do: History.save_profile(params, socket)

  def handle_event("delete-doc", _params, socket), do: Delete.delete_doc(socket)
  def handle_event("close-delete", _params, socket), do: Delete.close_delete(socket)
  def handle_event("confirm-delete", params, socket), do: Delete.confirm_delete(params, socket)

  def handle_event("discard-draft", _params, socket), do: Discard.discard_draft(socket)
  def handle_event("close-discard", _params, socket), do: Discard.close_discard(socket)
  def handle_event("confirm-discard", _params, socket), do: Discard.confirm_discard(socket)

  def handle_event("publish", _params, socket), do: Doc.publish(socket)
  def handle_event("unpublish", _params, socket), do: Doc.unpublish(socket)

  def handle_event("close-unpublish-guard", _params, socket),
    do: Doc.close_unpublish_guard(socket)

  def handle_event("confirm-unpublish", params, socket), do: Doc.confirm_unpublish(params, socket)
  def handle_event("duplicate-doc", _params, socket), do: Doc.duplicate_doc(socket)

  def handle_event("shares-open", params, socket), do: Shares.shares_open(params, socket)
  def handle_event("shares-close", _params, socket), do: Shares.shares_close(socket)
  def handle_event("shares-add", params, socket), do: Shares.shares_add(params, socket)
  def handle_event("shares-remove", params, socket), do: Shares.shares_remove(params, socket)

  def handle_event("item-share-open", params, socket),
    do: ItemShare.item_share_open(params, socket)

  def handle_event("item-share-close", _params, socket), do: ItemShare.item_share_close(socket)

  def handle_event("item-share-create", params, socket),
    do: ItemShare.item_share_create(params, socket)

  def handle_event("item-share-revoke", params, socket),
    do: ItemShare.item_share_revoke(params, socket)

  def handle_event("jump-to-user", params, socket), do: ItemShare.jump_to_user(params, socket)

  def handle_event("open-secondary-picker", _params, socket),
    do: Secondary.open_secondary_picker(socket)

  def handle_event("view-graph", _params, socket), do: Secondary.view_graph(socket)

  def handle_event("close-secondary-picker", _params, socket),
    do: Secondary.close_secondary_picker(socket)

  def handle_event("secondary-search", params, socket),
    do: Secondary.secondary_search(params, socket)

  def handle_event("select-secondary", params, socket),
    do: Secondary.select_secondary(params, socket)

  def handle_event("close-secondary", _params, socket), do: Secondary.close_secondary(socket)

  def handle_event("toggle-doc-checkbox", params, socket),
    do: Bulk.toggle_doc_checkbox(params, socket)

  def handle_event("bulk-clear", _params, socket), do: Bulk.bulk_clear(socket)
  def handle_event("bulk-publish", _params, socket), do: Bulk.bulk_publish(socket)
  def handle_event("bulk-unpublish", _params, socket), do: Bulk.bulk_unpublish(socket)

  def handle_event("schema_action", params, socket), do: Schema.schema_action(params, socket)
  def handle_event("close-confirm-modal", _params, socket), do: Schema.close_confirm_modal(socket)

  def handle_event("confirm-modal-dryrun", _params, socket),
    do: Schema.confirm_modal_dryrun(socket)

  def handle_event("confirm-modal-real", _params, socket), do: Schema.confirm_modal_real(socket)

  def handle_event("paper-toggle-edit", _params, socket), do: Paper.paper_toggle_edit(socket)
  def handle_event("paper-edit-block", params, socket), do: Paper.paper_edit_block(params, socket)

  def handle_event("paper-block-autosave", params, socket),
    do: Paper.paper_block_autosave(params, socket)

  def handle_event("backlinks-toggle", _params, socket), do: Paper.backlinks_toggle(socket)
  def handle_event("backlinks-refresh", _params, socket), do: Paper.backlinks_refresh(socket)
  def handle_event("open-backlink", params, socket), do: Paper.open_backlink(params, socket)

  def handle_event("paper-op", %{"op" => _} = op, socket), do: Paper.paper_op(op, socket)
  def handle_event("paper-add-block", params, socket), do: Paper.paper_add_block(params, socket)

  def handle_event("paper-slash-insert", params, socket),
    do: Paper.paper_slash_insert(params, socket)

  def handle_event("paper-add-property", params, socket),
    do: Paper.paper_add_property(params, socket)

  def handle_event("paper-unbind-property", params, socket),
    do: Paper.paper_unbind_property(params, socket)

  def handle_event("paper-delete-block", params, socket),
    do: Paper.paper_delete_block(params, socket)

  def handle_event("paper-move-block", params, socket), do: Paper.paper_move_block(params, socket)

  def handle_event("paper-move-block-to", params, socket),
    do: Paper.paper_move_block_to(params, socket)

  def handle_event("paper-callout-fold", params, socket),
    do: Paper.paper_callout_fold(params, socket)

  # ── Public, test-facing path/parse delegations (StudioLive.Path) ────────────

  @doc false
  defdelegate parse_path(path), to: Path

  @doc false
  def find_field_by_path(socket, path) do
    fields =
      case socket.assigns[:editor_schema] do
        %{fields: list} when is_list(list) -> list
        _ -> []
      end

    Path.field_at(fields, path)
  end

  @doc false
  defdelegate list_value_at(form, path), to: Path

  @doc false
  defdelegate put_value_at(form, path, value), to: Path

  @doc false
  defdelegate empty_for_of(field), to: Path

  # The default dataset for a bare `/studio` mount. Resolved through Content so
  # the literal isn't hardcoded at call sites.
  def default_dataset, do: Barkpark.Content.default_dataset()

  # ── Render ─────────────────────────────────────────────────────────────────
  # The full Studio shell template lives in StudioLive.Components.studio_shell/1
  # (imported above); render/1 stays here as the LiveView callback and hands the
  # assigns straight through.
  @impl true
  def render(assigns), do: studio_live_shell(assigns)
end
