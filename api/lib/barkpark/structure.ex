defmodule Barkpark.Structure do
  @moduledoc """
  Builds the navigation structure tree from schema definitions.
  Mirrors Sanity Studio's deskStructure — supports grouping, filtered views,
  singletons, dividers, and nested lists at any depth.

  ## Tiered desk (studio-structure-polish charter, Decisions 1/6/7)

  The tree is composed in THREE tiers, using ONLY existing node types so old Go
  TUI binaries render every tier without a client change (a NEW node `type`
  would be dropped wholesale by `cmd/barkpark/structure.go`'s `fromDeskNode`
  switch; nested `:list` recurses fine):

    * **MAIN** — flat, TOP-LEVEL (no wrapper, preserving deep-links): the host
      content/papers/sheets/taxonomy/content-types/settings groups, plus the
      desk items of any plugin whose effective placement is `:main` (tasks by
      default, or any promoted plugin). Books follow OnixEdit's
      enablement/placement; Media follows the media plugin's (`:top_menu`
      default = out of the tree). "content-types" (title "Content", issue
      #8463) is the GENERIC fallback: every non-plugin-owned, non-singleton
      schema that no curated group claimed — i.e. any consumer-registered
      type nobody wrote a home for — gets a drillable `:document_type_list`
      row there, so Studio can browse and edit it. "settings" keeps ONLY the
      schemas that opt into `singleton: true` (the real siteSettings-style
      config objects) — see `build_settings_group/3` and
      `build_generic_types_group/3`, which partition the exact same
      unowned+uncurated set by that ONE flag.

      Desk placement does NOT consult `visibility` (Gyldendal #25).
      `visibility` is an ACCESS control (who may read the type over the API);
      using it to also decide desk curation left a whole class homeless — a
      schema registered through `POST /v1/schemas/:dataset` defaults to
      `visibility: "public"`, which matched no group at all, and …Rest is
      census-driven so a type with zero documents was invisible outright.
      Which SECTION a consumer wants its type in remains unbuilt; that is the
      `deskSection` key of Gyldendal #25, tracked separately.
    * **Plugins** — ONE nested `:list` node (`id: "plugins"`) holding the desk
      items of ENABLED plugins with placement `:plugins`, grouped per plugin.
      Emitted only when non-empty.
    * **…Rest** — ONE nested `:list` node (`id: "rest"`), LAST, emitted only when
      non-empty: one child per doc TYPE present in the dataset
      (`Analytics.type_census/2`) that no placed node claimed. Drillable
      `:document_type_list` when a schema exists; a plain `:document` node when
      the type is orphaned (schema force-deleted). Counts include drafts — the
      tree never silently hides a doc type, it only organizes it.

  Per-workspace enablement/placement resolves through
  `Barkpark.Plugins.Enablement.effective/1`.
  """

  require Logger
  alias Barkpark.Content
  alias Barkpark.Content.Analytics
  alias Barkpark.Plugins.Enablement

  defmodule Node do
    @moduledoc "A node in the structure tree."
    defstruct [
      :id,
      :title,
      :icon,
      # :list, :document_type_list, :document, :divider
      :type,
      # schema type name (for doc lists/singletons)
      :type_name,
      # "field=value" filter string (used for UI phx-value; converted to filter_map before querying)
      :filter,
      # :public or :private
      :visibility,
      # schema type this node's visibility is gated on when the desk is
      # workspace-scoped (for plugin desk nodes that point at no schema type
      # of their own, e.g. OnixEdit's Bokbasen admin link — see
      # `scope_plugin_nodes/4`). nil = ungated.
      :requires_type,
      # child nodes
      items: [],
      # what opens when selected
      child: nil,
      # Gyldendal parity E3.2 — a `:document` node may pin a specific document
      # id (Sanity's `documentId`); nil = the legacy "id == type name" singleton.
      doc_id: nil,
      # Gyldendal parity E3.2 — a `:document_type_list` node may carry its own
      # sort ([%{"field", "direction"}]); nil = the schema's `desk.orderings`.
      orderings: nil
    ]
  end

  @doc """
  Build the full structure tree for a dataset.

  `opts` carries tenancy scope (`[workspace_id: ..., project_id: ...]`, as
  produced by `BarkparkWeb.ScopeHelpers.scope_opts/1`). When a `:workspace_id`
  is present the desk is scoped to that workspace: host groups gate on the
  workspace's own schemas (via `Content.list_schemas/2`), and plugin desk
  contributions are filtered to the workspace's types too — otherwise
  globally-registered plugins (e.g. frt's game groups) leak their nodes into
  every workspace's desk. With no scope (`[]`, the flat/Default desk) the
  filter is a no-op, preserving legacy behaviour.
  """
  def build(dataset \\ "production", opts \\ []) do
    # The desk lists a workspace's content TYPES, which are workspace-level —
    # NOT per-project. Scope by workspace + shared globals (`include_global`)
    # and the dataset STRING. Documents stay project-scoped downstream in
    # PaneBuilder. Unscoped (no `:workspace_id`) this still reads every tenant's
    # rows (the legacy desk).
    #
    # Like `census_opts/1` below, this is a WHITELIST: every key it does not name
    # is silently dropped, and a dropped key is only safe when its consumer
    # defaults to the NARROW behaviour. This list is the SCHEMA half of the pair
    # the census is the DOCUMENT half of — the two must name the same grant keys
    # or the desk narrows one tier and not the others. Naming each key, with its
    # sign (task-8f8a3a2e05146984; the same unnamed-drop defect as
    # task-c6d2e34c64100678 one function down):
    #
    #   * `:include_global` — SET here, not forwarded. Workspace-shared schemas
    #     (`workspace_id` NULL) belong on every workspace's desk.
    #
    #   * `:workspace_id` — FORWARDED. The tenancy floor the whole desk is built
    #     on. Its absence WIDENS to every tenant (the legacy flat desk).
    #
    #   * `:grant_scoped` — FORWARDED. `Content.Scope.maybe_scope_schemas_to_grants/2`
    #     is gated by `Keyword.get(opts, :grant_scoped, false)`, so DROPPING it
    #     read as "do not narrow", not as "narrow to nothing". Absence WIDENS.
    #     A grant-admitted non-member (LiveScope's grant arm) therefore read the
    #     WHOLE workspace catalog, and every MAIN/Plugins tier node is built from
    #     `schema_map` — so the desk named every content type outside the grant.
    #     The census fix (#14079) closed only the …Rest tier, which is
    #     census-driven; this closes the list beside it.
    #
    #   * `:caller_context` — FORWARDED, and load-bearing only because of the key
    #     above: `scope_schemas_to_grants/3` fails CLOSED without it, so
    #     forwarding the flag alone would BLANK a grantee's desk instead of
    #     narrowing it. On its own this key's absence narrows, which is why it
    #     was safe to drop before the flag arrived and is safe to forward now.
    #
    #   * `:project_id` — DROPPED, deliberately, and this drop WIDENS on purpose.
    #     Forwarding it would resolve a single project's `dataset_id` (a
    #     workspace can hold several same-named datasets across projects — that
    #     strictness wrongly hid types). A project-scoped GRANT still confines the
    #     caller's documents to its project; that is the grant ladder on the
    #     document path, not this drop.
    #
    #   * `:gating` — DROPPED. A desk-composition concern (`build_desk_items/3`
    #     reads it off `opts` directly); it selects which PLACED nodes render, and
    #     means nothing to a catalog read. Its absence changes no row.
    schema_opts =
      [include_global: true] ++
        Keyword.take(opts, [:workspace_id, :grant_scoped, :caller_context])

    schemas = Content.list_schemas(dataset, schema_opts)
    schema_map = Map.new(schemas, &{&1.name, &1})

    %Node{
      id: "root",
      title: "Structure",
      type: :list,
      items: build_desk_items(schema_map, dataset, opts)
    }
  end

  # ── Desk structure definition ──────────────────────────────────────────────
  # This is the equivalent of Sanity's deskStructure export.
  # Edit this function to change the navigation tree.

  # Compose the tiered desk (charter Decisions 1/6/7): MAIN (flat top-level),
  # one nested Plugins node, one trailing …Rest node. See the moduledoc.
  defp build_desk_items(schemas, dataset, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)

    # ── Harvested plugin-schema ownership (charter Decisions 11/12) ──
    # ONE `plugin_name => [owned type names]` map per desk build, from every
    # registered plugin's `owned_schema_types/0`. Feeds BOTH the …Rest
    # top-menu claim set and the Settings catch-all reject set — no hardcodes,
    # so adding plugin N+1 needs zero edits here. Ownership is enablement-
    # independent (a disabled plugin still owns its types).
    owned_map = plugin_owned_type_map()

    # `gating: :none` — RESOLUTION mode (PaneBuilder): enablement tiering is a
    # DISPLAY concern; nav-path resolution must see every type the database
    # holds, or a top-menu surface (Media) / disabled plugin's deep link could
    # never open its panes. Everything resolves as enabled; :top_menu
    # placements fold into MAIN so they are findable in the tree walk.
    enablement =
      case Keyword.get(opts, :gating, :enabled) do
        :none ->
          Enablement.effective(workspace_id)
          |> Map.new(fn {k, v} ->
            placement = if v.placement in [:main, :plugins], do: v.placement, else: :main
            {k, %{v | enabled: true, placement: placement}}
          end)

        _ ->
          Enablement.effective(workspace_id)
      end

    # ── MAIN host groups: always top-level, in charter order ──
    # The CURATED groups run first because the two catch-alls need to know
    # which types already have a hand-written home: `curated_types` is the
    # exact set of type names those groups claimed, so a curated type is never
    # ALSO dumped into the generic bucket (`paper` is public and curated —
    # without this it would list twice).
    curated = [
      build_content_group(schemas),
      build_papers_group(schemas),
      build_sheets_group(schemas),
      build_taxonomy_group(schemas)
    ]

    curated_types = collect_claimed_types(List.flatten(curated), [])

    # Gyldendal parity E3.3 — `desk.hidden: true` on a schema takes the type OUT
    # of the desk entirely: no generic/settings node, and it is CLAIMED so the
    # …Rest census does not resurrect it. This is the explicit opt-out the
    # never-hide invariant demands — a precompute type (the twin's
    # catalogueRow / frontpageResolved) is written by a worker, never edited,
    # and only confuses an editor. The documents stay readable everywhere else.
    hidden_types = hidden_type_set(schemas)
    curated_types = MapSet.union(curated_types, hidden_types)

    # `build_generic_types_group/3` sits right before Settings: it and
    # `build_settings_group/3` read the SAME unowned, uncurated schema set and
    # partition it by the `singleton` flag ALONE, so they are kept adjacent
    # here on purpose (one catch-all immediately followed by the other).
    host_main =
      case declared_desk(schemas, dataset, opts) do
        # Gyldendal parity E3.2 — a `deskStructure` document declares the MAIN
        # tier: order, dividers, nested lists, filtered type lists and pinned
        # singletons. It replaces the curated + generic + settings host groups
        # ONLY; plugin tiers and the …Rest census below are untouched, so a type
        # the declaration forgot still surfaces (the never-hide invariant).
        # ONE group: the declaration's own dividers are explicit nodes, so
        # `maybe_join/2` must not interleave positional dividers between them.
        {:ok, declared} ->
          [declared]

        :none ->
          curated ++
            [
              build_generic_types_group(schemas, owned_map, curated_types),
              build_settings_group(schemas, owned_map, curated_types)
            ]
      end

    # ── Placement-driven host groups: books follow OnixEdit, media follows
    # the media plugin. Each returns {main_placed_nodes, plugins_placed_nodes}. ──
    {books_main, books_plugins} =
      place_host_group(build_books_group(schemas), enablement, "onixedit")

    {media_main, media_plugins} =
      place_host_group(build_media_group(schemas, dataset), enablement, "media")

    # ── Plugin desk items, attributed per plugin and split by placement ──
    collect_opts =
      if Keyword.get(opts, :gating, :enabled) == :none,
        do: Keyword.delete(opts, :workspace_id),
        else: opts

    {plugin_main, plugin_plugins} =
      dataset
      |> safe_collect_attributed(collect_opts)
      |> split_attributed(enablement, schemas, dataset, opts)

    # ── MAIN tier (flat, top-level) ──
    main_groups = host_main ++ [books_main, media_main, plugin_main]

    # ── Plugins tier: one nested :list node, only when non-empty ──
    plugins_children = books_plugins ++ media_plugins ++ plugin_plugins

    plugins_tier =
      if plugins_children == [] do
        []
      else
        [%Node{id: "plugins", title: "Plugins", icon: "🧩", type: :list, items: plugins_children}]
      end

    non_rest_groups = main_groups ++ [plugins_tier]

    # ── …Rest tier: honest census of every DB type with no home, LAST ──
    placed_nodes = List.flatten(non_rest_groups)

    claimed =
      placed_nodes
      |> collect_claimed_types(top_menu_claimed_types(enablement, owned_map))
      |> MapSet.union(hidden_types)

    rest_children = build_rest_children(claimed, schemas, dataset, opts)

    rest_tier =
      if rest_children == [] do
        []
      else
        [%Node{id: "rest", title: "…Rest", icon: "🗂", type: :list, items: rest_children}]
      end

    maybe_join(non_rest_groups ++ [rest_tier])
  end

  # Place a host group (books / media) by its owning plugin's effective
  # enablement + placement. Disabled → dropped (its doc types then surface in
  # …Rest). `:main` → MAIN tier; `:plugins` → under the Plugins node; anything
  # else (`:top_menu`) → out of the tree (types claimed via
  # `top_menu_claimed_types/1` so they never leak into …Rest).
  defp place_host_group([], _enablement, _plugin_name), do: {[], []}

  defp place_host_group(nodes, enablement, plugin_name) do
    decl = Enablement.for_plugin(enablement, plugin_name)

    cond do
      not decl.enabled -> {[], []}
      decl.placement == :main -> {nodes, []}
      decl.placement == :plugins -> {[], nodes}
      true -> {[], []}
    end
  end

  # Collect plugin desk items attributed to their owning plugin (charter
  # Decision 4). Defensive: any failure degrades to no plugin items rather than
  # crashing the desk.
  defp safe_collect_attributed(dataset, opts) do
    Barkpark.Plugins.Registry.collect_desk_items_attributed(
      baseline: [],
      ctx: %{dataset: dataset, current_path: nil, scope: opts}
    )
  rescue
    _ -> %{host: [], plugins: []}
  catch
    _, _ -> %{host: [], plugins: []}
  end

  # Split attributed plugin items into {main_flat_nodes, plugins_group_nodes} by
  # each plugin's effective enablement/placement. Disabled plugins contribute
  # nothing (their types fall into …Rest). `:main` plugins ride the MAIN tier
  # flat (promotion); `:plugins` plugins get one per-plugin group node under the
  # Plugins tier; `:top_menu` plugins are surfaced outside the tree entirely.
  defp split_attributed(%{plugins: pairs}, enablement, schemas, dataset, opts) do
    Enum.reduce(pairs, {[], []}, fn {name, items}, {main_acc, plugins_acc} ->
      decl = Enablement.for_plugin(enablement, name)

      if not decl.enabled do
        {main_acc, plugins_acc}
      else
        nodes =
          items
          |> Enum.with_index()
          |> Enum.map(fn {item, idx} -> plugin_item_to_node(item, idx) end)
          |> Enum.reject(&is_nil/1)
          |> scope_plugin_nodes(schemas, dataset, opts)

        cond do
          nodes == [] -> {main_acc, plugins_acc}
          decl.placement == :main -> {main_acc ++ nodes, plugins_acc}
          decl.placement == :top_menu -> {main_acc, plugins_acc}
          true -> {main_acc, plugins_acc ++ [plugin_group_node(name, nodes)]}
        end
      end
    end)
  end

  defp split_attributed(_attributed, _enablement, _schemas, _dataset, _opts), do: {[], []}

  # One per-plugin group node under the Plugins tier — "grouped per plugin"
  # (charter Decision 1). A nested :list, so it recurses on every consumer.
  #
  # `:icon` is "puzzle" — the same glyph the Plugins tier itself carries ("🧩"
  # aliases to it), because a per-plugin group IS a Plugins-tier row. It used to
  # be omitted entirely, which left EVERY `plugin-grp-*` child with `icon: nil`
  # and 500'd `/studio/plugins` on a clean database (spd-w18-nil-icon-500) —
  # structural, not data-dependent. The renderer is fail-safe now too; this
  # emitter still names a real glyph so the rows say "plugin", not "file".
  defp plugin_group_node(name, nodes) do
    %Node{
      id: "plugin-grp-#{name}",
      title: plugin_display_name(name),
      icon: "puzzle",
      type: :list,
      items: nodes
    }
  end

  # Human labels for the Plugins-tier group headers. Falls back to a
  # title-cased plugin name for any plugin not explicitly mapped.
  defp plugin_display_name("onixedit"), do: "Onix"
  defp plugin_display_name("tickets"), do: "Tickets"
  defp plugin_display_name("pulse"), do: "Lightning Storm"
  defp plugin_display_name("frt"), do: "Frame & Time"
  defp plugin_display_name("github"), do: "GitHub"

  defp plugin_display_name(name) when is_binary(name),
    do: name |> String.replace("_", " ") |> String.capitalize()

  # ── …Rest census (charter Decision 6) ──────────────────────────────────

  # The set of doc-type names already claimed by a placed node — the recursive,
  # deduped walk of MAIN + Plugins tiers (a type surfaces via several nodes,
  # e.g. `doc_type_with_filters/1`'s status sub-views). Seeded with the types
  # owned by out-of-tree (:top_menu) plugins so those never fall into …Rest.
  defp collect_claimed_types(nodes, extra) do
    Enum.reduce(nodes, MapSet.new(extra), &collect_type_names/2)
  end

  defp collect_type_names(%Node{type_name: tn, items: items}, acc) do
    acc = if is_binary(tn) and tn != "", do: MapSet.put(acc, tn), else: acc
    Enum.reduce(items || [], acc, &collect_type_names/2)
  end

  defp collect_type_names(_, acc), do: acc

  # …Rest children: every censused type not claimed by a placed node. Drillable
  # when a schema exists in scope; a plain :document leaf when orphaned (schema
  # force-deleted) — either way the count is honest (drafts included) and the
  # type is NEVER silently hidden.
  defp build_rest_children(claimed, schemas, dataset, opts) do
    dataset
    |> Analytics.type_census(census_opts(opts))
    |> Enum.reject(fn %{type: type} -> is_nil(type) or MapSet.member?(claimed, type) end)
    |> Enum.map(fn %{type: type, total: total} -> rest_child_node(type, total, schemas) end)
  end

  # The census MIRRORS `build/2`'s schema scope: workspace + nil-workspace
  # globals, project NOT narrowed. `Analytics.type_census/2` enforces that.
  #
  # This helper is a WHITELIST, so every key it does not name is silently
  # dropped — and a dropped key is only safe when its consumer defaults to the
  # NARROW behaviour. Naming each one, with its sign (task-c6d2e34c64100678,
  # where the unnamed drops were half the defect):
  #
  #   * `:workspace_id` — FORWARDED. The tenancy floor the census is built on.
  #
  #   * `:grant_scoped` — FORWARDED. `Content.Scope.maybe_scope_to_grants/2` is
  #     gated by `Keyword.get(opts, :grant_scoped, false)`, so DROPPING it read
  #     as "do not narrow", not as "narrow to nothing". Absence WIDENS. A
  #     grant-admitted non-member (LiveScope's grant arm) therefore censused the
  #     whole workspace, disclosing every type name and document count outside
  #     the grant.
  #
  #   * `:caller_context` — FORWARDED, and load-bearing only because of the key
  #     above: `scope_to_grants/3` fails CLOSED without it, so forwarding the
  #     flag alone would BLANK a grantee's …Rest tier instead of narrowing it.
  #     On its own this key's absence narrows (`Schema.bypasses_visibility_gate?/1`
  #     catch-alls to false), which is why it was safe to drop before the flag
  #     arrived and is safe to forward now.
  #
  #   * `:project_id` — DROPPED, deliberately. The desk lists a workspace's
  #     content TYPES, which are workspace-level, not per-project; narrowing to
  #     one project would MISREPORT the census against the tree `build/2` draws
  #     around it. A project-scoped GRANT still confines the census to its
  #     project — that is the grant ladder, not this drop.
  defp census_opts(opts),
    do: Keyword.take(opts, [:workspace_id, :grant_scoped, :caller_context])

  # Both branches name a REAL glyph. They used to leave `:icon` nil — the orphan
  # branch by omission, the schema branch whenever the schema declared no icon —
  # which 500'd `/studio/rest` for an authenticated admin (spd-w18-nil-icon-500).
  # "file" is the neutral document glyph the desk already falls back to for a
  # pane with no icon (`studio_live/components.ex`), so a …Rest row now reads as
  # "documents of a type with no home" rather than as absence.
  defp rest_child_node(type, total, schemas) do
    title = "#{type} (#{total})"

    case Map.get(schemas, type) do
      nil ->
        # Orphaned type — no schema in scope. A plain, non-drillable :document
        # leaf (Go keeps it; pane_builder renders nothing to drill). Truth over
        # silence: these rows exist and the tree says so.
        %Node{id: "rest-#{type}", title: title, icon: "file", type: :document, type_name: type}

      schema ->
        %Node{
          id: "rest-#{type}",
          title: title,
          icon: Map.get(schema, :icon) || "file",
          type: :document_type_list,
          type_name: type
        }
    end
  end

  # Schema types OWNED by an enabled plugin surfaced OUTSIDE the tree
  # (`:top_menu`) — claimed so they do not fall into …Rest (they have a home in
  # the top menu). Only top-menu-capable plugins need entries; every other
  # plugin's types are claimed through its placed tree nodes. The owned type
  # names come from the harvested `owned_map` (Decision 11) — no hardcode.
  defp top_menu_claimed_types(enablement, owned_map) do
    enablement
    |> Enum.filter(fn {_name, decl} -> decl.enabled and decl.placement == :top_menu end)
    |> Enum.flat_map(fn {name, _decl} -> Map.get(owned_map, name, []) end)
  end

  @doc """
  Public view of the harvested `plugin_name => [owned type names]` ownership map
  (charter Decision 19).

  A thin wrapper over the private `plugin_owned_type_map/0` — the SAME harvest the
  tiered desk uses (Decisions 11/12), NOT a replica — so a consumer outside the
  desk build (e.g. Workspace Settings' honest typeless-enable hint) reads plugin
  ownership through one source of truth. Keeps the harvest's `ensure_loaded`/rescue
  guard: one malformed plugin degrades to "owns nothing", never crashes the caller.
  """
  @spec owned_schema_types_map() :: %{optional(String.t()) => [String.t()]}
  def owned_schema_types_map, do: plugin_owned_type_map()

  # ── Harvested plugin-schema ownership (charter Decisions 11/12) ──────────
  #
  # ONE `plugin_name => [owned type names]` map, built per desk build from every
  # registered plugin's `owned_schema_types/0`. Defensive at both layers: the
  # `use Barkpark.Plugin` default already wraps `register_schemas([])` in
  # try/rescue, and this harvester guards missing/raising overrides too, so one
  # malformed plugin degrades to "owns nothing" rather than killing the desk.
  defp plugin_owned_type_map do
    for %{name: name, module: module} <- Barkpark.Plugins.Registry.all(),
        is_binary(name),
        into: %{} do
      {name, safe_owned_schema_types(module)}
    end
  rescue
    _ -> %{}
  end

  defp safe_owned_schema_types(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :owned_schema_types, 0) do
      case module.owned_schema_types() do
        types when is_list(types) -> Enum.filter(types, &is_binary/1)
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  # The flat set of EVERY plugin-owned schema name across the harvested map.
  defp owned_type_set(owned_map) do
    owned_map
    |> Map.values()
    |> List.flatten()
    |> MapSet.new()
  end

  # When the desk is workspace-scoped, plugin desk contributions must be
  # gated to the workspace's own schemas. Plugins register globally (e.g.
  # frt's game groups, the tasks "Tasks" list) and their `desk_items/1`
  # callbacks are NOT scope-aware, so without this filter every workspace
  # shows every plugin's nodes. Rule: a plugin node is dropped iff it points
  # at a content type that EXISTS in the catalog but is NOT registered in this
  # scope. Nodes pointing at no known type (custom plugin pages) and purely
  # structural nodes (dividers) pass through. Unscoped builds (no
  # `:workspace_id` — the flat/Default desk) skip filtering entirely, so the
  # extra catalog read only happens for scoped requests.
  defp scope_plugin_nodes(nodes, schemas, dataset, opts) do
    if Keyword.get(opts, :workspace_id) do
      in_scope = MapSet.new(Map.keys(schemas))
      gateable = MapSet.new(Enum.map(Content.list_schemas(dataset), & &1.name))

      nodes
      |> Enum.map(&filter_plugin_node(&1, in_scope, gateable))
      |> Enum.reject(&is_nil/1)
    else
      nodes
    end
  end

  # An explicit gating schema (set by the plugin via `requires_schema`) wins —
  # it lets a schema-less node (divider, admin-page link) be gated on a type
  # it can't name structurally.
  defp filter_plugin_node(%Node{requires_type: req} = node, in_scope, gateable)
       when is_binary(req) do
    gate_typed_node(node, req, in_scope, gateable)
  end

  defp filter_plugin_node(
         %Node{type: :plugin_document_list, type_name: type} = node,
         in_scope,
         gateable
       ) do
    gate_typed_node(node, type, in_scope, gateable)
  end

  defp filter_plugin_node(%Node{type: :plugin_link, filter: path} = node, in_scope, gateable) do
    case plugin_link_type(path) do
      nil -> node
      type -> gate_typed_node(node, type, in_scope, gateable)
    end
  end

  defp filter_plugin_node(%Node{type: :list, items: items} = node, in_scope, gateable) do
    kept =
      items
      |> Enum.map(&filter_plugin_node(&1, in_scope, gateable))
      |> Enum.reject(&is_nil/1)

    # Drop a nested group whose content rows were all filtered out (leaving
    # only dividers / an empty list) — a header pointing at nothing.
    if Enum.any?(kept, &content_row?/1), do: %{node | items: kept}, else: nil
  end

  defp filter_plugin_node(%Node{} = node, _in_scope, _gateable), do: node

  # Keep iff in scope; drop iff a real catalog type absent from scope; keep
  # unknown (non-schema) types — we only gate what we can positively classify.
  defp gate_typed_node(node, type, in_scope, gateable) do
    cond do
      MapSet.member?(in_scope, type) -> node
      MapSet.member?(gateable, type) -> nil
      true -> node
    end
  end

  # Singleton desk links carry a flat `/studio/<dataset>/<type>` path (see
  # frt's `singleton_link/4`); pull the trailing type segment back out so the
  # link can be gated like a typed node. Non-conforming paths → nil (un-gated).
  defp plugin_link_type(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["studio", _dataset, type] -> type
      _ -> nil
    end
  end

  defp plugin_link_type(_), do: nil

  defp content_row?(%Node{type: type})
       when type in [:plugin_document_list, :plugin_link, :document_type_list, :document],
       do: true

  defp content_row?(%Node{type: :list, items: items}), do: Enum.any?(items, &content_row?/1)
  defp content_row?(_), do: false

  # `idx` is the item's position in the plugin slice (nested items compose
  # "#{parent}-#{child}") — used only where the item carries nothing unique
  # to hash. Positional, NOT `System.unique_integer/1`: node ids must be
  # stable across rebuilds (LiveView keyed diffs; `/v1/structure` responses
  # should byte-compare for TUI callers).
  #
  # A plugin's `resolve_desk_items/2` override may hand back full `%Node{}`
  # structs (its own, or amended host nodes). Pass them through verbatim —
  # they are gated downstream like every other plugin contribution.
  defp plugin_item_to_node(%Node{} = node, _idx), do: node

  defp plugin_item_to_node(%{type: :divider} = item, idx) do
    %Node{
      type: :divider,
      id: "plugin-div-#{idx}",
      title: item[:label],
      requires_type: item[:requires_schema]
    }
  end

  defp plugin_item_to_node(%{type: :link, label: label, path: path} = item, _idx) do
    %Node{
      id: "plugin-link-#{:erlang.phash2({label, path})}",
      title: label,
      icon: item[:icon],
      type: :plugin_link,
      filter: path,
      requires_type: item[:requires_schema]
    }
  end

  defp plugin_item_to_node(%{type: :document_list, label: label, doc_type: doc_type} = item, _idx) do
    %Node{
      id: "plugin-doclist-#{:erlang.phash2({label, doc_type, item[:filter] || %{}})}",
      title: label,
      icon: item[:icon],
      type: :plugin_document_list,
      type_name: doc_type,
      # `filter` carries the raw filter map (PaneBuilder special-cases the
      # :plugin_document_list branch and reads it as a map, NOT via
      # `Structure.parse_filter/1` which only handles "field=value" strings).
      filter: item[:filter] || %{}
    }
  end

  defp plugin_item_to_node(%{type: :nested, label: label, items: inner} = item, idx)
       when is_list(inner) do
    %Node{
      id: "plugin-nest-#{:erlang.phash2({label, length(inner)})}",
      title: label,
      icon: item[:icon],
      type: :list,
      items:
        inner
        |> Enum.with_index()
        |> Enum.map(fn {child, j} -> plugin_item_to_node(child, "#{idx}-#{j}") end)
        |> Enum.reject(&is_nil/1)
    }
  end

  defp plugin_item_to_node(_, _idx), do: nil

  # Joins non-empty groups with a single divider between adjacent non-empty
  # groups. Avoids stray dividers when a group is absent. If a group
  # itself begins with its own `:divider` (plugin contributions often do,
  # to label themselves), drop the synthesized one — otherwise the tree
  # ends up with consecutive dividers. Divider ids are positional (stable
  # across rebuilds); `id_prefix` keeps the two call sites (host groups,
  # host↔plugin join) from colliding.
  defp maybe_join(groups, id_prefix \\ "div") do
    groups
    |> Enum.reject(&(&1 == []))
    |> Enum.with_index()
    |> Enum.flat_map(fn {group, idx} ->
      if idx == 0 do
        group
      else
        case group do
          [%Node{type: :divider} | _] -> group
          _ -> [%Node{type: :divider, id: "#{id_prefix}-#{idx}"} | group]
        end
      end
    end)
  end

  # Content types with filtered sub-views (like Sanity's documentTypeList with ordering)
  defp build_content_group(schemas) do
    items = []

    # Posts — with status filter sub-views
    items =
      if Map.has_key?(schemas, "post") do
        items ++ [doc_type_with_filters(schemas["post"])]
      else
        items
      end

    # Pages — simple list
    items =
      if Map.has_key?(schemas, "page") do
        items ++ [doc_type_list_item(schemas["page"])]
      else
        items
      end

    # Projects — with status filter sub-views
    items =
      if Map.has_key?(schemas, "project") do
        items ++ [doc_type_with_filters(schemas["project"])]
      else
        items
      end

    items
  end

  # Papers (convergence: papers are first-class type-"paper" documents).
  # Surfaced as its own desk group. The list opens each paper LIVE inside the
  # Studio editor pane at `/studio/:dataset/paper/:slug` — Studio-internal
  # navigation, NOT a link out to `/papers/:slug`. The structure + list panes
  # stay visible; the paper's blocks render (and stream) in the editor pane.
  # See PaneBuilder's special casing of the "paper" type.
  defp build_papers_group(schemas) do
    if Map.has_key?(schemas, "paper") do
      [doc_type_list_item(schemas["paper"])]
    else
      []
    end
  end

  # Sheets (M2): type-"sheet" documents open as the collaborative grid
  # editor inside the Studio editor pane at `/studio/:dataset/sheet/:slug` —
  # the same Studio-internal navigation shape as papers. See PaneBuilder's
  # special casing of the "sheet" type (`view: :sheet`).
  defp build_sheets_group(schemas) do
    if Map.has_key?(schemas, "sheet") do
      [doc_type_list_item(schemas["sheet"])]
    else
      []
    end
  end

  # Plugin-owned book schema (OnixEdit). Private visibility, but surfaced
  # in the top-level content nav rather than buried under Settings.
  defp build_books_group(schemas) do
    if Map.has_key?(schemas, "book") do
      [doc_type_list_item(schemas["book"])]
    else
      []
    end
  end

  # Plugin-owned media library schemas (Media plugin).
  defp build_media_group(schemas, dataset) do
    has_assets = Map.has_key?(schemas, "mediaAsset")
    has_collections = Map.has_key?(schemas, "mediaCollection")

    library_link = %Node{
      id: "media-library",
      title: "Media Library",
      icon: "image",
      type: :plugin_link,
      # Deliberately FLAT — Structure has no scope knowledge. PaneBuilder
      # canonicalises it to the /d/ shape at source, against the current
      # scope (Paths.plugin_link_href/2).
      filter: "/studio/#{dataset}/media"
    }

    cond do
      has_assets and has_collections ->
        [
          %Node{
            # Must NOT use id "media" — that collides with the MediaLive route
            # at `/studio/:dataset/media` and breaks Structure navigation
            # (push_patch cannot cross LiveViews).
            id: "media-desk",
            title: "Media",
            icon: "🖼",
            type: :list,
            visibility: :private,
            items: [
              library_link,
              doc_type_list_item(schemas["mediaAsset"]),
              doc_type_list_item(schemas["mediaCollection"])
            ]
          }
        ]

      has_assets ->
        [library_link, doc_type_list_item(schemas["mediaAsset"])]

      has_collections ->
        [library_link, doc_type_list_item(schemas["mediaCollection"])]

      true ->
        []
    end
  end

  # Taxonomy types — supporting content (authors, categories)
  defp build_taxonomy_group(schemas) do
    items = []

    items =
      if Map.has_key?(schemas, "author") do
        items ++ [doc_type_list_item(schemas["author"])]
      else
        items
      end

    items =
      if Map.has_key?(schemas, "category") do
        items ++ [doc_type_list_item(schemas["category"])]
      else
        items
      end

    items
  end

  # Settings — HOST config singletons (siteSettings/navigation/colors, …)
  # grouped under a sub-list, each rendered as a `:document` node whose pane
  # resolves the ONE canonical row (id == type name — `PaneBuilder`'s
  # `fetch_doc_with_draft(type_name, type_name, …)`). The catch-all rejects by
  # plugin OWNERSHIP, not enablement (charter Decision 12): any private schema
  # whose name is in the harvested `owned_map` is a plugin's type, not a host
  # singleton — enabled or not — so it must NOT masquerade here. An enabled
  # plugin renders its type via its own desk group (no double-list); a
  # disabled plugin's private type falls to …Rest with an honest count (no
  # Settings-singleton leak).
  #
  # Singleton semantics (issue #8463) are now an explicit, EXPLICIT opt-in:
  # only schemas with `singleton: true` land here. This function and
  # `build_generic_types_group/2` partition the exact same private+unowned
  # set by that one flag — a schema is drillable list (Content) XOR singleton
  # (Settings), never both, never neither. Pre-existing private schemas that
  # never set the flag default to `false` (the Ecto column default) and fall
  # to Content instead of masquerading as a broken singleton — which is the
  # bug this issue reports. The three real host singletons opt back in from
  # their seed definitions (`Barkpark.Seeds.Demo`); an already-deployed
  # instance's existing rows are flipped by the companion backfill migration
  # (`20260726130000_backfill_singleton_for_host_settings_types`).
  # `visibility` is NOT consulted here (Gyldendal #25). It is an ACCESS
  # control — who may read the type over the API — and was doing double duty
  # as a desk-curation control, which silently cost a public `singleton: true`
  # schema its home: it matched neither this filter nor the generic one, so it
  # vanished from the desk entirely (zero documents → not even censused into
  # …Rest). Desk placement is decided by `singleton` alone; the two jobs are
  # separated. `curated_types` keeps a hand-curated type (e.g. the public
  # `paper`) from ALSO landing in a catch-all.
  defp build_settings_group(schemas, owned_map, curated_types) do
    owned = owned_type_set(owned_map)

    private =
      schemas
      |> Map.values()
      |> Enum.filter(& &1.singleton)
      |> Enum.reject(&MapSet.member?(owned, &1.name))
      |> Enum.reject(&MapSet.member?(curated_types, &1.name))

    if private == [] do
      []
    else
      [
        %Node{
          id: "settings",
          title: "Settings",
          icon: "⚙",
          type: :list,
          visibility: :private,
          items:
            Enum.map(private, fn s ->
              %Node{
                id: s.name,
                title: s.title,
                icon: s.icon,
                type: :document,
                type_name: s.name,
                visibility: :private
              }
            end)
        }
      ]
    end
  end

  # Content (generic fallback, issue #8463) — every PRIVATE, non-plugin-owned
  # schema that does NOT opt into `singleton: true`. This is the fix for
  # "Studio cannot browse consumer-registered document types": before this
  # group existed, EVERY such schema fell into `build_settings_group/2` and
  # rendered as a `:document` singleton node, whose pane looks up a document
  # whose id equals the type name — dead for a normal N-document type. Here
  # each schema gets the same `:document_type_list` node the curated host
  # groups use (`doc_type_list_item/1`), so its documents are actually
  # browsable and editable.
  #
  # Deliberately SCHEMA-driven, not census-driven like …Rest
  # (`build_rest_children/4`, which only surfaces a type once a document of
  # it exists): a type registered via `POST /v1/schemas` with zero documents
  # still needs a home the instant it exists, so "create the first document
  # of my new type" is reachable from Studio without seeding data out of
  # band first.
  #
  # Grouped under one titled sub-list (like Settings/Media) rather than
  # flattened into `build_content_group/1`'s un-headered top-level items —
  # the real-world case that filed #8463 registers 25 custom types, and a
  # flat dump of that many rows into the MAIN tier would bury the curated
  # post/page/project items. "Settings" stays reserved for the small, stable
  # set of true singletons; "Content" collapses everything else into one
  # discoverable, growing bucket. See the PR description for the full naming
  # rationale considered.
  # `visibility` is NOT consulted (Gyldendal #25) — see `build_settings_group/3`.
  # Before that separation this filter read `visibility == "private"`, so a
  # consumer who POSTed a schema to `/v1/schemas/:dataset` without a
  # `visibility` key got the column default `"public"` and NO desk home at
  # all: not the hardcoded content group, not here, not Settings, and …Rest is
  # census-driven so a type with zero documents was not even listed there.
  defp build_generic_types_group(schemas, owned_map, curated_types) do
    owned = owned_type_set(owned_map)

    generic =
      schemas
      |> Map.values()
      |> Enum.reject(& &1.singleton)
      |> Enum.reject(&MapSet.member?(owned, &1.name))
      |> Enum.reject(&MapSet.member?(curated_types, &1.name))

    if generic == [] do
      []
    else
      [
        %Node{
          id: "content-types",
          title: "Content",
          icon: "🗂",
          type: :list,
          items: Enum.map(generic, &doc_type_list_item/1)
        }
      ]
    end
  end

  # ── Node builders ──────────────────────────────────────────────────────────

  # A document type that has a status field → gets a sub-list with filtered views
  defp doc_type_with_filters(schema) do
    status_field =
      Enum.find(schema.fields, fn f ->
        f["name"] == "status" && is_list(f["options"])
      end)

    if status_field do
      %Node{
        id: schema.name,
        title: schema.title,
        icon: schema.icon,
        type: :list,
        type_name: schema.name,
        visibility: :public,
        items:
          [
            %Node{
              id: "#{schema.name}-all",
              title: "All #{schema.title}",
              icon: schema.icon,
              type: :document_type_list,
              type_name: schema.name
            },
            %Node{type: :divider, id: "#{schema.name}-div"}
          ] ++
            Enum.map(status_field["options"], fn opt ->
              %Node{
                id: "#{schema.name}-#{opt}",
                title: String.capitalize(opt),
                icon: status_icon(opt),
                type: :document_type_list,
                type_name: schema.name,
                filter: "status=#{opt}"
              }
            end)
      }
    else
      doc_type_list_item(schema)
    end
  end

  defp doc_type_list_item(schema) do
    %Node{
      id: schema.name,
      title: schema.title,
      icon: schema.icon,
      type: :document_type_list,
      type_name: schema.name,
      visibility: :public
    }
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # ── Gyldendal parity E3.2 — the declared desk ──────────────────────────────
  #
  # A per-dataset `deskStructure` document (the consumer registers the schema;
  # `singleton: true`, one `items` field) holds an ordered tree in a small
  # data-only vocabulary that maps 1:1 onto existing %Node{} types, so
  # /v1/structure and the Go TUI need no wire change:
  #
  #   {"kind":"singleton","type":"frontpage","documentId":"frontpage","title":"Forside","icon":"home"}
  #   {"kind":"divider","title":"Filtrert"}
  #   {"kind":"list","title":"Utgivelser","icon":"book","items":[…]}
  #   {"kind":"documentTypeList","type":"publication","title":"Uten omslag",
  #      "filter":{"content.cover":{"is":"null"}},"orderings":[{"field":"title","direction":"asc"}]}
  #
  # Read under the PUBLISHED perspective ("publish to apply"), scoped to the
  # caller's workspace. Absent → :none (the hardcoded tree). A malformed
  # document degrades to :none with a logged reason — never a blank desk.
  defp hidden_type_set(schemas) do
    schemas
    |> Map.values()
    |> Enum.filter(&desk_hidden?/1)
    |> MapSet.new(& &1.name)
  end

  defp desk_hidden?(%{desk: %{"hidden" => true}}), do: true
  defp desk_hidden?(_), do: false

  @desk_structure_type "deskStructure"

  defp declared_desk(_schemas, dataset, opts) do
    scope = Keyword.take(opts, [:workspace_id])

    case Content.get_document(@desk_structure_type, @desk_structure_type, dataset, scope) do
      {:ok, %{content: %{"items" => items}}} when is_list(items) and items != [] ->
        ctx = %{dataset: dataset, scope: scope}

        nodes =
          items
          |> Enum.with_index()
          |> Enum.map(fn {item, i} -> declared_item_to_node(item, "desk-#{i}", ctx) end)
          |> Enum.reject(&is_nil/1)

        if nodes == [] do
          Logger.warning(
            "deskStructure for #{dataset} declares no recognisable items — using the default desk"
          )

          :none
        else
          {:ok, nodes}
        end

      {:ok, _} ->
        Logger.warning("deskStructure for #{dataset} has no items list — using the default desk")
        :none

      _ ->
        :none
    end
  rescue
    e ->
      Logger.warning(
        "deskStructure for #{dataset} could not be read (#{Exception.message(e)}) — using the default desk"
      )

      :none
  end

  defp declared_item_to_node(%{"kind" => "singleton"} = item, idx, _ctx) do
    type = item["type"]

    if is_binary(type) and type != "" do
      %Node{
        id: item["id"] || "#{idx}-#{type}",
        title: item["title"] || type,
        icon: item["icon"],
        type: :document,
        type_name: type,
        doc_id: item["documentId"] || type,
        visibility: :private
      }
    end
  end

  defp declared_item_to_node(%{"kind" => "divider"} = item, idx, _ctx),
    do: %Node{type: :divider, id: item["id"] || idx, title: item["title"]}

  defp declared_item_to_node(%{"kind" => "list"} = item, idx, ctx) do
    children =
      (item["items"] || [])
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {child, j} -> declared_item_to_node(child, "#{idx}-#{j}", ctx) end)
      |> Enum.reject(&is_nil/1)

    %Node{
      id: item["id"] || idx,
      title: item["title"] || "Group",
      icon: item["icon"],
      type: :list,
      items: children
    }
  end

  defp declared_item_to_node(%{"kind" => "documentTypeList"} = item, idx, _ctx) do
    type = item["type"]

    if is_binary(type) and type != "" do
      %Node{
        id: item["id"] || "#{idx}-#{type}",
        title: item["title"] || type,
        icon: item["icon"],
        type: :document_type_list,
        type_name: type,
        visibility: :public,
        filter: if(is_map(item["filter"]), do: item["filter"], else: nil),
        orderings: if(is_list(item["orderings"]), do: item["orderings"], else: nil)
      }
    end
  end

  # Gyldendal parity E3.3 — `groupBy`: Sanity's "Etter kategori" — one child
  # list per document of the `over` type, each filtered to the rows whose `by`
  # path equals that document's id. Built at desk time from the PUBLISHED
  # `over` rows (bounded); an `over` type with no rows yields an empty group.
  #
  #   {"kind":"groupBy","title":"Etter kategori","type":"publication",
  #    "by":"content.category","over":"category","orderings":[…]}
  @group_by_fanout 200

  defp declared_item_to_node(%{"kind" => "groupBy"} = item, idx, ctx) do
    type = item["type"]
    over = item["over"]
    by = item["by"]

    if is_binary(type) and is_binary(over) and is_binary(by) do
      children =
        over
        |> Content.list_documents(
          ctx.dataset,
          [perspective: :published, limit: @group_by_fanout] ++ ctx.scope
        )
        |> Enum.map(fn doc ->
          key = Barkpark.Content.DraftId.published_id(doc.doc_id)

          %Node{
            id: "#{idx}-#{key}",
            title: doc.title || key,
            icon: item["icon"],
            type: :document_type_list,
            type_name: type,
            visibility: :public,
            filter: %{by => %{"eq" => key}},
            orderings: if(is_list(item["orderings"]), do: item["orderings"], else: nil)
          }
        end)

      %Node{
        id: item["id"] || idx,
        title: item["title"] || "By #{over}",
        icon: item["icon"],
        type: :list,
        items: children
      }
    end
  end

  defp declared_item_to_node(_item, _idx, _ctx), do: nil

  @doc """
  Parse a `field=value` filter string (used by `Structure.Node.filter`)
  into a map suitable for `Barkpark.Content.list_documents/3`'s
  `:filter_map` option. Returns `%{}` for nil / "" / malformed input.
  """
  @spec parse_filter(String.t() | map() | nil) :: map()
  def parse_filter(nil), do: %{}
  def parse_filter(""), do: %{}
  # Gyldendal parity E3.1 — a node may carry a FULL `Content.Query` filter map
  # (the shape desk_groups and :plugin_document_list already use), so a
  # declared list such as «Uten omslag» = %{"content.cover.assetId" => %{"is"
  # => "null"}} rides the same node type as the legacy "field=value" string.
  def parse_filter(%{} = map), do: map

  def parse_filter(s) when is_binary(s) do
    case String.split(s, "=", parts: 2) do
      [field, value] -> %{field => value}
      _ -> %{}
    end
  end

  defp status_icon("published"), do: "●"
  defp status_icon("draft"), do: "○"
  defp status_icon("active"), do: "◆"
  defp status_icon("planning"), do: "◇"
  defp status_icon("completed"), do: "✓"
  defp status_icon("archived"), do: "▪"
  defp status_icon(_), do: "·"
end
