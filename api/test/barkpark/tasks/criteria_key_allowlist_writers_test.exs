defmodule Barkpark.Tasks.CriteriaKeyAllowlistWritersTest do
  @moduledoc """
  pds-bl-stray-keys-on-acceptance-criteria — the declared key set of an
  acceptance_criteria entry, on every writer that touches entries:

    * CREATE (`Content.create_document/4`, the funnel for `bp task create`
      and mutate create/createOrReplace) refuses an unknown key, naming it;
    * DOC PATCH (`Content.upsert_document/4`) refuses one too — and so does a
      patch of an UNRELATED field on a row that still carries a legacy stray,
      which is why the corpus cleanup must run before this deploys;
    * STAMP and CLOSE (`Tasks.Stamp`, `Tasks.Close`, rev-fenced writes behind
      the content door) keep working on rows with every declared key AND on a
      row that still carries a legacy stray: they never write a stray, and
      they never refuse an old one, so no row can get stuck on a stamp or close.
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Close, Stamp, Validation}

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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp create(doc_id, criteria, scope) do
    Content.create_document(
      "task",
      %{
        "doc_id" => doc_id,
        "title" => doc_id,
        "content" => %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => criteria
        }
      },
      @dataset,
      scope
    )
  end

  defp declared_entry(text, met),
    do: %{
      "criterion" => text,
      "met" => met,
      "evidence" => if(met, do: "proof", else: ""),
      "attempts" => [],
      "weight" => 2,
      "merge_gate" => false
    }

  # A row as history wrote it, BEHIND the door (see stamp_test.exs's
  # install_legacy_criteria!/2 for why that is the honest fixture).
  defp install_legacy!(doc, criteria) do
    stored = Repo.get!(Document, doc.id)
    content = Map.put(stored.content, "acceptance_criteria", criteria)

    {1, _} =
      from(d in Document, where: d.id == ^stored.id)
      |> Repo.update_all(set: [content: content, rev: Tasks.Internal.generate_rev()])

    Repo.get!(Document, doc.id)
  end

  defp error_text(result), do: inspect(result)

  test "CREATE refuses an unknown key, naming it and the allowed set", %{scope: scope} do
    result = create(uniq("create-stray"), [%{"criterion" => "ships", "index" => 0}], scope)

    assert {:error, _} = result
    assert error_text(result) =~ ~s(\\"index\\")
    assert error_text(result) =~ Enum.join(Validation.criterion_keys(), ", ")
  end

  test "CREATE accepts every declared key", %{scope: scope} do
    assert {:ok, _} = create(uniq("create-ok"), [declared_entry("ships", false)], scope)
  end

  test "DOC PATCH refuses an unknown key on the criteria it writes", %{scope: scope} do
    doc_id = uniq("patch-stray")
    {:ok, _} = create(doc_id, [declared_entry("ships", false)], scope)

    result =
      Content.upsert_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [Map.put(declared_entry("ships", false), "note", "x")]
          }
        },
        @dataset,
        scope
      )

    assert {:error, _} = result
    assert error_text(result) =~ ~s(\\"note\\")
  end

  test "STAMP works on a row with every declared key, and on a row with a legacy stray", %{
    scope: scope
  } do
    for legacy? <- [false, true] do
      doc_id = uniq("stamp")
      {:ok, doc} = create(doc_id, [declared_entry("ships", false)], scope)

      if legacy?,
        do: install_legacy!(doc, [Map.put(declared_entry("ships", false), "index", 0)])

      {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", scope)
      epoch = claimed.content["claim"]["epoch"]

      result =
        Stamp.stamp(doc.id, "w",
          observed_epoch: epoch,
          criterion: 0,
          criterion_text: "ships",
          outcome: {:met, "proof"}
        )

      assert match?({:ok, _}, result), "legacy?=#{legacy?}: #{inspect(result)}"
      {:ok, stamped} = result

      [entry] = stamped.content["acceptance_criteria"]
      assert entry["met"] == true
      assert entry["weight"] == 2, "a declared key survives the stamp"
    end
  end

  test "CLOSE works on a row with every declared key, and on a row with a legacy stray", %{
    scope: scope
  } do
    for legacy? <- [false, true] do
      {:ok, doc} = create(uniq("close"), [declared_entry("ships", true)], scope)

      if legacy?,
        do: install_legacy!(doc, [Map.put(declared_entry("ships", true), "amendment", "x")])

      result = Close.close(doc.id, "w", observed_epoch: 0, lifecycle_status: "done")
      assert match?({:ok, _}, result), "legacy?=#{legacy?}: #{inspect(result)}"
      {:ok, closed} = result

      assert closed.content["lifecycle_status"] == "done"
    end
  end
end
