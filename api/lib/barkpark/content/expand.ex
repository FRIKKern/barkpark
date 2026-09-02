defmodule Barkpark.Content.Expand do
  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
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

    # ── Batch hydration — kills the `?expand=` N+1 ────────────────────────────
    # The per-ref path issued one `Content.get_document` (Repo.one) PLUS two
    # `Content.get_schema` per resolved reference (query count 2N+1). Instead:
    #   1. COLLECT every {ref_type, ref_id} this expansion will resolve;
    #   2. HYDRATE the target documents in ONE scoped batch query PER ref_type
    #      (`get_documents_by_ids/3` — SAME scope stack as `get_document/4`) and
    #      memoize each ref_type's schema ONCE (mirroring `load_schemas/3`);
    #   3. ASSEMBLE by swapping each reference value for its pre-rendered doc.
    # Query count is now constant in the resolved-document count N.
    ref_pairs = collect_ref_pairs(docs, spec, schemas)
    resolved = resolve_refs(ref_pairs, dataset, opts, published_only, caller_context)

    Enum.map(docs, fn doc ->
      schema = Map.get(schemas, doc["_type"])

      case ref_fields_for(schema, spec) do
        [] -> doc
        fields -> Enum.reduce(fields, doc, &put_expanded(&1, &2, resolved))
      end
    end)
  end

  # Swap one reference field's stored value for its pre-resolved render. An
  # unresolvable id (or a non-list value on an array field) is left untouched —
  # byte-identical to the prior per-ref path.
  defp put_expanded(field, acc, resolved) do
    field_name = field["name"]
    {ref_type, array?} = ref_target(field)

    case Map.get(acc, field_name) do
      nil ->
        acc

      value when array? and is_list(value) ->
        Map.put(acc, field_name, Enum.map(value, &expand_element(&1, ref_type, resolved)))

      _value when array? ->
        acc

      value ->
        case ref_id_from(value) do
          nil ->
            acc

          ref_id ->
            case Map.get(resolved, {ref_type, ref_id}) do
              nil -> acc
              rendered -> Map.put(acc, field_name, rendered)
            end
        end
    end
  end

  defp expand_element(el, ref_type, resolved) do
    case ref_id_from(el) do
      nil -> el
      ref_id -> Map.get(resolved, {ref_type, ref_id}, el)
    end
  end

  # Every {ref_type, ref_id} pair the expansion will resolve, de-duplicated, so
  # the hydration can batch one query per ref_type instead of one per ref.
  defp collect_ref_pairs(docs, spec, schemas) do
    docs
    |> Enum.flat_map(fn doc ->
      case ref_fields_for(Map.get(schemas, doc["_type"]), spec) do
        [] ->
          []

        fields ->
          Enum.flat_map(fields, fn field ->
            {ref_type, array?} = ref_target(field)
            collect_field_pairs(Map.get(doc, field["name"]), ref_type, array?)
          end)
      end
    end)
    |> Enum.uniq()
  end

  defp collect_field_pairs(nil, _ref_type, _array?), do: []

  defp collect_field_pairs(value, ref_type, true) when is_list(value) do
    Enum.flat_map(value, fn el ->
      case ref_id_from(el) do
        nil -> []
        id -> [{ref_type, id}]
      end
    end)
  end

  defp collect_field_pairs(_value, _ref_type, true), do: []

  defp collect_field_pairs(value, ref_type, false) do
    case ref_id_from(value) do
      nil -> []
      id -> [{ref_type, id}]
    end
  end

  # Hydrate + render every collected pair up front → %{{ref_type, ref_id} =>
  # rendered_doc}. ONE `get_documents_by_ids/3` (a single scoped Repo.all) and
  # ONE `ref_schema/3` resolution per DISTINCT ref_type — the query count no
  # longer scales with the number of resolved references.
  defp resolve_refs([], _dataset, _opts, _published_only, _caller_context), do: %{}

  defp resolve_refs(ref_pairs, dataset, opts, published_only, caller_context) do
    # The batch read's owner-scope reads `opts[:caller_context]` through
    # `Scope.scope_to_owner/2`, which only accepts a `%CallerContext{}` or nil.
    # Expand's caller_context is DUAL-USE — it also carries render sentinels
    # (e.g. `:internal`, which bypasses field redaction) that scope_to_owner
    # does not understand. Normalize the QUERY scope to nil for any non-struct
    # sentinel (fail-closed to unowned rows — the module doctrine). The per-ref
    # `get_document/4` path only owner-scoped OWNER_SCOPED types, so a
    # non-owner_scoped ref (rows carry NULL owner_id, which the nil clause admits)
    # stays byte-identical; the ORIGINAL caller_context still drives the
    # `Envelope.render` redaction below.
    #
    # The batch read's SCHEMA-visibility clamp (`Query.restrict_to_visible_types/3`,
    # task-38786b2edab15955) reads the same normalized `query_opts` key, so a
    # render sentinel resolves to nil and is CLAMPED — a non-`%CallerContext{}`
    # has not earned the private-type view. Fail-closed, and inert in practice:
    # both production call sites (`query_controller.ex:112` and `:466`) pass a
    # real `CallerContext.from_conn/1`.
    query_opts =
      case caller_context do
        %CallerContext{} -> opts
        _ -> Keyword.put(opts, :caller_context, nil)
      end

    ref_pairs
    |> Enum.group_by(fn {ref_type, _id} -> ref_type end, fn {_ref_type, id} -> id end)
    |> Enum.reduce(%{}, fn {ref_type, ids}, acc ->
      ids = Enum.uniq(ids)
      # Memoized once per ref_type (was two get_schema per ref).
      schema = ref_schema(ref_type, dataset, opts)

      # One scoped batch: the ids AND their `drafts.` twins together, so the
      # published-then-draft fallback the per-ref path did with a SECOND Repo.one
      # costs no extra query. `published_only` suppresses the draft twins so a
      # read-share can never leak a draft (unchanged guarantee).
      fetch_ids =
        if published_only, do: ids, else: ids ++ Enum.map(ids, &("drafts." <> &1))

      docs_map = Content.get_documents_by_ids(fetch_ids, dataset, query_opts)

      Enum.reduce(ids, acc, fn id, acc2 ->
        case pick_ref_doc(docs_map, id, ref_type, published_only) do
          nil -> acc2
          doc -> Map.put(acc2, {ref_type, id}, Envelope.render(doc, schema, caller_context))
        end
      end)
    end)
  end

  # Published-first, then the `drafts.` twin — the exact precedence the per-ref
  # `resolve_ref/6` had. `get_document/4` filtered `type == ref_type`; the
  # TYPELESS batch does not, so re-apply that guard (`typed_doc/2`): a doc_id
  # whose row is another type resolves to nil, byte-identical to the old path.
  defp pick_ref_doc(docs_map, id, ref_type, published_only) do
    case typed_doc(Map.get(docs_map, id), ref_type) do
      nil when not published_only -> typed_doc(Map.get(docs_map, "drafts." <> id), ref_type)
      doc -> doc
    end
  end

  defp typed_doc(%{type: ref_type} = doc, ref_type), do: doc
  defp typed_doc(_doc, _ref_type), do: nil

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

  # A single reference field's value is either a plain id string or a Sanity-style
  # `%{"_ref" => id}` object — both resolve to the target id. Returns nil for any
  # other shape (an array of refs, an absent field, or an unrecognized value),
  # leaving it unexpanded.
  defp ref_id_from(v) when is_binary(v) and v != "", do: v
  defp ref_id_from(%{"_ref" => v}) when is_binary(v) and v != "", do: v
  defp ref_id_from(_), do: nil

  # The referenced type's schema, for field-visibility redaction of the expanded
  # document. Nil when none resolves — redaction then falls back to the
  # schema-free encrypted-field guard. Scoped via `opts`, with the shared
  # GLOBAL-schema fallback (@canonical capability:schema-resolution-for-redaction).
  #
  # BEHAVIOUR CHANGE: this site's own retry accepted `{:ok, schema}`
  # UNCONDITIONALLY, so on a scoped miss it could bind a FOREIGN tenant's
  # same-named schema and gate this tenant's expanded refs with another tenant's
  # field visibility. The shared helper accepts the retry ONLY for a genuinely
  # global (`workspace_id: nil`) row, closing that inverse hazard.
  defp ref_schema(ref_type, dataset, opts) do
    case Content.Schema.get_schema_for_redaction(ref_type, dataset, opts) do
      {:ok, schema} -> schema
      :error -> nil
    end
  end
end
