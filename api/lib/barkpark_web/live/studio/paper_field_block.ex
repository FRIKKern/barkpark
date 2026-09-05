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
  component updates its OWN `:value` assign locally before sending `:paper_op`.
  It retains that pending value across older or refused parent renders, and
  clears the pending marker only when the block carries the exact value back.
  The successful echo is therefore a no-op DOM diff for the touched input, so
  it does not move the cursor; a refused save remains available for retry.

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

  require Logger

  alias BarkparkWeb.Components.Fields.{
    ArrayField,
    CodelistField,
    CompositeField,
    LocalizedTextField,
    TreeCodelistField
  }

  alias Barkpark.Content.SchemaDefinition.Field

  # Client-controlled bracket indices (`[N]` / `[0].tags[N]`) drive the arrayOf
  # merge's `0..max_idx` list build + `List.duplicate(nil, …)` padding. A crafted
  # form-change key like `[99999999999]` would otherwise allocate a ~10^11-element
  # list and OOM the whole BEAM. Anything past this ceiling is hostile or a bug —
  # mirrors the sheets grid clamps next door.
  @max_array_index 10_000

  @impl true
  def update(%{block: block} = assigns, socket) do
    field_type = Map.get(block, "type")
    persisted_value = derive_value(block)

    # A rejected parent write re-renders this component with the last persisted
    # block. Keep the user's local value until the parent eventually echoes that
    # exact value after a successful retry. An older successful echo likewise
    # cannot overwrite a newer pending edit.
    {value, pending_value?} =
      if socket.assigns[:pending_value?] do
        local_value = socket.assigns.value

        if persisted_value == local_value,
          do: {persisted_value, false},
          else: {local_value, true}
      else
        {persisted_value, false}
      end

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
      |> assign(:value, value)
      |> assign(:pending_value?, pending_value?)
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
      <form id={"#{@id}-form"} phx-change="inner-change" phx-target={@myself} phx-hook="BarkparkFieldBridge" data-paper-field-flush>
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
      <form id={"#{@id}-form"} phx-change="inner-change" phx-target={@myself} phx-hook="BarkparkFieldBridge" data-paper-field-flush>
        <ul class="bp-paper-chips">
          <li :for={{chip, i} <- Enum.with_index(@value)} class="bp-paper-chip">
            <input type="text" name={"[#{i}]"} value={chip} aria-label="Edit value" />
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
      <form id={"#{@id}-form"} phx-change="inner-change" phx-target={@myself} phx-hook="BarkparkFieldBridge" data-paper-field-flush>
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
      <form id={"#{@id}-form"} phx-change="inner-change" phx-target={@myself} phx-hook="BarkparkFieldBridge" data-paper-field-flush>
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
      <form id={"#{@id}-form"} phx-change="inner-change" phx-target={@myself} phx-hook="BarkparkFieldBridge" data-paper-field-flush>
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
      <form id={"#{@id}-form"} phx-change="inner-change" phx-target={@myself} phx-hook="BarkparkFieldBridge" data-paper-field-flush>
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

  # The Edit→View boundary cannot use the ordinary phx-change reply as a save
  # acknowledgement: this component only forwards the op, while the parent
  # LiveView performs the actual persistence. Carry a correlation id to that
  # parent so it can report the result after applying this exact operation.
  def handle_event(
        "inner-flush",
        %{"request_id" => request_id, "values" => params} = payload,
        socket
      )
      when is_map(params) do
    params = Map.drop(params, ["_target", "_csrf_token"])
    new_value = merge_change(socket.assigns.field_type, socket.assigns.value, params)

    {:noreply, persist(socket, new_value, request_id, payload["if_rev"])}
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

    {:noreply, persist(socket, new_list, params["request_id"], params["if_rev"])}
  end

  # Fall-through: a stale/forged phx event must not FunctionClauseError-crash
  # the parent LiveView. Keep LAST among handle_event/3 clauses. (LiveComponent —
  # handle_info routes to the parent, so no handle_info/2 catch-all here.)
  def handle_event(event, _params, socket) do
    Logger.warning("studio/paper_field_block: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # ── value persistence ───────────────────────────────────────────────────────

  # Update the component's own value assign (focus-preserving on the echo),
  # then notify the paper LiveView with a patch-block op carrying the new
  # value. The parent routes it through the canonical `paper_op/2` pipeline
  # (Content.apply_paper_block_op → persist + broadcast + re-sync).
  defp persist(socket, new_value, request_id \\ nil, if_rev \\ nil) do
    if_rev = if_rev || socket.assigns[:if_rev]

    op = %{
      "op" => "patch-block",
      "id" => socket.assigns.block_id,
      "patch" => %{"value" => new_value}
    }

    if request_id do
      send(self(), {:paper_op, Map.put(op, "if_rev", if_rev), request_id})
    else
      send(self(), {:paper_op, Map.put(op, "if_rev", if_rev)})
    end

    socket
    |> assign(:value, new_value)
    |> assign(:pending_value?, true)
  end

  # ── value derivation + merge ────────────────────────────────────────────────

  defp derive_value(%{"type" => "arrayOf"} = block) do
    block
    |> Map.get("value", [])
    |> List.wrap()
    |> normalize_legacy_composite_rows(block)
  end

  defp derive_value(%{"type" => "codelist"} = block), do: Map.get(block, "value")

  defp derive_value(%{"type" => type} = block) when type in ["composite", "localizedText"],
    do: Map.get(block, "value", %{}) || %{}

  defp derive_value(block), do: Map.get(block, "value")

  # D37 (authoring-excellence W4) — legacy bare-string tag write-loss, render seam.
  #
  # When an arrayOf's element type is `composite`, a legacy bare-STRING row (the
  # historical flat-string `tags` shape, e.g. `["obsidian"]`) reconstitutes as
  # `%{"tag" => s}` BEFORE it reaches the composite editor. Without this, the
  # element renders with a BLANK `tag` input (the composite renderer reads
  # `get_value(scalar, "tag", "") == ""`), and the very first `phx-change`
  # serialises the whole form — re-submitting an empty `[i].tag` — which would
  # DROP the tag name. Reconstituting here means the name renders in its field
  # AND rides the next change intact; the first edit also self-heals the row to
  # the map shape. See `ensure_map/1` for the merge-seam belt-and-suspenders.
  #
  # SCOPED TO THE TAGS PATH (D37 genericity guard): the reconstitution fires ONLY
  # when the composite element declares a `"tag"` subfield — i.e. the tags shape
  # (paper.json tags `of.fields` = tag/strength/rationale). This is deliberately
  # narrow: `ensure_map/1` at the merge seam is generic and cannot see the
  # subfield schema, so if the reconstitution were blanket it would stamp a
  # spurious `"tag"` onto EVERY composite's legacy scalar. Confining it to
  # tag-declaring composites means:
  #   * a SCALAR arrayOf (of.type not composite — e.g. keywords) keeps its bare
  #     strings, and
  #   * a NON-tag composite (amount/currency, contributors/name+role, …) is never
  #     reconstituted, so no `"tag"` key is invented for it.
  # `tags` is the sole composite that ever persisted a bare-string form, so this
  # is a no-op for every other composite (always map-shaped).
  defp normalize_legacy_composite_rows(list, block) when is_list(list) do
    if tag_bearing_composite?(block) do
      Enum.map(list, fn
        s when is_binary(s) -> %{"tag" => s}
        other -> other
      end)
    else
      list
    end
  end

  defp tag_bearing_composite?(%{"of" => %{"type" => "composite"} = of}) do
    of
    |> Map.get("fields", [])
    |> Enum.any?(&(is_map(&1) and Map.get(&1, "name") == "tag"))
  end

  defp tag_bearing_composite?(_), do: false

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
    # leading `[N]` index, AND any key carrying an oversized index segment
    # (`@max_array_index`). Rejecting the WHOLE key — not clamping one segment —
    # is deliberate: a truncated path like `[0].tags[huge]` → `[0].tags` would
    # silently overwrite the wrong element. `seen`/`max_idx`/`replace_at_grow`
    # all derive from `parsed`, so this one guard bounds the entire alloc.
    parsed =
      params
      |> Enum.map(fn {k, v} -> {parse_key_path(k), v} end)
      |> Enum.reject(fn {path, _v} ->
        path == [] or Enum.any?(path, &(is_integer(&1) and &1 > @max_array_index))
      end)

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

  # D37 (authoring-excellence W4) — legacy bare-string tag write-loss.
  #
  # A composite-element subfield edit lands via `Map.put(ensure_map(child), key,
  # value)`. When `child` is a legacy bare STRING row (the historical flat-string
  # tag shape, e.g. `["obsidian"]`), the old catch-all reconstituted it as `%{}`
  # — silently DROPPING the tag's name on the very first subfield edit. Preserve
  # the scalar under `"tag"` so the name survives: the row round-trips as
  # `%{"tag" => "obsidian", <edited-sub> => …}` instead of losing "obsidian".
  #
  # The `"tag"` key is double-proven for the sole field that carries this legacy
  # form: the paper schema's tags composite (priv/plugins/bulldocs/schemas/
  # paper.json — {"name":"tag"}) AND the label-spine validator
  # (content/label_spine.ex main_tag reads get(top, "tag")).
  #
  # This is the merge-seam belt-and-suspenders behind `normalize_legacy_composite_rows/2`
  # (the render seam). `ensure_map/1` is GENERIC — the element's subfield schema
  # never reaches it — but the render seam is SCOPED to tag-declaring composites,
  # so for the tags field a bare string is already reconstituted to a map before
  # it ever reaches here (this head does not fire for tags in the normal flow).
  # It survives only as defense for a params-only edit path. For a non-tag
  # composite a bare scalar (which the corpus does not contain — `tags` is the
  # sole composite with a historical bare-string form) would be PRESERVED under
  # "tag" rather than dropped to `%{}` — strictly safer than the old catch-all.
  defp ensure_map(s) when is_binary(s), do: %{"tag" => s}
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
