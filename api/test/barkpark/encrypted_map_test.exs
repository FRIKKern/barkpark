defmodule Barkpark.EncryptedMapTest do
  use ExUnit.Case, async: true

  alias Barkpark.EncryptedMap

  describe "type/0" do
    test "is :binary (Cloak stores ciphertext as binary)" do
      assert EncryptedMap.type() == :binary
    end
  end

  describe "cast/1" do
    test "accepts a plain map and wraps it in {:ok, map}" do
      assert {:ok, %{"key" => "value"}} = EncryptedMap.cast(%{"key" => "value"})
    end

    test "accepts nil and returns {:ok, nil}" do
      assert {:ok, nil} = EncryptedMap.cast(nil)
    end

    test "rejects a non-map value" do
      assert :error = EncryptedMap.cast("not a map")
    end

    test "accepts a nested map" do
      input = %{"a" => %{"b" => 1}}
      assert {:ok, ^input} = EncryptedMap.cast(input)
    end
  end

  describe "embed_as/1" do
    test "returns :self for any format" do
      assert EncryptedMap.embed_as(:json) == :self
      assert EncryptedMap.embed_as(:dump) == :self
    end
  end

  describe "equal?/2" do
    test "returns true for identical maps" do
      assert EncryptedMap.equal?(%{"x" => 1}, %{"x" => 1})
    end

    test "returns false for different maps" do
      refute EncryptedMap.equal?(%{"x" => 1}, %{"x" => 2})
    end

    test "returns true for identical nil values" do
      assert EncryptedMap.equal?(nil, nil)
    end
  end

  describe "dump/1 and load/1" do
    test "round-trips a map through encrypt/decrypt" do
      map = %{"hello" => "world", "count" => 42}

      assert {:ok, ciphertext} = EncryptedMap.dump(map)
      assert is_binary(ciphertext)

      assert {:ok, decrypted} = EncryptedMap.load(ciphertext)
      # JSON round-trip: integer values survive, keys become strings
      assert decrypted == %{"hello" => "world", "count" => 42}
    end

    test "dump(nil) returns {:ok, nil}" do
      assert {:ok, nil} = EncryptedMap.dump(nil)
    end

    test "load(nil) returns {:ok, nil}" do
      assert {:ok, nil} = EncryptedMap.load(nil)
    end

    test "ciphertext differs from plaintext JSON" do
      map = %{"secret" => "data"}
      {:ok, ciphertext} = EncryptedMap.dump(map)
      refute ciphertext == Jason.encode!(map)
    end
  end
end
