defmodule BarkparkWeb.StudioComponents.Editor do
  @moduledoc """
  Studio editor-pane **core** — the document header, field wrappers and
  renderer, the editor shell, doc-action buttons, cross-field validation
  banner, and schema-group helpers. The secondary chrome (bulk action
  bar, secondary-pane card + picker, presence-nav overlay) lives in the
  sibling `BarkparkWeb.StudioComponents.EditorFields`. Extracted from the
  former monolithic `BarkparkWeb.StudioComponents`; both halves are
  re-exported there as a thin facade so every call site keeps working
  unchanged.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  import BarkparkWeb.Icons

  alias BarkparkWeb.Components.FieldInputs
  alias BarkparkWeb.Components.Fields.Visibility
  alias BarkparkWeb.Studio.Plugins.Adapter, as: PluginAdapter

  @doc """
  Sanity-style document chrome header for the editor pane. Emits the
  legacy `<div class="pane-header editor-header">` markup so it can
  replace StudioLive's former hand-rolled header byte-identically
  (it is emitted from `studio_editor_shell/1` today). The component was originally also consumed by the
  plugin BookView / BookEditor LVs (removed in Goal `barkpark-zdy`);
  StudioLive is the sole caller today. The corresponding CSS lives in
  `root.html.heex` (hoisted from StudioLive's inline `<style>`).

  Attributes:
    * `:dataset`   — (required) string, current dataset name. Carried
                     so callers can compose other links if needed.
    * `:title`     — (required) document title text.
    * `:back_href` — (optional) when present, render a `←` arrow link
                     before the status pill (used by plugin LVs;
                     StudioLive omits this).

  Slots:
    * `:status_pill` — small badge rendered before the title (e.g.
                       Draft/Published). Matches the legacy badge
                       slot order in `editor-header`.
    * `:presence`    — presence-dot block rendered after the title
                       (StudioLive only — plugin LVs leave empty).
    * `:meta`        — extra inline meta tokens (e.g. _id, _type,
                       timestamps). Rendered as a small muted row at
                       the end of the left flex container; empty for
                       StudioLive (no rendered output) so byte-identity
                       holds.
    * `:actions`     — top-right action buttons (History/Delete/
                       Publish in StudioLive; previously Bokbasen/
                       ONIX export and Open-in-editor in the removed
                       plugin LVs). Slot contents render verbatim —
                       preserve any `data-test-id` attributes.
  """
  attr :dataset, :string, required: true
  attr :title, :string, required: true
  attr :back_href, :string, default: nil
  # spd-bl-focus-after-select — when true, this header is the focus target
  # for the navigation that just opened the document: at narrow/phone a
  # Structure-row select DESTROYS the clicked row (strip/hidden), so focus
  # falls to <body> unless the opened document itself catches it. Same
  # tabindex="-1" + phx-mounted={JS.focus()} idiom pane_column/1 pins for
  # expand-pane (absent by default, so an initial load never steals focus).
  attr :focus_on_mount, :boolean, default: false

  slot :status_pill
  slot :presence
  slot :meta
  slot :actions

  def document_header(assigns) do
    ~H"""
    <div
      class="pane-header editor-header"
      tabindex={@focus_on_mount && "-1"}
      phx-mounted={@focus_on_mount && JS.focus()}
    >
      <%!-- spd-b35: `min-width: 0` + `max-width: 70%` are LOAD-BEARING, not
            cosmetics. Without them this group's flex base size is its
            max-content width (the title is `white-space: nowrap`, so its own
            `min-width: auto` floor is the WHOLE string) while the actions group
            below has `flex-basis: 0`. Once the title alone exceeds the header,
            free space goes negative and the shrink phase distributes by
            flex-shrink x flex-basis — the actions' scaled shrink factor is
            1 x 0 = 0, so the title keeps every pixel and the action bar
            resolves to a ZERO-WIDTH box. Its buttons then still have
            non-empty layout boxes (clipped by `bp-overflow-menu`'s
            `overflow: hidden`, spilled leftwards by `justify-content:
            flex-end`) sitting on top of the title and the presence dots, so
            every real-mouse click on a doc action hit-tests to
            `.pane-header-title` or `.presence-dot` instead. Capping this group
            keeps the leftover space positive, so the actions always get a
            real, content-independent width and the title ellipsises instead.
            Measured before/after in Chrome across {short,long} title x
            {0,1,3} dots x {1400,1280,760,520,360,260}px: 22/36 -> 36/36. --%>
      <div style="display: flex; align-items: center; gap: 8px; min-width: 0; max-width: 70%;">
        <%= if @back_href do %>
          <a href={@back_href} class="btn btn-ghost btn-sm" aria-label="Back to Studio">&larr;</a>
        <% end %>
        <%= render_slot(@status_pill) %>
        <span class="pane-header-title"><%= @title %></span>
        <%= render_slot(@presence) %>
        <%= if @meta != [] do %>
          <div class="editor-header-meta" style="font-size: 11px; color: var(--fg-dim); display: flex; gap: 12px; flex-wrap: wrap; margin-left: 4px;">
            <%= render_slot(@meta) %>
          </div>
        <% end %>
      </div>
      <div style="display: flex; gap: 6px; min-width: 0; flex: 1; justify-content: flex-end;">
        <%= render_slot(@actions) %>
      </div>
    </div>
    """
  end

  @doc """
  Wrapper for a single field row in the editor body. Emits the legacy
  `<div class="editor-field">` markup with `<label class="editor-field-label">`
  containing the field title, optional `*` required indicator, and
  optional type pill. Used by StudioLive (line 1143 + 1159) and plugin
  LVs to keep field rhythm consistent. CSS in `root.html.heex`.

  Attributes:
    * `:label`    — (required) field label text.
    * `:type`     — (optional) field type tag (e.g. "string", "image");
                     when set renders the small `editor-field-type`
                     pill next to the label.
    * `:required` — (optional, default false) renders a `*` indicator.
    * `:errors`   — (optional, default []) list of error strings; when
                     non-empty adds the `has-error` class and renders a
                     `<div class="field-errors">` below the input.

  Default slot: the input/control itself.
  """
  attr :label, :string, required: true
  attr :type, :string, default: nil
  attr :required, :boolean, default: false
  attr :errors, :list, default: []
  attr :onix_element, :string, default: nil
  slot :inner_block, required: true

  def editor_field(assigns) do
    ~H"""
    <div class={"editor-field #{if @errors != [], do: "has-error"}"}>
      <label class="editor-field-label">
        <%= @label %>
        <%= if @required do %><span class="field-required">*</span><% end %>
        <%= if @type do %><span class="editor-field-type"><%= @type %></span><% end %>
      </label>
      <%= if @onix_element do %>
        <span class="bp-onix-hint" data-onix-element>
          ONIX: <code><%= @onix_element %></code>
        </span>
      <% end %>
      <%= render_slot(@inner_block) %>
      <%= if @errors != [] do %>
        <div class="field-errors"><%= Enum.join(@errors, ", ") %></div>
      <% end %>
    </div>
    """
  end

  @doc false
  # Extract the ONIX element name from a field. Handles both atom-keyed
  # `%Field{}` structs (post-adapter) and string-keyed raw maps (book.json
  # passthrough). Returns the element string, or nil if not present.
  def onix_element(%{onix: %{} = o}), do: Map.get(o, "element") || Map.get(o, :element)
  def onix_element(%{"onix" => %{} = o}), do: Map.get(o, "element") || Map.get(o, :element)
  def onix_element(_), do: nil

  @doc """
  Centered placeholder for the editor pane when no document is loaded
  or loading failed. Emits the legacy `<div class="editor-empty">`
  markup. CSS in `root.html.heex`.

  Attributes:
    * `:message` — (required) primary message text.

  Optional `:icon` slot for a leading icon/glyph (e.g. `<.icon name="file-text">`).
  """
  attr :message, :string, required: true
  slot :icon

  def empty_editor(assigns) do
    ~H"""
    <div class="editor-empty">
      <div style="color: var(--fg-dim); text-align: center;">
        <%= if @icon != [] do %>
          <div style="margin-bottom: 12px; opacity: 0.4;"><%= render_slot(@icon) %></div>
        <% end %>
        <div class="text-sm"><%= @message %></div>
      </div>
    </div>
    """
  end

  # ── The third seam: a named document that does not resolve (spd-w19) ────────
  #
  # THE DISEASE, generalised past papers: when the desk walk cannot produce an
  # editor, the shell fell to `<.empty_editor message="Select a document to
  # edit">` — a shrug that reads identically whether the viewer selected
  # nothing, opened a deleted document, or drilled a type whose schema is not
  # installed. spd-w18 fixed the paper-body case (`unrenderable_document_notice/1`,
  # a document that RESOLVES and cannot render). This is its sibling arm: a
  # document that does not resolve at all.
  #
  # The four states are DERIVED from `(panes, nav_path)` by
  # `StudioLive.Shared.empty_editor_state/2`, because every nil-editor producer
  # in `PaneBuilder` returns a bare `nil` and is therefore indistinguishable at
  # the shell's attrs (charter D260). This component only renders what that
  # derivation named; it never re-derives and never guesses.
  #
  #   * `:not_found`        — the type is real, the id is not in this dataset.
  #   * `:no_schema`        — the id names a type with no installed schema.
  #   * `:unknown_node`     — the first path segment names no desk node at all.
  #   * `:nothing_selected` — nav_path is empty. The calm state, NOT an alert:
  #                           nothing went wrong, so nothing shouts.
  #
  # `unrenderable_content` is deliberately NOT a reason here — #7897's
  # `unrenderable_document_notice/1` owns that arm, at the resolved-document end.
  #
  # Shape copied from the one member of this family whose markup a test actually
  # pins (`unrenderable_document_notice/1`): `role="alert"` +
  # `aria-live="assertive"` + a stable `data-test-id` + the document's OWN id and
  # its REAL type + a plain-language reason + a named, focusable way out.
  #
  # THE FOCUS DESTINATION (charter D269) IS THE LANDMARK, NOT THE CONTROL.
  # D269 decided "the tabindex=-1 landmark", and the landmark is this notice's own
  # `role="alert"` container: `tabindex="-1"` sits there, so a later slice can
  # `.focus()` it and an assistive-tech user hears the WHOLE reason rather than
  # just the label of a button. It shipped on the primary recovery ANCHOR instead,
  # which was actively wrong twice over: an `<a href>` is ALREADY programmatically
  # focusable without any tabindex, so `-1` bought nothing there — and it REMOVES
  # the element from the tab order, which in the `:no_schema` and `:unknown_node`
  # arms (a single control apiece) left the only way out reachable by mouse only.
  # The recovery controls are therefore natively tabbable, in every arm.
  attr :reason, :atom, default: :nothing_selected
  attr :doc_id, :string, default: nil
  attr :doc_type, :string, default: nil
  # The type's own list URL — nil when no real type is known (`:unknown_node`),
  # in which case the primary control falls back to the desk root.
  attr :list_href, :string, default: nil
  attr :desk_href, :string, required: true
  # `:not_found` triage (Gyldendal 35c, `Shared.triage_not_found/2`): the CAUSE
  # the card names — `:absent` | `:elsewhere` | `:out_of_reach` | nil (untriaged,
  # renders as absent). Only `:elsewhere` may mention another workspace, and
  # then it NAMES it and links to the document there.
  attr :cause, :atom, default: nil
  attr :elsewhere_name, :string, default: nil
  attr :elsewhere_href, :string, default: nil
  attr :grant_scope, :string, default: nil

  def unresolved_document_notice(%{reason: :nothing_selected} = assigns) do
    ~H"""
    <div class="editor-empty" data-test-id="studio-editor-nothing-selected" data-reason="nothing_selected">
      <div style="color: var(--fg-dim); text-align: center;">
        <div style="margin-bottom: 12px; opacity: 0.4;"><.icon name="file-text" size={40} /></div>
        <div class="text-sm">No document is open. Pick one from the list to start editing.</div>
      </div>
    </div>
    """
  end

  def unresolved_document_notice(assigns) do
    ~H"""
    <div
      class="bp-paper-unrenderable"
      role="alert"
      aria-live="assertive"
      tabindex="-1"
      data-test-id="studio-unresolved-document-notice"
      data-reason={@reason}
      data-doc-id={@doc_id}
      data-doc-type={@doc_type}
      data-cause={@cause}
    >
      <p class="bp-paper-unrenderable-title">
        Studio could not open this document.
      </p>
      <p :if={@reason == :not_found and @cause == :elsewhere} class="bp-paper-unrenderable-reason">
        No <%= @doc_type %> with the id <code><%= @doc_id %></code> exists in this workspace —
        but a document with that id lives in the workspace <strong><%= @elsewhere_name %></strong>.
      </p>
      <p :if={@cause == :out_of_reach} class="bp-paper-unrenderable-reason">
        <%= if @reason == :unknown_node do %>The type <code><%= @doc_type %></code> exists in this dataset<% else %>A <%= @doc_type %> with the id <code><%= @doc_id %></code> exists in this dataset<% end %>, but your
        access grant does not cover it<%= if @grant_scope && @grant_scope != "" do %> (it covers <%= @grant_scope %>)<% end %>.
        Ask whoever shared access with you to widen the grant.
      </p>
      <p :if={@reason == :not_found and @cause not in [:elsewhere, :out_of_reach]} class="bp-paper-unrenderable-reason">
        No <%= @doc_type %> with the id <code><%= @doc_id %></code> exists in this dataset. It may
        have been deleted.
      </p>
      <p :if={@reason == :no_schema} class="bp-paper-unrenderable-reason">
        No schema for <code><%= @doc_type %></code> is installed in this dataset, so Studio has no
        fields to show its documents with<%= if @doc_id && @doc_id != @doc_type do %> (you asked for <code><%= @doc_id %></code>)<% end %>.
        Whatever is stored under that type is untouched.
      </p>
      <p :if={@reason == :unknown_node and @cause != :out_of_reach} class="bp-paper-unrenderable-reason">
        This desk has no section named <code><%= @doc_type %></code>, so the path could not be
        walked to a document<%= if @doc_id && @doc_id != @doc_type do %> (<code><%= @doc_id %></code>)<% end %>.
        The link may predate a structure change, or the plugin that owned it may be disabled.
      </p>
      <div class="bp-paper-unrenderable-actions">
        <a
          :if={@cause == :elsewhere and @elsewhere_href}
          href={@elsewhere_href}
          class="btn btn-primary btn-sm"
          data-test-id="studio-unresolved-open-elsewhere"
        >
          Open it in <%= @elsewhere_name %>
        </a>
        <a
          href={@list_href || @desk_href}
          class={["btn btn-sm", if(@cause == :elsewhere and @elsewhere_href, do: "btn-ghost", else: "btn-primary")]}
          data-test-id="studio-unresolved-recovery"
        >
          <%= if @list_href, do: "Back to the #{@doc_type} list", else: "Back to the desk" %>
        </a>
        <a
          :if={@list_href}
          href={@desk_href}
          class="btn btn-ghost btn-sm"
          data-test-id="studio-unresolved-back-to-desk"
        >
          Back to the desk
        </a>
      </div>
    </div>
    """
  end

  @doc """
  Renders one schema field row: the `<.editor_field>` wrapper plus the
  v1/v2 fork that dispatches to either `FieldInputs.input/1` (v1 leaf
  controls) or `PluginAdapter.render/2` (v2 composite/arrayOf/codelist/
  localizedText). Output is byte-identical to the field-row markup
  StudioLive formerly rendered inline; the live call site is now
  `studio_editor_shell/1`.

  The plain `<input type="text" name="doc[title]">` for the title row is
  NOT a schema field and stays inline inside `studio_editor_shell/1`.

  Attributes:
    * `:field`             — (required) one schema field map.
    * `:editor_form`       — (required) form state map keyed by field name.
    * `:dataset`           — (default `"production"`) plumbed to FieldInputs.
    * `:validation_errors` — (default `%{}`) keyed by field name; values are
                              error string lists.
    * `:parent_assigns`    — (default `%{}`) full parent LV assigns map,
                              required by `PluginAdapter.render/2` for v2
                              schema fields (OnixEdit `book` etc.).
  """
  attr :field, :map, required: true
  attr :editor_form, :map, required: true
  attr :dataset, :string, default: "production"
  attr :validation_errors, :map, default: %{}
  attr :parent_assigns, :map, default: %{}

  def studio_field_renderer(assigns) do
    ~H"""
    <% field_name = @field["name"] %>
    <% type = @field["type"] %>
    <% rules = @field["validation"] || %{} %>
    <% required? = rules["required"] == true %>
    <% errors = Map.get(@validation_errors, field_name, []) %>
    <%= if self_titled?(type) do %>
      <%!-- v2 structural types render their own <legend>; skip outer label,
           but keep error display + onix hint as inline rows below the field. --%>
      <div class={"editor-field editor-field-self-titled #{if errors != [], do: "has-error"}"}>
        <%= if PluginAdapter.v2?(@field) do %>
          <%= PluginAdapter.render(@parent_assigns, @field) %>
        <% else %>
          <FieldInputs.input
            field={@field}
            editor_form={@editor_form}
            dataset={@dataset}
            scope_prefix={Map.get(@parent_assigns, :scope_prefix, "")}
            api_token_raw={Map.get(@parent_assigns, :api_token_raw, "")}
            doc_key={editor_doc_key(@parent_assigns)}
          />
        <% end %>
        <%= if onix = onix_element(@field) do %>
          <span class="bp-onix-hint" data-onix-element>
            ONIX: <code><%= onix %></code>
          </span>
        <% end %>
        <%= if errors != [] do %>
          <div class="field-errors"><%= Enum.join(errors, ", ") %></div>
        <% end %>
      </div>
    <% else %>
      <.editor_field
        label={@field["title"] || field_name}
        type={type}
        required={required?}
        errors={errors}
        onix_element={onix_element(@field)}
      >
        <%= if PluginAdapter.v2?(@field) do %>
          <%= PluginAdapter.render(@parent_assigns, @field) %>
        <% else %>
          <FieldInputs.input
            field={@field}
            editor_form={@editor_form}
            dataset={@dataset}
            scope_prefix={Map.get(@parent_assigns, :scope_prefix, "")}
            api_token_raw={Map.get(@parent_assigns, :api_token_raw, "")}
            doc_key={editor_doc_key(@parent_assigns)}
          />
        <% end %>
      </.editor_field>
    <% end %>
    """
  end

  # The open document's id for keying per-field canvases (see FieldInputs
  # `doc_key`); "doc" when no document is open (a render without one).
  defp editor_doc_key(%{editor_doc: %{doc_id: id}}) when is_binary(id), do: id
  defp editor_doc_key(_), do: "doc"

  # v2 structural field types own their own title via <fieldset><legend>.
  # Routing them through `editor_field` would render the same title twice
  # — once in `<label class="editor-field-label">`, once in the legend.
  # See `barkpark-jwcb`.
  defp self_titled?(type), do: type in ~w(arrayOf composite localizedText)

  @doc """
  StudioLive editor column, extracted from StudioLive's former
  monolithic render; its live call site is now `studio_live_shell/1`.
  Renders the `<.document_header>` (Task #9) + form-with-fields when an
  `editor_doc` is loaded, or `<.empty_editor>` (Task #9) otherwise.
  Schema fields delegate to `<.studio_field_renderer>` (which itself
  wraps `FieldInputs.input/1` per Task #10 byte-identity contract).

  The TODO in `studio_live_shell/1` (hand-rolled editor column)
  is preserved verbatim — WI2 does NOT absorb that debt; it requires a
  `<.pane_column>` API change (design plan archived).

  Historical note: the plugin BookView / BookEditor LVs (removed in
  Goal `barkpark-zdy`) deliberately did NOT consume this component —
  their action sets diverged enough (Bokbasen pills, ONIX export,
  custom tab nav) that wrapping forced endless slots. They called
  `<.document_header>` directly. StudioLive is the only consumer today.

  Events bubble to StudioLive: save, autosave, show-history, delete-doc,
  publish, unpublish, plus the studio_field_renderer phx-click events
  (open-image-picker, clear-image). The reference field is now owned
  client-side by `<bp-reference-picker>` (Task #12 WI2) and bridges
  through autosave; open-ref-picker / clear-ref handlers in StudioLive
  are orphaned-but-harmless until v2 cleanup.

  Slots:
    * `:extra_actions` — (optional) appended after Publish/Unpublish.
                          Currently unused; documented for plugin LVs.
    * `:empty_state`   — (optional) overrides the default
                          `<.empty_editor message="Select a document …">`.
  """
  attr :editor_doc, :map, default: nil
  attr :editor_schema, :map, default: nil
  attr :editor_type, :string, default: nil
  attr :editor_form, :map, required: true
  attr :editor_is_draft, :boolean, default: false
  attr :dataset, :string, required: true
  attr :validation_errors, :map, default: %{}
  attr :save_status, :string, default: ""

  # ── Concurrent-edit conflict (studio-concurrent-edit) ──────────────
  # True when a remote save of the open doc arrived while the local form
  # buffer held unsaved edits. Renders a "reload?" banner above the form
  # instead of silently overwriting the buffer; the button posts
  # "reload-remote-doc", which reloads the doc from the DB.
  attr :doc_conflict, :boolean, default: false

  # ── Server-owned save halt mirror (p-hollow-studio-mirror) ─────────
  # The verbatim reason string from a `{:error, {:halted, reason}}` write
  # veto (a plugin lifecycle gate — M1 template violation today, the
  # hollow-doc quality gate tomorrow). `nil` → banner not rendered. The
  # editor MIRRORS this server truth; it never authors the copy or owns
  # the gate (charter D5/D6).
  attr :paper_halt, :string, default: nil
  attr :presences, :list, default: []
  attr :parent_assigns, :map, default: %{}
  attr :nav_group, :string, default: nil

  # ── Cross-field validations (Task barkpark-cgn) ────────────────────
  # List of unsatisfied rule maps (string-keyed: name, title, level,
  # fields). Empty list → banner not rendered, no visual cost on
  # schemas that declare no rules.
  attr :cross_violations, :list, default: []
  # ── Content preview side-pane (Goal barkpark-G1, task s3) ──────────
  # Doc-type-agnostic. Parent passes pre-rendered iodata + a soft
  # toggle. The pane is rendered iff `content_preview_rendered != nil`
  # AND the toggle is on — there is NO hardcoded doc-type gate.
  attr :content_preview_rendered, :any, default: nil
  attr :content_preview_visible, :boolean, default: true

  # ── Draft-vs-Published diff view (Task barkpark-uix) ───────────────
  # `diff_visible` flips the editor body between the form and the
  # field-level diff. `published_doc` is the published twin of the open
  # draft (nil when no draft is open, or when the draft has no
  # published counterpart). The toggle button is gated on both
  # editor_is_draft AND a non-nil published_doc — i.e. exactly the
  # case where a meaningful diff exists.
  attr :diff_visible, :boolean, default: false
  attr :published_doc, :map, default: nil

  # ── Editor-header doc actions (Goal barkpark-cjs, s4) ──────────────────
  # List of resolved doc-action maps from
  # `StudioLive.resolved_doc_actions/1`. Each entry is a string-keyed map
  # matching the `Barkpark.Plugin.doc_action` typespec — `"name"`,
  # `"label"`, `"kind"` (`"event"` | `"modal"` | `"link"`), `"scope"`
  # (`"editor_header"` | `"overflow"`), and an `"opts"` map carrying
  # per-kind payload (the phx-click event for `"event"`, an href template
  # for `"link"`, a modal payload for `"modal"`). When empty (e.g. legacy
  # callers that haven't been migrated yet), the editor header renders no
  # action buttons — the action bar should be considered authoritative.
  attr :doc_actions, :list, default: []

  # spd-bl-focus-after-select — threaded through to document_header above.
  attr :focus_on_mount, :boolean, default: false

  slot :extra_actions
  slot :empty_state

  def studio_editor_shell(assigns) do
    show_diff_toggle =
      assigns.editor_doc != nil and assigns.editor_is_draft and
        assigns.published_doc != nil

    assigns =
      assigns
      |> assign(
        :show_content_preview,
        assigns.content_preview_rendered != nil and assigns.content_preview_visible and
          not (assigns.diff_visible and show_diff_toggle)
      )
      |> assign(:show_diff_toggle, show_diff_toggle)
      |> assign(:show_diff, show_diff_toggle and assigns.diff_visible)

    ~H"""
    <%= if @editor_doc do %>
      <div class="editor-panel" data-role="content">
        <.document_header
          dataset={@dataset}
          title={@editor_doc.title || "Untitled"}
          focus_on_mount={@focus_on_mount}
        >
          <:status_pill>
            <span class={"badge badge-#{if @editor_is_draft, do: "draft", else: @editor_doc.status}"}>
              <%= if @editor_is_draft, do: "draft", else: @editor_doc.status %>
            </span>
          </:status_pill>
          <:presence>
            <% doc_presences = presences_on_doc(@presences, Barkpark.Content.published_id(@editor_doc.doc_id), @dataset) %>
            <%= if doc_presences != [] do %>
              <%!-- spd-b35: the indicator is DECORATION — it has no click
                    handler and `cursor: default`, so it must never be a
                    pointer target. `.presence-dots` is `pointer-events: none`
                    in root.html.heex; the per-dot `title=` tooltip that used
                    to carry the editor's name went with it. It was mouse-only
                    anyway (a 10px hover target, invisible to keyboard and
                    touch), so the name now rides `role="img"` +
                    `aria-label` on the group, which every input mode can
                    reach. The richer hover/inspection affordance still lives
                    on `.presence-nav` in the studio bar (`.presence-tooltip`),
                    which this change does not touch. --%>
              <div class="presence-dots" role="img" aria-label={presence_dots_label(doc_presences)}>
                <%= for p <- doc_presences do %>
                  <div class="presence-dot" style={"background: #{p.color}"}></div>
                <% end %>
              </div>
            <% end %>
          </:presence>
          <:actions>
            <bp-overflow-menu class="bp-overflow-menu">
              <%= for action <- @doc_actions do %>
                <.doc_action_button
                  action={action}
                  editor_doc={@editor_doc}
                  dataset={@dataset}
                  workspace_slug={scope_slug(@parent_assigns, :current_workspace)}
                  project_slug={scope_slug(@parent_assigns, :current_project)}
                />
              <% end %>
              <%= render_slot(@extra_actions) %>
            </bp-overflow-menu>
          </:actions>
        </.document_header>

        <div class={"editor-with-preview " <> if(@show_content_preview, do: "has-onix-preview", else: "")}>
        <div class="editor-body editor-panel-main">
          <%= if @editor_schema do %>
            <div class="editor-meta">
              <%!-- A schema's `:icon` is workspace DATA and nullable, so it gets
                    the same `drawable_icon/1` guard `tab_icon/1` and
                    `doc_action_glyph/1` already use. Unguarded, an iconless
                    schema 500'd the WHOLE Studio editor for every document of
                    that type — the largest of the three spd-w18-nil-icon-500
                    crash sites. --%>
              <.icon name={drawable_icon(@editor_schema.icon) || "file"} size={14} /> <%= @editor_schema.title %> &middot; <%= length(@editor_schema.fields) %> fields
            </div>
          <% end %>

          <.cross_violations_banner violations={@cross_violations} />
          <.doc_conflict_banner conflict={@doc_conflict} />
          <.paper_halt_banner reason={@paper_halt} />

          <%= if @show_diff do %>
            <BarkparkWeb.Components.DraftDiff.draft_diff
              draft={@editor_doc}
              published={@published_doc}
              schema={@editor_schema}
            />
          <% else %>
            <%= if schema_groups(@editor_schema) != [] do %>
              <div class="bp-tab-bar" role="tablist">
                <%= for grp <- schema_groups(@editor_schema) do %>
                  <button
                    type="button"
                    phx-click="select-group"
                    phx-value-group={grp["name"]}
                    role="tab"
                    aria-selected={@nav_group == grp["name"]}
                    title={grp["title"]}
                    aria-label={grp["title"]}
                    class={"bp-tab " <> if(@nav_group == grp["name"], do: "is-active", else: "")}
                  ><span class="bp-tab-icon" aria-hidden="true"><.icon name={tab_icon(grp)} /></span></button>
                <% end %>
              </div>
            <% end %>

            <form phx-submit="save" phx-change="autosave" id="editor-form">
              <.editor_field
                label="Title"
                required={(get_title_validation(@editor_schema) || %{})["required"] == true}
                errors={Map.get(@validation_errors, "title", [])}
              >
                <input type="text" name="doc[title]" value={@editor_form["title"]} class="form-input" phx-debounce="300" />
              </.editor_field>
              <%= if @editor_schema do %>
                <%= for field <- visible_fields(Enum.reject(@editor_schema.fields, & &1["name"] == "title"), @nav_group),
                        Visibility.visible?(field, @editor_form) do %>
                  <.studio_field_renderer
                    field={field}
                    editor_form={@editor_form}
                    dataset={@dataset}
                    validation_errors={@validation_errors}
                    parent_assigns={@parent_assigns}
                  />
                <% end %>
              <% end %>
              <div class="editor-actions">
                <span class="save-status" role="status" aria-live="polite"><%= @save_status %></span>
              </div>
            </form>
          <% end %>
        </div>
        <BarkparkWeb.Components.OnixPreview.content_preview
          :if={@show_content_preview}
          rendered={@content_preview_rendered}
          type={@editor_type || ""}
        />
        </div>
      </div>
    <% else %>
      <%= if @empty_state != [] do %>
        <%= render_slot(@empty_state) %>
      <% else %>
        <.empty_editor message="Select a document to edit">
          <:icon><.icon name="file-text" size={40} /></:icon>
        </.empty_editor>
      <% end %>
    <% end %>
    """
  end

  # Dataset arm mirrors PresenceState.on_doc/3 (tsk-url-p0): the same doc_id
  # in another dataset is NOT co-presence.
  defp presences_on_doc(presences, doc_id, dataset) do
    Enum.filter(presences, &(&1.doc_id == doc_id and Map.get(&1, :dataset) == dataset))
  end

  # spd-b35: the accessible name for the `.presence-dots` group. Replaces the
  # per-dot `title=` tooltip, which only a mouse could reach and which the
  # group's `pointer-events: none` now makes unreachable even by one. Same
  # "<name> is editing" vocabulary the tooltip used, folded into one sentence
  # so a screen reader announces the group once instead of per 10px dot.
  defp presence_dots_label(presences) do
    names = Enum.map(presences, &Map.get(&1, :name, "User"))

    case names do
      [one] -> "#{one} is editing"
      many -> "#{Enum.join(many, ", ")} are editing"
    end
  end

  # Slug off the parent LV's resolved scope structs — "" when unscoped
  # (flat surface) so href interpolation degrades to empty segments.
  defp scope_slug(parent_assigns, key) do
    case Map.get(parent_assigns || %{}, key) do
      %{slug: slug} when is_binary(slug) -> slug
      _ -> ""
    end
  end

  @doc """
  Renders a single editor-header doc-action — `"event"`, `"modal"`, or
  `"link"` — from a resolved doc-action map (see
  `Barkpark.Plugin.doc_action` typespec + `StudioLive.default_doc_actions/2`).

  Used by `studio_editor_shell/1` to walk the resolved list inside
  `<bp-overflow-menu>`. Splits out so the case statement stays out of the
  shell's main HEEx.

    * `"event"` → `<button phx-click=<opts.event>>`
    * `"modal"` → `<button phx-click="schema_action" phx-value-name=<name>>`
    * `"link"`  → `<a href=<interpolated-href>>`

  Class / style / `data-test-id` are read off `opts` so the host's built-in
  buttons preserve their existing attrs (`btn btn-primary btn-sm` on
  Publish, `color: var(--destructive)` on Delete, `data-test-id` on
  Duplicate / Open another / schema actions). Plugin-contributed actions
  without those opts fall back to `btn btn-ghost btn-sm`.
  """
  attr :action, :map, required: true
  attr :editor_doc, :map, default: nil
  attr :dataset, :string, required: true
  # Scope slugs for href interpolation (tsk-url-p2): a schema action may
  # carry :workspace / :project placeholders alongside :dataset / :id.
  attr :workspace_slug, :string, default: ""
  attr :project_slug, :string, default: ""

  def doc_action_button(assigns) do
    ~H"""
    <%= case @action["kind"] do %>
      <% "link" -> %>
        <a
          href={
            interpolate_doc_action_href(
              @action,
              @editor_doc,
              @dataset,
              @workspace_slug,
              @project_slug
            )
          }
          class={action_button_class(@action)}
          title={@action["label"]}
          aria-label={@action["label"]}
          data-test-id={doc_action_test_id(@action)}
        ><.doc_action_glyph action={@action} /></a>
      <% "modal" -> %>
        <button
          type="button"
          class={action_button_class(@action)}
          style={action_button_style(@action)}
          title={@action["label"]}
          aria-label={@action["label"]}
          data-test-id={doc_action_test_id(@action)}
          phx-click="schema_action"
          phx-value-name={@action["name"]}
        ><.doc_action_glyph action={@action} /></button>
      <% _ -> %>
        <%!-- default: "event" — dispatch the named phx-click event --%>
        <button
          type="button"
          class={action_button_class(@action)}
          style={action_button_style(@action)}
          title={@action["label"]}
          aria-label={@action["label"]}
          data-test-id={doc_action_test_id(@action)}
          phx-click={doc_action_event(@action)}
        ><.doc_action_glyph action={@action} /></button>
    <% end %>
    """
  end

  # Renders the action's icon if one is declared, falling back to the
  # text label so plugin-contributed actions that pre-date the icon
  # convention still render a clickable button. The icon SVG is
  # aria-hidden so screen readers announce the parent button's
  # aria-label exactly once. See task barkpark-jl4x.
  attr :action, :map, required: true

  defp doc_action_glyph(assigns) do
    icon_name = doc_action_icon(assigns.action)
    assigns = assign(assigns, :icon_name, drawable_icon(icon_name))

    ~H"""
    <%= if @icon_name do %>
      <span class="bp-action-icon" aria-hidden="true"><.icon name={@icon_name} size={16} /></span>
    <% else %>
      <%= @action["label"] %>
    <% end %>
    """
  end

  # Read the icon name from either `opts.icon` (task barkpark-jl4x
  # convention for built-ins) or the top-level `"icon"` key (existing
  # schema-action spec — see `Barkpark.Plugin.doc_action` typespec and
  # `OnixEdit.document_actions/0`). Returns nil when neither is set;
  # callers fall back to the text label so the button stays usable.
  defp doc_action_icon(action) do
    case action do
      %{"opts" => %{"icon" => icon}} when is_binary(icon) -> icon
      %{"icon" => icon} when is_binary(icon) -> icon
      _ -> nil
    end
  end

  # A doc action's icon can arrive from a PLUGIN or a workspace SCHEMA, so the
  # name is an unbounded string from outside the tree — `known_icon?/1` is the
  # guard `BarkparkWeb.Icons` prescribes for exactly that case. An unknown name
  # degrades to `nil`, which is the shape `doc_action_glyph/1` already handles
  # by rendering the action's text label: a readable button rather than either
  # a wrong picture or (in :test, where `icon/1` raises) a crashed render.
  # Developer-authored names stay honest — the icons tripwire reds on those
  # statically, before they can ever reach this fallback.
  #
  # Kept clear of any `attr` declaration: `attr` binds to the NEXT function
  # defined, so a private helper sitting between `attr :action` and
  # `doc_action_glyph/1` gets compiled as the component itself and is then
  # called with an assigns map.
  defp drawable_icon(name) when is_binary(name) do
    if BarkparkWeb.Icons.known_icon?(name), do: name, else: nil
  end

  defp drawable_icon(_), do: nil

  defp doc_action_event(action) do
    case action["opts"] do
      %{"event" => ev} when is_binary(ev) -> ev
      _ -> action["name"]
    end
  end

  defp action_button_class(action) do
    case action["opts"] do
      %{"class" => c} when is_binary(c) -> c
      _ -> "btn btn-ghost btn-sm"
    end
  end

  defp action_button_style(action) do
    case action["opts"] do
      %{"style" => s} when is_binary(s) -> s
      _ -> nil
    end
  end

  defp doc_action_test_id(action) do
    case action["opts"] do
      %{"data_test_id" => id} when is_binary(id) ->
        id

      _ ->
        case action["kind"] do
          k when k in ["modal", "link"] -> "schema-action-#{action["name"]}"
          _ -> nil
        end
    end
  end

  # Same interpolation StudioLive used for schema-declared `"link"`
  # actions. Falls back to `"#"` when href is missing. Substitutes
  # `:dataset` and `:id` (published id — drafts. prefix stripped).
  defp interpolate_doc_action_href(action, doc, dataset, ws_slug, proj_slug) do
    case action["opts"] do
      %{"href" => href} when is_binary(href) ->
        do_interpolate_href(href, doc, dataset, ws_slug, proj_slug)

      _ ->
        case action["href"] do
          href when is_binary(href) -> do_interpolate_href(href, doc, dataset, ws_slug, proj_slug)
          _ -> "#"
        end
    end
  end

  # Placeholder vocabulary: :dataset · :id · :workspace · :project
  # (tsk-url-p2 added the scope pair — a plugin action can address the
  # scoped API, e.g. href: "/w/:workspace/p/:project/v1/data/doc/:dataset/...").
  # :workspace is replaced before :w-anything ambiguity can arise because
  # the replacements run longest-token-first.
  defp do_interpolate_href(href, doc, dataset, ws_slug, proj_slug) do
    id =
      case doc do
        %{doc_id: doc_id} -> Barkpark.Content.published_id(doc_id)
        _ -> ""
      end

    href
    |> String.replace(":workspace", to_string(ws_slug || ""))
    |> String.replace(":project", to_string(proj_slug || ""))
    |> String.replace(":dataset", to_string(dataset || ""))
    |> String.replace(":id", id)
  end

  @doc """
  Renders the cross-field validation banner at the top of the editor pane
  (Task barkpark-cgn). Empty list → nothing renders. Each violation
  surfaces its title and level (error|warning) plus the first involved
  field as a hint.

  This is the first-pass UI from the task spec — count + per-rule rows.
  The inline-per-field highlight pass lives behind future work, gated on
  stable per-field DOM ids (currently absent from `editor_field`).
  """
  attr :violations, :list, default: []

  def cross_violations_banner(assigns) do
    assigns =
      assign(
        assigns,
        :counts,
        %{
          error: Enum.count(assigns.violations, &(&1["level"] == "error")),
          warning: Enum.count(assigns.violations, &(&1["level"] == "warning"))
        }
      )

    ~H"""
    <%= if @violations != [] do %>
      <div class="bp-violations" role="status" aria-live="polite" data-test-id="cross-violations">
        <div class="bp-violations-summary">
          <span class="bp-violations-count">
            <%= length(@violations) %> issue<%= if length(@violations) != 1, do: "s" %>:
          </span>
          <%= if @counts.error > 0 do %>
            <span class="bp-violations-error"><%= @counts.error %> error<%= if @counts.error != 1, do: "s" %></span>
          <% end %>
          <%= if @counts.error > 0 and @counts.warning > 0 do %>
            <span>·</span>
          <% end %>
          <%= if @counts.warning > 0 do %>
            <span class="bp-violations-warning"><%= @counts.warning %> warning<%= if @counts.warning != 1, do: "s" %></span>
          <% end %>
        </div>
        <ul class="bp-violations-list">
          <%= for v <- @violations do %>
            <li class={"bp-violation-item bp-violations-#{v["level"] || "error"}"}
                data-test-id={"cross-violation-#{v["name"]}"}>
              <span class="bp-violation-title"><%= v["title"] || v["name"] %></span>
              <%= if is_list(v["fields"]) and v["fields"] != [] do %>
                <span class="bp-violation-fields">&nbsp;— <%= List.first(v["fields"]) %></span>
              <% end %>
            </li>
          <% end %>
        </ul>
      </div>
    <% end %>
    """
  end

  @doc """
  Concurrent-edit conflict banner (studio-concurrent-edit). Rendered above the
  form when another user saved the open document while the local buffer held
  unsaved edits. Offers a Reload action ("reload-remote-doc") that discards the
  buffer and reloads from the DB. `conflict == false` → nothing renders.
  """
  attr :conflict, :boolean, default: false

  def doc_conflict_banner(assigns) do
    ~H"""
    <%= if @conflict do %>
      <div class="bp-violations bp-doc-conflict" role="alert" aria-live="assertive"
           data-test-id="doc-conflict-banner">
        <div class="bp-violations-summary">
          <span class="bp-violations-warning">
            Updated by another user — your unsaved edits are kept.
          </span>
        </div>
        <button
          type="button"
          class="btn btn-sm"
          phx-click="reload-remote-doc"
          data-test-id="doc-conflict-reload"
        >Reload</button>
      </div>
    <% end %>
    """
  end

  @doc """
  Server-owned save-halt mirror (p-hollow-studio-mirror). Rendered when a
  paper write was vetoed by a plugin lifecycle gate — the write seam returns
  `{:error, {:halted, reason}}` and the paper handler stashes `reason` in the
  `paper_halt` assign. The banner shows that server reason VERBATIM (M1
  template violation today, the hollow-doc quality gate tomorrow): the editor
  mirrors the server truth and never authors its own copy (charter D5/D6).
  `reason == nil` → nothing renders; the next accepted edit clears the assign.
  """
  attr :reason, :string, default: nil

  def paper_halt_banner(assigns) do
    ~H"""
    <%= if @reason do %>
      <div class="bp-violations bp-paper-halt" role="alert" aria-live="assertive"
           data-test-id="paper-halt-banner">
        <div class="bp-violations-summary">
          <span class="bp-violations-error"><%= @reason %></span>
        </div>
      </div>
    <% end %>
    """
  end

  defp get_title_validation(nil), do: nil

  defp get_title_validation(schema) do
    case Enum.find(schema.fields, &(&1["name"] == "title")) do
      %{"validation" => v} -> v
      _ -> nil
    end
  end

  @doc """
  Read the `groups` declaration from a schema map (Sanity-style field-group
  tabs). Tolerates atom or string keys; returns `[]` for legacy schemas that
  never declared any groups so the editor's tab bar is hidden entirely
  (back-compat invariant — post/page/author/etc. render unchanged).
  """
  def schema_groups(nil), do: []

  def schema_groups(schema) do
    case Map.get(schema, :groups) || Map.get(schema, "groups") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # Per-group icon (task barkpark-sfzn). Plugins that omit "icon" still
  # render — falls back to a neutral "circle" so the tab bar never blanks.
  # A group's icon is workspace-schema data, so an unrecognised name gets the
  # same neutral "circle" rather than reaching `icon/1`, which raises in :test.
  defp tab_icon(%{"icon" => icon}) when is_binary(icon) and icon != "",
    do: drawable_icon(icon) || "circle"

  defp tab_icon(_), do: "circle"

  @doc """
  Filter top-level fields to those visible on the currently selected tab.

  `nav_group == nil` — no active tab → show everything (legacy / no-groups
  schemas, plus the back-compat path while StudioLive is mounting).

  `nav_group` set — keep only fields whose `"group"` attribute matches the
  active tab. Fields without a `"group"` are not surfaced on any tab; the
  ONIX book schema tags every top-level field explicitly so this is a
  deliberate signal, not an oversight (decision recorded in this task).
  """
  def visible_fields(fields, nil), do: fields

  def visible_fields(fields, group_name) when is_binary(group_name) do
    Enum.filter(fields, fn f -> Map.get(f, "group") == group_name end)
  end
end
