defmodule Barkpark.Auth.ApiTokenTest do
  # DataCase (not the bare ExUnit.Case) so the FK-abort describe below can hit a
  # real Repo; async: false because a Postgres FK violation aborts the sandbox
  # transaction (matches the MediaFile/Document FK sibling tests).
  use Barkpark.DataCase, async: false

  import Barkpark.AccountsFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo

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

  # FK-abort containment (Felix W18). `api_tokens.workspace_id` and
  # `api_tokens.owner_user_id` are real Postgres FKs (default names
  # `api_tokens_<col>_fkey`). Each bad-FK insert lives in its OWN test: a
  # violation aborts the sandbox transaction, so nothing may run after it.
  describe "changeset/2 FK-abort containment" do
    defp insert(overrides) do
      attrs =
        Map.merge(
          %{token_hash: ApiToken.hash_token("fk-#{System.unique_integer([:positive])}")},
          overrides
        )

      %ApiToken{} |> ApiToken.changeset(attrs) |> Repo.insert()
    end

    test "non-existent workspace_id returns {:error, changeset}, never a raise" do
      assert {:error, %Ecto.Changeset{} = cs} = insert(%{workspace_id: Ecto.UUID.generate()})
      assert {"does not exist", _} = cs.errors[:workspace_id]
    end

    test "non-existent owner_user_id returns {:error, changeset}, never a raise" do
      assert {:error, %Ecto.Changeset{} = cs} = insert(%{owner_user_id: Ecto.UUID.generate()})
      assert {"does not exist", _} = cs.errors[:owner_user_id]
    end

    test "live workspace + owner_user references still insert" do
      ws = create_workspace!()
      user = register_user("fk-owner-#{System.unique_integer([:positive])}@example.com")

      assert {:ok, %ApiToken{} = token} =
               insert(%{workspace_id: ws.id, owner_user_id: user.id})

      assert token.workspace_id == ws.id
      assert token.owner_user_id == user.id
    end
  end
end
