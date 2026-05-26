defmodule Barkpark.AuthTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy

  defp workspace(slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: "Auth WS"})
    ws
  end

  # Insert a token with a known raw value so verify_token/1 can be exercised.
  # `attrs` overlays extra fields (revoked_at / expires_at / workspace_id).
  defp insert_token(raw, attrs \\ %{}) do
    base = %{
      token_hash: ApiToken.hash_token(raw),
      label: "l",
      dataset: "test",
      permissions: ["read"]
    }

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    token
  end

  defp seconds_from_now(secs) do
    DateTime.utc_now() |> DateTime.add(secs, :second) |> DateTime.truncate(:second)
  end

  describe "verify_token/1 — base behaviour" do
    test "an active token verifies (no regression)" do
      raw = "active-" <> Ecto.UUID.generate()
      token = insert_token(raw)

      assert {:ok, verified} = Auth.verify_token(raw)
      assert verified.id == token.id
    end

    test "an unknown token is unauthorized" do
      assert Auth.verify_token("nope-" <> Ecto.UUID.generate()) == {:error, :unauthorized}
    end
  end

  describe "verify_token/1 — revocation" do
    test "a revoked token is rejected (was: authenticated)" do
      raw = "revoked-" <> Ecto.UUID.generate()
      token = insert_token(raw)

      # Sanity: verifies before revocation.
      assert {:ok, _} = Auth.verify_token(raw)

      assert {:ok, _} = Auth.revoke_token(token)
      assert Auth.verify_token(raw) == {:error, :unauthorized}
    end
  end

  describe "verify_token/1 — expiry" do
    test "an expired token (expires_at in the past) is rejected" do
      raw = "expired-" <> Ecto.UUID.generate()
      insert_token(raw, %{expires_at: seconds_from_now(-60)})

      assert Auth.verify_token(raw) == {:error, :unauthorized}
    end

    test "a non-expired token (expires_at in the future) still verifies" do
      raw = "future-" <> Ecto.UUID.generate()
      token = insert_token(raw, %{expires_at: seconds_from_now(3600)})

      assert {:ok, verified} = Auth.verify_token(raw)
      assert verified.id == token.id
    end

    test "a nil expires_at never expires" do
      raw = "nilexp-" <> Ecto.UUID.generate()
      insert_token(raw, %{expires_at: nil})

      assert {:ok, _} = Auth.verify_token(raw)
    end
  end

  describe "revoke_token/1" do
    test "stamps revoked_at and accepts a struct" do
      token = insert_token("rt-struct-" <> Ecto.UUID.generate())
      assert is_nil(token.revoked_at)

      assert {:ok, revoked} = Auth.revoke_token(token)
      refute is_nil(revoked.revoked_at)
    end

    test "accepts a token id" do
      raw = "rt-id-" <> Ecto.UUID.generate()
      token = insert_token(raw)

      assert {:ok, revoked} = Auth.revoke_token(token.id)
      assert revoked.id == token.id
      refute is_nil(revoked.revoked_at)
      assert Auth.verify_token(raw) == {:error, :unauthorized}
    end

    test "unknown id → {:error, :not_found}" do
      assert Auth.revoke_token(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "deleted-workspace orphan (cascade)" do
    test "deleting a token's home workspace deletes the token (no orphan auth)" do
      ws = workspace("ws-cascade")
      raw = "cascade-" <> Ecto.UUID.generate()

      {:ok, token} = Auth.create_token(raw, "l", "test", ["read", "write", "admin"], ws.id)
      assert token.workspace_id == ws.id
      assert {:ok, _} = Auth.verify_token(raw)

      # Delete the home workspace — the FK cascade must take the token with it.
      Repo.delete!(ws)

      assert is_nil(Repo.get(ApiToken, token.id))
      # The orphan vector is closed: a token whose workspace is gone no longer
      # authenticates (previously it persisted with workspace_id NULL).
      assert Auth.verify_token(raw) == {:error, :unauthorized}
    end
  end
end
