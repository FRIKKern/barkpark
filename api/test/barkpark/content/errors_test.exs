defmodule Barkpark.Content.ErrorsTest do
  use ExUnit.Case, async: true
  alias Barkpark.Content.Errors

  test "maps not_found" do
    assert Errors.to_envelope({:error, :not_found}) ==
             %{code: "not_found", message: "document not found", status: 404}
  end

  test "maps changeset errors" do
    cs =
      {%{}, %{title: :string}}
      |> Ecto.Changeset.cast(%{}, [:title])
      |> Ecto.Changeset.validate_required([:title])

    env = Errors.to_envelope({:error, cs})
    assert env.code == "validation_failed"
    assert env.status == 422
    assert env.details == %{title: ["can't be blank"]}
  end

  test "maps rev mismatch" do
    assert %{code: "rev_mismatch", status: 409} = Errors.to_envelope({:error, :rev_mismatch})
  end
end
