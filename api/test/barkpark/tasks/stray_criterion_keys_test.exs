defmodule Barkpark.Tasks.StrayCriterionKeysTest do
  @moduledoc """
  The reviewed data step for pds-bl-stray-keys-on-acceptance-criteria
  (`Tasks.StrayCriterionKeys`, run on a box through
  `Barkpark.Release.clean_stray_criterion_keys/1`). Legacy rows are installed
  BEHIND the write door, the way history wrote them.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureIO

  alias Barkpark.{Content, Release, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{StrayCriterionKeys, Validation}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp legacy_task!(scope, criteria) do
    doc_id = "stray-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" =>
              Enum.map(criteria, &Map.take(&1, ["criterion", "met", "evidence"]))
          }
        },
        @dataset,
        scope
      )

    content = Map.put(doc.content, "acceptance_criteria", criteria)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id)
      |> Repo.update_all(set: [content: content, rev: Tasks.Internal.generate_rev()])

    Repo.get!(Document, doc.id)
  end

  defp criteria_of(doc), do: Repo.get!(Document, doc.id).content["acceptance_criteria"]

  defp mine(report, doc), do: Enum.filter(report.actions, &(&1.doc_id == doc.doc_id))

  test "dry run reports and writes nothing; apply cleans exactly per the ruling; a re-run is clean",
       %{
         scope: scope
       } do
    doc =
      legacy_task!(scope, [
        %{"criterion" => "a", "met" => true, "evidence" => "p", "index" => 0, "weight" => 2},
        %{"criterion" => "b", "met" => true, "evidence" => "p", "amendment" => "AMENDED by hand"},
        %{"criterion" => "c", "met" => false, "evidence" => "", "note" => "REVIEW: falsely met"},
        %{"criterion" => "d", "met" => true, "evidence" => "p", " met" => false},
        %{"criterion" => "e", "met" => false, "evidence" => "", "index" => 9},
        %{"criterion" => "f", "met" => false, "evidence" => "", "owner" => "x"}
      ])

    before = criteria_of(doc)

    dry = StrayCriterionKeys.run()
    assert criteria_of(doc) == before, "the dry run wrote"

    assert Enum.map(mine(dry, doc), &{&1.index, &1.key, &1.action}) == [
             {0, "index", :drop},
             {1, "amendment", :fold_into_amendments},
             {2, "note", :move_into_attempts},
             {3, " met", :drop},
             {4, "index", :report},
             {5, "owner", :report}
           ]

    applied = StrayCriterionKeys.run(apply: true)
    assert applied.changed >= 1
    [a, b, c, d, e, f] = criteria_of(doc)

    assert a == %{"criterion" => "a", "met" => true, "evidence" => "p", "weight" => 2}
    refute Map.has_key?(b, "amendment")
    assert [%{"note" => "AMENDED by hand", "worker" => "legacy-amendment"}] = b["amendments"]
    refute Map.has_key?(c, "note")
    assert [%{"note" => "REVIEW: falsely met", "worker" => "legacy-note"}] = c["attempts"]
    assert d == %{"criterion" => "d", "met" => true, "evidence" => "p"}, "met stays as stored"
    assert e["index"] == 9, "a mismatched index is reported, not touched"
    assert f["owner"] == "x", "an unruled key is reported, not touched"

    rerun = StrayCriterionKeys.run()

    assert Enum.map(mine(rerun, doc), &{&1.index, &1.key, &1.action}) == [
             {4, "index", :report},
             {5, "owner", :report}
           ]
  end

  test "a row cleaned of ruled strays passes the allowlist", %{scope: scope} do
    doc =
      legacy_task!(scope, [
        %{"criterion" => "a", "met" => true, "evidence" => "p", "index" => 0},
        %{"criterion" => "b", "met" => false, "evidence" => "", "note" => "n", " met" => true}
      ])

    refute is_nil(Validation.criteria_violation(criteria_of(doc)))
    StrayCriterionKeys.run(apply: true)
    assert Validation.criteria_violation(criteria_of(doc)) == nil
  end

  test "the release entry point runs it (dry run by default) and prints the report", %{
    scope: scope
  } do
    doc =
      legacy_task!(scope, [%{"criterion" => "a", "met" => true, "evidence" => "p", "index" => 0}])

    out =
      capture_io(fn -> send(self(), Release.clean_stray_criterion_keys(boot: fn -> :ok end)) end)

    assert_received %{scanned: _}
    assert out =~ "dry run"
    assert criteria_of(doc) |> hd() |> Map.has_key?("index")
  end
end
