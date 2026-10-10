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
  use Gettext, backend: BarkparkWeb.Gettext

  attr :field, :map, required: true
  attr :editor_form, :map, required: true
  attr :dataset, :string, default: "production"
  # The open document's id — keys a field canvas wrapper so a doc→doc patch
  # navigation remounts it instead of transplanting the `phx-update="ignore"`
  # wrapper across documents (paper_canvas.ex bug #1c).
  attr :doc_key, :string, default: "doc"
  # Moves when the server replaced a rich text / reference / image value of the
  # open document (Shared.next_form_gen/2) — part of doc_wrap_id/4.
  attr :form_gen, :integer, default: 0
  attr :doc_type, :string, default: "document"
  attr :document_rev, :string, default: nil
  # Whether the viewer may change a `readOnly` schema field (an admin, as the
  # server's #21536 rule). `false` renders such a field display-only; `nil`
  # (a caller that does not say) keeps the ordinary input.
  attr :schema_admin, :boolean, default: nil
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
  # Types whose own clause below already copes with a structured (map/list)
  # stored value: reference/image read ids and JSON, array/object render
  # read-only JSON, richText renders block content read-only.
  @structured_value_types ~w(richText reference image array object slug)

  # A schema field declared `"readOnly": true` is shown, not edited, in the
  # Classic form for a NON-admin (task-d483903133c370e1). No form input is
  # rendered, so the save never posts it and the stored value survives
  # byte-identical, the same way the structured-value clause above keeps a value
  # it cannot show. It matches the server rule (#21536): the mutate door refuses
  # a non-admin change and keeps an admin's. So an admin (`schema_admin: true`,
  # from `Caps.admin_affordance?/1`) gets the ordinary input below, and a
  # caller that does not say (`schema_admin` absent) keeps today's input too.
  # Declared before the structured-value clause so a readOnly composite (a
  # map, like mediaAsset `fileInfo`) is display-only too (task-08b6c963d72ce983).
  def input(%{field: %{"readOnly" => true, "name" => name}, schema_admin: false} = assigns) do
    form = assigns[:editor_form] || %{}
    assigns = assign(assigns, n: name, v: readonly_json(Map.get(form, name)))

    ~H"""
    <div data-readonly-field={@n} data-schema-readonly>
      <output style="display:block;padding:6px 0;font-size:13px;opacity:0.75;"><%= @v %></output>
    </div>
    """
  end

  # A SCALAR input handed a STRUCTURED stored value — a Sanity-shaped slug
  # `{"_type": "slug", "current": "…"}`, an object in a string field, a list in
  # a select — crashed the whole document route (`Phoenix.HTML.Safe not
  # implemented for Map`, or `lists in Phoenix.HTML …`; stranger walk,
  # 2026-09-30, a post created through the API with a Sanity slug). Render it
  # read-only with NO form input: the Classic save then never posts the field,
  # so the stored value survives byte-identical instead of being replaced by a
  # string. Declared before every scalar clause so none of them sees a map.
  def input(%{field: %{"type" => t, "name" => name}, editor_form: %{} = form} = assigns)
      when t not in @structured_value_types and is_map_key(form, name) and
             (is_map(:erlang.map_get(name, form)) or is_list(:erlang.map_get(name, form))) do
    assigns = assign(assigns, n: name, v: readonly_json(Map.get(form, name)))

    ~H"""
    <div data-readonly-field={@n} data-structured-value>
      <pre style="margin:0;padding:8px 10px;border:1px dashed var(--input);border-radius:6px;font-family:var(--font-mono);font-size:12px;white-space:pre-wrap;word-break:break-word;opacity:0.75;"><%= @v %></pre>
      <span style="display:block;margin-top:4px;font-size:11px;opacity:0.55;"><%= gettext("read-only — stored as structured data this field's editor cannot show; saved unchanged") %></span>
    </div>
    """
  end

  def input(%{field: %{"type" => "select", "name" => name, "options" => opts} = f} = assigns)
      when is_list(opts) do
    val = scalar_text(Map.get(assigns.editor_form, name, ""))
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
      <option :if={@show_placeholder} value="" selected disabled={@required}><%= gettext("Select…") %></option>
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
      data-paper-doc-key={"#{@dataset}:#{@doc_type}:#{@doc_key}"}
      data-document-rev={@document_rev}
      data-canvas-blocks={@blocks_json}
      data-canvas-vocabulary={@vocab_json}
      data-canvas-dataset={@dataset}
      data-canvas-token={@api_token_raw}
      data-save-strings={field_canvas_save_strings()}
      data-strings={BarkparkWeb.StudioLocale.component_strings(:paper_canvas)}
      data-test-id="field-canvas"
    >
      <bp-paper-canvas></bp-paper-canvas>
    </div>
    """
  end

  # A plain richText whose stored value is NOT a string — Portable Text blocks,
  # the shape `bp seed` writes for richText and the JS SDK/Sanity path uses.
  # The Classic editor below is an HTML-string contenteditable; handed a list it
  # crashed the whole document route with `ArgumentError … lists in
  # Phoenix.HTML and templates may only contain integers …` (stranger walk,
  # 2026-09-30: `bp make schema widget` → `bp schema apply` → `bp seed widget`
  # → open it in Studio = 500). Show it read-only like the array/object clause
  # and emit NO form input, so a Classic save preserves the stored blocks
  # byte-identically instead of replacing them with an HTML string.
  def input(%{field: %{"type" => "richText", "name" => name}} = assigns) do
    case Map.get(assigns.editor_form, name, "") do
      val when is_binary(val) or is_nil(val) ->
        rich_text_editor(assign(assigns, n: name, v: val))

      # Portable Text (owner ruling #44) edits as HTML in the contenteditable;
      # the save turns it back into blocks.
      blocks when name not in ["body", "blocks"] and is_list(blocks) and blocks != [] ->
        if Barkpark.Content.PortableText.blocks?(blocks),
          do:
            rich_text_editor(
              assign(assigns, n: name, v: Barkpark.Content.PortableText.to_html(blocks))
            ),
          else: rich_text_readonly(assign(assigns, n: name, v: readonly_json(blocks)))

      blocks ->
        rich_text_readonly(assign(assigns, n: name, v: readonly_json(blocks)))
    end
  end

  def input(%{field: %{"type" => t, "name" => name} = f} = assigns)
      when t == "text" do
    val = scalar_text(Map.get(assigns.editor_form, name, ""))
    rows = Map.get(f, "rows") || 3
    assigns = assign(assigns, n: name, v: val, rows: rows)

    ~H"""
    <textarea id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} name={"doc[#{@n}]"} class="form-input" rows={@rows} phx-debounce="500"><%= @v %></textarea>
    """
  end

  def input(%{field: %{"type" => "boolean", "name" => name}} = assigns) do
    # A stored JSON `true` (what the API, SDK and `bp seed` write) is checked
    # too — reading only the string "true" rendered it UNCHECKED, so the
    # hidden "false" posted and an edit of ANY other field flipped it to false.
    checked = Map.get(assigns.editor_form, name, "") in [true, "true"]
    assigns = assign(assigns, n: name, c: checked)

    ~H"""
    <label class="form-switch">
      <input type="hidden" name={"doc[#{@n}]"} value="false" />
      <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="checkbox" name={"doc[#{@n}]"} value="true" checked={@c} phx-debounce="100" />
      <span class="form-switch-track" aria-hidden="true"></span>
      <%!-- Both words ship and CSS `:checked` shows the true one, so the word
            follows a click before any re-render, in the Studio language
            (task-70fd7cef5d0266aa). aria-hidden: the checkbox announces its state. --%>
      <span class="form-switch-state" aria-hidden="true"><span class="form-switch-state-off"><%= gettext("Off") %></span><span class="form-switch-state-on"><%= gettext("On") %></span></span>
    </label>
    """
  end

  # A datetime shows local wall time and saves a UTC instant (owner ruling
  # #46). The HIDDEN input carries the name and the stored value and is the
  # only control the form posts; the nameless picker is the editor's view,
  # and `BarkparkDatetimeField` (priv/static/assets/bp-datetime-field.js)
  # converts between the two.
  def input(%{field: %{"type" => "datetime", "name" => name}} = assigns) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <div id={"bp-dt-wrap-#{@id_prefix}#{@n}"} phx-hook="BarkparkDatetimeField" class="bp-datetime-field">
      <input type="hidden" id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} name={"doc[#{@n}]"} value={@v} data-datetime-value phx-debounce="300" />
      <input type="datetime-local" class="form-input" aria-label={@field["title"] || @n} />
    </div>
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
    label = if has_value, do: stored, else: gettext("No color")

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
      <button :if={@has_value} type="button" data-color-clear class="btn btn-sm" style="font-size:12px;"><%= gettext("Clear") %></button>
    </div>
    """
  end

  # reference → mediaAsset: visual picker (thumbnail grid + library browser).
  def input(
        %{field: %{"type" => "reference", "name" => name, "refType" => "mediaAsset"}} = assigns
      ) do
    val = reference_id(Map.get(assigns.editor_form, name, ""))
    assigns = assign(assigns, n: name, v: val)

    ~H"""
    <div id={doc_wrap_id("bp-mp-ref-wrap", @n, @doc_key, @form_gen)} phx-update="ignore" phx-hook="BarkparkFieldBridge">
      <input type="hidden" id={"bp-mp-ref-hidden-#{@n}"} name={"doc[#{@n}]"} value={@v} phx-debounce="500" />
      <bp-media-picker data-strings={BarkparkWeb.StudioLocale.component_strings(:media)}
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
  #
  # Gyldendal parity E1.6 (task-cd8e10ca44ccb932 criterion 0): the field may
  # name SEVERAL target types — Sanity's `to: [{type: "publication"}, …]` (also
  # accepted as `refTypes: [...]`). `ref-type` then carries them comma-joined;
  # the picker searches across the set (`types=`) and shows the type on every
  # hit and on the selected pill. A single `refType` renders byte-identically.
  def input(%{field: %{"type" => "reference", "name" => name} = f} = assigns) do
    val = reference_id(Map.get(assigns.editor_form, name, ""))
    assigns = assign(assigns, n: name, v: val, ref_type: Enum.join(reference_types(f), ","))

    ~H"""
    <div id={doc_wrap_id("bp-ref-wrap", @n, @doc_key, @form_gen)} phx-update="ignore" phx-hook="BarkparkFieldBridge">
      <input type="hidden" id={"bp-ref-hidden-#{@n}"} name={"doc[#{@n}]"} value={@v} phx-debounce="500" />
      <bp-reference-picker data-strings={BarkparkWeb.StudioLocale.component_strings(:reference)}
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
    <div id={doc_wrap_id("bp-mp-wrap", @n, @doc_key, @form_gen)} phx-update="ignore" phx-hook="BarkparkFieldBridge">
      <input type="hidden" id={"bp-mp-hidden-#{@n}"} name={"doc[#{@n}]"} value={@v} phx-debounce="500" />
      <bp-media-picker data-strings={BarkparkWeb.StudioLocale.component_strings(:media)}
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
  def input(%{field: %{"type" => "slug", "name" => name} = f} = assigns) do
    # Either stored shape edits as its text (owner ruling #43).
    raw = Map.get(assigns.editor_form, name, "")
    val = if is_map(raw), do: Barkpark.Content.SlugValue.text(raw) || "", else: scalar_text(raw)
    source = slug_source_of(f)
    assigns = assign(assigns, n: name, v: val, source: source)

    ~H"""
    <div style="display:flex;gap:6px;align-items:center;">
      <input id={if @id_prefix == "", do: nil, else: @id_prefix <> @n} type="text" name={"doc[#{@n}]"} value={@v} class="form-input" phx-debounce="500" style="flex:1;min-width:0;" />
      <button type="button" class="btn btn-sm" phx-click="slug-generate" phx-value-field={@n} data-slug-source={@source} title={gettext("Generate from %{source}", source: @source)}><%= gettext("Generate") %></button>
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
      <span style="display:block;margin-top:4px;font-size:11px;opacity:0.55;"><%= gettext("read-only — the .scaffy source of truth; edit in the repo") %></span>
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
      <span style="display:block;margin-top:4px;font-size:11px;opacity:0.55;"><%= gettext("read-only — managed via API") %></span>
    </div>
    """
  end

  def input(%{field: %{"name" => name}} = assigns) do
    val = scalar_text(Map.get(assigns.editor_form, name, ""))

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
  # A JSON number or boolean stored in a field whose Classic control is a text
  # input / select (a string field holding `true`, a select whose options are
  # numbers). HEEx renders `value={true}` as a BARE attribute, which a browser
  # posts as "" — an edit of another field erased the value — and a select
  # compares option strings to the raw number and selected nothing. Render the
  # text the input holds; `Forms` keeps the stored type when it comes back
  # unedited.
  defp scalar_text(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp scalar_text(v), do: v

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
  #
  # Sanity also declares alt text as a SUBFIELD, `fields: [{name: "alt"}]`
  # (task-6f2b84a0e32688ad, server side task-f0f51946d2de672d): the picker's alt
  # input then edits that subfield, which sits on the image object as `alt`,
  # beside the asset (docs/contracts/schema-v2.md "Stored value shapes").
  defp image_option?(field, "alt" = key) do
    if image_flag?(field, key) or declares_subfield?(field, "alt"), do: true, else: nil
  end

  defp image_option?(field, key), do: if(image_flag?(field, key), do: true, else: nil)

  defp image_flag?(field, key),
    do: Map.get(field, key) == true or get_in(field, ["options", key]) == true

  defp declares_subfield?(field, name) do
    case Map.get(field, "fields") do
      fields when is_list(fields) ->
        Enum.any?(fields, &(is_map(&1) and (&1["name"] || &1[:name]) == name))

      _ ->
        false
    end
  end

  @doc """
  The picker attributes an image schema field asks for — `%{hotspot:, alt:}`,
  each `true` or `nil` (omitted). Shared by the Classic input and Beta's
  property rows so both offer the same controls.
  """
  @spec image_picker_flags(map() | nil) :: %{hotspot: true | nil, alt: true | nil}
  def image_picker_flags(%{} = field),
    do: %{hotspot: image_option?(field, "hotspot"), alt: image_option?(field, "alt")}

  def image_picker_flags(_), do: %{hotspot: nil, alt: nil}

  # The picker's wire value is a STRING (a bare URL or a JSON object). A value
  # that was decoded into a map at the save boundary (Forms.coerce_field_value)
  # is re-encoded here so the same picker reads both.
  @doc """
  The field a slug is generated from — Sanity's `options.source` (also
  accepted flat as `"source"`), defaulting to `"title"` (Gyldendal parity
  E1.6). Only a non-empty string source counts; Sanity's function-valued
  sources have no declarative form here.
  """
  @spec slug_source_of(map()) :: String.t()
  def slug_source_of(field) when is_map(field) do
    case get_in(field, ["options", "source"]) || Map.get(field, "source") do
      s when is_binary(s) and s != "" -> s
      _ -> "title"
    end
  end

  def slug_source_of(_), do: "title"

  # The text box's accessible name: the field's title, else its name.
  defp rich_text_label(%{"title" => title}, _name) when is_binary(title) and title != "",
    do: title

  defp rich_text_label(_field, name), do: name

  defp rich_text_editor(assigns) do
    ~H"""
    <div id={doc_wrap_id("bp-rt-wrap", @n, @doc_key, @form_gen)} phx-update="ignore" phx-hook="BarkparkFieldBridge">
      <input type="hidden" id={"bp-rt-hidden-#{@n}"} name={"doc[#{@n}]"} value={@v} phx-debounce="500" />
      <bp-rich-text-editor value={@v} data-bridge-target={"bp-rt-hidden-#{@n}"} data-strings={BarkparkWeb.StudioLocale.component_strings(:rich_text)} data-label={rich_text_label(@field, @n)}></bp-rich-text-editor>
    </div>
    """
  end

  @doc """
  The id a field's `<label for=…>` can point at when `input/1` renders it
  with `id_prefix`, or `nil` when the clause renders no single labelable
  control carrying that id: the web-component widgets (rich text, reference,
  image), radio groups, read-only structured values and the v2 composites.

  Mirrors the clause order of `input/1`; a label whose `for` names no element
  is ignored by the browser, so a miss here costs a name, never a crash.
  """
  @spec label_target(map(), map(), String.t()) :: String.t() | nil
  def label_target(%{"type" => t, "name" => name} = field, form, prefix)
      when is_binary(name) and is_binary(prefix) and prefix != "" do
    value = Map.get(form || %{}, name)

    cond do
      t not in @structured_value_types and (is_map(value) or is_list(value)) -> nil
      t in ~w(richText reference image source array object) -> nil
      t in ~w(arrayOf composite codelist localizedText) -> nil
      t == "select" and Barkpark.Content.SelectOptions.radio?(field) -> nil
      true -> prefix <> name
    end
  end

  def label_target(_field, _form, _prefix), do: nil

  # [doc-keyed-ignore-wrappers] The id of a `phx-update="ignore"` wrapper that
  # owns a hidden input + web component (rich text, reference, image,
  # mediaAsset reference). LiveView never patches the children of an ignored
  # element, so with a field-name-only id (`bp-rt-wrap-body`) a doc→doc patch
  # in the same pane kept the PREVIOUS document's hidden input and widget, and
  # the next autosave wrote that document's body/author into the one now open
  # (task-eda246dcab63dc3f). Keying by the document makes a switch remount the
  # wrapper. The key is the PUBLISHED id: the first keystroke on a published
  # document turns `p1` into `drafts.p1`, and remounting then would drop the
  # caret mid-word. `form_gen` adds the same remount for a value the SERVER
  # replaced in the open document — another tab's save, Reload, a revision
  # restore (task-c7b0565a482b9d21); it is 0, and left out of the id, until then.
  defp doc_wrap_id(prefix, name, doc_key, form_gen) do
    key = "#{prefix}-#{name}-#{Barkpark.Content.DraftId.published_id(to_string(doc_key))}"
    if is_integer(form_gen) and form_gen > 0, do: "#{key}-g#{form_gen}", else: key
  end

  defp rich_text_readonly(assigns) do
    ~H"""
    <div data-readonly-field={@n}>
      <pre style="margin:0;padding:8px 10px;border:1px dashed var(--input);border-radius:6px;font-family:var(--font-mono);font-size:12px;white-space:pre-wrap;word-break:break-word;opacity:0.75;"><%= @v %></pre>
      <span style="display:block;margin-top:4px;font-size:11px;opacity:0.55;"><%= gettext("read-only — stored as block content, which the rich-text editor (HTML) cannot edit; saved unchanged") %></span>
    </div>
    """
  end

  @doc "The slug source for the schema field named `name` (default `\"title\"`)."
  @spec slug_source(map() | nil, String.t()) :: String.t()
  def slug_source(%{fields: fields}, name) when is_list(fields) do
    fields
    |> Enum.find(%{}, &(is_map(&1) and &1["name"] == name))
    |> slug_source_of()
  end

  def slug_source(_, _), do: "title"

  @doc """
  The document id a stored reference VALUE points at, as the string every
  picker's `value` attribute and hidden input carry.

  Studio persists a reference as the bare id string, but the API accepts — and
  `?expand` resolves — the Sanity-style object too (`{"_ref": id, "_type":
  "reference"}`, api-v1.md), so documents written through the JS SDK or
  `bp --set 'author:={"_ref":…}'` carry it. Rendered raw, that map crashed the
  whole editor with `Phoenix.HTML.Safe not implemented for Map` (a 500 on the
  document route; stranger walk 2026-09-30). The id it names is shown instead,
  and a Classic save keeps the stored object (an edit replaces its `_ref`) —
  `Forms` preserve guard.

  `nil` and anything with no readable id render as `""` (an empty picker).
  """
  @spec reference_id(term()) :: String.t()
  def reference_id(value) when is_binary(value), do: value
  def reference_id(%{"_ref" => ref}) when is_binary(ref), do: ref
  def reference_id(%{_ref: ref}) when is_binary(ref), do: ref
  def reference_id(_), do: ""

  @doc """
  Every target type a reference field may point at, in declaration order and
  deduplicated: `refType` (v1, one type), Sanity's `to: [{"type": t}, …]`, and
  the flat `refTypes: [t, …]`. `[]` when the field declares none.
  """
  @spec reference_types(map()) :: [String.t()]
  def reference_types(field) when is_map(field) do
    ref_type = Map.get(field, "refType") || Map.get(field, :refType)
    to = Map.get(field, "to") || Map.get(field, :to) || []
    ref_types = Map.get(field, "refTypes") || Map.get(field, :refTypes) || []

    ([ref_type] ++ to_types(to) ++ to_types(ref_types))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  def reference_types(_), do: []

  defp to_types(list) when is_list(list) do
    Enum.map(list, fn
      %{"type" => t} -> t
      %{type: t} -> t
      t when is_binary(t) -> t
      _ -> nil
    end)
  end

  defp to_types(_), do: []

  @doc """
  The image picker's wire value: a stored image object re-encoded as JSON, a
  string as is, anything else empty. Shared with the Beta block editor, whose
  field-image block carries the stored value verbatim.
  """
  def image_form_value(%{} = map), do: Jason.encode!(map)
  def image_form_value(v) when is_binary(v), do: v
  def image_form_value(_), do: ""

  # The words the field canvas hook shows when a save does not land
  # (task-fcbf22671c0c82df), in the Studio's language, keyed by the English.
  defp field_canvas_save_strings do
    Jason.encode!(%{
      "Save paused" => gettext("Save paused"),
      "This document changed elsewhere. Your edits are still here." =>
        gettext("This document changed elsewhere. Your edits are still here."),
      "Keep mine" => gettext("Keep mine"),
      "Use latest" => gettext("Use latest"),
      "Not saved" => gettext("Not saved"),
      "This edit was not saved. Your text is still here." =>
        gettext("This edit was not saved. Your text is still here.")
    })
  end
end
