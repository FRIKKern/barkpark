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

  # ── LOW-17: FieldCipher.decrypt fails closed on a malformed envelope ─────────
  describe "FieldCipher.decrypt — malformed envelope fails closed (LOW-17)" do
    test "a non-integer \"k\" returns :error, never raises (admin reveal path)" do
      # Pre-fix this FunctionClause-raised in DataKeys.dek_for_version/2 (guard
      # `is_integer(version)`), crashing the reveal request instead of denying it.
      crafted = %{"_bpenc" => 1, "k" => "not-an-int", "v" => Base.encode64("x")}
      assert :error = FieldCipher.decrypt(crafted, "dataset:#{Ecto.UUID.generate()}")
    end

    test "a float \"k\" returns :error" do
      assert :error = FieldCipher.decrypt(%{"_bpenc" => 1, "k" => 1.5, "v" => "x"}, "dataset:x")
    end

    test "a non-binary \"v\" returns :error (would raise in Base.decode64/1)" do
      assert :error = FieldCipher.decrypt(%{"_bpenc" => 1, "k" => 1, "v" => 12_345}, "dataset:x")
    end

    test "a missing \"k\"/\"v\" envelope returns :error" do
      assert :error = FieldCipher.decrypt(%{"_bpenc" => 1}, "dataset:x")
    end
  end

  # ── MEDIUM-9: KEK rotation end-to-end via the previous-KEK fallback ──────────
  describe "KEK rotation (MEDIUM-9 — rewrap_all with a previous-KEK fallback)" do
    test "rewrap_all completes a rotation; old DEKs re-wrap and ciphertext still decrypts" do
      old_cfg = Application.get_env(:barkpark, LocalKek)
      on_exit(fn -> Application.put_env(:barkpark, LocalKek, old_cfg) end)

      old_key = old_cfg[:key]
      old_version = old_cfg[:version] || 1

      # A DEK + a content ciphertext sealed under the CURRENT (soon-old) KEK.
      scope = "dataset:#{Ecto.UUID.generate()}"
      {1, dek} = DataKeys.active_dek(scope)
      env = FieldCipher.encrypt("rotate-me", scope)

      # Rotate the KEK: fresh current key, the OLD key moves to previous_keys.
      new_key = Base.encode64(:crypto.strong_rand_bytes(32))

      Application.put_env(:barkpark, LocalKek,
        key: new_key,
        previous_keys: [old_key],
        version: old_version + 1
      )

      # The stored blob was sealed by the OLD KEK. Pre-fix, unwrap tried only the
      # new key → :error → rewrap_all could never complete. With the previous-key
      # fallback it unwraps under the old key and re-wraps under the new one.
      assert {:ok, n} = DataKeys.rewrap_all()
      assert n >= 1

      row = Repo.one!(from d in DataKey, where: d.scope == ^scope)
      assert row.kek_version == old_version + 1
      # Re-wrapped blob unwraps to the SAME DEK under the NEW KEK.
      assert {:ok, ^dek} = KeyProvider.unwrap(row.wrapped_key)
      # Content ciphertext (DEK unchanged) still decrypts.
      assert {:ok, "rotate-me"} = FieldCipher.decrypt(env, scope)
    end

    test "unwrap prefers the current KEK, falling back to a previous one" do
      old_cfg = Application.get_env(:barkpark, LocalKek)
      on_exit(fn -> Application.put_env(:barkpark, LocalKek, old_cfg) end)

      dek = :crypto.strong_rand_bytes(32)
      wrapped_old = LocalKek.wrap(dek)

      new_key = Base.encode64(:crypto.strong_rand_bytes(32))
      Application.put_env(:barkpark, LocalKek, key: new_key, previous_keys: [old_cfg[:key]])

      # Sealed by the old key → only the previous-key fallback can unwrap it.
      assert {:ok, ^dek} = LocalKek.unwrap(wrapped_old)
      # A blob sealed by neither key still fails closed.
      stranger = Base.encode64(:crypto.strong_rand_bytes(60))
      assert :error = LocalKek.unwrap(stranger)
    end
  end

  # ── LOW-18: one ACTIVE DEK per scope is enforced by the DB ───────────────────
  describe "data_keys — one active DEK per scope (LOW-18)" do
    test "a second ACTIVE DEK for the same scope is rejected by the partial index" do
      scope = "dataset:#{Ecto.UUID.generate()}"
      {1, _dek} = DataKeys.active_dek(scope)

      assert_raise Ecto.ConstraintError, fn ->
        %DataKey{}
        |> DataKey.changeset(%{
          scope: scope,
          version: 2,
          wrapped_key: "x",
          kek_version: 1,
          active: true
        })
        |> Repo.insert!()
      end
    end

    test "many INACTIVE versions per scope are allowed (the index is partial)" do
      scope = "dataset:#{Ecto.UUID.generate()}"
      {1, _} = DataKeys.active_dek(scope)
      {2, _} = DataKeys.rotate_dek(scope)
      {3, _} = DataKeys.rotate_dek(scope)

      active = Repo.one!(from d in DataKey, where: d.scope == ^scope and d.active == true)
      assert active.version == 3
      assert Repo.aggregate(from(d in DataKey, where: d.scope == ^scope), :count) == 3
    end
  end
end
