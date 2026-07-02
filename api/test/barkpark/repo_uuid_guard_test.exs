defmodule Barkpark.RepoUuidGuardTest do
  # Pure, no-DB unit test for the shared :binary_id fetch guard.
  use ExUnit.Case, async: true

  alias Barkpark.Repo

  describe "uuid_or_nil/1" do
    test "a valid UUID casts through unchanged" do
      uuid = Ecto.UUID.generate()
      assert Repo.uuid_or_nil(uuid) == uuid
    end

    test "a valid UUID is returned as the CAST string (callers bind this value)" do
      # Ecto.UUID.cast downcases — the returned value, not the original, is bound.
      upper = String.upcase(Ecto.UUID.generate())
      assert Repo.uuid_or_nil(upper) == String.downcase(upper)
    end

    test "a non-UUID string returns nil" do
      assert Repo.uuid_or_nil("garbage") == nil
      assert Repo.uuid_or_nil("") == nil
      assert Repo.uuid_or_nil("evt_not_a_uuid") == nil
    end

    test "a non-binary argument returns nil" do
      assert Repo.uuid_or_nil(nil) == nil
      assert Repo.uuid_or_nil(123) == nil
      assert Repo.uuid_or_nil(%{}) == nil
      assert Repo.uuid_or_nil([:not, :binary]) == nil
    end
  end
end
