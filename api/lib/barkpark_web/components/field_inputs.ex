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

  The `reference` and `image` clauses emit `phx-click` events that the parent
  LiveView must handle in its `handle_event/3`. StudioLive implements them at
  these origin/main locations:

    * `"open-image-picker"` — studio_live.ex:360 — opens media picker modal.
      Payload: `%{"field" => name}`.
    * `"clear-image"` — studio_live.ex:377 — sets the field to `""` in
      `editor_form`. Payload: `%{"field" => name}`.
    * `"open-ref-picker"` — studio_live.ex:417 — loads ref candidates and opens
      ref picker modal. Payload: `%{"field" => name, "ref-type" => ref_type}`.
    * `"clear-ref"` — studio_live.ex:569 — sets the field to `""` in
      `editor_form`. Payload: `%{"field" => name}`.

  A LiveView that hosts this component for `reference` or `image` fields must
  implement those four events and the corresponding picker-modal markup.

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

  def input(%{field: %{"type" => t, "name" => name} = f} = assigns)
      when t in ["text", "richText"] do
    val = Map.get(assigns.editor_form, name, "")
    rows = Map.get(f, "rows") || if(t == "richText", do: 6, else: 3)
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

  def input(%{field: %{"type" => "image", "name" => name}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    has_image = val != "" and val != nil
    assigns = assign(assigns, n: name, v: val, has_image: has_image)

    ~H"""
    <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="hidden" name={"doc[#{@n}]"} value={@v} />
    <div class="image-field">
      <%= if @has_image do %>
        <div class="image-preview">
          <img src={@v} alt="" />
          <div class="image-preview-actions">
            <button type="button" class="btn btn-sm" phx-click="open-image-picker" phx-value-field={@n}>Change</button>
            <button type="button" class="btn btn-destructive btn-sm" phx-click="clear-image" phx-value-field={@n}>Remove</button>
          </div>
        </div>
      <% else %>
        <div class="image-upload-zone" phx-click="open-image-picker" phx-value-field={@n}>
          <div class="image-upload-icon">+</div>
          <div class="image-upload-text">Select or upload image</div>
        </div>
      <% end %>
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
