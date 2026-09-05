defmodule Barkpark.Content.SchemaDefinition do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "schema_definitions" do
    field :name, :string
    field :title, :string
    field :icon, :string
    field :visibility, :string, default: "public"

    # Row/ownership ACL opt-in (Phase 4, core-auth). When `true`, reads of this
    # type's documents are restricted by `Barkpark.Content.Scope.scope_to_owner/2`
    # (non-admin users see only their own + unowned rows; admins / api-tokens see
    # all), and writes stamp the acting user's id into `documents.owner_id`.
    # Defaults to `false` → byte-identical to today for every existing schema.
    field :owner_scoped, :boolean, default: false

    # Desk-placement opt-in (issue #8463). A non-plugin-owned schema that no
    # curated host group claimed is, by default, generic consumer content —
    # `Barkpark.Structure` gives it a browsable `:document_type_list` node
    # (same pane the curated host groups use) so any of a project's own
    # registered types can be opened and edited in Studio. `singleton: true`
    # opts a schema OUT of that generic bucket and into the siteSettings-style
    # behavior instead: a single `:document` node whose id equals the type
    # name (the config-object shape — one canonical row, no list to browse).
    # Defaults to `false` → a schema that never sets this is treated as
    # ordinary content, never silently buried as a dead singleton.
    #
    # This flag is the SOLE desk discriminant. `visibility` below is an access
    # control and is deliberately NOT consulted for placement (Gyldendal #25):
    # it defaults to "public", so keying placement on it stranded every schema
    # registered without an explicit `visibility`.
    # See `Barkpark.Structure.build_settings_group/3`.
    field :singleton, :boolean, default: false
    field :fields, {:array, :map}, default: []
    field :dataset, :string, default: "production"
    field :cors_origins, {:array, :string}, default: []
    field :actions, {:array, :map}, default: []
    field :groups, {:array, :map}, default: []
    field :desk_groups, {:array, :map}, default: []

    # Generic list-row preview (additive, SOFT — pure render metadata).
    # Names 1–2 content fields the Studio list panes show per row:
    #   %{"badge" => <field-or-spec>, "meta" => <field-or-spec>}
    # where a spec is a field-name string or %{"field" => f, "prefix" => p}.
    # Consumed generically by `BarkparkWeb.Studio.PaneBuilder` for every
    # doc type; empty map (default) → rows render unchanged.
    field :list_preview, :map, default: %{}
    # Gyldendal parity E3 — the schema-level DESK block. `orderings` is a list of
    # %{"field" => name, "direction" => "asc" | "desc"} the desk list applies
    # (Sanity's `orderings`); the first entry is the default sort. Empty map ==
    # no declaration, the list keeps today's order.
    field :desk, :map, default: %{}
    field :initial_values, :map, default: %{}
    field :cross_validations, {:array, :map}, default: []

    # Expectation layer (additive, SOFT — never blocks a document).
    #   * `layout`  — ordered list interleaving field-refs with free-content
    #                 region markers; see `default_layout/1` for the shape.
    #   * `prefill`  — scaffold used to pre-fill a new document; evolves the
    #                 flat `initial_values`. See `default_prefill/1`.
    field :layout, {:array, :map}, default: []
    field :prefill, :map, default: %{}

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    # W2 additive seam. `:dataset_entity` — the legacy `dataset` STRING field
    # still owns `:dataset` (dual presence). FK column is `dataset_id`.
    belongs_to :dataset_entity, Barkpark.Tenancy.Dataset,
      foreign_key: :dataset_id,
      type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(schema_def, attrs) do
    schema_def
    |> cast(attrs, [
      :name,
      :title,
      :icon,
      :visibility,
      :owner_scoped,
      :singleton,
      :fields,
      :dataset,
      :cors_origins,
      :actions,
      :groups,
      :desk_groups,
      :desk,
      :list_preview,
      :initial_values,
      :cross_validations,
      :layout,
      :prefill,
      :workspace_id,
      :project_id,
      :dataset_id
    ])
    |> validate_required([:name, :title])
    |> validate_inclusion(:visibility, ~w(public private))
    |> validate_desk_group_filters()
    |> validate_desk_block()
    # W2 uniqueness flip: schema identity is now (name, dataset_id) — a project
    # can hold the same schema NAME in distinct datasets (e.g. "post" in
    # production + test), so the dataset_id leaf keeps them from colliding. The
    # `dataset` STRING stays as a mirror.
    |> unique_constraint([:name, :dataset_id],
      name: :schema_definitions_name_dataset_id_index
    )
    # Companion to the (name, dataset_id) index: rows with a NULL dataset_id are
    # NOT protected by that index (Postgres treats each NULL as distinct), so a
    # PARTIAL unique index on (name, dataset) WHERE dataset_id IS NULL backstops
    # the flat-deployment case (no project → no dataset_id). Map its violation
    # to a changeset error instead of a raised Ecto.ConstraintError.
    |> unique_constraint([:name, :dataset],
      name: :schema_definitions_name_dataset_null_dataset_id_index
    )
    # FK-abort containment (Felix W16). `workspace_id/project_id/dataset_id` are
    # real Postgres FKs (schema_definitions_<col>_fkey, migration
    # 20260527160000_cascade_content_on_scope_delete). `Content.upsert_schema/3`
    # writes this changeset raw via Repo.insert()/update() — without these, an
    # insert referencing a scope row deleted concurrently RAISES Ecto.ConstraintError
    # (a 500) instead of returning {:error, changeset}. Bare calls → Ecto-default
    # constraint names.
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:dataset_id)
  end

  # `desk_groups` is a bare `{:array, :map}` — until this guard, NOTHING checked
  # what was inside one. A chip carrying a typo'd filter op
  # (`%{"filter" => %{"status" => %{"bogus" => "x"}}}`) was accepted at WRITE,
  # stored, and then detonated at RENDER inside the Studio LiveView, because the
  # query builder now refuses an unsupported op instead of silently returning
  # every row. Catching it here is the honest half of that trade: the person who
  # can fix the typo is the one who gets the error, at the moment they make it.
  #
  # Only a CHANGED `desk_groups` is validated (`get_change/2`), so an unrelated
  # update to a schema that already stores a bad chip is not blocked — that chip
  # is handled at render by `BarkparkWeb.Studio.PaneBuilder`'s pre-flight.
  #
  # The error names the field as well as the op: this is an authenticated admin
  # write path, on the caller's OWN schema, so there is no field-visibility gate
  # to sit past (unlike the read-path envelope — see
  # `Barkpark.Content.InvalidFilterError`).
  # `desk.orderings` must be a list of %{"field" => binary, "direction" =>
  # "asc"|"desc"} — validated only when changed, like desk_groups, so an
  # unrelated update never reds on a legacy value.
  defp validate_desk_block(changeset) do
    case get_change(changeset, :desk) do
      %{} = desk ->
        case Map.get(desk, "orderings") || Map.get(desk, :orderings) do
          nil ->
            changeset

          list when is_list(list) ->
            case Enum.find(list, &(not valid_ordering?(&1))) do
              nil ->
                changeset

              bad ->
                add_error(
                  changeset,
                  :desk,
                  "orderings entries must be %{\"field\" => name, \"direction\" => \"asc\" | \"desc\"}, got #{inspect(bad)}"
                )
            end

          other ->
            add_error(changeset, :desk, "orderings must be a list, got #{inspect(other)}")
        end

      _ ->
        changeset
    end
  end

  defp valid_ordering?(%{} = o) do
    field = Map.get(o, "field") || Map.get(o, :field)
    dir = Map.get(o, "direction") || Map.get(o, :direction) || "asc"
    is_binary(field) and field != "" and dir in ["asc", "desc"]
  end

  defp valid_ordering?(_), do: false

  defp validate_desk_group_filters(changeset) do
    case get_change(changeset, :desk_groups) do
      groups when is_list(groups) ->
        case Enum.find_value(groups, &offending_desk_group_filter/1) do
          nil -> changeset
          message -> add_error(changeset, :desk_groups, message)
        end

      _ ->
        changeset
    end
  end

  defp offending_desk_group_filter(group) when is_map(group) do
    name = Map.get(group, "name") || Map.get(group, :name) || "(unnamed)"

    case Map.get(group, "filter") || Map.get(group, :filter) do
      nil ->
        nil

      filter ->
        case Barkpark.Content.Query.validate_filter_map(filter) do
          :ok ->
            nil

          {:error, {nil, :not_a_map}} ->
            "desk group #{inspect(to_string(name))}: filter must be a map of " <>
              "field => %{op => value}"

          {:error, {field, op}} ->
            "desk group #{inspect(to_string(name))}: unsupported filter operator " <>
              "#{inspect(op)} on field #{inspect(field)}; valid operators: " <>
              Enum.join(Barkpark.Content.Query.valid_filter_ops(), ", ")
        end
    end
  end

  defp offending_desk_group_filter(_group), do: nil

  # ─────────────────────────────────────────────────────────────────────────────
  # Schema Definition v2 spec — Phase 0 (masterplan-20260425-085425, decisions
  # 7, 12, 17, 20). Compile-time data-only DSL — NO Code.eval, NO runtime macro
  # evaluation, NO dynamic compilation. Owns:
  #
  #   * nested `composite` (object with named subfields)
  #   * `arrayOf` (with `ordered: true|false`)
  #   * `codelist` (with `version: integer`)
  #   * `localizedText` (with `languages`, `format`, `fallbackChain`)
  #   * top-level `validations: [...]` slot (rule evaluator ships in Phase 3)
  #   * per-field `onix:` metadata pass-through (emission ships in Phase 6)
  #   * reserved namespaces:
  #       - `bp_*`           plugin custom fields (locked — audit clean)
  #       - `plugin:<n>:<f>` plugin private fields (rejected for non-plugin
  #                          schemas via parse/2 `plugin:` opt)
  # ─────────────────────────────────────────────────────────────────────────────

  @plugin_reserved_prefix "plugin:"
  @plugin_custom_prefix "bp_"

  @v2_field_types ~w(composite arrayOf codelist localizedText)
  @valid_localized_formats ~w(plain rich)

  @doc "Reserved field-name prefix for plugin-private fields."
  def plugin_reserved_prefix, do: @plugin_reserved_prefix

  @doc "Locked plugin custom-field prefix (Phase 0 audit: no collisions)."
  def plugin_custom_prefix, do: @plugin_custom_prefix

  defmodule Parsed do
    @moduledoc false
    defstruct [:name, :title, :version, :fields, :validations, :raw]

    @type t :: %__MODULE__{
            name: String.t() | nil,
            title: String.t() | nil,
            version: 1 | 2,
            fields: [Barkpark.Content.SchemaDefinition.Field.t()],
            validations: [map()],
            raw: map()
          }
  end

  defmodule Field do
    @moduledoc false
    defstruct [
      :name,
      :type,
      :title,
      :options,
      # composite
      :fields,
      # arrayOf
      :of,
      :ordered,
      # codelist
      :codelist_id,
      :version,
      # localizedText
      :languages,
      :format,
      :fallback_chain,
      # passthrough
      :onix,
      :validations,
      # sidebar-test classification (pd-doctrine t7, rule 4). Data-only, additive,
      # opt-in — codifies "does this field read as part of the article?" as a
      # SCHEMA FACT rather than editor folklore. Consumed later by sidebar-v2 (D1
      # says the schema-v2 generalization lands as pure metadata; no editor
      # consumer this wave). Valid values are EXACTLY:
      #   * `"body"`    — reads as the article (title, body, rich text, featured
      #                   image, content blocks).
      #   * `"sidebar"` — WordPress-style right rail (slug, status, taxonomies,
      #                   relations, dates, trade metadata, settings).
      #   * `nil`       — unclassified (the attribute is absent). Byte-compatible
      #                   with every existing schema; a schema without `surface`
      #                   parses and round-trips unchanged (D3-additive).
      # Any other value is rejected as `{:error, :field_surface_invalid}`.
      :surface,
      # field-encryption marker (Phase 2, core-auth). Data-only — `true` flags a
      # field whose value is stored ciphertext-at-rest via
      # `Barkpark.Content.Encryption` on the write path. No migration: this lives
      # on the parsed Field struct, derived from the schema's `fields` JSON.
      # Defaults to `false` when the attribute is absent (legacy schemas).
      :encrypted,
      :raw,
      # field-visibility metadata (Phase 3, core-auth). Data-only, additive,
      # opt-in — consumed ONLY by `Barkpark.Content.Envelope.render/3`, which is
      # the single output chokepoint that DROPS a field a caller may not see.
      # No migration: these live inline in the schema's `fields` JSON.
      #   * `private`     — `true` hides the field from every non-admin caller.
      #   * `visibility`  — "public" | "private" | "owner_only" (no validation).
      #   * `readable_by`  — allowlist of user_ids / token_ids that may see it.
      # Absent ⇒ `private: false`, `visibility: nil`, `readable_by: []` ⇒ public,
      # so a legacy schema is byte-identical to today.
      private: false,
      visibility: nil,
      readable_by: []
    ]

    @type t :: %__MODULE__{}
  end

  @doc """
  Parses a v2 schema map and returns `{:ok, %Parsed{}}` or `{:error, reason}`.

  Accepts atom-keyed or string-keyed maps. The result's `version` field is `2`
  if any top-level field uses a v2 type (`composite`, `arrayOf`, `codelist`,
  `localizedText`); otherwise `1` (a "flat" schema — see `flat?/1`).

  ## Options

    * `:plugin` — when set to a plugin name string (e.g. `"onixedit"`), fields
      named `plugin:<plugin>:<field>` are allowed (matching their own plugin
      namespace). Defaults to `false`, which rejects any field name in the
      reserved `plugin:` namespace.
  """
  @spec parse(map(), keyword()) :: {:ok, Parsed.t()} | {:error, term()}
  def parse(schema, opts \\ [])

  def parse(schema, opts) when is_map(schema) do
    plugin = Keyword.get(opts, :plugin, false)
    schema_str = stringify(schema)

    with {:ok, fields_raw} <- fetch_fields(schema_str),
         {:ok, parsed_fields} <- parse_fields(fields_raw, plugin),
         {:ok, validations} <- parse_validations(Map.get(schema_str, "validations", [])) do
      version = if Enum.any?(parsed_fields, &v2_shape?/1), do: 2, else: 1

      {:ok,
       %Parsed{
         name: Map.get(schema_str, "name"),
         title: Map.get(schema_str, "title"),
         version: version,
         fields: parsed_fields,
         validations: validations,
         raw: schema_str
       }}
    end
  end

  def parse(_, _), do: {:error, :schema_must_be_a_map}

  @doc """
  Returns `true` for legacy schemas (no v2 field types and empty `validations`
  slot). The recursive validator (W2.2) calls this to decide `flat_mode`.

  Existing seed schemas (post, author, page, …) MUST return `true` here — that
  is the legacy-parity invariant locked by the masterplan.
  """
  @spec flat?(Parsed.t() | map()) :: boolean()
  def flat?(%Parsed{} = parsed) do
    parsed.validations == [] and not Enum.any?(parsed.fields, &v2_shape?/1)
  end

  def flat?(schema) when is_map(schema) do
    case parse(schema) do
      {:ok, parsed} -> flat?(parsed)
      {:error, _} -> false
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Expectation layer — Exp-P1 (barkpark-u7q5). An Expectation is today's
  # schema_definition PLUS two additive, SOFT parts: `layout` and `prefill`.
  # Both are metadata, never constraints — a document with missing or reordered
  # fields is always valid. These pure functions DERIVE a sensible default
  # Expectation from an existing schema so nothing has to migrate.
  #
  # ## Shapes
  #
  #   layout  = [
  #     %{"kind" => "field",  "name" => "title", "max" => 1, "enforce" => false},
  #     %{"kind" => "field",  "name" => "slug",  "max" => 1, "enforce" => false},
  #     ...one entry per top-level field, in declared order...,
  #     %{"kind" => "region", "name" => "body"}   # trailing free-content region
  #   ]
  #
  #   prefill = the schema's `initial_values` map verbatim (a flat scaffold),
  #             or `%{}` when none is declared.
  #
  # A `field` entry references a top-level field by `name`. It MAY carry optional
  # CARDINALITY keys (EX1, barkpark-q39y):
  #
  #   * `"max"`     — integer cap on how many bound blocks of this field a
  #                   document may hold; `nil`/absent means unlimited.
  #   * `"enforce"` — boolean (default `false`). When `true`, the cap is HARD:
  #                   inserting past `max` is rejected. When `false`, the cap is
  #                   SOFT: the slash menu hides the field at the cap, but a
  #                   block can still be inserted programmatically.
  #
  # A `region` entry marks a free-content area (rich blocks live here) and is
  # UNCHANGED — it carries no cardinality. The derived default always appends
  # exactly one trailing `body` region.
  # ─────────────────────────────────────────────────────────────────────────────

  @default_region_name "body"

  @doc """
  Synthesize a default `layout` from a schema's field order.

  Accepts a `%SchemaDefinition{}`, a `%Parsed{}`, or a raw schema map. Each
  top-level field becomes a
  `%{"kind" => "field", "name" => <name>, "max" => 1, "enforce" => false}` entry
  in declared order (EX1: each derived field is expected exactly once, SOFTLY —
  the slash menu hides it at the cap but never blocks an insert), followed by
  one trailing `%{"kind" => "region", "name" => "body"}` free-content marker.

  Fields without a usable string `name` are skipped (the region is always
  appended regardless).
  """
  @spec default_layout(t() | Parsed.t() | map()) :: [map()]
  def default_layout(schema) do
    field_entries =
      schema
      |> field_names()
      |> Enum.map(fn name ->
        %{"kind" => "field", "name" => name, "max" => 1, "enforce" => false}
      end)

    field_entries ++ [%{"kind" => "region", "name" => @default_region_name}]
  end

  @doc """
  Synthesize a default `prefill` scaffold from a schema's `initial_values`.

  Returns the `initial_values` map verbatim when present, else `%{}`. Dynamic
  tokens (`$today`, `$today.year`) are preserved unresolved — resolution
  happens at document-create time, not here.
  """
  @spec default_prefill(t() | Parsed.t() | map()) :: map()
  def default_prefill(%__MODULE__{initial_values: iv}) when is_map(iv), do: iv
  def default_prefill(%Parsed{raw: raw}) when is_map(raw), do: prefill_from_raw(raw)
  def default_prefill(schema) when is_map(schema), do: prefill_from_raw(schema)
  def default_prefill(_), do: %{}

  @doc """
  Resolve the full Expectation for a schema: returns `{layout, prefill}`.

  Explicit stored `layout`/`prefill` win when non-empty; otherwise the
  field-order default is derived. This is the SOFT, never-blocking read used
  by the schema read API (`Content.resolve_expectation/1`).
  """
  @spec resolve_expectation(t() | Parsed.t() | map()) :: %{
          layout: [map()],
          prefill: map()
        }
  def resolve_expectation(%__MODULE__{} = schema) do
    layout =
      case schema.layout do
        list when is_list(list) and list != [] -> list
        _ -> default_layout(schema)
      end

    prefill =
      case schema.prefill do
        map when is_map(map) and map_size(map) > 0 -> map
        _ -> default_prefill(schema)
      end

    %{layout: layout, prefill: prefill}
  end

  def resolve_expectation(schema) do
    %{layout: default_layout(schema), prefill: default_prefill(schema)}
  end

  # Top-level field names in declared order, from any accepted input shape.
  defp field_names(%__MODULE__{fields: fields}) when is_list(fields) do
    fields
    |> Enum.map(fn f -> f["name"] || f[:name] end)
    |> Enum.filter(&is_binary/1)
  end

  defp field_names(%Parsed{fields: fields}) when is_list(fields) do
    fields
    |> Enum.map(& &1.name)
    |> Enum.filter(&is_binary/1)
  end

  defp field_names(schema) when is_map(schema) do
    case parse(schema) do
      {:ok, parsed} -> field_names(parsed)
      {:error, _} -> []
    end
  end

  defp field_names(_), do: []

  defp prefill_from_raw(raw) do
    case Map.get(raw, "initial_values") || Map.get(raw, :initial_values) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  # ─── private ────────────────────────────────────────────────────────────────

  defp fetch_fields(schema_str) do
    case Map.get(schema_str, "fields") do
      list when is_list(list) -> {:ok, list}
      nil -> {:error, :missing_fields}
      _ -> {:error, :fields_must_be_list}
    end
  end

  defp parse_fields(fields, plugin) when is_list(fields) do
    fields
    |> Enum.reduce_while({:ok, []}, fn raw_field, {:ok, acc} ->
      case parse_field(raw_field, plugin) do
        {:ok, f} -> {:cont, {:ok, [f | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp parse_fields(_, _), do: {:error, :fields_must_be_list}

  defp parse_field(raw, plugin) when is_map(raw) do
    f = stringify(raw)
    name = Map.get(f, "name")
    type = Map.get(f, "type")

    with :ok <- validate_field_name(name, plugin),
         {:ok, surface} <- parse_field_surface(Map.get(f, "surface")),
         {:ok, %Field{} = base} <- parse_field_type(type, f, plugin) do
      {:ok,
       %{
         base
         | name: name,
           type: type,
           title: Map.get(f, "title"),
           options: Map.get(f, "options"),
           onix: Map.get(f, "onix"),
           validations: Map.get(f, "validations", []),
           encrypted: Map.get(f, "encrypted", false),
           private: Map.get(f, "private", false),
           visibility: Map.get(f, "visibility"),
           readable_by: Map.get(f, "readable_by", []),
           surface: surface,
           raw: f
       }}
    end
  end

  defp parse_field(_, _), do: {:error, :field_must_be_a_map}

  # sidebar-test classification (pd-doctrine t7, rule 4). Absent ⇒ nil
  # (unclassified — byte-compatible with every legacy schema). Only the two
  # canonical values pass; anything else is a hard parse error.
  defp parse_field_surface(nil), do: {:ok, nil}
  defp parse_field_surface(v) when v in ~w(body sidebar), do: {:ok, v}
  defp parse_field_surface(_), do: {:error, :field_surface_invalid}

  defp validate_field_name(nil, _), do: {:error, :field_missing_name}

  defp validate_field_name(name, plugin) when is_binary(name) do
    if String.starts_with?(name, @plugin_reserved_prefix) do
      cond do
        is_binary(plugin) and
            String.starts_with?(name, "#{@plugin_reserved_prefix}#{plugin}:") ->
          :ok

        true ->
          {:error, {:reserved_namespace, name}}
      end
    else
      :ok
    end
  end

  defp validate_field_name(_, _), do: {:error, :field_name_must_be_string}

  # composite — recursive object with named subfields
  defp parse_field_type("composite", f, plugin) do
    case parse_fields(Map.get(f, "fields", []), plugin) do
      {:ok, kids} -> {:ok, %Field{fields: kids}}
      err -> err
    end
  end

  # arrayOf — `ordered: true|false` flag, single `of` shape descriptor
  defp parse_field_type("arrayOf", f, plugin) do
    of = Map.get(f, "of")
    ordered = Map.get(f, "ordered", false)
    name = Map.get(f, "name", "array")

    cond do
      not is_boolean(ordered) ->
        {:error, {:array_ordered_must_be_boolean, name}}

      is_nil(of) or not is_map(of) ->
        {:error, {:array_missing_of, name}}

      true ->
        item_raw = Map.put(stringify(of), "name", name <> "[item]")

        case parse_field(item_raw, plugin) do
          {:ok, child} -> {:ok, %Field{ordered: ordered, of: child}}
          err -> err
        end
    end
  end

  # codelist — registry-backed enum with pinned issue version
  defp parse_field_type("codelist", f, _plugin) do
    codelist_id = Map.get(f, "codelistId")
    version = Map.get(f, "version")

    cond do
      not is_binary(codelist_id) ->
        {:error, {:codelist_missing_id, Map.get(f, "name")}}

      not (is_nil(version) or is_integer(version)) ->
        {:error, {:codelist_version_must_be_integer, codelist_id}}

      true ->
        {:ok, %Field{codelist_id: codelist_id, version: version}}
    end
  end

  # localizedText — multi-language string with fallback chain
  defp parse_field_type("localizedText", f, _plugin) do
    languages = Map.get(f, "languages", [])
    format_str = Map.get(f, "format", "plain")
    fallback = Map.get(f, "fallbackChain", [])

    cond do
      not (is_list(languages) and Enum.all?(languages, &is_binary/1)) ->
        {:error, {:localized_invalid_languages, Map.get(f, "name")}}

      format_str not in @valid_localized_formats ->
        {:error, {:localized_invalid_format, format_str}}

      not (is_list(fallback) and Enum.all?(fallback, &is_binary/1)) ->
        {:error, {:localized_invalid_fallback, Map.get(f, "name")}}

      true ->
        {:ok,
         %Field{
           languages: languages,
           format: localized_format_atom(format_str),
           fallback_chain: fallback
         }}
    end
  end

  # any other binary type-tag (string, slug, text, richText, image, select,
  # boolean, datetime, color, reference, array, …) is treated as a v1
  # leaf — parsed permissively, preserved verbatim in `raw`.
  defp parse_field_type(t, _f, _plugin) when is_binary(t) do
    {:ok, %Field{}}
  end

  defp parse_field_type(_, _, _), do: {:error, :field_type_must_be_string}

  defp parse_validations(v) when is_list(v), do: {:ok, v}
  defp parse_validations(_), do: {:error, :validations_must_be_list}

  defp v2_shape?(%Field{type: t}) when t in @v2_field_types, do: true
  defp v2_shape?(_), do: false

  defp localized_format_atom("plain"), do: :plain
  defp localized_format_atom("rich"), do: :rich

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
