defmodule Barkpark.VaultTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Vault

  describe "encrypt/1 and decrypt/1" do
    test "round-trips a binary value" do
      plaintext = "secret-api-credential"

      assert {:ok, ciphertext} = Vault.encrypt(plaintext)
      assert {:ok, ^plaintext} = Vault.decrypt(ciphertext)
    end

    test "ciphertext is different from plaintext" do
      plaintext = "some sensitive data"

      assert {:ok, ciphertext} = Vault.encrypt(plaintext)
      refute ciphertext == plaintext
    end

    test "produces unique ciphertext each call (random IV)" do
      plaintext = "same input"

      assert {:ok, ct1} = Vault.encrypt(plaintext)
      assert {:ok, ct2} = Vault.encrypt(plaintext)

      refute ct1 == ct2
    end

    test "decrypt returns error tuple for invalid ciphertext" do
      assert {:error, _} = Vault.decrypt("not-valid-ciphertext")
    end

    test "round-trips an empty binary" do
      assert {:ok, ciphertext} = Vault.encrypt("")
      assert {:ok, ""} = Vault.decrypt(ciphertext)
    end
  end
end
