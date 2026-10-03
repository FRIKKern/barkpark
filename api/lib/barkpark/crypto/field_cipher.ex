defmodule Barkpark.Crypto.FieldCipher do
  @moduledoc """
  Encrypt/decrypt a single content-field value at rest, using the per-scope DEK
  from `Barkpark.Crypto.DataKeys`.

  A plaintext value becomes a self-describing **envelope map** stored in place of
  the field inside `documents.content`:

      %{"_bpenc" => 1, "k" => <dek_version>, "v" => Base64(iv ‖ tag ‖ ct)}

  AES-256-GCM with a fresh 12-byte IV per call; the **scope is the AAD**, so a
  ciphertext can't be lifted from one dataset/tenant and replayed under another.
  GCM authentication means any tamper → `:error` (fails closed). The `"k"`
  (DEK version) lets `decrypt/2` find the right key after rotation.

  Values are JSON-encoded before encryption so non-string fields (numbers, maps,
  lists) round-trip exactly.
  """
  alias Barkpark.Crypto.DataKeys

  @marker "_bpenc"
  @version 1
  @iv_bytes 12
  @tag_bytes 16

  # @canonical capability:field-encryption aka:encrypt-field,field-cipher,encrypted-field,secrets-at-rest
  @doc "True when `value` is an encryption envelope produced by `encrypt/2`."
  @spec encrypted?(term()) :: boolean()
  def encrypted?(%{@marker => _}), do: true
  def encrypted?(_), do: false

  @doc """
  Encrypt `value` under the active DEK for `(workspace_id, scope)`. Returns the
  envelope map. An envelope THIS server sealed under the same
  `(workspace_id, scope)` passes through untouched (idempotent — re-saving a doc
  whose secret field is already ciphertext does not double-encrypt).

  Owner ruling #18 (task-f462de9e4c1c4621): a value that only LOOKS like an
  envelope — a caller-built `%{"_bpenc" => 1, "k" => 1, "v" => <plaintext>}`,
  or a real envelope sealed under another workspace or dataset — fails the
  round trip and is sealed like any other value instead of being stored as
  given. The content write path refuses such a value up front with a 422
  (`Content.Encryption.encrypt_marked/4`); this clause is the floor for every
  other caller.

  The DEK is selected per-workspace (charter D51-D54) but the AAD stays the BARE
  `scope` — the same scope binding a ciphertext cannot be replayed under another
  dataset. `workspace_id` defaults to `nil` (the NULL-workspace DEK), so the
  arity-2 call site and the direct-crypto tests are unchanged.
  """
  @spec encrypt(term(), String.t(), binary() | nil) :: map()
  def encrypt(value, scope, workspace_id \\ nil)

  def encrypt(value, scope, workspace_id)
      when is_map(value) and is_map_key(value, @marker) and is_binary(scope) do
    case verify(value, scope, workspace_id) do
      :ok -> value
      :error -> seal(value, scope, workspace_id)
    end
  end

  def encrypt(value, scope, workspace_id) when is_binary(scope),
    do: seal(value, scope, workspace_id)

  @doc """
  `:ok` when `value` is an envelope that decrypts under `(workspace_id, scope)`,
  i.e. one this server sealed for that scope; `:error` for anything else,
  including a caller-built envelope and a real one from another scope.
  """
  @spec verify(term(), String.t(), binary() | nil) :: :ok | :error
  def verify(%{@marker => _} = value, scope, workspace_id) when is_binary(scope) do
    case decrypt(value, scope, workspace_id) do
      {:ok, _} -> :ok
      :error -> :error
    end
  end

  def verify(_value, _scope, _workspace_id), do: :error

  defp seal(value, scope, workspace_id) do
    {version, dek} = DataKeys.active_dek(workspace_id, scope)
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    plaintext = Jason.encode!(value)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, plaintext, scope, true)

    %{@marker => @version, "k" => version, "v" => Base.encode64(iv <> tag <> ct)}
  end

  @doc """
  Decrypt an envelope produced by `encrypt/2` back to the original value.
  `{:ok, value}` or `:error` (unknown key version, bad payload, or tamper).
  A non-envelope value returns `{:ok, value}` unchanged (so callers can decrypt
  blindly over a content map).
  """
  @spec decrypt(term(), String.t(), binary() | nil) :: {:ok, term()} | :error
  def decrypt(envelope, scope, workspace_id \\ nil)

  # LOW-17: GUARD the payload shape. A crafted envelope with a non-integer "k" or
  # a non-binary "v" used to raise (FunctionClauseError in `DataKeys.dek_for_version/3`
  # / `Base.decode64/1`) on the admin reveal path. Now a malformed envelope falls
  # through to the `%{@marker => _} -> :error` clause below — fail closed, no raise.
  def decrypt(%{@marker => @version, "k" => version, "v" => encoded}, scope, workspace_id)
      when is_binary(scope) and is_integer(version) and is_binary(encoded) do
    with {:ok, dek} <- DataKeys.dek_for_version(workspace_id, scope, version),
         {:ok, <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>>} <-
           Base.decode64(encoded),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, ct, scope, tag, false),
         {:ok, value} <- Jason.decode(plaintext) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  def decrypt(%{@marker => _}, _scope, _workspace_id), do: :error
  def decrypt(value, _scope, _workspace_id), do: {:ok, value}
end
