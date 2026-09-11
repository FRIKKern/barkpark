defmodule Barkpark.Tasks.CriteriaContractSubstitutionTest do
  @moduledoc """
  The claim-time acceptance-contract fence (task-11390a3b900c8a09, c2) —
  `Barkpark.Tasks.CriteriaContract.check_substitution/2`, wired into the
  publish seam (`Content.Lifecycle.gate_task_publish/2`), which is where BOTH
  write doors converge: a bare-id `patch` on a `type:task` is published-first
  and LANDS through `Content.Mutations.land_patch/5` → `publish_document/4`,
  and the doc patch-then-publish idiom calls the same function.

  THE PROBE is the 2026-07-10 incident shape, replayed: a row under a LIVE
  claim, published with four criteria, is republished with a foreign
  four-criterion array — every criterion text replaced, and the foreign rows
  carrying met/evidence of their own. Pre-fix that publish is ACCEPTED with no
  warning, because `criteria_fence/2` matches a published criterion by text
  and then falls back to the POSITIONAL slot, where the foreign row regresses
  neither `met` nor `evidence`. `refuses_a_wholesale_substitution` is the RED
  arm: collapse `CriteriaContract.check_substitution/2` to `:ok` (≈ pre-fix
  main) and it fails, and `positional_fallback_alone_lets_the_incident_through`
  documents WHY the neighbouring fence could not see it.

  The passing arms are the point of the narrow predicate: adding a criterion,
  rewording ONE of several, reordering, and stamping evidence are legitimate
  edits under a claim and must all still land.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.CriteriaContract

  @dataset "criteria_contract_test"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

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

  # ── fixtures ─────────────────────────────────────────────────────────────

  # The victim's own contract — `gp-w5-epic-close`'s shape: four criteria, the
  # writer's own evidence on two of them.
  defp own_criteria do
    [
      %{"criterion" => "own c0: the epic close paper is published", "met" => false},
      %{
        "criterion" => "own c1: every wave task is closed on its claim epoch",
        "met" => true,
        "evidence" => "closed 14/14 on epoch 1"
      },
      %{
        "criterion" => "own c2: the debrief links each wave paper",
        "met" => true,
        "evidence" => "6 wave papers linked"
      },
      %{"criterion" => "own c3: the charter records the seal", "met" => false}
    ]
  end

  # The FOREIGN contract — `era-w8-zero-tax-harness`'s shape. Same length, and
  # deliberately proof-bearing at the indexes the victim's own proofs occupy,
  # so every positional counterpart regresses NOTHING.
  defp foreign_criteria do
    [
      %{
        "criterion" => "foreign c0: the auth test suite runs green on main",
        "met" => true,
        "evidence" => "mix test test/auth — 41 tests, 0 failures"
      },
      %{
        "criterion" => "foreign c1: the zero-tax harness reports a baseline",
        "met" => true,
        "evidence" => "baseline 0.0%"
      },
      %{
        "criterion" => "foreign c2: the harness is wired into CI",
        "met" => true,
        "evidence" => "workflow added"
      },
      %{
        "criterion" => "foreign c3: a mainline merge sha proves it",
        "met" => true,
        "evidence" => "sha deadbeef"
      }
    ]
  end

  defp mk_published_task!(doc_id, scope, criteria) do
    content =
      %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "description" => "fixture #{doc_id}",
        "acceptance_criteria" => criteria
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => "Contract fixture #{doc_id}", "content" => content},
        @dataset,
        scope
      )

    {:ok, pub} = Content.publish_document(doc_id, "task", @dataset, scope)
    pub
  end

  # Claim through the SANCTIONED verb, so `claim.work_field_digests` is stamped
  # by `Tasks.Claim` exactly as production stamps it — never hand-written here.
  defp claim!(doc_id, worker, scope) do
    {:ok, claimed} = Tasks.claim_by_id(doc_id, worker, scope)

    assert is_binary(
             get_in(claimed.content, ["claim", "work_field_digests", "acceptance_criteria"])
           ),
           "PRECONDITION: the sanctioned claim must stamp a criteria field digest — " <>
             "without it this whole file measures nothing"

    claimed
  end

  defp stage_draft!(doc_id, changes, scope) do
    {:ok, pub} = Content.get_document(doc_id, "task", @dataset, scope)

    {:ok, draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => pub.title,
          "content" => Map.merge(pub.content, changes)
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    draft
  end

  defp publish(doc_id, scope), do: Content.publish_document(doc_id, "task", @dataset, scope)

  defp published_texts!(doc_id, scope) do
    {:ok, doc} = Content.get_document(doc_id, "task", @dataset, scope)
    Enum.map(doc.content["acceptance_criteria"], & &1["criterion"])
  end

  # ── the refusal ──────────────────────────────────────────────────────────

  describe "a wholesale substitution under a live claim" do
    test "is refused at the publish seam, and the row is untouched", %{scope: scope} do
      id = "cc-incident-replay"
      mk_published_task!(id, scope, own_criteria())
      claim!(id, "gp-w5-builder", scope)

      before = published_texts!(id, scope)

      stage_draft!(id, %{"acceptance_criteria" => foreign_criteria()}, scope)

      assert {:error, {:invalid_task_content, errors}} = publish(id, scope)

      assert [message] = errors["acceptance_criteria"]
      assert message =~ "WHOLESALE"
      assert message =~ "live claim"
      assert message =~ "gp-w5-builder"

      # BEFORE ANY WRITE: the published row still carries its own contract.
      assert published_texts!(id, scope) == before

      # AND NO EPOCH CONSUMED: the claim is byte-identical.
      {:ok, doc} = Content.get_document(id, "task", @dataset, scope)
      assert doc.content["claim"]["epoch"] == 1
      assert doc.content["claim"]["worker"] == "gp-w5-builder"
    end

    test "the neighbouring criteria_fence sees NOTHING in this payload", %{scope: scope} do
      # WHY the guard is needed rather than a widening of `criteria_fence/2`:
      # on this exact pair the fence reports no regression at all, because each
      # proof-bearing published row finds a positional counterpart that keeps
      # `met: true` and a non-blank `evidence`. Asserted through the public
      # predicate: swap the CONTRACT check off and the pair is accepted.
      id = "cc-fence-blind"
      mk_published_task!(id, scope, own_criteria())
      claim!(id, "gp-w5-builder", scope)

      {:ok, pub} = Content.get_document(id, "task", @dataset, scope)
      substituted = Map.put(pub.content, "acceptance_criteria", foreign_criteria())

      # The contract gate refuses it …
      assert {:error, {:invalid_task_content, _}} =
               CriteriaContract.check_substitution(pub.content, substituted)

      # … while every published proof still finds a met, evidenced counterpart
      # at its own index — which is all `criteria_fence/2` ever asks.
      for {pub_row, index} <- Enum.with_index(pub.content["acceptance_criteria"]),
          pub_row["met"] == true do
        counterpart = Enum.at(foreign_criteria(), index)
        assert counterpart["met"] == true
        assert counterpart["evidence"] not in [nil, ""]
      end
    end
  end

  # ── the legitimate edits that must keep landing ──────────────────────────

  describe "legitimate edits under a live claim still publish" do
    test "adding a criterion", %{scope: scope} do
      id = "cc-add"
      mk_published_task!(id, scope, own_criteria())
      claim!(id, "w", scope)

      added = own_criteria() ++ [%{"criterion" => "own c4: a follow-up", "met" => false}]
      stage_draft!(id, %{"acceptance_criteria" => added}, scope)

      assert {:ok, _} = publish(id, scope)
      assert length(published_texts!(id, scope)) == 5
    end

    test "rewording ONE of four", %{scope: scope} do
      id = "cc-reword"
      mk_published_task!(id, scope, own_criteria())
      claim!(id, "w", scope)

      reworded =
        List.replace_at(own_criteria(), 0, %{"criterion" => "own c0, reworded", "met" => false})

      stage_draft!(id, %{"acceptance_criteria" => reworded}, scope)

      assert {:ok, _} = publish(id, scope)
      assert hd(published_texts!(id, scope)) == "own c0, reworded"
    end

    test "reordering", %{scope: scope} do
      id = "cc-reorder"
      mk_published_task!(id, scope, own_criteria())
      claim!(id, "w", scope)

      stage_draft!(id, %{"acceptance_criteria" => Enum.reverse(own_criteria())}, scope)

      assert {:ok, _} = publish(id, scope)

      assert published_texts!(id, scope) ==
               Enum.reverse(Enum.map(own_criteria(), & &1["criterion"]))
    end

    test "stamping evidence onto an unmet criterion", %{scope: scope} do
      id = "cc-stamp"
      mk_published_task!(id, scope, own_criteria())
      claim!(id, "w", scope)

      stamped =
        List.replace_at(own_criteria(), 0, %{
          "criterion" => "own c0: the epic close paper is published",
          "met" => true,
          "evidence" => "/papers/gp-epic-close"
        })

      stage_draft!(id, %{"acceptance_criteria" => stamped}, scope)

      assert {:ok, _} = publish(id, scope)
      assert published_texts!(id, scope) == Enum.map(own_criteria(), & &1["criterion"])
    end
  end

  # ── the scope boundaries, asserted on the predicate directly ─────────────

  describe "the predicate's exemptions" do
    setup do
      digest =
        Barkpark.Tasks.WorkDigest.field_digests(nil, %{"acceptance_criteria" => own_criteria()})
        |> Map.fetch!("acceptance_criteria")

      claimed = %{
        "acceptance_criteria" => own_criteria(),
        "claim" => %{
          "worker" => "w",
          "epoch" => 1,
          "work_field_digests" => %{"acceptance_criteria" => digest}
        }
      }

      %{claimed: claimed, foreign: %{"acceptance_criteria" => foreign_criteria()}}
    end

    test "CONTROL: the fully-armed pair refuses", %{claimed: claimed, foreign: foreign} do
      assert {:error, {:invalid_task_content, _}} =
               CriteriaContract.check_substitution(claimed, foreign)
    end

    test "no claim at all is exempt", %{claimed: claimed, foreign: foreign} do
      unclaimed = Map.delete(claimed, "claim")
      assert :ok = CriteriaContract.check_substitution(unclaimed, foreign)
    end

    test "a CLOSED claim is exempt", %{claimed: claimed, foreign: foreign} do
      closed = put_in(claimed, ["claim", "closed_at"], "2026-09-11T00:00:00Z")
      assert :ok = CriteriaContract.check_substitution(closed, foreign)
    end

    test "a legacy claim carrying no criteria digest is exempt", %{
      claimed: claimed,
      foreign: foreign
    } do
      legacy = update_in(claimed["claim"], &Map.delete(&1, "work_field_digests"))
      assert :ok = CriteriaContract.check_substitution(legacy, foreign)
    end

    test "criteria that already drifted since the claim are exempt", %{
      claimed: claimed,
      foreign: foreign
    } do
      drifted =
        put_in(
          claimed,
          ["claim", "work_field_digests", "acceptance_criteria"],
          "0" <> String.duplicate("f", 15)
        )

      assert :ok = CriteriaContract.check_substitution(drifted, foreign)
    end

    test "a SINGLE-criterion row is exempt — substitution and reword are one event" do
      one = [%{"criterion" => "the only criterion", "met" => false}]

      digest =
        Barkpark.Tasks.WorkDigest.field_digests(nil, %{"acceptance_criteria" => one})
        |> Map.fetch!("acceptance_criteria")

      published = %{
        "acceptance_criteria" => one,
        "claim" => %{
          "worker" => "w",
          "epoch" => 1,
          "work_field_digests" => %{"acceptance_criteria" => digest}
        }
      }

      incoming = %{"acceptance_criteria" => [%{"criterion" => "a total rewrite", "met" => false}]}

      assert :ok = CriteriaContract.check_substitution(published, incoming)
    end

    test "an EMPTIED list is left to the fences that own deletion", %{claimed: claimed} do
      assert :ok = CriteriaContract.check_substitution(claimed, %{"acceptance_criteria" => []})
    end
  end
end
