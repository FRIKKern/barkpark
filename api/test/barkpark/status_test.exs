defmodule Barkpark.StatusTest do
  @moduledoc """
  Behavior-preservation guard for `Status.get_incident/1` after it was
  de-duplicated onto the canonical `Repo.uuid_or_nil/1` (uuid-guarded-fetch).
  A valid id still resolves the row; a non-UUID string (or a well-formed but
  absent UUID) folds to `nil` — never an `Ecto.CastError` 500.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Status

  test "get_incident resolves a real incident by its UUID" do
    {:ok, incident} =
      Status.create_incident(%{
        title: "Elevated errors",
        impact: "minor",
        status: "investigating"
      })

    assert %Status.Incident{} = fetched = Status.get_incident(incident.id)
    assert fetched.id == incident.id
  end

  test "get_incident with a non-UUID string returns nil, not a CastError" do
    assert Status.get_incident("not-a-uuid") == nil
  end

  test "get_incident with a well-formed but absent UUID returns nil" do
    assert Status.get_incident(Ecto.UUID.generate()) == nil
  end
end
