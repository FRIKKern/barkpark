defmodule BarkparkWeb.Studio.Desk.ImageParts do
  @moduledoc """
  The desk's image field around its picker, as the TanStack Studio's
  (`ImageInput.tsx`, J12): what an EMPTY field writes, the image's own
  fields under the image, and the look of its "Edit hotspot and crop"
  dialog.

  THE SHAPE. A new image in an empty field is Sanity's canonical value,
  `{_type: "image", asset: {_type: "reference", _ref}}` (TanStack's
  `pickedImage`), so the picker is asked for the reference shape. A field
  already holding the legacy `{url, assetId, …}` shape (migrated content)
  keeps it: the picker would otherwise write a reference it has no ref for.
  The hotspot `{x, y, width, height}`, the crop `{top, bottom, left,
  right}` and the declared fields (`alt`) sit on the image object in either
  shape, as Sanity stores them (docs/contracts/schema-v2.md "Stored value
  shapes"). The save path is the picker's hidden input, as before: nothing
  here writes.

  THE IMAGE'S FIELDS. Each declared string or text subfield is a field of
  its own under the image (TanStack's `FieldView` per `field.fields`): its
  title as the label, its "Field actions" place, an input named by its path
  (`mainImage.alt`). The input belongs to no form (`form`, an id no form
  has): what is typed goes to the picker (`bp-desk-image.js`), which puts
  it on the image object and saves the field as a whole.

  THE DIALOG is drawn by `bp-desk-image.js` into the page's body, over the
  form; its look is here (`sheet/1`), in the desk's tokens.
  """
  use Phoenix.Component

  alias BarkparkWeb.Studio.Desk.FieldActions

  @part_types ~w(string text)
  # An id no element of the page has: the input is in no form.
  @no_form "dk-image-part-no-form"

  @doc """
  The value shape an image field asks its picker for in the desk:
  `"asset-ref"` unless the stored value is the legacy shape (a URL string,
  or a map naming `url` or `assetId` without an `asset`).
  """
  @spec value_shape(term()) :: String.t() | nil
  def value_shape(stored) do
    if legacy?(stored), do: nil, else: "asset-ref"
  end

  defp legacy?(%{"asset" => %{}}), do: false
  defp legacy?(%{} = map), do: Map.has_key?(map, "url") or Map.has_key?(map, "assetId")

  defp legacy?(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        false

      "{" <> _ = json ->
        case Jason.decode(json) do
          {:ok, %{} = map} -> legacy?(map)
          _ -> true
        end

      _url ->
        true
    end
  end

  defp legacy?(_), do: false

  @doc "The subfields drawn under the image: its declared string and text fields."
  @spec parts(map()) :: [map()]
  def parts(%{"fields" => fields}) when is_list(fields),
    do: Enum.filter(fields, &(is_map(&1) and is_binary(&1["name"]) and &1["type"] in @part_types))

  def parts(_field), do: []

  attr :field, :map, required: true, doc: "the image field's schema"
  attr :value, :any, required: true, doc: "the stored image value (a map or its JSON)"
  attr :locked, :boolean, default: false, doc: "the image field is read-only here"

  @doc "The image's own fields, each a `.field` of its own under the image."
  def fields(assigns) do
    assigns =
      assign(assigns,
        image: assigns.field["name"],
        parts: parts(assigns.field),
        stored: decoded(assigns.value),
        no_form: @no_form
      )

    ~H"""
    <div :for={part <- @parts} class="editor-field field dk-image-part">
      <label class="editor-field-label" for={"#{@image}.#{part["name"]}"}>{part["title"] || part["name"]}</label>
      <FieldActions.menu name={"#{@image}.#{part["name"]}"} paste={not @locked} />
      <input
        :if={part["type"] == "string"}
        id={"#{@image}.#{part["name"]}"}
        type="text"
        class="form-input"
        form={@no_form}
        value={text(@stored, part["name"])}
        readonly={@locked}
        data-desk-image-part={part["name"]}
        data-desk-image-for={@image}
      />
      <textarea
        :if={part["type"] == "text"}
        id={"#{@image}.#{part["name"]}"}
        class="form-input"
        rows="3"
        form={@no_form}
        readonly={@locked}
        data-desk-image-part={part["name"]}
        data-desk-image-for={@image}
      >{text(@stored, part["name"])}</textarea>
    </div>
    """
  end

  defp decoded(%{} = map), do: map

  defp decoded(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decoded(_), do: %{}

  defp text(stored, name) do
    case Map.get(stored, name) do
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  @doc "The crop button and the dialog's look, in the desk's tokens."
  def sheet(assigns) do
    ~H"""
    <style>
      .dk .dk-edit fieldset.editor-field > .field-actions { top: -34px; }
      .dk .dk-edit .dk-image-part { margin-top: 32px; }
      .dk .dk-edit .bp-mp-crop { box-sizing: border-box; display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: var(--dk-glass); box-shadow: inset 0 0 0 1px var(--dk-line); color: var(--dk-icon-muted); cursor: pointer; }
      .dk .dk-edit .bp-mp-crop svg { width: 21px; height: 21px; }
      @media (max-width: 768px) and (pointer: coarse) { .dk .dk-edit .bp-mp-crop { width: 44px; height: 44px; } }
      .dk.dk-crop-layer { --dk-crop-line: rgb(255 255 255 / 0.5); --dk-crop-line-hot: rgb(255 255 255); --dk-crop-handle: rgb(255 255 255); --dk-crop-handle-ring: rgb(0 0 0); --dk-crop-dim: rgb(0 0 0 / 0.5); position: fixed; z-index: 60; display: grid; place-items: center; grid-template-rows: minmax(0, 1fr); background: var(--dk-backdrop); color: var(--dk-fg); font-size: 13px; line-height: 19px; }
      .dk.dk-crop-layer .dk-crop-dialog { box-sizing: border-box; width: min(640px, calc(100% - 24px)); max-height: calc(100% - 24px); display: flex; flex-direction: column; border-radius: 6px; background: var(--dk-bg); box-shadow: var(--dk-popover-shadow); }
      .dk.dk-crop-layer .dk-dialog-head { display: flex; align-items: center; justify-content: space-between; padding: 12px 12px 0 20px; }
      .dk.dk-crop-layer h2 { margin: 0; font-size: 13px; line-height: 19px; font-weight: 600; }
      .dk.dk-crop-layer .dk-dialog-close { display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
      .dk.dk-crop-layer .dk-dialog-close:hover { background: var(--dk-icon-hover); color: var(--dk-fg); }
      .dk.dk-crop-layer :is(button, [tabindex]):focus-visible { outline: 1px solid var(--dk-focus-ring); outline-offset: -1px; }
      .dk.dk-crop-layer .dialog-body { padding: 8px 20px; overflow: auto; }
      .dk.dk-crop-layer .label { font-weight: 500; margin: 32px 0 4px; }
      .dk.dk-crop-layer .muted { max-width: 464px; margin: 0; color: var(--dk-muted); }
      .dk.dk-crop-layer .hotspot-tool { position: relative; margin: 12px 0 28px; display: flex; justify-content: center; padding: 12px; background: repeating-conic-gradient(var(--dk-fill-soft) 0 25%, var(--dk-bg) 0 50%) 0 0 / 16px 16px; box-shadow: inset 0 0 0 1px var(--dk-border); }
      .dk.dk-crop-layer .hotspot-tool > svg { max-width: 100%; height: auto; overflow: visible; user-select: none; }
      .dk.dk-crop-layer .crop-dim { fill: var(--dk-crop-dim); }
      .dk.dk-crop-layer .crop-area { fill: transparent; cursor: move; }
      .dk.dk-crop-layer .crop-rect { fill: none; stroke: var(--dk-crop-line); stroke-width: 1; pointer-events: none; outline: none; }
      .dk.dk-crop-layer .hotspot { fill: transparent; stroke: var(--dk-crop-line); stroke-width: 1; cursor: move; outline: none; }
      .dk.dk-crop-layer .hotspot-tool:is(:has(.crop-area:hover), :has(.handle-hit[data-handle^=crop]:hover), [data-dragging=crop]) .crop-rect,
      .dk.dk-crop-layer .hotspot-tool:is(:has(.hotspot:hover), :has(.handle-hit[data-handle=hotspotHandle]:hover), [data-dragging=hotspot]) .hotspot { stroke: var(--dk-crop-line-hot); }
      .dk.dk-crop-layer .crop-rect:focus-visible, .dk.dk-crop-layer .hotspot:focus-visible { stroke: var(--dk-focus-ring); stroke-width: 2; }
      .dk.dk-crop-layer :is(.hotspot-handle, .crop-handle) { fill: var(--dk-crop-handle); stroke: var(--dk-crop-handle-ring); stroke-width: 1; }
      .dk.dk-crop-layer :is(.crop-rect, .hotspot, .hotspot-handle, .crop-handle, .hotspot-guides line) { vector-effect: non-scaling-stroke; }
      .dk.dk-crop-layer .hotspot-tool:has(.hotspot:focus-visible) .hotspot-handle, .dk.dk-crop-layer .hotspot-tool:has(.crop-rect:focus-visible) .crop-handle { stroke: var(--dk-focus-ring); }
      .dk.dk-crop-layer .handle-hit { fill: transparent; }
      .dk.dk-crop-layer .hotspot-guides { stroke: var(--dk-fg); stroke-opacity: 0.2; stroke-width: 1; stroke-dasharray: 3 3; pointer-events: none; }
      .dk.dk-crop-layer .handle-grab { display: none; fill: transparent; }
      .dk.dk-crop-layer [data-handle="hotspotHandle"], .dk.dk-crop-layer [data-handle="crop-topLeft"], .dk.dk-crop-layer [data-handle="crop-bottomRight"] { cursor: nwse-resize; }
      .dk.dk-crop-layer [data-handle="crop-top"], .dk.dk-crop-layer [data-handle="crop-bottom"] { cursor: ns-resize; }
      .dk.dk-crop-layer [data-handle="crop-left"], .dk.dk-crop-layer [data-handle="crop-right"] { cursor: ew-resize; }
      .dk.dk-crop-layer [data-handle="crop-topRight"], .dk.dk-crop-layer [data-handle="crop-bottomLeft"] { cursor: nesw-resize; }
      .dk.dk-crop-layer .crop-size { opacity: 0; transition: opacity 0.15s; }
      .dk.dk-crop-layer .hotspot-tool:is(:has(.crop-area:hover), :has(.handle-hit[data-handle^=crop]:hover), :has(.crop-rect:focus-visible), [data-dragging=crop]) .crop-size { opacity: 1; }
      .dk.dk-crop-layer .crop-size rect { fill: var(--dk-focus-ring); }
      .dk.dk-crop-layer .crop-size text { fill: var(--dk-crop-line-hot); font-size: 10px; font-weight: 500; }
      .dk.dk-crop-layer .crop-previews { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-bottom: 12px; align-items: start; }
      .dk.dk-crop-layer .crop-previews[hidden] { display: none; }
      .dk.dk-crop-layer .crop-previews figure { margin: 0; }
      .dk.dk-crop-layer .crop-previews figcaption { font-size: 13px; font-weight: 600; margin-bottom: 6px; }
      .dk.dk-crop-layer .crop-preview { position: relative; overflow: hidden; background: repeating-conic-gradient(var(--dk-fill-soft) 0 25%, var(--dk-bg) 0 50%) 0 0 / 16px 16px; outline: 1px solid var(--dk-border); outline-offset: -1px; }
      .dk.dk-crop-layer .crop-preview img { position: absolute; max-width: none; }
      @media (max-width: 599px) and (pointer: coarse) { .dk.dk-crop-layer .handle-grab { display: inline; } }
    </style>
    """
  end
end
