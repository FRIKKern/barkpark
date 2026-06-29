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

  @canonical capability:field-encryption-chokepoint aka:encrypt-marked,reveal-fields,decrypt-document
  """

  alias Barkpark.Content
  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Content.SchemaDefinition.Field
  alias Barkpark.Crypto.FieldCipher

  @doc """
  Encrypt every field marked `encrypted: true` in `content`, resolving the
  schema for `{type, dataset}`. Returns the (possibly) rewritten content map.

  Behavioural contract:

    * No schema, an unparseable schema, or no marked field → `content` is
      returned byte-identical (the no-op / no-behaviour-change path).
    * Already-encrypted values pass through (idempotent re-save).
    * Encryption never fails (the active DEK is created on demand), so this can
      never crash the write path.
  """
  @spec encrypt_marked(map(), String.t(), String.t()) :: map()
  def encrypt_marked(content, type, dataset)
      when is_map(content) and is_binary(type) and is_binary(dataset) do
    case resolve_fields(type, dataset) do
      {:ok, fields} ->
        case transform_map(content, fields, scope(dataset), :encrypt) do
          {:ok, encrypted} -> encrypted
          # Encryption never returns :error, but fail safe to "leave unchanged"
          # rather than ever raising on a surprising shape.
          :error -> content
        end

      :error ->
        content
    end
  end

  def encrypt_marked(content, _type, _dataset), do: content

  @doc """
  Decrypt every `encrypted: true` field of `doc` against `schema`, under the
  DEK scope for `dataset`. Returns `{:ok, doc_with_plaintext}` or `:error` when
  any marked envelope fails to decrypt (unknown key version, bad payload, or
  GCM tamper — fails closed).

  This is the privileged reveal primitive; callers MUST gate it on
  authorization (see `Barkpark.Content.reveal_fields/4`).
  """
  @spec decrypt_document(Document.t(), SchemaDefinition.t(), String.t()) ::
          {:ok, Document.t()} | :error
  def decrypt_document(
        %Document{content: content} = doc,
        %SchemaDefinition{fields: raw_fields},
        dataset
      )
      when is_map(content) and is_list(raw_fields) and is_binary(dataset) do
    case parse_fields(raw_fields) do
      {:ok, fields} ->
        case transform_map(content, fields, scope(dataset), :decrypt) do
          {:ok, decrypted} -> {:ok, %{doc | content: decrypted}}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  def decrypt_document(_doc, _schema, _dataset), do: :error

  # ── internals ──────────────────────────────────────────────────────────────

  defp scope(dataset), do: "dataset:" <> dataset

  # Resolve the schema for {type, dataset} and parse its raw `fields` JSON into
  # %Field{} structs (which carry the :encrypted marker). Any miss — no schema,
  # not a map list, parse error — yields :error so the caller leaves content
  # untouched (never crash the write path).
  defp resolve_fields(type, dataset) do
    case Content.get_schema(type, dataset) do
      {:ok, %SchemaDefinition{fields: raw}} -> parse_fields(raw)
      _ -> :error
    end
  end

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
  defp transform_map(content, fields, scope, mode) when is_map(content) and is_list(fields) do
    Enum.reduce_while(fields, {:ok, content}, fn %Field{name: name} = field, {:ok, acc} ->
      if is_binary(name) and Map.has_key?(acc, name) do
        case transform_value(Map.get(acc, name), field, scope, mode) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
          :error -> {:halt, :error}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp transform_map(value, _fields, _scope, _mode), do: {:ok, value}

  # Transform a single VALUE according to a field's shape. An `encrypted: true`
  # field encrypts/decrypts the whole value as one envelope (works for scalars,
  # maps, and lists — FieldCipher JSON-encodes). A composite recurses into its
  # subfields; an arrayOf applies its `of` descriptor to each item. Anything
  # else passes through unchanged.
  defp transform_value(value, %Field{encrypted: true}, scope, mode),
    do: apply_cipher(value, scope, mode)

  defp transform_value(value, %Field{type: "composite", fields: subfields}, scope, mode)
       when is_list(subfields) and is_map(value),
       do: transform_map(value, subfields, scope, mode)

  defp transform_value(value, %Field{type: "arrayOf", of: %Field{} = of}, scope, mode)
       when is_list(value),
       do: transform_list(value, of, scope, mode)

  defp transform_value(value, _field, _scope, _mode), do: {:ok, value}

  defp transform_list(list, of_field, scope, mode) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case transform_value(item, of_field, scope, mode) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp apply_cipher(value, scope, :encrypt), do: {:ok, FieldCipher.encrypt(value, scope)}
  defp apply_cipher(value, scope, :decrypt), do: FieldCipher.decrypt(value, scope)
end
