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
    * `dataset` (default `"production"`): plumbed through to the
      `bp-reference-picker` Web Component as a `dataset` attribute so the
      WC's typeahead query hits the right dataset. Legacy hard-coded
      `"production"`; default keeps byte-identity.

  ## Caller contract — `phx-click` events

  Both `image` (Task #12 WI1) and `reference` (Task #12 WI2) fields are
  rendered by Web Components — `<bp-media-picker>` and `<bp-reference-picker>`
  respectively — which own the entire UX (browse / upload / select / search /
  clear). They bridge their value through `BarkparkFieldBridge`; no per-LV
  events are required. The legacy `"open-image-picker"` / `"clear-image"` /
  `"select-media"` / `"upload-image"` / `"open-ref-picker"` / `"clear-ref"`
  handlers and the legacy picker-modal markup remain in StudioLive but are no
  longer invoked from this component (orphaned-but-harmless until v2 cleanup).

  ## Field types

  Pattern-matched in source order:

    1. `select` (with `options` list)
    2. `text` / `richText` (textarea)
    3. `boolean` (hidden + checkbox pair)
    4. `datetime` (datetime-local input)
    5. `color`
    6. `reference` (`refType` required)
    7. `image`
    8. default fallback (string, slug, unknown — text input)
  """

  use Phoenix.Component

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

  def input(%{field: %{"type" => "datetime", "name" => name}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="datetime-local" name={"doc[#{@n}]"} value={@v} class="form-input" phx-debounce="300" />
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

  # reference → mediaAsset: visual picker (thumbnail grid + library browser).
  def input(%{field: %{"type" => "reference", "name" => name, "refType" => "mediaAsset"}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <div id={"bp-mp-ref-wrap-#{@n}"} phx-update="ignore" phx-hook="BarkparkFieldBridge">
      <input type="hidden" id={"bp-mp-ref-hidden-#{@n}"} name={"doc[#{@n}]"} value={@v} phx-debounce="500" />
      <bp-media-picker
        value={@v}
        value-mode="reference"
        dataset={@dataset}
        data-bridge-target={"bp-mp-ref-hidden-#{@n}"}
        data-token={@api_token_raw}
      ></bp-media-picker>
    </div>
    """
  end

  # reference: bp-reference-picker Web Component (Task #12 WI2) bridged
  # via the hidden input + BarkparkFieldBridge hook (root.html.heex).
  # phx-update="ignore" gives the WC sole ownership of its inner DOM.
  # The WC owns search + select + clear; the legacy phx-click=
  # "open-ref-picker"/"clear-ref" modal flow is bypassed. The hidden
  # input persists the ref doc id as a string, matching the v1
  # reference-field persistence model exactly.
  def input(%{field: %{"type" => "reference", "name" => name, "refType" => ref_type}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val, ref_type: ref_type)

    ~H"""
    <div id={"bp-ref-wrap-#{@n}"} phx-update="ignore" phx-hook="BarkparkFieldBridge">
      <input type="hidden" id={"bp-ref-hidden-#{@n}"} name={"doc[#{@n}]"} value={@v} phx-debounce="500" />
      <bp-reference-picker value={@v} ref-type={@ref_type} dataset={@dataset} data-bridge-target={"bp-ref-hidden-#{@n}"}></bp-reference-picker>
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
      <bp-media-picker value={@v} dataset={@dataset} data-bridge-target={"bp-mp-hidden-#{@n}"} data-token={@api_token_raw}></bp-media-picker>
    </div>
    """
  end

  # v1 "array" / "object" fields (e.g. the task schema's `dependencies`
  # and `claim`): structured data with no Classic leaf editor. Render the
  # current value as read-only pretty-printed JSON and emit NO form
  # input — submitting these through a text input would round-trip a
  # structured value as a string and corrupt it. Because the field is
  # absent from the submitted `doc[...]` params, the save path
  # (`Content.classic_save_content/4`) preserves the stored value
  # byte-identically. Edits go through the API (`/v1/tasks`, mutate
  # endpoints), not the Studio form.
  def input(%{field: %{"type" => t, "name" => name}} = assigns)
      when t in ["array", "object"] do
    val = Map.get(assigns.editor_form, name)
    assigns = assign(assigns, n: name, v: readonly_json(val))

    ~H"""
    <div data-readonly-field={@n}>
      <pre style="margin:0;padding:8px 10px;border:1px dashed var(--input);border-radius:6px;font-family:var(--font-mono);font-size:12px;white-space:pre-wrap;word-break:break-word;opacity:0.75;"><%= @v %></pre>
      <span style="display:block;margin-top:4px;font-size:11px;opacity:0.55;">read-only — managed via API</span>
    </div>
    """
  end

  def input(%{field: %{"name" => name}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val, numeric: numeric_name?(name))

    ~H"""
    <%= if @numeric do %>
      <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="text" inputmode="numeric" pattern="-?[0-9]+(\.[0-9]+)?" name={"doc[#{@n}]"} value={@v} class="form-input bp-input-numeric" phx-debounce="500" />
    <% else %>
      <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="text" name={"doc[#{@n}]"} value={@v} class="form-input" phx-debounce="500" />
    <% end %>
    """
  end

  # Name-based heuristic: ONIX types numeric fields as `string` (e.g.
  # `priceAmount`, `editionNumber`, `attempt_count`, ~30 fields). Renderer
  # detects them by name suffix or exact match and emits `inputmode="numeric"`
  # + a `.bp-input-numeric` class hook so mobile keyboards switch to digits
  # and CSS can render the input visually distinct (monospace, right-aligned).
  # Mirrors the helper in `Components.Fields.CompositeField`; kept private here
  # to preserve module isolation. Renderer-only — deleting fully reverts.
  @numeric_suffixes ~w(Count Number Year Amount Percent)
  @numeric_names ~w(quantity weeks days pageRun extentValue priceAmount taxRate)

  defp numeric_name?(name) when is_binary(name) do
    name in @numeric_names or
      Enum.any?(@numeric_suffixes, fn suf -> String.ends_with?(name, suf) end)
  end

  defp numeric_name?(_), do: false

  # Pretty-print a structured (array/object) field value for the
  # read-only display. nil / "" → an em-dash placeholder; values that
  # cannot JSON-encode (shouldn't happen for jsonb-sourced content)
  # fall back to `inspect/1` rather than crash the editor pane.
  defp readonly_json(nil), do: "—"
  defp readonly_json(""), do: "—"

  defp readonly_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end
end
