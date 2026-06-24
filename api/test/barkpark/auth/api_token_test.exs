defmodule Barkpark.Auth.ApiTokenTest do
  use ExUnit.Case, async: true

  alias Barkpark.Auth.ApiToken

  describe "hash_token/1" do
    test "returns a lowercase hex SHA-256 digest (64 chars)" do
      result = ApiToken.hash_token("mysecret")
      assert is_binary(result)
      assert byte_size(result) == 64
      assert result =~ ~r/^[0-9a-f]+$/
    end

    test "same input always produces the same hash (deterministic)" do
      raw = "stable-token-#{System.unique_integer()}"
      assert ApiToken.hash_token(raw) == ApiToken.hash_token(raw)
    end

    test "different inputs produce different hashes" do
      a = ApiToken.hash_token("token-a")
      b = ApiToken.hash_token("token-b")
      refute a == b
    end

    test "empty string is hashed without error" do
      result = ApiToken.hash_token("")
      assert byte_size(result) == 64
    end
  end

  describe "changeset/2" do
    test "valid attrs with required token_hash produces a valid changeset" do
      cs =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token("raw"),
          label: "dev key",
          dataset: "production",
          permissions: ["read", "write"]
        })

      assert cs.valid?
    end

    test "missing token_hash is invalid" do
      cs = %ApiToken{} |> ApiToken.changeset(%{label: "no hash"})
      refute cs.valid?
      assert :token_hash in Keyword.keys(cs.errors)
    end

    test "changeset carries the cast permissions list" do
      cs =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: "abc123",
          permissions: ["read", "admin"]
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :permissions) == ["read", "admin"]
    end
  end
end
