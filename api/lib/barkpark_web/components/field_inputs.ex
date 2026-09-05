defmodule BarkparkWeb.Components.FieldInputs do
  @moduledoc """
  Public function-component for v1 leaf-field inputs in the Studio editor form.

  This module is a verbatim extraction of the seven `defp render_input/2` clauses
  formerly private to `BarkparkWeb.StudioLive` (origin/main 19ded88, lines
  1488..1604). Output is byte-identical to the legacy renderer for every v1
  schema (post, page, author, category, project, siteSettings, navigation,
  colors) — EXCEPT the `color` clause, deliberately reworked so an unset
  optional color field no longer renders/persists a phantom `#3b82f6`
  (hidden-input mirror + `BarkparkColorField` hook; see that clause) — and the
  `select` clause, which now renders a leading empty placeholder when the
  stored value matches no option, so an untouched OPTIONAL select no longer
  serializes/persists its first option as a phantom default (see that clause).
  Two surgical injection points are added without changing rendered
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
    8. `source` (read-only verbatim monospace `<pre>`, no form input — the
       scaffy `command` type's `.scaffy` bytes; edits go through the repo, never
       the form)
    9. `array` / `object` (read-only pretty-printed JSON, no form input)
    10. default fallback (string, slug, unknown — text input)
  """

  use Phoenix.Component

  attr :field, :map, required: true
  attr :editor_form, :map, required: true
  attr :dataset, :string, default: "production"
  # The open document's id — keys a field canvas wrapper so a doc→doc patch
  # navigation remounts it instead of transplanting the `phx-update="ignore"`
  # wrapper across documents (paper_canvas.ex bug #1c).
  attr :doc_key, :string, default: "doc"
  # Scoped-surface URL prefix ("/w/<ws>/p/<proj>", tsk-url-p2) — emitted as
  # the pickers' scope-prefix attribute so their fetches hit the scoped API
  # mirror. "" on the flat surface keeps every fetch byte-identical.
  attr :scope_prefix, :string, default: ""
  attr :id_prefix, :string, default: ""
  attr :api_token_raw, :string, default: ""

  # An OPTIONAL select whose stored value matches NO option must NOT drag its
  # first option into autosave. A native <select> always form-serializes SOME
  # option; with no `selected` marker the browser picks the FIRST one, so an
  # untouched optional field (e.g. seeded author.role) would persist a phantom
  # default. Fix (Sanity's "no selection" idiom): when the stored value matches
  # no option, render a leading empty placeholder `<option value="" selected>` —
  # "" serializes as empty and `Content.Forms.build_content/2`'s empty-string
  # drop keeps the field absent. A REQUIRED field still forces a choice: its
  # placeholder is `disabled`, so the user cannot settle on "no value" and the
  # required-field validator flags the empty until a real option is picked.
  # Selects WITH a matching stored value are unchanged (that option is selected;
  # no placeholder). Required detection is rule-based (`validation.required`),
  # never name-based — cf. `Content.Forms` status handling (forms.ex).
  def input(%{field: %{"type" => "select", "name" => name, "options" => opts} = f} = assigns)
      when is_list(opts) do
    val = Map.get(assigns.editor_form, name, "")
    options = Barkpark.Content.SelectOptions.normalize(opts)
    has_selection = val in Enum.map(options, & &1.value)
    required = get_in(f, ["validation", "required"]) == true

    assigns =
      assign(assigns,
        n: name,
        opts: options,
        v: val,
        show_placeholder: not has_selection,
        required: required,
        radio: Barkpark.Content.SelectOptions.radio?(f)
      )

    ~H"""
    <%!-- Gyldendal parity E1.5 — options normalise through
         `Barkpark.Content.SelectOptions` (bare values or {value,title} pairs;
         the TITLE is shown, the VALUE stored) and `"layout": "radio"` renders
         Sanity's radio list. An optional radio group with no stored value has
         NO checked input: nothing serialises, so the field stays absent — the
         same "no selection" idiom the placeholder <option> gives the <select>. --%>
    <div :if={@radio} class="form-radio-group" role="radiogroup" data-field={@n}>
      <%= for o <- @opts do %>
        <label class="form-radio">
          <input type="radio" name={"doc[#{@n}]"} value={o.value} checked={o.value == @v} required={@required} phx-debounce="100" />
          <span><%= o.label %></span>
        </label>
      <% end %>
    </div>
    <select :if={not @radio} id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} name={"doc[#{@n}]"} class="form-input" phx-debounce="300">
      <option :if={@show_placeholder} value="" selected disabled={@required}>Select…</option>
      <%= for o <- @opts do %><option value={o.value} selected={o.value == @v}><%= o.label %></option><% end %>
    </select>
    """
  end

  # richText: bp-rich-text-editor Web Component (Task #11 WI4) bridged
  # via the hidden input + BarkparkFieldBridge hook (root.html.heex).
  # phx-update="ignore" gives the WC sole ownership of its inner DOM.
  # See docs/studio/web-components.md for the full contract.
  # richText with `"editor": "blocks"` — Gyldendal parity stage E1. The field
  # is edited by the SAME <bp-paper-canvas> the paper editor uses, seeded with
  # the field's own block array and the field's declared vocabulary
  # (data-canvas-vocabulary, the twin of data-canvas-constraints). There is NO
  # hidden input and no BarkparkFieldBridge: block edits travel as ops through
  # the BarkparkFieldCanvas hook → `field-block-ops` → the field-scoped apply
  # path, and the server echo comes back on `bp:field-canvas-update`. An
  # unconfigured richText keeps the clause below byte-identically.
  def input(%{field: %{"type" => "richText", "name" => name, "editor" => "blocks"} = f} = assigns) do
    blocks = Barkpark.Content.field_blocks(Map.get(assigns.editor_form, name))

    # A field that declares `"blocks"` keeps EXACTLY what it names — the
    # declaration NARROWS. A field that says `"editor": "blocks"` and nothing
    # else gets the papers block vocabulary, read from the ONE source the
    # server-side write path reads (`FieldVocabulary.from_field/1` applies the
    # same default in `apply_field_block_ops`), never a second list typed here.
    vocab =
      case Map.get(f, "blocks") do
        %{} = declared -> declared
        _ -> Barkpark.PortableDoc.FieldVocabulary.default_declaration()
      end

    assigns =
      assign(assigns,
        n: name,
        blocks_json: Jason.encode!(blocks),
        vocab_json: Jason.encode!(vocab)
      )

    ~H"""
    <div
      id={"bp-fc-wrap-#{@doc_key}-#{@n}"}
      phx-update="ignore"
      phx-hook="BarkparkFieldCanvas"
      class="bp-paper-edit-canvas bp-field-canvas"
      data-field={@n}
      data-doc-key={@doc_key}
      data-canvas-blocks={@blocks_json}
      data-canvas-vocabulary={@vocab_json}
      data-canvas-dataset={@dataset}
      data-canvas-token={@api_token_raw}
      data-test-id="field-canvas"
    >
      <bp-paper-canvas></bp-paper-canvas>
    </div>
    """
  end

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
    <label class="form-switch">
      <input type="hidden" name={"doc[#{@n}]"} value="false" />
      <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="checkbox" name={"doc[#{@n}]"} value="true" checked={@c} phx-debounce="100" />
      <span class="form-switch-track" aria-hidden="true"></span>
      <span class="form-switch-state"><%= if @c, do: "On", else: "Off" %></span>
    </label>
    """
  end

  def input(%{field: %{"type" => "datetime", "name" => name}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="datetime-local" name={"doc[#{@n}]"} value={@v} class="form-input" phx-debounce="300" />
    """
  end

  # color: an OPTIONAL color field that the user never touched must NOT
  # render or persist a phantom default. A native `<input type="color">`
  # cannot hold an empty value (it coerces to #000000) and is always
  # form-serialized when it carries a `name`, so an untouched field would
  # otherwise drag a phantom hex into every autosave. Instead we mirror the
  # picker into a hidden input (the ONLY named control) via the
  # `BarkparkColorField` hook — the same hidden-input + synthetic-`input`
  # bridge the WC fields use. The hidden value is "" when unset, so
  # `Content.Forms.build_content/2`'s empty-string drop keeps it out of the
  # saved content; the picker itself is nameless and never autosaves on its
  # own. A stored value renders as before (swatch + hex + Clear); an unset
  # field renders a neutral "No color" state and a dimmed swatch.
  def input(%{field: %{"type" => "color", "name" => name}} = assigns) do
    stored = Map.get(assigns.editor_form, name)
    has_value = is_binary(stored) and stored != ""
    # Hidden (submitted) value: the real hex, or "" so autosave drops it.
    hidden_v = if has_value, do: stored, else: ""
    # Native picker needs a #rrggbb value; use a neutral fallback when unset.
    picker_v = if has_value, do: stored, else: "#000000"
    label = if has_value, do: stored, else: "No color"

    picker_style =
      "width:36px;height:36px;border:1px solid var(--input);border-radius:6px;cursor:pointer;background:transparent;" <>
        if has_value, do: "", else: "opacity:0.4;"

    assigns =
      assign(assigns,
        n: name,
        hidden_v: hidden_v,
        picker_v: picker_v,
        label: label,
        has_value: has_value,
        picker_style: picker_style
      )

    ~H"""
    <div id={"bp-color-wrap-#{@n}"} phx-hook="BarkparkColorField" style="display:flex;align-items:center;gap:10px;">
      <input type="hidden" data-color-value name={"doc[#{@n}]"} value={@hidden_v} phx-debounce="300" />
      <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="color" value={@picker_v} data-color-unset={to_string(not @has_value)} style={@picker_style} />
      <span style="font-family:var(--font-mono);font-size:13px;"><%= @label %></span>
      <button :if={@has_value} type="button" data-color-clear class="btn btn-sm" style="font-size:12px;">Clear</button>
    </div>
    """
  end

  # reference → mediaAsset: visual picker (thumbnail grid + library browser).
  def input(
        %{field: %{"type" => "reference", "name" => name, "refType" => "mediaAsset"}} = assigns
      ) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <div id={"bp-mp-ref-wrap-#{@n}"} phx-update="ignore" phx-hook="BarkparkFieldBridge">
      <input type="hidden" id={"bp-mp-ref-hidden-#{@n}"} name={"doc[#{@n}]"} value={@v} phx-debounce="500" />
      <bp-media-picker
        value={@v}
        value-mode="reference"
        dataset={@dataset}
        scope-prefix={@scope_prefix}
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
      <bp-reference-picker
        value={@v}
        ref-type={@ref_type}
        dataset={@dataset}
        scope-prefix={@scope_prefix}
        data-bridge-target={"bp-ref-hidden-#{@n}"}
      ></bp-reference-picker>
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
  def input(%{field: %{"type" => "image", "name" => name} = f} = assigns) do
    val = image_form_value(Map.get(assigns.editor_form, name, ""))

    assigns =
      assign(assigns,
        n: name,
        v: val,
        hotspot: image_option?(f, "hotspot"),
        alt: image_option?(f, "alt")
      )

    ~H"""
    <div id={"bp-mp-wrap-#{@n}"} phx-update="ignore" phx-hook="BarkparkFieldBridge">
      <input type="hidden" id={"bp-mp-hidden-#{@n}"} name={"doc[#{@n}]"} value={@v} phx-debounce="500" />
      <bp-media-picker
        value={@v}
        dataset={@dataset}
        scope-prefix={@scope_prefix}
        data-bridge-target={"bp-mp-hidden-#{@n}"}
        data-token={@api_token_raw}
        hotspot={@hotspot}
        alt={@alt}
      ></bp-media-picker>
    </div>
    """
  end

  # Slug fields get Sanity's signature affordance: a Generate button that
  # derives the slug from the document title server-side (Tenancy.slugify/1,
  # the same slugger workspace/project creation uses). The button is a plain
  # phx-click — StudioLive's "slug-generate" handler writes the derived slug
  # through the normal autosave path, so it lands in editor_form + the draft
  # exactly like a typed value. The input itself stays the standard text
  # input (hand-editing always wins).
  def input(%{field: %{"type" => "slug", "name" => name}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <div style="display:flex;gap:6px;align-items:center;">
      <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="text" name={"doc[#{@n}]"} value={@v} class="form-input" phx-debounce="500" style="flex:1;min-width:0;" />
      <button type="button" class="btn btn-sm" phx-click="slug-generate" phx-value-field={@n} title="Generate from title">Generate</button>
    </div>
    """
  end

  # "source" field (the scaffy `command` type's `source`): the verbatim
  # `.scaffy` bytes. Render the RAW multi-line value in a read-only monospace
  # `<pre>` and emit NO form input — the `.scaffy` file is the source of truth
  # and edits go through the repo, never the Studio form. Rendering it as a
  # `text` textarea would round-trip an editable, form-submitted value that a
  # Studio save could silently diverge from the repo; rendering it via
  # `readonly_json` would collapse the multi-line source to a one-line escaped
  # blob. `<%= @v %>` HTML-escapes the raw string. Because the field is absent
  # from the submitted `doc[...]` params, the save path
  # (`Content.classic_save_content/4`) preserves the stored bytes
  # byte-identically.
  def input(%{field: %{"type" => "source", "name" => name}} = assigns) do
    val = Map.get(assigns.editor_form, name)
    assigns = assign(assigns, n: name, v: to_string(val || ""))

    ~H"""
    <div data-readonly-field={@n} data-source-field>
      <pre style="margin:0;padding:8px 10px;border:1px dashed var(--input);border-radius:6px;font-family:var(--font-mono);font-size:12px;line-height:1.5;white-space:pre;overflow:auto;max-height:60vh;opacity:0.85;"><%= @v %></pre>
      <span style="display:block;margin-top:4px;font-size:11px;opacity:0.55;">read-only — the .scaffy source of truth; edit in the repo</span>
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

    # A field DECLARED "number" always gets the numeric treatment — the
    # name heuristic below only exists for ONIX's string-typed numerics
    # (priceAmount etc.); task.priority is type:number with no matching
    # suffix and rendered as a plain text input (found by the 2026-06-12
    # field-QA sweep).
    numeric = numeric_name?(name) or assigns.field["type"] == "number"
    assigns = assign(assigns, n: name, v: val, numeric: numeric)

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

  # Gyldendal parity E1 — an image field opts into the focal point and the
  # alt-text input the way Sanity does (`options.hotspot`), or flat:
  # {"type":"image","hotspot":true,"alt":true}. Absent → the picker renders
  # byte-identically (the attribute is omitted, not set to "false").
  defp image_option?(field, key) do
    flat = Map.get(field, key)
    nested = get_in(field, ["options", key])
    if flat == true or nested == true, do: true, else: nil
  end

  # The picker's wire value is a STRING (a bare URL or a JSON object). A value
  # that was decoded into a map at the save boundary (Forms.coerce_field_value)
  # is re-encoded here so the same picker reads both.
  defp image_form_value(%{} = map), do: Jason.encode!(map)
  defp image_form_value(v) when is_binary(v), do: v
  defp image_form_value(_), do: ""
end
