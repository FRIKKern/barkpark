defmodule Barkpark.Content.Expand do
  alias Barkpark.Content
  alias Barkpark.Content.Envelope

  @type spec :: :all | [String.t()]

  @spec expand([map()], spec(), String.t(), keyword()) :: [map()]
  def expand(docs, spec, dataset, opts \\ [])
  def expand([], _spec, _dataset, _opts), do: []
  def expand(docs, [], _dataset, _opts), do: docs

  def expand(docs, spec, dataset, opts) do
    # `published_only` (default false) hardens reference expansion for read-only
    # public shares: when true, an unresolvable PUBLISHED target is left
    # UNexpanded instead of falling back to its `drafts.` twin — so a read
    # share can never leak draft content through `?expand=`. When false the
    # behaviour is byte-identical to before.
    published_only = Keyword.get(opts, :published_only, false)
    # Field-visibility (Phase 3): a referenced document is rendered THROUGH the
    # same caller, with the ref-type's own schema, so a `private` field on an
    # expanded reference is redacted exactly as it would be at the top level.
    caller_context = Keyword.get(opts, :caller_context)

    docs_by_type = Enum.group_by(docs, & &1["_type"])
    # Thread the caller's scope (in `opts`) into schema resolution so reference
    # fields are detected with the SAME tenant scope as the document reads.
    # get_schema/3 resolves workspace-or-global, so this still finds a global
    # schema (legacy / authed callers) AND a scoped one (e.g. an anonymous
    # read-share query whose type schema lives in the shared workspace).
    schemas = load_schemas(Map.keys(docs_by_type), dataset, opts)

    Enum.map(docs, fn doc ->
      type = doc["_type"]
      schema = Map.get(schemas, type)

      case ref_fields_for(schema, spec) do
        [] ->
          doc

        fields ->
          Enum.reduce(fields, doc, fn field, acc ->
            field_name = field["name"]
            {ref_type, array?} = ref_target(field)

            case Map.get(acc, field_name) do
              nil ->
                acc

              value when array? ->
                Map.put(
                  acc,
                  field_name,
                  expand_each(value, ref_type, dataset, opts, published_only, caller_context)
                )

              value ->
                case ref_id_from(value) do
                  nil ->
                    acc

                  ref_id ->
                    case resolve_ref(
                           ref_id,
                           ref_type,
                           dataset,
                           opts,
                           published_only,
                           caller_context
                         ) do
                      nil -> acc
                      resolved -> Map.put(acc, field_name, resolved)
                    end
                end
            end
          end)
      end
    end)
  end

  defp load_schemas(types, dataset, opts) do
    types
    |> Enum.map(fn type ->
      case Content.get_schema(type, dataset, opts) do
        {:ok, schema} ->
          {type, schema}

        _ ->
          # Fall back to a GLOBAL (tenant-less) schema. The schema only drives
          # reference-FIELD detection (which fields are references) — it is
          # content-type structure, not tenant data — so a global lookup is
          # safe. The referenced DOCUMENT reads (resolve_ref) stay scoped via
          # `opts`, so this never widens cross-tenant document access. This keeps
          # BOTH a scoped schema (anonymous read-share query) AND a legacy global
          # schema (existing scoped-reads-with-global-schema callers) working.
          case Content.get_schema(type, dataset) do
            {:ok, schema} -> {type, schema}
            _ -> {type, nil}
          end
      end
    end)
    |> Map.new()
  end

  defp ref_fields_for(nil, _spec), do: []

  defp ref_fields_for(schema, :all) do
    Enum.filter(schema.fields, &ref_field?/1)
  end

  defp ref_fields_for(schema, fields) when is_list(fields) do
    Enum.filter(schema.fields, &(ref_field?(&1) && &1["name"] in fields))
  end

  # A reference field — either a direct `reference` field or an `arrayOf` whose
  # element type is `reference` (e.g. a `tags` list of tag refs).
  defp ref_field?(%{"type" => "reference", "refType" => rt}) when is_binary(rt), do: true

  defp ref_field?(%{"type" => "arrayOf", "of" => %{"type" => "reference", "refType" => rt}})
       when is_binary(rt),
       do: true

  defp ref_field?(_), do: false

  # {ref_type, array?} for a reference / arrayOf-of-reference field. Only called
  # on fields that already passed ref_field?/1.
  defp ref_target(%{"type" => "arrayOf", "of" => %{"refType" => rt}}), do: {rt, true}
  defp ref_target(%{"refType" => rt}), do: {rt, false}

  # Resolve each element of an array-of-references; an unresolvable element (or a
  # non-list value) is left untouched.
  defp expand_each(list, ref_type, dataset, opts, published_only, caller_context)
       when is_list(list) do
    Enum.map(list, fn el ->
      case ref_id_from(el) do
        nil ->
          el

        ref_id ->
          case resolve_ref(ref_id, ref_type, dataset, opts, published_only, caller_context) do
            nil -> el
            resolved -> resolved
          end
      end
    end)
  end

  defp expand_each(value, _ref_type, _dataset, _opts, _published_only, _caller_context), do: value

  # A single reference field's value is either a plain id string or a Sanity-style
  # `%{"_ref" => id}` object — both resolve to the target id. Returns nil for any
  # other shape (an array of refs, an absent field, or an unrecognized value),
  # leaving it unexpanded.
  defp ref_id_from(v) when is_binary(v) and v != "", do: v
  defp ref_id_from(%{"_ref" => v}) when is_binary(v) and v != "", do: v
  defp ref_id_from(_), do: nil

  defp resolve_ref(ref_id, ref_type, dataset, opts, published_only, caller_context) do
    ref_schema = ref_schema(ref_type, dataset, opts)

    case Content.get_document(ref_id, ref_type, dataset, opts) do
      {:ok, doc} ->
        Envelope.render(doc, ref_schema, caller_context)

      _ when published_only ->
        # Read-share path: the published target is absent. Do NOT fetch or
        # render the `drafts.` twin — leave the reference unexpanded (the same
        # null/omitted outcome as any unresolvable ref), never leaking a draft.
        nil

      _ ->
        case Content.get_document("drafts." <> ref_id, ref_type, dataset, opts) do
          {:ok, doc} -> Envelope.render(doc, ref_schema, caller_context)
          _ -> nil
        end
    end
  end

  # The referenced type's schema, for field-visibility redaction of the expanded
  # document. Nil when none resolves — redaction then falls back to the
  # schema-free encrypted-field guard. Scoped via `opts`, with a global fallback
  # mirroring `load_schemas/3`.
  defp ref_schema(ref_type, dataset, opts) do
    case Content.get_schema(ref_type, dataset, opts) do
      {:ok, schema} ->
        schema

      _ ->
        case Content.get_schema(ref_type, dataset) do
          {:ok, schema} -> schema
          _ -> nil
        end
    end
  end
end
