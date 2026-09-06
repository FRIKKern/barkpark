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
  on the unfixed resolver.

  ## SUPERSEDED IN PART (task-49eef068420df918, THE ONE RULE)

  This file used to assert that the tie was broken by `dataset` ASC and that
  repeated calls named the SAME row. That order was the defect one level up: it
  made the claim land on the alphabetically-first dataset's copy — for the eleven
  live twins, the EMPTY one — silently. `Barkpark.Tasks.TwinResolver` now REFUSES
  an unnamed cross-dataset tie instead of picking, so the three twin tests below
  assert the refusal. The property this file was filed for is intact and still
  asserted: no `Ecto.MultipleResultsError`, ever — a typed 409 is not a 500.
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
  # TWO DRAFTS, NOT TWO PUBLISHED ROWS, and that is deliberate.
  # `Content.create_document/4` lands a DRAFT (`drafts.<id>`), and publishing
  # from a test would have to satisfy the authoring wall's label spine — a 20+
  # character description AND 1-12 weighted tags that must already exist as
  # registered `type:tag` documents, which a test database does not carry.
  #
  # The collision does not need publishing to exist. `documents` is unique on
  # (doc_id, type, dataset_id), so ONE `drafts.<id>` slug in TWO datasets is
  # already two matching rows, and the targeted-claim resolver reaches them
  # through its `drafts.` fallback. That is the raise this row is about.
  #
  # WHAT THIS FILE THEREFORE DOES NOT COVER: the published-first arm of the
  # order. That arm is inherited verbatim from `fetch_task_exact/3`, where
  # #15551 already covers it; here the tie falls through to `dataset` ASC,
  # which is what the determinism and ordering tests below assert.
  # `dataset_twin_intended` on the SECOND create: `Tasks.DatasetTwinFence` now
  # refuses exactly this birth (that is its own test), and a fixture that must
  # BUILD the shape under measurement is the stated-intent escape's reason to
  # exist. Without it this file could no longer construct a twin at all.
  defp mk_in_both!(scope, doc_id) do
    for dataset <- [@primary, @secondary] do
      {:ok, draft} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => "#{doc_id} (#{dataset})",
            "content" => %{
              "kind" => "task",
              "lifecycle_status" => "open",
              "dataset_twin_intended" => true,
              "acceptance_criteria" => [
                %{"criterion" => "the fixture is claimable", "met" => false, "evidence" => ""}
              ]
            }
          },
          dataset,
          scope
        )

      draft
    end
  end

  describe "a targeted claim of a doc_id that lives in two datasets" do
    test "does not raise — it REFUSES, and names every dataset that holds the id",
         %{scope: scope} do
      doc_id = uniq("cross-claim")
      [_a, _b] = mk_in_both!(scope, doc_id)

      # THE ORIGINAL DEFECT, still pinned: on origin/main before #15551's sibling
      # fix, `Repo.one/1` over two matching rows raised Ecto.MultipleResultsError
      # and the caller saw a 500.
      e =
        assert_raise Barkpark.Tasks.AmbiguousTwinError, fn ->
          Tasks.claim_by_id(doc_id, "worker-cross", scope)
        end

      assert e.datasets == Enum.sort([@primary, @secondary])
      assert Plug.Exception.status(e) == 409
    end

    test "the refusal is STABLE — the same call refuses the same way every time",
         %{scope: scope} do
      doc_id = uniq("cross-determinism")
      [_a, _b] = mk_in_both!(scope, doc_id)

      for _ <- 1..3 do
        e =
          assert_raise Barkpark.Tasks.AmbiguousTwinError, fn ->
            Tasks.claim_by_id(doc_id, "worker-cross", scope)
          end

        assert e.datasets == Enum.sort([@primary, @secondary])
      end
    end

    test "NEITHER copy is claimed — no dataset order decides a write", %{scope: scope} do
      doc_id = uniq("cross-published")
      twins = mk_in_both!(scope, doc_id)

      # The old order claimed @secondary here ("aker-brygge" sorts first) while
      # the fixture inserts @primary FIRST — insertion order and dataset order
      # disagree on purpose. The rule's answer is that neither is written.
      assert_raise Barkpark.Tasks.AmbiguousTwinError, fn ->
        Tasks.claim_by_id(doc_id, "worker-cross", scope)
      end

      for twin <- twins do
        after_refusal = Repo.get!(Document, twin.id)
        assert after_refusal.content["lifecycle_status"] == "open"
        refute after_refusal.content["claim"]
      end
    end

    test "an ordinary single-dataset row is unaffected", %{scope: scope} do
      doc_id = uniq("single-dataset")

      {:ok, only} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => doc_id,
            "content" => %{
              "kind" => "task",
              "acceptance_criteria" => [
                %{
                  "criterion" => "the fixture states its bar",
                  "met" => true,
                  "evidence" => "fixture"
                }
              ],
              "lifecycle_status" => "open"
            }
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
