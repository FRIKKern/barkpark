defmodule Barkpark.Content.SchemaDefinition do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "schema_definitions" do
    field :name, :string
    field :title, :string
    field :icon, :string
    field :visibility, :string, default: "public"
    field :fields, {:array, :map}, default: []
    field :dataset, :string, default: "production"
    field :cors_origins, {:array, :string}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schema_def, attrs) do
    schema_def
    |> cast(attrs, [:name, :title, :icon, :visibility, :fields, :dataset, :cors_origins])
    |> validate_required([:name, :title])
    |> validate_inclusion(:visibility, ~w(public private))
    |> unique_constraint([:name, :dataset])
  end

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
      :raw
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
         {:ok, base} <- parse_field_type(type, f, plugin) do
      {:ok,
       %Field{
         base
         | name: name,
           type: type,
           title: Map.get(f, "title"),
           options: Map.get(f, "options"),
           onix: Map.get(f, "onix"),
           validations: Map.get(f, "validations", []),
           raw: f
       }}
    end
  end

  defp parse_field(_, _), do: {:error, :field_must_be_a_map}

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
