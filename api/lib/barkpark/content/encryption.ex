defmodule Barkpark.Content.Encryption do
  @moduledoc """
  The field-encryption CHOKEPOINT — wires the Phase-0 envelope cipher
  (`Barkpark.Crypto.FieldCipher`) into the content write path.

  A schema field marked `encrypted: true` (see
  `Barkpark.Content.SchemaDefinition.Field`) has its value replaced by an
  opaque envelope BEFORE the document is written to storage, so the plaintext
  never lands in `documents.content` (ciphertext-at-rest). This is the single
  place encryption happens on write — `Barkpark.Content.Writer` calls
  `encrypt_marked/3` right before every `Document.changeset`.

  Reads are NEVER auto-decrypted: a normal query returns the ciphertext
  envelope. Decryption is the explicit, admin-only `decrypt_document/3`
  (surfaced as `Barkpark.Content.reveal_fields/4`).

  The DEK scope is `"dataset:" <> dataset` — the same AAD the cipher binds, so
  a ciphertext cannot be replayed under another dataset.

  Both directions are idempotent: `FieldCipher.encrypt/2` passes an existing
  envelope through untouched, and `FieldCipher.decrypt/2` passes a non-envelope
  value through unchanged. Recursion descends `composite` subfields and
  `arrayOf` items, so a marked subfield deep inside a structure is still
  covered.
  """

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId, SchemaDefinition}
  alias Barkpark.Content.SchemaDefinition.Field
  alias Barkpark.Crypto.FieldCipher

  @doc """
  Encrypt every field marked `encrypted: true` in `content`, resolving the
  schema for `{type, dataset}`. Returns `{:ok, content}` with the (possibly)
  rewritten map, or `{:error, {:encryption_failed, details}}` when a
  marked-encrypted field cannot be sealed (HIGH-3 — fail closed).

  Behavioural contract:

    * No schema, or a schema with NO `encrypted: true` field anywhere → `content`
      is returned byte-identical as `{:ok, content}` (the no-op /
      no-behaviour-change guarantee).
    * Already-encrypted values pass through (idempotent re-save).
    * A schema that declares ANY encrypted field but whose strict parse fails
      (a plugin-namespaced sibling, a field missing `type`, …) takes a per-field
      LENIENT pass: encrypt every encrypted-marked field that resolves, and
      `{:error, {:encryption_failed, …}}` the moment one cannot be processed.
      A marked field is NEVER persisted as plaintext.
  """
  # `scope` is the document's workspace id (binary | nil) or a keyword list
  # `[workspace_id: …, project_id: …]`. It picks BOTH the DEK and the schema:
  # a scoped write resolves the type in its own workspace, then the shared
  # global layer, never another workspace (task-f2a1a8429edd0d88). Before this
  # the lookup ran with no scope, which resolves `dataset` to the Default
  # workspace's dataset: a non-Default workspace's `encrypted: true` field was
  # stored as plaintext, or Default's same-named type decided what to encrypt.
  #
  #
  # `opts[:doc_id]` (owner ruling #18 bind half, task-7cdf86a62a1d8c08): the id
  # of the document being written. With it, new seals are version-2 envelopes
  # bound to (type, published doc id, top-level field), and an envelope sent
  # for a field must be bound to THIS document and field (a v1 envelope still
  # passes when it decrypts under the bare scope). Without it, seals stay v1.
  #
  # @canonical capability:field-encryption-chokepoint aka:encrypt-marked,reveal-fields,decrypt-document
  @spec encrypt_marked(map(), String.t(), String.t(), binary() | keyword() | nil, keyword()) ::
          {:ok, map()}
          | {:error, {:encryption_failed, term()}}
          | {:error, {:validation_failed, String.t(), map(), String.t()}}
  def encrypt_marked(content, type, dataset, scope \\ nil, opts \\ [])

  def encrypt_marked(content, type, dataset, scope, opts)
      when is_map(content) and is_binary(type) and is_binary(dataset) do
    scope_opts = scope_opts(scope)
    workspace_id = Keyword.get(scope_opts, :workspace_id)
    cx = cx(dataset, workspace_id, type, Keyword.get(opts, :doc_id))

    case schema_for_write(type, dataset, scope_opts) do
      {:ok, %SchemaDefinition{fields: raw}} when is_list(raw) ->
        encrypt_against_schema(content, raw, cx)

      # Schema present with a non-list `fields`, or genuinely absent: there is no
      # DECLARED `encrypted: true` field we could leak, so a no-op is correct.
      # (`get_schema/2` returns only `{:ok, _}` | `{:error, :not_found}` today; a
      # transient DB fault RAISES and aborts the write — already fail-closed.)
      {:ok, %SchemaDefinition{}} ->
        {:ok, content}

      {:error, :not_found} ->
        {:ok, content}

      # Any UNEXPECTED return (e.g. a future error tuple) → fail CLOSED rather
      # than risk persisting a marked field as plaintext on a contract change.
      other ->
        {:error, {:encryption_failed, {:schema_lookup, other}}}
    end
  end

  def encrypt_marked(content, _type, _dataset, _scope, _opts), do: {:ok, content}

  @doc """
  Turn the sealed values of `content` (a document's stored content) back into
  plain values, so the content can be written under ANOTHER document id (a
  clone or duplicate) and be sealed for that document. A v2 envelope is bound
  to its document, so copying it verbatim would be refused. `{:ok, content}`,
  or `:error` when a marked envelope does not decrypt.
  """
  @spec unseal_for_copy(map(), String.t(), String.t(), binary() | keyword() | nil, String.t()) ::
          {:ok, map()} | :error
  def unseal_for_copy(content, type, dataset, scope, source_doc_id)
      when is_map(content) and is_binary(type) and is_binary(dataset) do
    scope_opts = scope_opts(scope)
    cx = cx(dataset, Keyword.get(scope_opts, :workspace_id), type, source_doc_id)

    with {:ok, %SchemaDefinition{fields: raw}} when is_list(raw) <-
           schema_for_write(type, dataset, scope_opts),
         {:parsed, {:ok, fields}} <- {:parsed, parse_fields(raw)},
         {:ok, plain} <- transform_map(content, fields, cx, :decrypt) do
      {:ok, decrypt_bound_blocks(plain, fields, cx)}
    else
      # A marked envelope that does not open: never copy it as if it were plain.
      :error -> :error
      # No schema, or one that does not parse: the content copies as it is
      # (the write's own check still refuses an envelope it cannot verify).
      _ -> {:ok, content}
    end
  end

  def unseal_for_copy(content, _type, _dataset, _scope, _source_doc_id), do: {:ok, content}

  @doc """
  Upgrade every version-1 envelope in a document's marked fields (top-level,
  nested and bound block copies) to a version-2 seal bound to that document
  and field. Version-2 envelopes and plain values are left as they are, so a
  second run changes nothing. `{:ok, content}`; `:error` when a v1 envelope
  does not open under this document's key (it is never rewritten blind).
  """
  @spec upgrade_v1(map(), String.t(), String.t(), binary() | keyword() | nil, String.t()) ::
          {:ok, map()} | :error
  def upgrade_v1(content, type, dataset, scope, doc_id)
      when is_map(content) and is_binary(type) and is_binary(dataset) and is_binary(doc_id) do
    scope_opts = scope_opts(scope)
    cx = cx(dataset, Keyword.get(scope_opts, :workspace_id), type, doc_id)

    with {:ok, %SchemaDefinition{fields: raw}} when is_list(raw) <-
           schema_for_write(type, dataset, scope_opts),
         {:parsed, {:ok, fields}} <- {:parsed, parse_fields(raw)},
         {:ok, upgraded} <- transform_map(content, fields, cx, :upgrade),
         {:blocks, {:ok, upgraded}} <- {:blocks, upgrade_bound_blocks(upgraded, fields, cx)} do
      {:ok, upgraded}
    else
      :error -> :error
      {:blocks, :error} -> :error
      _ -> {:ok, content}
    end
  end

  def upgrade_v1(content, _type, _dataset, _scope, _doc_id), do: {:ok, content}

  # Bound block copies, all or nothing: a block whose v1 value will not open
  # fails the whole document rather than leaving it half upgraded.
  defp upgrade_bound_blocks(%{"blocks" => blocks} = content, fields, cx) when is_list(blocks) do
    by_name =
      for %Field{name: n} = f <- fields, is_binary(n) and n != "", into: %{}, do: {n, f}

    blocks
    |> Enum.reduce_while({:ok, []}, fn
      %{"fieldName" => name, "value" => value} = block, {:ok, acc} when is_binary(name) ->
        case Map.get(by_name, name) do
          %Field{} = field ->
            case transform_value(value, field, at_field(cx, name), :upgrade) do
              {:ok, v} -> {:cont, {:ok, [Map.put(block, "value", v) | acc]}}
              :error -> {:halt, :error}
            end

          _ ->
            {:cont, {:ok, [block | acc]}}
        end

      block, {:ok, acc} ->
        {:cont, {:ok, [block | acc]}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Map.put(content, "blocks", Enum.reverse(acc))}
      :error -> :error
    end
  end

  defp upgrade_bound_blocks(content, _fields, _cx), do: {:ok, content}

  # The cipher context threaded through every walk: the DEK scope, the
  # workspace, and (when the document id is known) the binding base.
  defp cx(dataset, workspace_id, type, doc_id) do
    bind =
      if is_binary(type) and is_binary(doc_id) and doc_id != "",
        do: {type, DraftId.published_id(doc_id)},
        else: nil

    %{scope: scope(dataset), ws: workspace_id, bind: bind, top: nil}
  end

  defp at_field(cx, name), do: if(cx.top == nil, do: %{cx | top: name}, else: cx)

  defp cx_binding(%{bind: {type, pid}, top: top}) when is_binary(top),
    do: FieldCipher.binding(type, pid, top)

  defp cx_binding(_cx), do: nil

  defp scope_opts(ws) when is_binary(ws), do: [workspace_id: ws]

  defp scope_opts(opts) when is_list(opts) do
    opts
    |> Keyword.take([:workspace_id, :project_id])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp scope_opts(_), do: []

  # An unscoped write keeps the historical global read. A scoped write walks
  # its own scope, its workspace, then the shared global layer
  # (`Content.resolve_schema/3`), so a global plugin schema still encrypts.
  defp schema_for_write(type, dataset, []), do: Content.get_schema(type, dataset)

  defp schema_for_write(type, dataset, scope_opts) do
    case Content.resolve_schema(type, dataset, scope_opts) do
      {:ok, schema} -> {:ok, schema}
      :error -> {:error, :not_found}
    end
  end

  # HIGH-3 (red-team): FAIL CLOSED. The pre-hardening code returned `content`
  # verbatim whenever the schema failed to STRICT-parse — persisting an
  # `encrypted: true` field as PLAINTEXT-AT-REST. Now: a clean strict parse drives
  # the original fast path; a strict-parse failure falls back to `lenient_encrypt`,
  # which protects every encrypted-marked field it can resolve and REJECTS the
  # write the instant one cannot be sealed.
  defp encrypt_against_schema(content, raw_fields, cx) do
    case parse_fields(raw_fields) do
      {:ok, fields} ->
        # No marked field anywhere → byte-identical no-op (additive guarantee;
        # also skips the content["blocks"] walk for an un-encrypted corpus).
        if any_sensitive?(fields) do
          encrypt_with_fields(content, fields, cx)
        else
          {:ok, content}
        end

      :error ->
        lenient_encrypt(content, raw_fields, cx)
    end
  end

  # Strict parse failed. If NO raw field carries an `encrypted` marker (anywhere,
  # including composite subfields / arrayOf `of`), the schema merely has an
  # unrelated parse defect and never had a secret to protect → no-op, exactly as
  # before. Otherwise we MUST protect the secret: parse each encrypted-marked
  # field in isolation, encrypt the ones that resolve, and fail closed if any
  # encrypted-marked field cannot be parsed.
  defp lenient_encrypt(content, raw_fields, cx) do
    marked = Enum.filter(raw_fields, &raw_field_encrypted?/1)

    if marked == [] do
      {:ok, content}
    else
      {fields, failed} =
        Enum.reduce(marked, {[], []}, fn raw, {ok, bad} ->
          case parse_one_field(raw) do
            {:ok, %Field{name: n} = f} when is_binary(n) and n != "" -> {[f | ok], bad}
            _ -> {ok, [raw_field_name(raw) | bad]}
          end
        end)

      if failed == [] do
        encrypt_with_fields(content, Enum.reverse(fields), cx)
      else
        {:error, {:encryption_failed, %{unprocessable_fields: Enum.reverse(failed)}}}
      end
    end
  end

  defp encrypt_with_fields(content, fields, cx) do
    case unsealed_paths(content, fields, cx) do
      [] -> seal_with_fields(content, fields, cx)
      paths -> {:error, unsealed_error(paths)}
    end
  end

  # Owner ruling #18 (task-f462de9e4c1c4621): the server accepts an envelope in
  # an `encrypted: true` field only when it decrypts under this document's own
  # (workspace, dataset) key — i.e. it is one this server sealed. A
  # caller-built `{"_bpenc": 1, "k": 1, "v": "<plaintext>"}` used to pass
  # `FieldCipher.encrypt/3` untouched and land as plain text at rest; a real
  # envelope from another workspace landed undecryptable. Both now refuse the
  # write with a 422 that names the field. Bind half (task-7cdf86a62a1d8c08):
  # with the document id known, a v2 envelope must be bound to THIS document
  # and field, so one copied from another document or field is refused too.
  # A v1 envelope (sealed before binding) is still judged by the bare scope.
  defp unsealed_paths(content, fields, cx) do
    top =
      for %Field{name: n} = f <- fields,
          is_binary(n),
          is_map(content),
          Map.has_key?(content, n),
          transform_value(Map.get(content, n), f, at_field(cx, n), :verify) == :error,
          do: n

    top ++ unsealed_block_paths(content, fields, cx)
  end

  defp unsealed_block_paths(%{"blocks" => blocks}, fields, cx) when is_list(blocks) do
    by_name =
      for %Field{name: n} = f <- fields, is_binary(n) and n != "", into: %{}, do: {n, f}

    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"fieldName" => name, "value" => value}, i} when is_binary(name) ->
        case Map.get(by_name, name) do
          %Field{} = f ->
            if transform_value(value, f, at_field(cx, name), :verify) == :error,
              do: ["blocks[#{i}].value (#{name})"],
              else: []

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp unsealed_block_paths(_content, _fields, _cx), do: []

  defp unsealed_error(paths) do
    {:validation_failed, "encrypted field",
     Map.new(paths, &{&1, ["is not a value this server encrypted for this field"]}),
     "Send the plain value of an encrypted field; the server encrypts it. Keep an encrypted value only by sending back exactly what this document returned for that field, or by leaving the field out of the write."}
  end

  defp seal_with_fields(content, fields, cx) do
    case transform_map(content, fields, cx, :encrypt) do
      # Encrypt the PROJECTED keys (content[fieldName]) AND the bound block
      # values they are projected from — see encrypt_bound_blocks/4.
      {:ok, encrypted} -> {:ok, encrypt_bound_blocks(encrypted, fields, cx)}
      # encrypt never returns :error today, but fail CLOSED if it ever does —
      # never persist a half-sealed content map.
      :error -> {:error, {:encryption_failed, :encrypt_failed}}
    end
  end

  @doc """
  Decrypt every `encrypted: true` field of `doc` against `schema`, under the
  DEK scope for `dataset`. Returns `{:ok, doc_with_plaintext}` or `:error` when
  any marked envelope fails to decrypt (unknown key version, bad payload, or
  GCM tamper — fails closed).

  This is the privileged reveal primitive; callers MUST gate it on
  authorization (see `Barkpark.Content.reveal_fields/4`).
  """
  @spec decrypt_document(Document.t(), SchemaDefinition.t(), String.t(), binary() | nil) ::
          {:ok, Document.t()} | :error
  def decrypt_document(doc, schema, dataset, workspace_id \\ nil)

  def decrypt_document(
        %Document{content: content} = doc,
        %SchemaDefinition{fields: raw_fields},
        dataset,
        workspace_id
      )
      when is_map(content) and is_list(raw_fields) and is_binary(dataset) do
    case parse_fields(raw_fields) do
      {:ok, fields} ->
        cx = cx(dataset, workspace_id, doc.type, doc.doc_id)

        case transform_map(content, fields, cx, :decrypt) do
          {:ok, decrypted} -> {:ok, %{doc | content: decrypted}}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  def decrypt_document(_doc, _schema, _dataset, _workspace_id), do: :error

  # ── internals ──────────────────────────────────────────────────────────────

  defp scope(dataset), do: "dataset:" <> dataset

  # True when ANY field in the schema (or nested composite subfield / arrayOf
  # element) is marked `encrypted: true`. Drives the no-op short-circuit so an
  # un-encrypted schema is byte-identical to pre-Phase-2 behaviour.
  defp any_sensitive?(fields) when is_list(fields), do: Enum.any?(fields, &sensitive_field?/1)
  defp any_sensitive?(_), do: false

  defp sensitive_field?(%Field{encrypted: true}), do: true

  defp sensitive_field?(%Field{type: "composite", fields: subs}) when is_list(subs),
    do: any_sensitive?(subs)

  defp sensitive_field?(%Field{type: "arrayOf", of: %Field{} = of}), do: sensitive_field?(of)

  # Several-named-member-types arrayOf (task-b3ebbd3ab1575e2a): any one
  # member's own fields may carry `encrypted: true`, same as a single-shape
  # `of`'s own fields would.
  defp sensitive_field?(%Field{type: "arrayOf", of_types: types}) when is_map(types),
    do: Enum.any?(Map.values(types), &sensitive_field?/1)

  defp sensitive_field?(_), do: false

  # The CHOKEPOINT's second half. A bound block in content["blocks"] carries a
  # plaintext "value" that `PortableDoc.Projection.project` copies VERBATIM into
  # content[fieldName]. If we encrypted only the projected key, the plaintext
  # would (a) still sit at rest inside the block and (b) overwrite the ciphertext
  # envelope the next time ANY write path re-projects — sheet-snapshot refresh,
  # edge disconnect, publish/unpublish content copy, or block-id backfill. So we
  # encrypt the block value too, under the SAME %Field{} descriptor that drives
  # the projected-key encryption (composite/arrayOf recursion included). The
  # result is fully ciphertext-at-rest: downstream re-projection then copies an
  # envelope, which FieldCipher.encrypt passes through idempotently. This is why
  # encryption stays a SINGLE chokepoint — the four copy/project paths need no
  # encryption call of their own; they only ever propagate already-encrypted
  # content.
  defp encrypt_bound_blocks(content, fields, cx),
    do: map_bound_blocks(content, fields, cx, :encrypt)

  # The clone path's mirror: bound block values back to plain values.
  defp decrypt_bound_blocks(content, fields, cx),
    do: map_bound_blocks(content, fields, cx, :decrypt)

  defp map_bound_blocks(%{"blocks" => blocks} = content, fields, cx, mode)
       when is_list(blocks) do
    by_name =
      for %Field{name: n} = f <- fields, is_binary(n) and n != "", into: %{}, do: {n, f}

    Map.put(content, "blocks", Enum.map(blocks, &map_bound_block(&1, by_name, cx, mode)))
  end

  defp map_bound_blocks(content, _fields, _cx, _mode), do: content

  # A bound block's value is the same field as content[fieldName], so it is
  # bound to that field name.
  defp map_bound_block(%{"fieldName" => name} = block, by_name, cx, mode)
       when is_binary(name) do
    case Map.get(by_name, name) do
      %Field{} = field ->
        if Map.has_key?(block, "value") do
          case transform_value(Map.get(block, "value"), field, at_field(cx, name), mode) do
            {:ok, value} -> Map.put(block, "value", value)
            :error -> block
          end
        else
          block
        end

      _ ->
        block
    end
  end

  defp map_bound_block(block, _by_name, _cx, _mode), do: block

  # Parse a SINGLE raw field in isolation (the lenient per-field fallback). A
  # plugin-namespaced sibling or a missing-`type` field that broke the STRICT
  # whole-schema parse does not block sealing the OTHER encrypted fields.
  defp parse_one_field(raw) do
    case SchemaDefinition.parse(%{"fields" => [raw]}) do
      {:ok, %SchemaDefinition.Parsed{fields: [%Field{} = field]}} -> {:ok, field}
      _ -> :error
    end
  end

  # Raw (pre-parse) detection of an `encrypted: true` marker, recursing into a
  # composite's `fields` and an arrayOf's `of`. Schema `fields` are jsonb →
  # string keys; tolerate a JSON-string "true" too. Used ONLY on the
  # strict-parse-failure path, so a malformed schema that still DECLARES a secret
  # fails closed instead of leaking it.
  defp raw_field_encrypted?(raw) when is_map(raw) do
    truthy?(Map.get(raw, "encrypted")) or
      raw_any_encrypted?(Map.get(raw, "fields")) or
      raw_field_encrypted?(Map.get(raw, "of"))
  end

  defp raw_field_encrypted?(_), do: false

  defp raw_any_encrypted?(list) when is_list(list), do: Enum.any?(list, &raw_field_encrypted?/1)
  defp raw_any_encrypted?(_), do: false

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp raw_field_name(raw) when is_map(raw), do: Map.get(raw, "name") || "unknown"
  defp raw_field_name(_), do: "unknown"

  defp parse_fields(raw) when is_list(raw) do
    case SchemaDefinition.parse(%{"fields" => raw}) do
      {:ok, %SchemaDefinition.Parsed{fields: fields}} -> {:ok, fields}
      {:error, _} -> :error
    end
  end

  defp parse_fields(_), do: :error

  # Walk a keyed content map against a list of %Field{}, transforming each
  # present field's value. Short-circuits to :error on the first decrypt
  # failure (encrypt never fails).
  defp transform_map(content, fields, cx, mode) when is_map(content) and is_list(fields) do
    Enum.reduce_while(fields, {:ok, content}, fn %Field{name: name} = field, {:ok, acc} ->
      if is_binary(name) and Map.has_key?(acc, name) do
        case transform_value(Map.get(acc, name), field, at_field(cx, name), mode) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
          :error -> {:halt, :error}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp transform_map(value, _fields, _cx, _mode), do: {:ok, value}

  # Transform a single VALUE according to a field's shape. An `encrypted: true`
  # field encrypts/decrypts the whole value as one envelope (works for scalars,
  # maps, and lists — FieldCipher JSON-encodes). A composite recurses into its
  # subfields; an arrayOf applies its `of` descriptor to each item. Anything
  # else passes through unchanged.
  defp transform_value(value, %Field{encrypted: true}, cx, mode),
    do: apply_cipher(value, cx, mode)

  defp transform_value(value, %Field{type: "composite", fields: subfields}, cx, mode)
       when is_list(subfields) and is_map(value),
       do: transform_map(value, subfields, cx, mode)

  defp transform_value(value, %Field{type: "arrayOf", of: %Field{} = of}, cx, mode)
       when is_list(value),
       do: transform_list(value, of, cx, mode)

  # Several-named-member-types arrayOf (task-b3ebbd3ab1575e2a): each item
  # names its own member type via `"_type"`, so the shape driving its
  # encryption/decryption is looked up per item rather than shared by the
  # whole array.
  defp transform_value(value, %Field{type: "arrayOf", of_types: types}, cx, mode)
       when is_map(types) and is_list(value),
       do: transform_typed_list(value, types, cx, mode)

  defp transform_value(value, _field, _cx, _mode), do: {:ok, value}

  defp transform_typed_list(list, types, cx, mode) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case transform_value(item, item_type_field(item, types), cx, mode) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  # An item with no known `_type` (malformed, or a type the schema does not
  # declare) gets a blank %Field{} — transform_value's catch-all then passes
  # it through unchanged rather than guessing a shape for it. Validation
  # (Barkpark.Content.Validation) is what REFUSES that item; encryption's job
  # here is only to never crash on it.
  defp item_type_field(%{} = item, types) do
    case Map.get(item, "_type") do
      t when is_binary(t) -> Map.get(types, t) || %Field{}
      _ -> %Field{}
    end
  end

  defp item_type_field(_item, _types), do: %Field{}

  defp transform_list(list, of_field, cx, mode) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case transform_value(item, of_field, cx, mode) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp apply_cipher(value, cx, :encrypt),
    do: {:ok, FieldCipher.encrypt(value, cx.scope, cx.ws, cx_binding(cx))}

  # A plain value is fine (the encrypt pass seals it); an envelope must be one
  # this server sealed under the same key and, for a v2 envelope, for this
  # document and field.
  defp apply_cipher(value, cx, :verify) do
    if FieldCipher.encrypted?(value) do
      case FieldCipher.verify(value, cx.scope, cx.ws, cx_binding(cx)) do
        :ok -> {:ok, value}
        :error -> :error
      end
    else
      {:ok, value}
    end
  end

  defp apply_cipher(value, cx, :decrypt),
    do: FieldCipher.decrypt(value, cx.scope, cx.ws, cx_binding(cx))

  # v1 -> bound v2 (the reseal tool's upgrade mode). Anything else unchanged.
  defp apply_cipher(value, cx, :upgrade) do
    case {FieldCipher.version(value), cx_binding(cx)} do
      {1, binding} when is_binary(binding) ->
        case FieldCipher.decrypt(value, cx.scope, cx.ws) do
          {:ok, plain} -> {:ok, FieldCipher.encrypt(plain, cx.scope, cx.ws, binding)}
          :error -> :error
        end

      _ ->
        {:ok, value}
    end
  end
end
