defmodule Barkpark.Content.Envelope do
  @moduledoc """
  Canonical v1 document envelope. Flat map with reserved `_`-prefixed keys.

  Reserved keys: _id, _type, _rev, _draft, _publishedId, _createdAt, _updatedAt.
  All other keys come from the document's stored content plus `title`.
  User content cannot override reserved keys.

  ## Field visibility (Phase 3, core-auth)

  `render/3` is the SINGLE output chokepoint where per-field visibility is
  enforced — every read surface (REST query, search, share-link, history, and
  reference expansion) threads its caller through here so a `private` /
  `owner_only` / allowlisted field is DROPPED before it can leave the system.

  The contract FAILS CLOSED — a nil/anonymous caller is the MOST restrictive,
  never a bypass:

    * `caller_context == nil` ⇒ treated as the anonymous PUBLIC-ONLY principal —
      every `private` / `owner_only` / `readable_by` / encrypted field is
      dropped. A nil caller is NEVER an "internal full-content" signal (that was
      the WS-B bug: media payloads and the legacy dump passed nil and leaked the
      whole document). Internal/writer paths that legitimately carry the FULL
      document (the mutation-result echo, the broadcast payload, the stored
      `mutation_event` snapshot that is re-redacted per-subscriber downstream)
      pass the explicit `:internal` sentinel — never nil.
    * `caller_context == :internal` ⇒ NO redaction (the explicit full-content
      sentinel; not reachable from any request path).
    * `caller_context.is_admin` ⇒ NO redaction (admins see all; note ciphertext
      is still NOT decrypted here — decryption stays the explicit
      `Content.reveal_fields/4` API).
    * Any other caller ⇒ encrypted-ciphertext fields are dropped (they default
      to PRIVATE regardless of schema, preserving the Phase 2 invariant), and —
      when a `schema` is supplied — `private` / `visibility` / `readable_by`
      fields are dropped unless the caller is authorized.

  With no encrypted values and no visibility metadata declared, the output is
  byte-identical to the legacy `render/1` — even for an anonymous/nil caller
  (no private fields ⇒ nothing to redact).
  """

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, SchemaDefinition}
  alias Barkpark.Crypto.FieldCipher

  @reserved ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt)

  # @canonical capability:visibility-redaction aka:redact,render,private-field,field-visibility,owner_only doc:docs/auth-user-sessions.md
  def render(doc, schema \\ nil, caller_context \\ nil) do
    user_fields =
      (doc.content || %{})
      |> Map.drop(@reserved)
      |> Map.put("title", doc.title)

    Map.merge(user_fields, %{
      "_id" => doc.doc_id,
      "_type" => doc.type,
      "_rev" => doc.rev,
      "_draft" => Content.draft?(doc.doc_id),
      "_publishedId" => Content.published_id(doc.doc_id),
      "_createdAt" => to_iso8601(doc.inserted_at),
      "_updatedAt" => to_iso8601(doc.updated_at)
    })
    |> redact_by_field_visibility(schema, caller_context, doc_owner_id(doc))
  end

  def render_many(docs, schema \\ nil, caller_context \\ nil),
    do: Enum.map(docs, &render(&1, schema, caller_context))

  @doc """
  Variant of `render_many/3` for MULTI-TYPE result sets — the search surfaces
  (multi-type REST search, federated search, live search channel) where no
  single schema applies. `schema_fun` resolves a `doc.type` to its
  `%SchemaDefinition{}` (or nil); the result is memoised per distinct type
  across the set, mirroring `Content.Export`'s per-type schema cache.

  Without this, those surfaces render with `schema == nil`, so a non-encrypted
  `private` / `visibility` / `owner_only` / `readable_by` field has no schema
  entry and leaks to a non-authorized caller — the schema-free guard only
  catches encrypted ciphertext. Resolving each doc's own schema closes the leak
  exactly as single-type search already does.
  """
  def render_many_by_type(docs, schema_fun, caller_context) when is_function(schema_fun, 1) do
    {rendered, _cache} =
      Enum.map_reduce(docs, %{}, fn doc, cache ->
        {schema, cache} = resolve_schema_cached(cache, doc.type, schema_fun)
        {render(doc, schema, caller_context), cache}
      end)

    rendered
  end

  defp resolve_schema_cached(cache, type, schema_fun) do
    case Map.fetch(cache, type) do
      {:ok, schema} ->
        {schema, cache}

      :error ->
        schema = schema_fun.(type)
        {schema, Map.put(cache, type, schema)}
    end
  end

  @doc """
  Redact an ALREADY-rendered envelope map under a subscriber's caller context —
  the same single chokepoint as `render/3`, but for the rare path that holds a
  frozen envelope snapshot rather than a live `%Document{}`.

  The SSE replay path uses this for a *delete* event: the live document is gone,
  so it cannot be re-rendered, but the stored `mutation_events.document` snapshot
  must still be redacted before it reaches a non-authorized subscriber. `owner_id`
  is the document's owner for `owner_only` checks (nil when unknown ⇒ `owner_only`
  conservatively drops). A `nil` caller is a no-op (byte-identical), matching
  `render/3`.
  """
  def redact(envelope, schema \\ nil, caller_context \\ nil, owner_id \\ nil)

  def redact(envelope, schema, caller_context, owner_id) when is_map(envelope),
    do: redact_by_field_visibility(envelope, schema, caller_context, owner_id)

  # Non-map payload (e.g. a delete event with no stored snapshot) — pass through.
  def redact(envelope, _schema, _caller_context, _owner_id), do: envelope

  # ── field-visibility redaction (the single chokepoint) ────────────────────

  # No caller context => FAIL CLOSED. A nil caller is the most restrictive
  # anonymous principal: redact every private / owner_only / readable_by /
  # encrypted field (public-only). This closes the WS-B leak paths that passed
  # nil and dumped full content. Internal/writer paths that must carry the FULL
  # document pass the explicit `:internal` sentinel below — NEVER nil.
  defp redact_by_field_visibility(envelope, schema, nil, owner_id),
    do: redact_by_field_visibility(envelope, schema, %CallerContext{}, owner_id)

  # Explicit internal/full-content sentinel — the mutation-result echo, the
  # broadcast payload, and the stored mutation_event snapshot (re-redacted
  # per-subscriber downstream) ride this. Not reachable from any request path.
  defp redact_by_field_visibility(envelope, _schema, :internal, _owner_id), do: envelope

  # Admins see everything. Ciphertext is still NOT decrypted (that is the
  # explicit Content.reveal_fields/4 API) — an admin simply sees the envelope.
  defp redact_by_field_visibility(envelope, _schema, %CallerContext{is_admin: true}, _owner_id),
    do: envelope

  defp redact_by_field_visibility(envelope, schema, %CallerContext{} = ctx, owner_id) do
    fields = raw_fields(schema)

    Enum.reduce(envelope, %{}, fn {key, value}, acc ->
      cond do
        # Reserved system keys (_id, _type, …) are never user data — always kept.
        key in @reserved -> Map.put(acc, key, value)
        drop_field?(key, value, fields, ctx, owner_id) -> acc
        true -> Map.put(acc, key, value)
      end
    end)
  end

  defp drop_field?(key, value, fields, ctx, owner_id) do
    cond do
      # Encrypted ciphertext defaults to PRIVATE for every non-admin caller,
      # independent of schema — this holds even when no schema is supplied, so
      # a marked field can never leak (as ciphertext) on any read surface.
      FieldCipher.encrypted?(value) ->
        true

      true ->
        case find_raw_field(fields, key) do
          # Unknown / undeclared field => public (legacy parity).
          nil -> false
          field -> not field_visible?(field, ctx, owner_id)
        end
    end
  end

  # System fields that are always filterable / orderable — real columns or
  # reserved keys, never carriers of per-field visibility metadata.
  @system_filterable ~w(title status doc_id)

  @doc """
  May this caller reference `field_name` in a FILTER or ORDER clause?

  The filter/order query oracle (WS-B MEDIUM-4): a WHERE/ORDER built over a
  field the caller cannot SEE lets them binary-search or sort by its hidden
  value even though `render/3` redacts it from the response body. The read
  surface calls this to REJECT such a clause before it reaches the query layer.

  Fail-closed and consistent with `render/3`'s visibility rules:

    * `nil` / `:internal` caller and admins ⇒ unrestricted (internal/system
      reads; their output still rides the `render/3` redaction boundary).
    * reserved (`_id`…) and promoted (`title`/`status`/`doc_id`) fields ⇒ always
      allowed.
    * a declared `private` / `owner_only` / `readable_by` field ⇒ allowed ONLY
      when the caller is authorized (owner_only with no doc in hand ⇒ denied for
      non-admins — conservative).
    * an UNDECLARED field (nil schema or not in `fields`) ⇒ public (legacy
      parity). Encrypted-marked fields are already immune (stored ciphertext
      never matches a plaintext probe).
  """
  def field_readable?(_schema, _field_name, nil), do: true
  def field_readable?(_schema, _field_name, :internal), do: true
  def field_readable?(_schema, _field_name, %CallerContext{is_admin: true}), do: true

  def field_readable?(schema, field_name, %CallerContext{} = ctx) when is_binary(field_name) do
    top = field_top_segment(field_name)

    cond do
      top in @reserved ->
        true

      top in @system_filterable ->
        true

      true ->
        case find_raw_field(raw_fields(schema), top) do
          nil -> true
          field -> field_visible?(field, ctx, nil)
        end
    end
  end

  def field_readable?(_schema, _field_name, _ctx), do: true

  # Top-level segment of a (possibly nested / `content.`-prefixed) filter path —
  # `content.meta.seo` and `meta.seo` both resolve their visibility against the
  # declared `meta` parent field.
  defp field_top_segment(field) do
    field |> String.replace_prefix("content.", "") |> String.split(".") |> hd()
  end

  defp field_visible?(field, %CallerContext{} = ctx, owner_id) do
    private = truthy?(get_attr(field, "private"))
    visibility = get_attr(field, "visibility")
    readable_by = list_attr(get_attr(field, "readable_by"))

    cond do
      # An explicit allowlist match always GRANTS access, overriding other flags.
      in_readable_by?(readable_by, ctx) -> true
      private -> false
      visibility == "private" -> false
      visibility == "owner_only" -> owner_match?(ctx, owner_id)
      # A non-empty allowlist with no match is restricted (deny by default).
      readable_by != [] -> false
      true -> true
    end
  end

  defp owner_match?(%CallerContext{user_id: uid}, owner_id)
       when is_binary(uid) and is_binary(owner_id),
       do: uid == owner_id

  defp owner_match?(_ctx, _owner_id), do: false

  defp in_readable_by?(readable_by, %CallerContext{user_id: uid, token_id: tid})
       when is_list(readable_by) do
    (is_binary(uid) and uid in readable_by) or (is_binary(tid) and tid in readable_by)
  end

  defp in_readable_by?(_readable_by, _ctx), do: false

  # The document owner for `owner_only` checks. Phase 4 lands a first-class
  # `owner_id`; until then this is conservatively nil (=> non-owner is dropped),
  # read safely off the struct without assuming the field exists.
  defp doc_owner_id(doc), do: Map.get(doc, :owner_id)

  # Field-metadata source. Both call sites pass a `%SchemaDefinition{}`, whose
  # `fields` are the raw string-keyed JSON maps; the `%Parsed{}` / raw-map shapes
  # are supported defensively. Parse-free on purpose — robust against schemas
  # carrying plugin-namespaced fields that would fail a strict parse.
  defp raw_fields(%SchemaDefinition{fields: f}) when is_list(f), do: f
  defp raw_fields(%SchemaDefinition.Parsed{raw: %{"fields" => f}}) when is_list(f), do: f
  defp raw_fields(%{"fields" => f}) when is_list(f), do: f
  defp raw_fields(_), do: []

  defp find_raw_field(fields, key) when is_list(fields) do
    Enum.find(fields, fn f -> get_attr(f, "name") == key end)
  end

  defp find_raw_field(_fields, _key), do: nil

  # Accept either a string-keyed raw map or an atom-keyed struct/map.
  defp get_attr(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, atomize(key))
  defp get_attr(_map, _key), do: nil

  defp atomize("private"), do: :private
  defp atomize("visibility"), do: :visibility
  defp atomize("readable_by"), do: :readable_by
  defp atomize("name"), do: :name
  defp atomize(_), do: :__unknown__

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp list_attr(l) when is_list(l), do: l
  defp list_attr(_), do: []

  defp to_iso8601(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
    |> String.replace_suffix("+00:00", "Z")
  end

  defp to_iso8601(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_iso8601()
    |> String.replace_suffix("+00:00", "Z")
  end

  defp to_iso8601(nil), do: nil
end
