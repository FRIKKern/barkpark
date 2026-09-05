defmodule BarkparkWeb.Components.Fields.ArrayField do
  @moduledoc """
  HEEx form component for v2 `arrayOf` field type
  (masterplan-20260425-085425, Phase 0 line 55, Decision 13).

  Renders one row per element using the element's field component. Per
  Decision 13, ordered arrays expose **up/down buttons (NO drag)** for
  reordering; unordered arrays hide them. Add and remove buttons are
  always present.

  All reorder events are pure server round-trips: buttons emit `phx-click`
  with `phx-value-action` (`move_up` / `move_down` / `add_row` / `remove_row`)
  and `phx-value-index`. The parent LiveView handles them via the helpers
  exposed below — `move_up/2`, `move_down/2`, `add_row/2`, `remove_row/2`.
  No JS hook, no Sortable.js (Decision 13 explicitly defers drag to v2).

  ## Assigns

    * `:field` (required) — `%Field{type: "arrayOf"}`
    * `:value` — list (defaults to `[]`)
    * `:errors` — `%{integer_index => [error_message, ...] | %{...}}`
    * `:on_change` — `phx-change` event name for inputs
    * `:on_reorder` — `phx-click` event name for up/down/add/remove buttons
      (defaults to `"array_op"`)
    * `:plugin_name` — codelist plugin scope (optional)
    * `:path` — dotted path prefix (optional)
    * `:readonly` — disable add/remove/reorder buttons and pass-through to
      element renderers (defaults to `false`).
  """

  use Phoenix.Component

  alias BarkparkWeb.Components.Fields.{CodelistField, CompositeField, LocalizedTextField}

  attr :field, :map, required: true
  attr :value, :list, default: []
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :on_reorder, :string, default: "array_op"
  attr :plugin_name, :string, default: "core"
  attr :path, :string, default: ""
  attr :readonly, :boolean, default: false
  # Picker context (tsk-dossier-ref-picker): reference rows mount the same
  # bp-reference-picker / bp-media-picker Web Components the top-level
  # FieldInputs use, so they need the dataset, the scoped-surface URL
  # prefix, and (for media uploads) the bearer token. Defaults keep every
  # caller that predates the attrs rendering flat + tokenless.
  attr :dataset, :string, default: "production"
  attr :scope_prefix, :string, default: ""
  attr :api_token_raw, :string, default: ""
  # Optional `phx-target` for the reorder/add/remove buttons. Defaults to nil —
  # buttons then bubble to the enclosing LiveView (StudioLive). When a
  # `Phoenix.LiveComponent.CID` is passed (e.g. `@myself` from PaperFieldBlock),
  # the buttons target that component so their `phx-click` events route there
  # instead of the parent LiveView.
  attr :target, :any, default: nil

  def array_field(assigns) do
    assigns =
      assigns
      |> Map.put_new(:value, [])
      |> Map.put_new(:errors, %{})
      |> Map.put_new(:on_change, nil)
      |> Map.put_new(:on_reorder, "array_op")
      |> Map.put_new(:plugin_name, "core")
      |> Map.put_new(:path, "")
      |> Map.put_new(:readonly, false)
      |> Map.put_new(:target, nil)
      |> Map.put(:title, title_for(assigns.field))
      |> Map.put(:description, CompositeField.description_for(assigns.field))
      |> Map.put(:rows, Enum.with_index(assigns[:value] || []))
      |> Map.put(:ordered?, !!assigns.field.ordered)
      |> Map.put(:progress, checklist_progress(assigns.field, assigns[:value]))

    ~H"""
    <fieldset class="bp-field bp-field-array" data-field-type="arrayOf"
              data-field-name={@field.name} data-ordered={@ordered? && "true"}>
      <legend class="bp-field-title">
        <%= @title %><%= if @progress do %>
          <span class="bp-array-progress" data-met={@progress.met} data-total={@progress.total}><%= @progress.met %>/<%= @progress.total %> met</span>
        <% end %>
      </legend>
      <p :if={@description} class="bp-field-description"><%= @description %></p>
      <ol class="bp-array-rows">
        <%= for {row_value, idx} <- @rows do %>
          <li class={"bp-array-row " <> if(composite_rows?(@field), do: "bp-array-row-item", else: "")} data-row-index={idx}>
            <div class="bp-array-row-body">
              <%= render_element(assigns, row_value, idx) %>
            </div>
            <div class="bp-array-row-actions">
              <%= if @ordered? do %>
                <button
                  type="button"
                  class="bp-array-btn bp-array-btn-up"
                  phx-click={@on_reorder}
                  phx-target={@target}
                  phx-value-action="move_up"
                  phx-value-field={@field.name}
                  phx-value-path={@path}
                  phx-value-index={idx}
                  disabled={@readonly or idx == 0}
                  aria-label="Move up"
                >▲</button>
                <button
                  type="button"
                  class="bp-array-btn bp-array-btn-down"
                  phx-click={@on_reorder}
                  phx-target={@target}
                  phx-value-action="move_down"
                  phx-value-field={@field.name}
                  phx-value-path={@path}
                  phx-value-index={idx}
                  disabled={@readonly or idx == length(@rows) - 1}
                  aria-label="Move down"
                >▼</button>
              <% end %>
              <button
                type="button"
                class="bp-array-btn bp-array-btn-remove"
                phx-click={@on_reorder}
                phx-target={@target}
                phx-value-action="remove_row"
                phx-value-field={@field.name}
                phx-value-path={@path}
                phx-value-index={idx}
                disabled={@readonly}
                aria-label="Remove row"
              >×</button>
            </div>
            <%= for err <- row_errors(@errors, idx) do %>
              <span class="error" data-error-for-row={idx}><%= err %></span>
            <% end %>
          </li>
        <% end %>
      </ol>
      <button
        type="button"
        class="bp-array-btn bp-array-btn-add"
        phx-click={@on_reorder}
        phx-target={@target}
        phx-value-action="add_row"
        phx-value-field={@field.name}
        phx-value-path={@path}
        disabled={@readonly}
      >+ Add</button>
    </fieldset>
    """
  end

  # ─── public helpers — pure list operations the parent LiveView calls when
  # handling a reorder event. They are the single source of truth for the
  # "array up/down persistence" contract (Phase 0 line 60). ───────────────

  @doc "Swap rows `idx` and `idx-1`. Returns the list unchanged if `idx <= 0`."
  @spec move_up(list(), non_neg_integer()) :: list()
  def move_up(list, idx) when is_list(list) and is_integer(idx) and idx > 0 do
    if idx < length(list), do: do_swap(list, idx - 1, idx), else: list
  end

  def move_up(list, _), do: list

  @doc "Swap rows `idx` and `idx+1`. Returns the list unchanged if `idx` is the last row."
  @spec move_down(list(), non_neg_integer()) :: list()
  def move_down(list, idx) when is_list(list) and is_integer(idx) and idx >= 0 do
    if idx < length(list) - 1, do: do_swap(list, idx, idx + 1), else: list
  end

  def move_down(list, _), do: list

  @doc "Append a row to the list."
  @spec add_row(list(), term()) :: list()
  def add_row(list, row) when is_list(list), do: list ++ [row]

  @doc "Remove the row at `idx`. Returns the list unchanged if `idx` is out of range."
  @spec remove_row(list(), non_neg_integer()) :: list()
  def remove_row(list, idx) when is_list(list) and is_integer(idx) and idx >= 0 do
    if idx < length(list), do: List.delete_at(list, idx), else: list
  end

  def remove_row(list, _), do: list

  # ─── private ────────────────────────────────────────────────────────────────

  defp do_swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)

    list
    |> List.replace_at(i, b)
    |> List.replace_at(j, a)
  end

  defp render_element(assigns, row_value, idx) do
    item = element_field(assigns.field)
    row_path = "#{assigns.path}[#{idx}]"

    case item.type do
      # Gyldendal parity E1.5 — a composite ROW is Sanity's array item: a
      # collapsed <details> whose summary is the item's PREVIEW (title,
      # subtitle, thumbnail — from the element's `preview` spec or the first
      # string / image subfield), opened only while the row is empty. The
      # composite itself renders `bare` inside; three feature cards read as
      # three one-line rows instead of six thousand pixels of raw inputs.
      "composite" ->
        preview = item_preview(item, row_value)

        item_row(%{
          item: item,
          idx: idx,
          preview: preview,
          open: row_empty?(row_value),
          row_id: "bp-item-" <> sanitize_id("#{assigns.field.name}#{row_path}"),
          body:
            CompositeField.composite_field(%{
              field: item,
              value: row_value || %{},
              errors: row_subfield_errors(assigns.errors, idx),
              on_change: assigns.on_change,
              plugin_name: assigns.plugin_name,
              path: row_path,
              readonly: assigns.readonly,
              bare: true
            })
        })

      "arrayOf" ->
        array_field(%{
          field: item,
          value: row_value || [],
          errors: row_subfield_errors(assigns.errors, idx),
          on_change: assigns.on_change,
          on_reorder: assigns.on_reorder,
          plugin_name: assigns.plugin_name,
          path: row_path,
          readonly: assigns.readonly,
          target: Map.get(assigns, :target)
        })

      "codelist" ->
        CodelistField.codelist_field(%{
          field: item,
          value: row_value,
          errors: row_subfield_errors(assigns.errors, idx),
          on_change: assigns.on_change,
          plugin_name: assigns.plugin_name,
          path: row_path,
          readonly: assigns.readonly
        })

      "localizedText" ->
        LocalizedTextField.localized_text_field(%{
          field: item,
          value: row_value || %{},
          errors: row_subfield_errors(assigns.errors, idx),
          on_change: assigns.on_change,
          path: row_path,
          readonly: assigns.readonly
        })

      "reference" ->
        # Per-row picker (tsk-dossier-ref-picker) — same WC + hidden-input +
        # BarkparkFieldBridge shape as FieldInputs, row-scoped. The wrapper
        # id is keyed on (name, VALUE): phx-update="ignore" pins the WC's
        # internal DOM to the id, so a reorder/selection that changes the
        # row's value changes the id too → LiveView swaps in a fresh wrapper
        # rendering the right value instead of leaving a stale ignored node.
        reference_row(%{
          wrap_id: ref_row_id(assigns.field, row_path, row_value, idx),
          input_name: row_path,
          row_value: to_string(row_value || ""),
          ref_type: ref_type_of(item),
          dataset: assigns[:dataset] || "production",
          scope_prefix: assigns[:scope_prefix] || "",
          api_token_raw: assigns[:api_token_raw] || "",
          on_change: assigns.on_change,
          readonly: assigns.readonly
        })

      _ ->
        leaf_assigns = %{
          input_id: "f-#{assigns.field.name}-#{idx}",
          input_name: row_path,
          row_value: row_value,
          on_change: assigns.on_change,
          readonly: assigns.readonly
        }

        leaf_input(leaf_assigns)
    end
  end

  defp item_row(assigns) do
    ~H"""
    <details class="bp-array-item" id={@row_id} open={@open} data-row-index={@idx}>
      <summary class="bp-array-item-summary">
        <span :if={@preview.media} class="bp-array-item-media" aria-hidden="true">
          <img src={@preview.media} alt="" loading="lazy" />
        </span>
        <span :if={!@preview.media} class="bp-array-item-media bp-array-item-media-empty" aria-hidden="true"></span>
        <span class="bp-array-item-text">
          <span class="bp-array-item-title"><%= @preview.title %></span>
          <span :if={@preview.subtitle} class="bp-array-item-subtitle"><%= @preview.subtitle %></span>
        </span>
        <span class="bp-array-item-chevron" aria-hidden="true">▾</span>
      </summary>
      <div class="bp-array-item-body">
        <%= @body %>
      </div>
    </details>
    """
  end

  # The item preview. A schema may declare Sanity's `preview.select`-like spec
  # on the element: `"preview": {"title": "title", "subtitle": "buttonHref",
  # "media": "backgroundImage"}` — each a subfield NAME (dotted paths walk
  # nested maps, `image.url` for a picker value). Without a spec: title is the
  # first non-empty string/text subfield, media the first image subfield's
  # url, subtitle nil. An empty row reads as the element's title ("Feature-
  # kort") so a freshly added card is named before it has content.
  @doc false
  def item_preview(item, row_value) do
    row = if is_map(row_value), do: row_value, else: %{}
    spec = (subfield_attr(item, :raw) || %{}) |> Map.get("preview") || %{}
    subs = (Map.get(item, :fields) || []) |> Enum.reject(&is_nil/1)

    title =
      pick(row, spec["title"]) ||
        first_text(row, subs) ||
        title_for(item) ||
        "Item"

    %{
      title: title,
      subtitle: pick(row, spec["subtitle"]),
      media: media_url(pick(row, spec["media"]) || first_image(row, subs))
    }
  end

  defp pick(_row, nil), do: nil

  defp pick(row, path) when is_binary(path) do
    row
    |> get_in_path(String.split(path, "."))
    |> case do
      "" -> nil
      v when is_binary(v) -> v
      %{} = m -> m
      _ -> nil
    end
  end

  defp get_in_path(v, []), do: v
  defp get_in_path(%{} = m, [h | t]), do: get_in_path(Map.get(m, h), t)
  defp get_in_path(_, _), do: nil

  defp first_text(row, subs) do
    Enum.find_value(subs, fn sub ->
      type = subfield_attr(sub, :type)
      name = subfield_attr(sub, :name)

      if type in ["string", "text"] and is_binary(name) do
        case Map.get(row, name) do
          v when is_binary(v) and v != "" -> v
          _ -> nil
        end
      end
    end)
  end

  defp first_image(row, subs) do
    Enum.find_value(subs, fn sub ->
      if subfield_attr(sub, :type) == "image", do: Map.get(row, subfield_attr(sub, :name))
    end)
  end

  # A picker value is a bare URL or a JSON/map {url, assetId, …}.
  defp media_url(%{"url" => url}) when is_binary(url) and url != "", do: url

  defp media_url(v) when is_binary(v) do
    cond do
      v == "" ->
        nil

      String.starts_with?(v, "{") ->
        v
        |> Jason.decode()
        |> case do
          {:ok, %{"url" => url}} when is_binary(url) and url != "" -> url
          _ -> nil
        end

      true ->
        v
    end
  end

  defp media_url(_), do: nil

  defp row_empty?(nil), do: true

  defp row_empty?(%{} = m),
    do: Enum.all?(m, fn {_, v} -> v in [nil, "", [], %{}] or v == false end)

  defp row_empty?(_), do: false

  defp composite_rows?(field), do: subfield_attr(element_field(field), :type) == "composite"

  defp sanitize_id(s), do: s |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-")

  # mediaAsset references browse/select from the media library; everything
  # else gets the generic document typeahead.
  defp reference_row(%{ref_type: "mediaAsset"} = assigns) do
    ~H"""
    <div id={@wrap_id} phx-update="ignore" phx-hook="BarkparkFieldBridge" class="bp-array-ref-row">
      <input
        type="hidden"
        id={"#{@wrap_id}-h"}
        name={@input_name}
        value={@row_value}
        phx-change={@on_change}
      />
      <bp-media-picker
        value={@row_value}
        value-mode="reference"
        dataset={@dataset}
        scope-prefix={@scope_prefix}
        data-bridge-target={"#{@wrap_id}-h"}
        data-token={@api_token_raw}
      ></bp-media-picker>
    </div>
    """
  end

  defp reference_row(assigns) do
    ~H"""
    <div id={@wrap_id} phx-update="ignore" phx-hook="BarkparkFieldBridge" class="bp-array-ref-row">
      <input
        type="hidden"
        id={"#{@wrap_id}-h"}
        name={@input_name}
        value={@row_value}
        phx-change={@on_change}
      />
      <bp-reference-picker
        value={@row_value}
        ref-type={@ref_type}
        dataset={@dataset}
        scope-prefix={@scope_prefix}
        data-bridge-target={"#{@wrap_id}-h"}
      ></bp-reference-picker>
    </div>
    """
  end

  # Stable-per-(slot,value) DOM id. phash2 keeps it short + id-safe; idx
  # disambiguates duplicate values across rows.
  defp ref_row_id(field, row_path, row_value, idx) do
    "bp-aref-#{field.name}-#{idx}-#{:erlang.phash2({row_path, row_value})}"
  end

  # refType lives on the RAW field map (a v1 leaf key parse/2 preserves
  # verbatim); parsed %Field{} carries it under .raw, plain maps directly.
  defp ref_type_of(%{raw: %{} = raw}), do: raw["refType"] || ""
  defp ref_type_of(%{} = item), do: item["refType"] || Map.get(item, :ref_type) || ""

  defp leaf_input(assigns) do
    ~H"""
    <input
      type="text"
      class="bp-input"
      id={@input_id}
      name={@input_name}
      value={leaf_display(@row_value)}
      phx-change={@on_change}
      disabled={@readonly}
    />
    """
  end

  # Never let a structured row value crash the render: a map/list reaching the
  # leaf fallback (e.g. a block missing its `of` descriptor) has no
  # String.Chars impl — `to_string/1` here used to take down the whole
  # LiveView. Render it as JSON so the row stays visible and editable-adjacent
  # instead of fatal.
  defp leaf_display(nil), do: ""
  defp leaf_display(v) when is_binary(v), do: v
  defp leaf_display(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)
  defp leaf_display(v), do: Jason.encode!(v)

  # The arrayOf parser stores the element shape on `field.of` (a `%Field{}`).
  defp element_field(%{of: %{} = of}), do: of
  defp element_field(_), do: %{type: "string", name: "item", title: nil}

  # Checklist progress badge (lvw-t6): when the element composite declares a
  # boolean subfield named `met` — the task schema's `acceptance_criteria`
  # shape, and any other checkable-rows arrayOf — the legend shows an
  # "m/n met" badge. Counting semantics are owned by the ONE canonical impl
  # (`Barkpark.Tasks.Criteria.of_list/1`, wire §4): `met` must be exactly
  # `true`, garbage rows count as unmet, and an empty/absent list yields
  # `nil` → no badge (omit, never "0/0"). Read-only render metadata — no
  # events, no persistence.
  defp checklist_progress(field, value) do
    if checklist_field?(element_field(field)) do
      Barkpark.Tasks.Criteria.of_list(value)
    else
      nil
    end
  end

  defp checklist_field?(%{} = item) do
    subfields =
      case subfield_attr(item, :fields) do
        fields when is_list(fields) -> fields
        _ -> []
      end

    subfield_attr(item, :type) == "composite" and
      Enum.any?(subfields, fn f ->
        is_map(f) and subfield_attr(f, :name) == "met" and subfield_attr(f, :type) == "boolean"
      end)
  end

  defp checklist_field?(_), do: false

  # Subfields arrive as parsed `%Field{}` structs (atom keys) or raw schema
  # maps (string keys) depending on the caller — read both.
  defp subfield_attr(%{} = f, key), do: Map.get(f, key) || Map.get(f, Atom.to_string(key))
  defp subfield_attr(_, _), do: nil

  defp title_for(%{title: t}) when is_binary(t) and t != "", do: t
  defp title_for(%{name: n}) when is_binary(n), do: humanize(n)
  defp title_for(_), do: ""

  defp humanize(name) do
    name
    |> String.replace(~r/[_\-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp row_errors(errors, idx) when is_map(errors) do
    case Map.get(errors, idx) do
      list when is_list(list) -> list
      %{__self__: list} when is_list(list) -> list
      _ -> []
    end
  end

  defp row_errors(_, _), do: []

  defp row_subfield_errors(errors, idx) when is_map(errors) do
    case Map.get(errors, idx) do
      sub when is_map(sub) -> sub
      _ -> %{}
    end
  end

  defp row_subfield_errors(_, _), do: %{}
end
