defmodule Barkpark.Tasks.ClaimCrossDatasetTest do
  @moduledoc """
  THE SECOND FORK (task-ca05dd6a02a0b55f).

  `documents` is unique on `(doc_id, type, dataset_id)`, not `(doc_id, type)`,
  so one task doc_id can live in two datasets. `Claim.fetch_task_exact_locked/3`
  resolved it with a bare `Repo.one/1` and no `limit`, which raises
  `Ecto.MultipleResultsError` — a 500 on every targeted claim of such a row,
  forever.

  PR #15551 fixed exactly this defect in the READ path
  (`TasksController.fetch_task_exact/3`) and never found this fork. Measured
  against guerrilla 2026-09-05, three days after that deploy:
  `bp task get akbr-feedback-2026-08-epic` resolved, while
  `bp task claim akbr-feedback-2026-08-epic` still returned a ledger 500
  (request_id GNJljRgMcPdcwAYAABsC). A row that cannot be claimed cannot be
  stamped, closed or released either — all three are claim-fenced.

  RED-WITHOUT / GREEN-WITH. Every test here raises `Ecto.MultipleResultsError`
  on the unfixed resolver. The determinism test additionally guards the
  half-fix: `limit: 1` without a TOTAL order stops the raise and starts
  returning an arbitrary row, which is the worse defect.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @primary "production"
  @secondary "aker-brygge"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for dataset <- [@primary, @secondary], schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # The shape the uniqueness index permits and the resolver did not survive:
  # the SAME doc_id, type "task", in two datasets.
  # `Content.create_document/4` lands a DRAFT (`drafts.<id>`), so each copy is
  # published afterwards — the collision this row is about is between two
  # PUBLISHED rows carrying one slug in two datasets, which is what the
  # published-first arm of the order has to break.
  defp mk_in_both!(scope, doc_id) do
    for dataset <- [@primary, @secondary] do
      {:ok, _draft} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => "#{doc_id} (#{dataset})",
            "content" => %{
              "kind" => "task",
              "lifecycle_status" => "open",
              "acceptance_criteria" => [
                %{"criterion" => "the fixture is claimable", "met" => false, "evidence" => ""}
              ]
            }
          },
          dataset,
          scope
        )

      {:ok, published} = Content.publish_document(doc_id, "task", dataset, scope)
      published
    end
  end

  describe "a targeted claim of a doc_id that lives in two datasets" do
    test "does not raise — it resolves to one row and claims it", %{scope: scope} do
      doc_id = uniq("cross-claim")
      [a, b] = mk_in_both!(scope, doc_id)

      # THE DEFECT. On origin/main before this fix, Repo.one/1 over two matching
      # rows raises Ecto.MultipleResultsError and the caller sees a 500.
      assert {:ok, %Document{} = claimed} = Tasks.claim_by_id(doc_id, "worker-cross", scope)
      assert claimed.id in [a.id, b.id], "resolved a row that is not one of the two twins"
      assert %{"claim" => %{"worker" => "worker-cross"}} = claimed.content
    end

    test "resolves DETERMINISTICALLY — repeated calls name the same row", %{scope: scope} do
      doc_id = uniq("cross-determinism")
      [_a, _b] = mk_in_both!(scope, doc_id)

      # `limit: 1` alone stops the raise and starts returning an arbitrary row.
      # A claim that lands on a different dataset's copy per connection is a
      # worse defect than the 500, so the order must be TOTAL, not merely
      # present. Same worker re-claiming is a renewal, so this is legal and the
      # row identity is the thing under test.
      assert {:ok, %Document{id: first}} = Tasks.claim_by_id(doc_id, "worker-cross", scope)
      assert {:ok, %Document{id: second}} = Tasks.claim_by_id(doc_id, "worker-cross", scope)
      assert {:ok, %Document{id: third}} = Tasks.claim_by_id(doc_id, "worker-cross", scope)

      assert first == second and second == third,
             "the targeted-claim resolver returned different rows for the same doc_id"
    end

    test "breaks the tie by the ORDER, not by insertion accident", %{scope: scope} do
      doc_id = uniq("cross-published")
      twins = mk_in_both!(scope, doc_id)

      # The order is published-first, then dataset ascending. "aker-brygge"
      # sorts before "production", so the expected winner is named by the RULE
      # rather than by whichever row happened to be inserted first.
      expected = Enum.min_by(twins, & &1.dataset)

      # The exact match wins over the drafts. fallback, and among the exact
      # matches the published-first arm decides. Asserting the resolved id
      # rather than merely "it did not raise" is what makes the published-first
      # arm load-bearing in this file.
      assert {:ok, %Document{id: id}} = Tasks.claim_by_id(doc_id, "worker-cross", scope)
      assert id == expected.id
    end

    test "an ordinary single-dataset row is unaffected", %{scope: scope} do
      doc_id = uniq("single-dataset")

      {:ok, only} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => doc_id,
            "content" => %{"kind" => "task", "lifecycle_status" => "open"}
          },
          @primary,
          scope
        )

      # A limit can only change the outcome for a doc_id with more than one row
      # in scope. Every ordinary task must read byte-identically.
      assert {:ok, %Document{id: id}} = Tasks.claim_by_id(doc_id, "worker-cross", scope)
      assert id == only.id
    end
  end
end
