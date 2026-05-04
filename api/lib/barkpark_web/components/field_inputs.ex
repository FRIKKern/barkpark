defmodule BarkparkWeb.Components.FieldInputs do
  @moduledoc """
  Public function-component for v1 leaf-field inputs in the Studio editor form.

  This module is a verbatim extraction of the seven `defp render_input/2` clauses
  formerly private to `BarkparkWeb.StudioLive` (origin/main 19ded88, lines
  1488..1604). Output is byte-identical to the legacy renderer for every v1
  schema (post, page, author, category, project, siteSettings, navigation,
  colors). Two surgical injection points are added without changing rendered
  DOM under default usage:

    * `id_prefix` (default `""`): when non-empty, emits `id="<prefix><name>"`
      on the leaf control; when empty, the `id` attribute is omitted entirely
      (Phoenix drops `id={nil}`), matching the legacy DOM exactly.
    * `dataset` (default `"production"`): plumbed through to
      `Barkpark.Content.get_document/3` calls in the reference clause. Legacy
      hard-coded `"production"`; default keeps byte-identity.

  ## Caller contract — `phx-click` events

  The `reference` clause emits `phx-click` events that the parent LiveView
  must handle in its `handle_event/3`. StudioLive implements them at these
  origin/main locations:

    * `"open-ref-picker"` — studio_live.ex:417 — loads ref candidates and opens
      ref picker modal. Payload: `%{"field" => name, "ref-type" => ref_type}`.
    * `"clear-ref"` — studio_live.ex:569 — sets the field to `""` in
      `editor_form`. Payload: `%{"field" => name}`.

  A LiveView that hosts this component for `reference` fields must
  implement those two events and the corresponding picker-modal markup.

  Image fields (Task #12 WI1) are rendered by the `<bp-media-picker>` Web
  Component which owns the entire UX (browse / upload / select / clear).
  The WC bridges its value through `BarkparkFieldBridge`; no per-LV
  events are required. The legacy `open-image-picker` / `clear-image`
  / `select-media` / `upload-image` handlers and the
  `image_picker_modal` remain in StudioLive for the legacy modal flow
  but are no longer invoked from this component.

  ## Field types

  Pattern-matched in source order:

    1. `select` (with `options` list)
    2. `text` / `richText` (textarea)
    3. `boolean` (hidden + checkbox pair)
    4. `color`
    5. `reference` (`refType` required)
    6. `image`
    7. default fallback (string, slug, datetime, unknown — text input)
  """

  use Phoenix.Component

  alias Barkpark.Content

  attr :field, :map, required: true
  attr :editor_form, :map, required: true
  attr :dataset, :string, default: "production"
  attr :id_prefix, :string, default: ""
  attr :api_token_raw, :string, default: ""

  def input(%{field: %{"type" => "select", "name" => name, "options" => opts}} = assigns)
      when is_list(opts) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, opts: opts, v: val)

    ~H"""
    <select id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} name={"doc[#{@n}]"} class="form-input" phx-debounce="300">
      <%= for o <- @opts do %><option value={o} selected={o == @v}><%= o %></option><% end %>
    </select>
    """
  end

  # richText: bp-rich-text-editor Web Component (Task #11 WI4) bridged
  # via the hidden input + BarkparkFieldBridge hook (root.html.heex).
  # phx-update="ignore" gives the WC sole ownership of its inner DOM.
  # See docs/studio/web-components.md for the full contract.
  def input(%{field: %{"type" => "richText", "name" => name}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <div id={"bp-rt-wrap-#{@n}"} phx-update="ignore" phx-hook="BarkparkFieldBridge">
      <input type="hidden" id={"bp-rt-hidden-#{@n}"} name={"doc[#{@n}]"} value={@v} phx-debounce="500" />
      <bp-rich-text-editor value={@v} data-bridge-target={"bp-rt-hidden-#{@n}"}></bp-rich-text-editor>
    </div>
    """
  end

  def input(%{field: %{"type" => t, "name" => name} = f} = assigns)
      when t == "text" do
    val = Map.get(assigns.editor_form, name, "")
    rows = Map.get(f, "rows") || 3
    assigns = assign(assigns, n: name, v: val, rows: rows)

    ~H"""
    <textarea id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} name={"doc[#{@n}]"} class="form-input" rows={@rows} phx-debounce="500"><%= @v %></textarea>
    """
  end

  def input(%{field: %{"type" => "boolean", "name" => name}} = assigns) do
    checked = Map.get(assigns.editor_form, name, "") == "true"
    assigns = assign(assigns, n: name, c: checked)

    ~H"""
    <div class="form-checkbox">
      <input type="hidden" name={"doc[#{@n}]"} value="false" />
      <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="checkbox" name={"doc[#{@n}]"} value="true" checked={@c} phx-debounce="100" />
    </div>
    """
  end

  def input(%{field: %{"type" => "color", "name" => name}} = assigns) do
    val = Map.get(assigns.editor_form, name, "#3b82f6")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <div style="display:flex;align-items:center;gap:10px;">
      <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="color" name={"doc[#{@n}]"} value={@v} phx-debounce="300" style="width:36px;height:36px;border:1px solid var(--input);border-radius:6px;cursor:pointer;background:transparent;" />
      <span style="font-family:var(--font-mono);font-size:13px;"><%= @v %></span>
    </div>
    """
  end

  def input(%{field: %{"type" => "reference", "name" => name, "refType" => ref_type}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    has_ref = val != "" and val != nil
    # Resolve the referenced doc title for display
    ref_title =
      if has_ref do
        case Content.get_document(val, ref_type, assigns.dataset) do
          {:ok, doc} ->
            doc.title || val

          _ ->
            case Content.get_document("drafts.#{val}", ref_type, assigns.dataset) do
              {:ok, doc} -> doc.title || val
              _ -> val
            end
        end
      end

    assigns =
      assign(assigns, n: name, v: val, has_ref: has_ref, ref_title: ref_title, ref_type: ref_type)

    ~H"""
    <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="hidden" name={"doc[#{@n}]"} value={@v} />
    <div class="ref-field">
      <%= if @has_ref do %>
        <div class="ref-selected">
          <div class="ref-selected-info">
            <span class="ref-selected-title"><%= @ref_title %></span>
            <span class="ref-selected-type"><%= @ref_type %></span>
          </div>
          <div style="display: flex; gap: 6px;">
            <button type="button" class="btn btn-sm" phx-click="open-ref-picker" phx-value-field={@n} phx-value-ref-type={@ref_type}>Change</button>
            <button type="button" class="btn btn-destructive btn-sm" phx-click="clear-ref" phx-value-field={@n}>Remove</button>
          </div>
        </div>
      <% else %>
        <button type="button" class="btn btn-sm" phx-click="open-ref-picker" phx-value-field={@n} phx-value-ref-type={@ref_type} style="width: 100%; justify-content: flex-start; color: var(--fg-muted);">
          Select <%= @ref_type %>...
        </button>
      <% end %>
    </div>
    """
  end

  # image: bp-media-picker Web Component (Task #12 WI1) bridged via the
  # hidden input + BarkparkFieldBridge hook (root.html.heex). The WC owns
  # browse / upload / select / clear; no parent phx-click events are
  # required. `data-token` carries the raw bearer token plumbed from
  # session via LiveAuth.:fetch_api_token (empty string disables uploads).
  # phx-update="ignore" gives the WC sole ownership of its inner DOM.
  # See docs/studio/web-components.md for the full contract.
  def input(%{field: %{"type" => "image", "name" => name}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <div id={"bp-mp-wrap-#{@n}"} phx-update="ignore" phx-hook="BarkparkFieldBridge">
      <input type="hidden" id={"bp-mp-hidden-#{@n}"} name={"doc[#{@n}]"} value={@v} phx-debounce="500" />
      <bp-media-picker value={@v} data-bridge-target={"bp-mp-hidden-#{@n}"} data-token={@api_token_raw}></bp-media-picker>
    </div>
    """
  end

  def input(%{field: %{"name" => name}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="text" name={"doc[#{@n}]"} value={@v} class="form-input" phx-debounce="500" />
    """
  end
end
