defmodule BarkparkWeb.Studio.PaperFieldBlock do
  @moduledoc """
  Edit-mode control for a v2 COMPOSITE field block in the in-Studio paper
  editor (P2.3, barkpark-wxxa). One nested `Phoenix.LiveComponent` per
  composite block — `composite`, `arrayOf`, `codelist`, `localizedText`.

  ## Why a LiveComponent (research verdict B)

  The P2.1/P2.2 leaf + picker field blocks are client-side controls hosted
  under `<div phx-update="ignore" phx-hook="BarkparkFieldBlockBridge">` — they
  emit a `{op:"patch-block",…}` op via `pushEvent("paper-op")`. The v2
  composites CANNOT use that pattern: they emit **server-bound**
  `phx-change` / `phx-click` into a parent form, and the `arrayOf` reorder
  buttons + (deferred) `TreeCodelistField` are themselves stateful server
  surfaces. `phx-update="ignore"` would freeze them. So each composite block
  becomes a nested LiveComponent whose inner field components target
  `@myself`; on any inner change the component recomputes its OWN `value` and
  notifies the parent paper LiveView with the SAME `:paper_op` message the
  client bridge would have sent, routing through the canonical `paper_op/2`
  pipeline (persist + stream broadcast).

  ## Value shapes

    * `composite`      → `%{sub_name => value}`
    * `arrayOf`        → `[element, …]`
    * `codelist`       → `"code"` (string) or `nil`
    * `localizedText`  → `%{language => text}`

  ## Stream ↔ LiveComponent state/focus

  Edit mode is **assign-driven HTML**, NOT a stream (the streamed surface is
  the read-only View pane; see `studio_live.ex` `studio_paper_view/1`). After a
  `patch-block` op, `paper_op/2` re-syncs `paper_doc` and re-renders the
  assign-driven editor, which re-sends `update/2` to this component with the
  fresh block. To avoid clobbering an in-flight edit / losing input focus the
  component updates its OWN `:value` assign locally on every inner change
  BEFORE sending `:paper_op`. So when the server echo lands, the value the
  component re-derives from `block["value"]` already matches what is in the
  DOM — LiveView's diff is a no-op for the touched input and the caret is
  preserved. `update/2` is idempotent: it always re-derives from `assigns.block`
  but the local-first update means the echo never moves the cursor.

  ## Config-carrying blocks

  Each block carries its field CONFIG inline next to the `value`. The component
  builds a `%Barkpark.Content.SchemaDefinition.Field{}` descriptor from that
  inline config and hands it to the existing field component verbatim:

    * composite     — `"fields"` → subfield descriptors
    * arrayOf        — `"of"` element descriptor + `"ordered"` flag
    * codelist       — `"codelistId"` + `"version"`
    * localizedText  — `"languages"` + `"format"` + `"fallbackChain"`
  """

  use BarkparkWeb, :live_component

  alias BarkparkWeb.Components.Fields.{
    ArrayField,
    CodelistField,
    CompositeField,
    LocalizedTextField,
    TreeCodelistField
  }

  alias Barkpark.Content.SchemaDefinition.Field

  @impl true
  def update(%{block: block} = assigns, socket) do
    field_type = Map.get(block, "type")

    socket =
      socket
      |> assign(assigns)
      |> assign(:block_id, Map.get(block, "id"))
      |> assign(:field_type, field_type)
      |> assign(:label, Map.get(block, "label", ""))
      # codelist-only: the registry plugin discriminator (defaults to "core",
      # the same default CodelistField carries) and the picker variant
      # ("flat" → CodelistField <select>/<datalist>; "tree" → TreeCodelistField).
      |> assign(:plugin, Map.get(block, "plugin", "core"))
      |> assign(:variant, block_variant(block))
      # Always re-derive value from the block. The local-first update on inner
      # change means the server echo carries the value already in the DOM, so
      # this re-derive is a no-op diff for the edited input (focus preserved).
      |> assign(:value, derive_value(block))
      |> assign(:field, build_field(block))

    {:ok, socket}
  end

  # A tree-codelist row select arrives here via `send_update/3` (routed by the
  # host LiveView from the nested TreeCodelistField's notify). It carries only
  # the picked code under `:tree_value`. Persist it exactly like an inner form
  # change: update OWN value local-first, then send the canonical patch-block
  # op to the parent. The component's other assigns (block/field/variant) are
  # already set from the prior `%{block: …}` update — `send_update` merges.
  def update(%{tree_value: code}, socket) do
    {:ok, persist(socket, code)}
  end

  # ── render dispatch — one inner field component per type ────────────────────

  # NOTE on `path`: the inner field components separate composite subfields and
  # localizedText languages with a literal `.` (e.g. `prefix.subname`). Phoenix
  # decodes form params via `Plug.Conn.Query`, where `.` is NOT a nesting
  # separator — only `[…]` nests. So a dotted path ALWAYS arrives as a flat
  # key. We therefore render the inner components with `path=""`, which makes
  # composite/localizedText inputs name themselves with the bare subfield/lang
  # name (clean top-level keys), arrayOf SCALAR rows name `[0]` / `[1]` and
  # arrayOf COMPOSITE-element subfields name `[0].subname` / `[0].a.b` /
  # `[0].tags[1]` (bracket-anchored keys we parse), and codelist names itself
  # with the empty key. `merge_change` parses these flat params back into the
  # structured value.
  @impl true
  def render(%{field_type: "composite"} = assigns) do
    ~H"""
    <div id={@id} class="bp-paper-composite-block" data-field-type="composite" data-block-id={@block_id}>
      <form phx-change="inner-change" phx-target={@myself}>
        <CompositeField.composite_field field={@field} value={@value} on_change="inner-change" path="" />
      </form>
    </div>
    """
  end

  # chips — a thin RENDER variant of arrayOf (string `of`). Scalar chip inputs
  # name themselves `[i]` so the form's phx-change="inner-change" routes inline
  # edits through merge_change("arrayOf",…) verbatim; the × / + Add buttons route
  # through the existing inner-array-op handler (remove_row/add_row → persist/2).
  # Must precede the bare arrayOf head (function-clause order: specific first),
  # exactly like the codelist+tree head precedes the bare codelist head.
  def render(%{field_type: "arrayOf", variant: "chips"} = assigns) do
    ~H"""
    <div id={@id} class="bp-paper-composite-block" data-field-type="arrayOf" data-block-id={@block_id} data-array-variant="chips">
      <form phx-change="inner-change" phx-target={@myself}>
        <ul class="bp-paper-chips">
          <li :for={{chip, i} <- Enum.with_index(@value)} class="bp-paper-chip">
            <input type="text" name={"[#{i}]"} value={chip} />
            <button
              type="button"
              phx-click="inner-array-op"
              phx-target={@myself}
              phx-value-action="remove_row"
              phx-value-index={i}
              aria-label="Remove"
            >×</button>
          </li>
        </ul>
        <button
          type="button"
          phx-click="inner-array-op"
          phx-target={@myself}
          phx-value-action="add_row"
        >+ Add</button>
      </form>
    </div>
    """
  end

  def render(%{field_type: "arrayOf"} = assigns) do
    ~H"""
    <div id={@id} class="bp-paper-composite-block" data-field-type="arrayOf" data-block-id={@block_id}>
      <form phx-change="inner-change" phx-target={@myself}>
        <ArrayField.array_field
          field={@field}
          value={@value}
          on_change="inner-change"
          on_reorder="inner-array-op"
          target={@myself}
          path=""
        />
      </form>
    </div>
    """
  end

  # codelist — two variants share the SAME surrounding form. The form's
  # phx-change="inner-change" (targeting @myself) is what carries the picked
  # value home in BOTH cases:
  #
  #   * "flat" → CodelistField renders a native <select>/<datalist>/(small-tree)
  #     <select>; its own phx-change="inner-change" + path="value" fire the form
  #     change as %{"value" => code}.
  #   * "tree" → TreeCodelistField is a nested LiveComponent with its OWN
  #     expand/select/search state. It does NOT phx-change; instead it writes the
  #     picked code into a hidden `<input name="value">` inside this form. A
  #     tree-row select re-renders that hidden input with the new value, and the
  #     surrounding form's phx-change fires inner-change with %{"value" => code},
  #     which `merge_change("codelist", …)` reads exactly like the flat path.
  #
  # The tree component gets a STABLE id derived from the block id so it mounts
  # once and keeps its internal state across the parent's value echo (the same
  # local-first idempotence the leaf composites rely on).
  def render(%{field_type: "codelist", variant: "tree"} = assigns) do
    ~H"""
    <div id={@id} class="bp-paper-composite-block" data-field-type="codelist" data-block-id={@block_id} data-codelist-variant="tree">
      <form phx-change="inner-change" phx-target={@myself}>
        <.live_component
          module={TreeCodelistField}
          id={"tree-" <> @block_id}
          field={@field}
          value={@value}
          on_change="inner-change"
          plugin_name={@plugin}
          list_id={@field.codelist_id}
          input_name="value"
          notify_id={@id}
        />
      </form>
    </div>
    """
  end

  def render(%{field_type: "codelist"} = assigns) do
    ~H"""
    <div id={@id} class="bp-paper-composite-block" data-field-type="codelist" data-block-id={@block_id} data-codelist-variant="flat">
      <form phx-change="inner-change" phx-target={@myself}>
        <CodelistField.codelist_field
          field={@field}
          value={@value}
          on_change="inner-change"
          plugin_name={@plugin}
          path="value"
        />
      </form>
    </div>
    """
  end

  def render(%{field_type: "localizedText"} = assigns) do
    ~H"""
    <div id={@id} class="bp-paper-composite-block" data-field-type="localizedText" data-block-id={@block_id}>
      <form phx-change="inner-change" phx-target={@myself}>
        <LocalizedTextField.localized_text_field
          field={@field}
          value={@value}
          on_change="inner-change"
          path=""
        />
      </form>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="bp-paper-composite-block bp-paper-composite-unknown" data-block-id={@block_id}>
      <p class="bp-paper-edit-readonly">
        <%= @field_type %> blocks are not editable yet.
      </p>
    </div>
    """
  end

  # ── inner events: recompute OWN value, notify parent via :paper_op ──────────

  # An inner field input changed. Inner components render with `path=""`, so the
  # changed values arrive as FLAT top-level params (minus the LiveView
  # `_target` key). `merge_change` reassembles them into this block's
  # structured value for the active type. Update the LOCAL value first
  # (focus-preserving), then send the canonical patch-block op to the parent.
  @impl true
  def handle_event("inner-change", params, socket) do
    params = Map.drop(params, ["_target", "_csrf_token"])
    new_value = merge_change(socket.assigns.field_type, socket.assigns.value, params)

    {:noreply, persist(socket, new_value)}
  end

  # arrayOf structural op (add / remove / move_up / move_down) on THIS block's
  # own list value, replicating the parent `array_op` list helpers. We operate
  # on the component's own value, then send the same patch-block op.
  def handle_event("inner-array-op", %{"action" => action} = params, socket) do
    list = List.wrap(socket.assigns.value)
    idx = parse_idx(params["index"])

    new_list =
      case action do
        "add_row" -> ArrayField.add_row(list, empty_element(socket.assigns.field))
        "remove_row" -> ArrayField.remove_row(list, idx)
        "move_up" -> ArrayField.move_up(list, idx)
        "move_down" -> ArrayField.move_down(list, idx)
        _ -> list
      end

    {:noreply, persist(socket, new_list)}
  end

  # ── value persistence ───────────────────────────────────────────────────────

  # Update the component's own value assign (focus-preserving on the echo),
  # then notify the paper LiveView with a patch-block op carrying the new
  # value. The parent routes it through the canonical `paper_op/2` pipeline
  # (Content.apply_paper_block_op → persist + broadcast + re-sync).
  defp persist(socket, new_value) do
    op = %{
      "op" => "patch-block",
      "id" => socket.assigns.block_id,
      "patch" => %{"value" => new_value}
    }

    send(self(), {:paper_op, op})
    assign(socket, :value, new_value)
  end

  # ── value derivation + merge ────────────────────────────────────────────────

  defp derive_value(%{"type" => "arrayOf"} = block), do: List.wrap(Map.get(block, "value", []))
  defp derive_value(%{"type" => "codelist"} = block), do: Map.get(block, "value")

  defp derive_value(%{"type" => type} = block) when type in ["composite", "localizedText"],
    do: Map.get(block, "value", %{}) || %{}

  defp derive_value(block), do: Map.get(block, "value")

  # composite: with `path=""` the subfield inputs carry the bare subfield name,
  # so params arrive as a flat `%{sub_name => value}` map. Merge over the
  # current map so untouched sub-fields survive a single-field change.
  defp merge_change("composite", current, params) when is_map(params) do
    Map.merge(current || %{}, params)
  end

  # localizedText: same flat shape — `%{lang => text}`.
  defp merge_change("localizedText", current, params) when is_map(params) do
    Map.merge(current || %{}, params)
  end

  # arrayOf: with `path=""` the row inputs name themselves by their position in
  # the list. A SCALAR element names itself `[0]`, `[1]`, … (the bare bracket
  # index). A COMPOSITE element's subfields name themselves `[0].amount`,
  # `[0].currency`, … and a nested composite/array inside a composite element
  # extends that further (`[0].price.amount`, `[0].tags[1]`). `Plug.Conn.Query`
  # does NOT nest through `.` or a leading `[`, so EVERY one of these arrives as
  # a FLAT param key. We parse each key into a path of mixed integer indices
  # (from `[N]`) and string keys (from `.name`), then deep-merge each
  # (path, value) into the current list. The current list's length is the floor
  # so a blank/absent input never truncates it.
  defp merge_change("arrayOf", current, params) when is_map(params) do
    list = List.wrap(current)

    # Parse keys into {path, value}; drop any key we can't parse to a valid
    # leading `[N]` index.
    parsed =
      params
      |> Enum.map(fn {k, v} -> {parse_key_path(k), v} end)
      |> Enum.reject(fn {path, _v} -> path == [] end)

    seen =
      parsed
      |> Enum.map(fn {[idx | _], _} -> idx end)
      |> Enum.max(fn -> -1 end)

    max_idx = max(length(list) - 1, seen)

    if max_idx < 0 do
      list
    else
      base = Enum.map(0..max_idx, fn i -> Enum.at(list, i) end)
      Enum.reduce(parsed, base, fn {path, value}, acc -> put_path(acc, path, value) end)
    end
  end

  # codelist: the single value rides under the `"value"` key (path="value"),
  # so params arrive as `%{"value" => "code"}`.
  defp merge_change("codelist", current, params) when is_map(params) do
    case Map.get(params, "value") do
      nil -> current
      v -> v
    end
  end

  defp merge_change(_type, current, _params), do: current

  # ── Field descriptor construction from inline block config ──────────────────

  # composite — subfields parsed into nested %Field{} descriptors.
  defp build_field(%{"type" => "composite"} = block) do
    %Field{
      name: Map.get(block, "id"),
      type: "composite",
      title: Map.get(block, "label"),
      fields: Enum.map(Map.get(block, "fields", []), &build_subfield/1)
    }
  end

  # arrayOf — `of` element descriptor + `ordered` flag.
  defp build_field(%{"type" => "arrayOf"} = block) do
    %Field{
      name: Map.get(block, "id"),
      type: "arrayOf",
      title: Map.get(block, "label"),
      ordered: Map.get(block, "ordered", false) == true,
      of: build_subfield(Map.get(block, "of", %{"type" => "string"}))
    }
  end

  # codelist — `codelistId` + optional pinned `version`.
  defp build_field(%{"type" => "codelist"} = block) do
    %Field{
      name: Map.get(block, "id"),
      type: "codelist",
      title: Map.get(block, "label"),
      codelist_id: Map.get(block, "codelistId"),
      version: Map.get(block, "version")
    }
  end

  # localizedText — languages / format / fallbackChain.
  defp build_field(%{"type" => "localizedText"} = block) do
    %Field{
      name: Map.get(block, "id"),
      type: "localizedText",
      title: Map.get(block, "label"),
      languages: Map.get(block, "languages", []),
      format: localized_format(Map.get(block, "format", "plain")),
      fallback_chain: Map.get(block, "fallbackChain", [])
    }
  end

  defp build_field(block) do
    %Field{
      name: Map.get(block, "id"),
      type: Map.get(block, "type"),
      title: Map.get(block, "label")
    }
  end

  # A subfield / array-element descriptor. Recurses into nested composites,
  # arrays, codelists, localizedText so deeply-nested config is honoured.
  defp build_subfield(%{"type" => "composite"} = f) do
    %Field{
      name: Map.get(f, "name"),
      type: "composite",
      title: Map.get(f, "title"),
      fields: Enum.map(Map.get(f, "fields", []), &build_subfield/1),
      options: Map.get(f, "options"),
      onix: Map.get(f, "onix")
    }
  end

  defp build_subfield(%{"type" => "arrayOf"} = f) do
    %Field{
      name: Map.get(f, "name"),
      type: "arrayOf",
      title: Map.get(f, "title"),
      ordered: Map.get(f, "ordered", false) == true,
      of: build_subfield(Map.get(f, "of", %{"type" => "string"}))
    }
  end

  defp build_subfield(%{"type" => "codelist"} = f) do
    %Field{
      name: Map.get(f, "name"),
      type: "codelist",
      title: Map.get(f, "title"),
      codelist_id: Map.get(f, "codelistId"),
      version: Map.get(f, "version")
    }
  end

  defp build_subfield(%{"type" => "localizedText"} = f) do
    %Field{
      name: Map.get(f, "name"),
      type: "localizedText",
      title: Map.get(f, "title"),
      languages: Map.get(f, "languages", []),
      format: localized_format(Map.get(f, "format", "plain")),
      fallback_chain: Map.get(f, "fallbackChain", [])
    }
  end

  defp build_subfield(f) when is_map(f) do
    %Field{
      name: Map.get(f, "name"),
      type: Map.get(f, "type", "string"),
      title: Map.get(f, "title"),
      options: Map.get(f, "options"),
      onix: Map.get(f, "onix")
    }
  end

  defp build_subfield(_), do: %Field{name: "item", type: "string"}

  # An empty element for a freshly-added arrayOf row, shaped to the `of` type.
  defp empty_element(%Field{of: %Field{type: "composite"}}), do: %{}
  defp empty_element(%Field{of: %Field{type: "arrayOf"}}), do: []
  defp empty_element(%Field{of: %Field{type: "localizedText"}}), do: %{}
  defp empty_element(%Field{of: %Field{type: "codelist"}}), do: nil
  defp empty_element(_), do: ""

  defp localized_format("rich"), do: :rich
  defp localized_format(_), do: :plain

  # Codelist picker variant. Explicit `"variant"` wins; otherwise "flat".
  # Tree-vs-flat is an explicit block decision (not auto-derived from registry
  # shape here) so a block author opts into the heavier tree LiveComponent
  # deliberately — CodelistField still auto-promotes a large hierarchical flat
  # block to a tree when the registry is hierarchical, but the PaperFieldBlock
  # host honours the block's stated intent.
  defp codelist_variant(%{"variant" => "tree"}), do: "tree"
  defp codelist_variant(_), do: "flat"

  # Block render variant — the union of the arrayOf chips axis and the codelist
  # tree/flat axis. arrayOf honours an explicit "chips" intent (a thin render
  # skin over the arrayOf data path); codelist delegates to codelist_variant/1
  # so its tree/flat render heads keep matching unchanged. Everything else is
  # "flat". Keep codelist_variant/1 codelist-specific — do NOT widen it.
  defp block_variant(%{"type" => "arrayOf", "variant" => "chips"}), do: "chips"
  defp block_variant(%{"type" => "codelist"} = b), do: codelist_variant(b)
  defp block_variant(_), do: "flat"

  defp parse_idx(idx) when is_binary(idx) do
    case Integer.parse(idx) do
      {n, _} -> n
      _ -> -1
    end
  end

  defp parse_idx(idx) when is_integer(idx), do: idx
  defp parse_idx(_), do: -1

  # Parse an arrayOf input NAME into a path of segments. The first segment is
  # ALWAYS the integer list index (from a leading `[N]`); subsequent segments
  # are string subfield keys (from `.name`) or integer indices (from `[N]`),
  # honouring composites and nested arrays inside a composite element.
  #
  #   "[0]"                 -> [0]
  #   "[0].amount"          -> [0, "amount"]
  #   "[0].price.amount"    -> [0, "price", "amount"]
  #   "[0].tags[1]"         -> [0, "tags", 1]
  #
  # Returns `[]` for any name without a valid leading `[N]` so the caller can
  # skip it (e.g. a stray non-array param).
  defp parse_key_path(k) when is_binary(k) do
    case Regex.run(~r/^\[(\d+)\](.*)$/, k) do
      [_, n, rest] -> [String.to_integer(n) | parse_rest_segments(rest)]
      _ -> []
    end
  end

  defp parse_key_path(_), do: []

  # Tokenise the remainder after the leading `[N]` into segments. `.name`
  # yields a string key; `[N]` yields an integer index.
  defp parse_rest_segments(""), do: []

  defp parse_rest_segments(rest) when is_binary(rest) do
    ~r/\.([^.\[\]]+)|\[(\d+)\]/
    |> Regex.scan(rest)
    |> Enum.map(fn
      [_, name] when name != "" -> name
      [_, "", idx] -> String.to_integer(idx)
    end)
  end

  # Deep-set `value` at `path` (a list of integer indices / string keys) within
  # `acc`, creating intermediate lists/maps as the path dictates. A single
  # `[idx]` path replaces the whole element (the scalar-array contract).
  defp put_path(acc, [idx], value) when is_integer(idx) and is_list(acc) do
    replace_at_grow(acc, idx, value)
  end

  defp put_path(acc, [idx | rest], value) when is_integer(idx) and is_list(acc) do
    child = Enum.at(acc, idx)
    replace_at_grow(acc, idx, put_path_in(child, rest, value))
  end

  defp put_path(acc, _path, _value), do: acc

  # Set into a composite element (map) or a nested array (list) within an
  # element, following the remaining segments.
  defp put_path_in(child, [key], value) when is_binary(key) do
    Map.put(ensure_map(child), key, value)
  end

  defp put_path_in(child, [key | rest], value) when is_binary(key) do
    m = ensure_map(child)
    Map.put(m, key, put_path_in(Map.get(m, key), rest, value))
  end

  defp put_path_in(child, [idx], value) when is_integer(idx) do
    replace_at_grow(ensure_list(child), idx, value)
  end

  defp put_path_in(child, [idx | rest], value) when is_integer(idx) do
    l = ensure_list(child)
    replace_at_grow(l, idx, put_path_in(Enum.at(l, idx), rest, value))
  end

  defp put_path_in(_child, [], value), do: value

  defp ensure_map(m) when is_map(m), do: m
  defp ensure_map(_), do: %{}

  defp ensure_list(l) when is_list(l), do: l
  defp ensure_list(_), do: []

  # Replace element at `idx`, padding the list with nils if `idx` is past the
  # current end so a freshly-added row's first edit can land.
  defp replace_at_grow(list, idx, value) when idx < length(list) do
    List.replace_at(list, idx, value)
  end

  defp replace_at_grow(list, idx, value) do
    list ++ List.duplicate(nil, idx - length(list)) ++ [value]
  end
end
