defmodule Barkpark.Content.SchemaUpsertConvergeTest do
  @moduledoc """
  task-3748d052b83a9a2e — two first upserts of one schema name raced the read
  in `upsert_schema/3`: both saw no row, both inserted, and the loser answered
  422 "name has already been taken" (58 of 60, real two-process race). The
  loser now converges: its insert is skipped and its fields land on the
  winner's row. `insert_or_converge/3` is the loser's path, driven directly
  (the row exists; the read before it did not see it).
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.{Schema, SchemaDefinition}

  @ds "converge-test"

  defp attrs(name, title),
    do: %{
      "name" => name,
      "title" => title,
      "visibility" => "public",
      "fields" => [%{"name" => "title", "type" => "string"}]
    }

  defp stamped(attrs, scope) do
    {:ok, a} = attrs |> Map.put("dataset", @ds) |> Content.put_scope_attrs(scope)
    a
  end

  defp rows(name),
    do: Repo.all(from(s in SchemaDefinition, where: s.name == ^name and s.dataset == ^@ds))

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    %{scope: [workspace_id: ws.id, project_id: proj.id]}
  end

  test "the losing first insert lands on the winner's row as an update", %{scope: scope} do
    name = "conv_#{System.unique_integer([:positive])}"
    {:ok, winner} = Content.upsert_schema(attrs(name, "Winner"), @ds, scope)

    assert {:ok, %SchemaDefinition{} = landed} =
             Schema.insert_or_converge(stamped(attrs(name, "Loser"), scope), @ds, scope)

    assert landed.id == winner.id
    assert [%SchemaDefinition{id: id, title: "Loser"}] = rows(name)
    assert id == winner.id
  end

  test "a first insert with no rival is unchanged", %{scope: scope} do
    name = "conv_#{System.unique_integer([:positive])}"

    assert {:ok, %SchemaDefinition{title: "Only"}} =
             Schema.insert_or_converge(stamped(attrs(name, "Only"), scope), @ds, scope)

    assert [%SchemaDefinition{title: "Only"}] = rows(name)
  end

  test "an invalid schema still fails as before, nothing written", %{scope: scope} do
    name = "conv_#{System.unique_integer([:positive])}"
    bad = %{"name" => name, "visibility" => "public"}

    assert {:error, %Ecto.Changeset{}} =
             Schema.insert_or_converge(stamped(bad, scope), @ds, scope)

    assert rows(name) == []
  end
end
