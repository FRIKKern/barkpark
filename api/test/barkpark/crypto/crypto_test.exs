defmodule Barkpark.CryptoTest do
  @moduledoc """
  Phase 0 foundations: the envelope-DEK crypto stack
  (KeyProvider/LocalKek → DataKeys → FieldCipher).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Crypto.{DataKey, DataKeys, FieldCipher, KeyProvider, LocalKek}

  describe "LocalKek (KEK wrap/unwrap)" do
    test "round-trips a DEK" do
      dek = :crypto.strong_rand_bytes(32)
      wrapped = LocalKek.wrap(dek)
      assert is_binary(wrapped)
      assert wrapped != dek
      assert {:ok, ^dek} = LocalKek.unwrap(wrapped)
    end

    test "fresh IV per wrap — same DEK wraps to different bytes" do
      dek = :crypto.strong_rand_bytes(32)
      refute LocalKek.wrap(dek) == LocalKek.wrap(dek)
    end

    test "fails closed on a tampered wrap" do
      dek = :crypto.strong_rand_bytes(32)
      <<head::binary-size(20), byte, rest::binary>> = Base.decode64!(LocalKek.wrap(dek))
      tampered = Base.encode64(<<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)
      assert :error = LocalKek.unwrap(tampered)
    end

    test "the configured provider resolves to LocalKek by default" do
      assert KeyProvider.impl() == LocalKek
      assert KeyProvider.kek_version() == 1
    end
  end

  describe "DataKeys (per-scope DEK lifecycle)" do
    test "active_dek creates on demand and is stable across calls" do
      scope = "dataset:#{Ecto.UUID.generate()}"
      {v1, dek1} = DataKeys.active_dek(scope)
      assert v1 == 1
      assert byte_size(dek1) == 32
      assert {^v1, ^dek1} = DataKeys.active_dek(scope)
    end

    test "DEK is stored only wrapped (never plaintext in the row)" do
      scope = "dataset:#{Ecto.UUID.generate()}"
      {_v, dek} = DataKeys.active_dek(scope)
      row = Repo.one!(from d in DataKey, where: d.scope == ^scope)
      refute String.contains?(row.wrapped_key, Base.encode64(dek))
      assert {:ok, ^dek} = KeyProvider.unwrap(row.wrapped_key)
    end

    test "dek_for_version returns the right key and :error for unknown versions" do
      scope = "dataset:#{Ecto.UUID.generate()}"
      {v, dek} = DataKeys.active_dek(scope)
      assert {:ok, ^dek} = DataKeys.dek_for_version(scope, v)
      assert :error = DataKeys.dek_for_version(scope, 999)
    end

    test "rotate_dek starts a new active version; old version still resolvable" do
      scope = "dataset:#{Ecto.UUID.generate()}"
      {1, old} = DataKeys.active_dek(scope)
      {2, new} = DataKeys.rotate_dek(scope)
      refute new == old
      assert {2, ^new} = DataKeys.active_dek(scope)
      assert {:ok, ^old} = DataKeys.dek_for_version(scope, 1)
    end

    test "rewrap_all re-wraps every DEK and keeps it decryptable" do
      scope = "dataset:#{Ecto.UUID.generate()}"
      {_v, dek} = DataKeys.active_dek(scope)
      before = Repo.one!(from d in DataKey, where: d.scope == ^scope).wrapped_key
      assert {:ok, n} = DataKeys.rewrap_all()
      assert n >= 1
      after_ = Repo.one!(from d in DataKey, where: d.scope == ^scope).wrapped_key
      refute after_ == before
      assert {:ok, ^dek} = KeyProvider.unwrap(after_)
    end
  end

  describe "FieldCipher (envelope encryption of a content field)" do
    test "round-trips strings, numbers, maps, and lists" do
      scope = "dataset:#{Ecto.UUID.generate()}"

      for value <- ["hetzner-token-abc", 42, %{"a" => 1, "b" => [2, 3]}, ["x", "y"]] do
        env = FieldCipher.encrypt(value, scope)
        assert FieldCipher.encrypted?(env)
        assert {:ok, ^value} = FieldCipher.decrypt(env, scope)
      end
    end

    test "produces an opaque envelope with no plaintext" do
      scope = "dataset:#{Ecto.UUID.generate()}"
      env = FieldCipher.encrypt("super-secret", scope)
      assert %{"_bpenc" => 1, "k" => 1, "v" => v} = env
      refute String.contains?(v, "super-secret")
    end

    test "scope is the AAD — a ciphertext cannot be replayed under another scope" do
      env = FieldCipher.encrypt("secret", "dataset:aaaa")
      assert :error = FieldCipher.decrypt(env, "dataset:bbbb")
    end

    test "fails closed on a tampered envelope" do
      scope = "dataset:#{Ecto.UUID.generate()}"
      env = FieldCipher.encrypt("secret", scope)
      <<h::binary-size(18), byte, rest::binary>> = Base.decode64!(env["v"])
      bad = %{env | "v" => Base.encode64(<<h::binary, Bitwise.bxor(byte, 1), rest::binary>>)}
      assert :error = FieldCipher.decrypt(bad, scope)
    end

    test "is idempotent — re-encrypting an envelope is a no-op" do
      scope = "dataset:#{Ecto.UUID.generate()}"
      env = FieldCipher.encrypt("secret", scope)
      assert FieldCipher.encrypt(env, scope) == env
    end

    test "decrypt passes through non-envelope values unchanged" do
      assert {:ok, "plain"} = FieldCipher.decrypt("plain", "dataset:x")
    end

    test "decrypts across a DEK rotation via the stored version" do
      scope = "dataset:#{Ecto.UUID.generate()}"
      env_v1 = FieldCipher.encrypt("old", scope)
      {2, _new} = DataKeys.rotate_dek(scope)
      # Old ciphertext (k=1) still decrypts; new writes use k=2.
      assert {:ok, "old"} = FieldCipher.decrypt(env_v1, scope)
      env_v2 = FieldCipher.encrypt("new", scope)
      assert env_v2["k"] == 2
      assert {:ok, "new"} = FieldCipher.decrypt(env_v2, scope)
    end
  end
end
