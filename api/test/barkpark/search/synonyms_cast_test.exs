defmodule Barkpark.Search.SynonymsCastTest do
  # No DataCase: a non-UUID :id short-circuits in the cast guard and returns
  # before any Repo call, so these cases need no database.
  use ExUnit.Case, async: true

  alias Barkpark.Search.Synonyms

  test "delete/3 returns not_found for a non-UUID id without touching the DB" do
    assert Synonyms.delete("not-a-uuid", "search", "default") == {:error, :not_found}
  end

  test "delete/3 returns not_found for an empty id" do
    assert Synonyms.delete("", "search", "default") == {:error, :not_found}
  end

  test "delete/3 returns not_found for a truncated UUID" do
    assert Synonyms.delete("123e4567-e89b-12d3-a456", "search", "default") ==
             {:error, :not_found}
  end
end
