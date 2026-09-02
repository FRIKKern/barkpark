defmodule Barkpark.Content.PublishDoorLifecycleGuardTest do
  @moduledoc """
  The publish-door lifecycle gate (task-lifecycle-visibility) —
  `Content.Lifecycle.publish_document` refuses a task publish whose draft
  implies an illegal lifecycle transition against the published row, or would
  obliterate the published row's claim state (written only by the sanctioned
  claim/close primitives).

  The load-bearing probe is the RESURRECTION (proven at L1, run probe
  2026-07-22, pre-fix): create → publish → claim + close through the
  SANCTIONED verbs (published row `done`, `claim.worker` set) → birth a
  coexisting fresh open draft (legal at the Writer seam: done→open is the
  reopen edge) → republish it. Pre-gate the published row silently reverted
  done→open and `content.claim` became nil. Every refusal here is
  mutation-proven: collapsing `ensure_task_publish_transition_legal/5` to
  `:ok` (≈ pre-fix main) turns the refusal tests red in the other direction —
  the resurrection succeeds again.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "publish_door_gate_test"

  setup do
    # E3 tag registry: the fixture weighted tags every publish here carries
    # must resolve to PUBLISHED type:tag docs in this dataset.
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

  # PDS-D291: one MET criterion keeps `publish_claim_close!/3` out of the
  # close-artifact gate, which refuses a `done` close of a criteria-less
  # kind:task row whose reason names no PR+sha. This file measures the
  # publish door, not the close reason.
  defp mk_task!(doc_id, scope, content_extra \\ %{}, title \\ nil) do
    content =
      %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
      }
      # Unique description per call — keeps Tasks.Dedup AND the E4 publish
      # dedup wall quiet, so only the lifecycle shapes under test drive
      # outcomes.
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => title || "Gate fixture #{doc_id}",
          "content" => content
        },
        @dataset,
        scope
      )

    doc
  end

  defp published!(doc_id, scope) do
    {:ok, doc} = Content.get_document(doc_id, "task", @dataset, scope)
    doc
  end

  # Publish, then claim + close through the SANCTIONED verbs. Returns the
  # published row: lifecycle done, claim.worker set — the exact state the
  # resurrection probe attacks.
  defp publish_claim_close!(doc_id, scope, worker) do
    {:ok, _pub} = Content.publish_document(doc_id, "task", @dataset, scope)

    assert {:ok, claimed} = Tasks.claim_by_id(doc_id, worker, scope)
    assert claimed.content["lifecycle_status"] == "in_progress"
    epoch = claimed.content["claim"]["epoch"]

    assert {:ok, closed} = Tasks.close(claimed.id, worker, observed_epoch: epoch)
    assert closed.content["lifecycle_status"] == "done"
    assert closed.content["claim"]["worker"] == worker

    closed
  end

  # ── (a) the resurrection probe, REFUSED ──────────────────────────────────

  test "resurrection probe: republishing a stale open draft over a claimed+closed " <>
         "published row is refused — done survives, the claim survives",
       %{scope: scope} do
    mk_task!("pdg-resurrect", scope)
    closed = publish_claim_close!("pdg-resurrect", scope, "pdg-worker")

    # The coexisting fresh open draft — LEGAL at the Writer seam (was resolves
    # published-fallback to "done"; done→open is the reopen edge), so the draft
    # is born exactly as in the pre-fix probe. It carries NO claim.
    mk_task!("pdg-resurrect", scope)
    {:ok, stale} = Content.get_document("drafts.pdg-resurrect", "task", @dataset, scope)
    assert stale.content["lifecycle_status"] == "open"
    refute stale.content["claim"]

    # THE PROBE (measured pre-fix: {:ok, _} + published open + claim nil).
    assert {:error, {:invalid_task_content, %{"claim" => [message]}}} =
             Content.publish_document("pdg-resurrect", "task", @dataset, scope)

    assert message =~ "stale draft"
    assert message =~ "pdg-worker"
    assert message =~ "bp task claim"
    assert message =~ "bp task close"

    # The published row never moved: done stays done, the claim survives…
    pub = published!("pdg-resurrect", scope)
    assert pub.content["lifecycle_status"] == "done"
    assert pub.content["claim"]["worker"] == "pdg-worker"
    assert pub.content["claim"]["epoch"] == closed.content["claim"]["epoch"]
    assert pub.rev == closed.rev

    # …and the refusal is side-effect-free: the stale draft is NOT consumed.
    assert {:ok, _} = Content.get_document("drafts.pdg-resurrect", "task", @dataset, scope)
  end

  # ── (b) forged terminal state through the publish door, REFUSED ──────────

  test "a done-carrying draft (born via :sync, exempt at the Writer seam) cannot flip " <>
         "an open published row to done via publish",
       %{scope: scope} do
    mk_task!("pdg-forge", scope)
    {:ok, _} = Content.publish_document("pdg-forge", "task", @dataset, scope)

    # Sync.Applier's mirror shape births a done draft the Writer gate exempts —
    # the only remaining legal way a done draft can coexist with an open twin.
    assert {:ok, {_tx, _}} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => "pdg-forge",
                     "type" => "task",
                     "set" => %{"lifecycle_status" => "done"}
                   }
                 }
               ],
               @dataset,
               scope ++ [source: :sync]
             )

    # Publishing it from the API source is an open→done at the publish door —
    # refused, naming from, to and the close primitive.
    assert {:error, {:invalid_task_content, %{"lifecycle_status" => [message]}}} =
             Content.publish_document("pdg-forge", "task", @dataset, scope ++ [source: :api])

    assert message =~ "\"open\""
    assert message =~ "\"done\""
    assert message =~ "bp task close"

    assert published!("pdg-forge", scope).content["lifecycle_status"] == "open"
  end

  # ── (c) first publish is a birth — exempt ────────────────────────────────

  test "first publish succeeds: a plain open draft AND the importer's born-done draft",
       %{scope: scope} do
    # Distinct titles keep the E4 publish dedup wall quiet between the two
    # births — only the lifecycle shapes under test drive outcomes.
    mk_task!("pdg-birth-open", scope, %{}, "Fresh work item, open at birth")
    assert {:ok, pub} = Content.publish_document("pdg-birth-open", "task", @dataset, scope)
    assert pub.content["lifecycle_status"] == "open"

    # The importer shape: a legitimately-born-done draft, never published.
    mk_task!(
      "pdg-birth-done",
      scope,
      %{"lifecycle_status" => "done"},
      "Imported ledger seed row, already closed upstream"
    )

    assert {:ok, pub} = Content.publish_document("pdg-birth-done", "task", @dataset, scope)
    assert pub.content["lifecycle_status"] == "done"
  end

  # ── (d) lifecycle-unchanged republish passes untouched ───────────────────

  test "the met-flip republish flow: patch-then-publish with lifecycle unchanged passes, " <>
         "claim preserved verbatim",
       %{scope: scope} do
    mk_task!("pdg-metflip", scope, %{
      "acceptance_criteria" => [%{"criterion" => "it works", "met" => false, "evidence" => ""}]
    })

    {:ok, _} = Content.publish_document("pdg-metflip", "task", @dataset, scope)

    # A live claim on the published row — the claim state a republish must
    # carry through.
    assert {:ok, claimed} = Tasks.claim_by_id("pdg-metflip", "pdg-metflip-worker", scope)
    claim = claimed.content["claim"]

    # The met-flip: patch derives the draft from the CURRENT published content
    # (claim + lifecycle ride along verbatim), then republish collapses it.
    assert {:ok, {_tx, _}} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => "pdg-metflip",
                     "type" => "task",
                     "set" => %{
                       "acceptance_criteria" => [
                         %{"criterion" => "it works", "met" => true, "evidence" => "proof"}
                       ]
                     }
                   }
                 }
               ],
               @dataset,
               scope ++ [source: :api]
             )

    assert {:ok, pub} =
             Content.publish_document("pdg-metflip", "task", @dataset, scope ++ [source: :api])

    assert pub.content["lifecycle_status"] == "in_progress"
    assert pub.content["claim"] == claim
    assert [%{"met" => true}] = pub.content["acceptance_criteria"]
  end

  # ── (e) legal transitions via publish keep working ───────────────────────

  test "a legal transition rides publish: open → blocked via patch-then-publish",
       %{scope: scope} do
    mk_task!("pdg-block", scope)
    {:ok, pub} = Content.publish_document("pdg-block", "task", @dataset, scope)

    # `blocked` is terminal for the mutations close guard, so the patch carries
    # the revision escape (proves the caller read the row) — and because
    # open → blocked is LEGAL in the D7 table both the Writer-seam gate and
    # the publish-door gate let it through.
    assert {:ok, {_tx, _}} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => "pdg-block",
                     "type" => "task",
                     "ifRevisionID" => pub.rev,
                     "set" => %{"lifecycle_status" => "blocked"}
                   }
                 }
               ],
               @dataset,
               scope ++ [source: :api]
             )

    assert {:ok, pub} =
             Content.publish_document("pdg-block", "task", @dataset, scope ++ [source: :api])

    assert pub.content["lifecycle_status"] == "blocked"
  end

  # ── (f) replication is exempt, and the exemption is not vacuous ──────────

  test "the SAME resurrection shape from source :sync passes (replication mirrors " <>
         "upstream verbatim)",
       %{scope: scope} do
    mk_task!("pdg-sync", scope)
    publish_claim_close!("pdg-sync", scope, "pdg-sync-worker")
    mk_task!("pdg-sync", scope)

    # Control (distrust vacuous green): from :api this exact shape is refused —
    # see the resurrection probe above. From :sync it mirrors upstream.
    assert {:ok, pub} =
             Content.publish_document("pdg-sync", "task", @dataset, scope ++ [source: :sync])

    assert pub.content["lifecycle_status"] == "open"
  end

  # ── (g) the :sync exemption does NOT extend to the criteria fence ─────────
  #
  # pds-bl-sync-source-bypasses-publish-door: the `:sync` exemption used to be
  # taken BEFORE any gate ran, so a PULL-applied mirror write could blank a
  # `met: true` flag or a non-empty evidence string with no guard at all. The
  # ruling (recorded at the exemption site in lifecycle.ex): transition + claim
  # checks stay mirror-exempt, the CRITERIA FENCE is source-blind — no
  # legitimate upstream can need to erase a stamped proof, because every write
  # door upstream refuses that erasure too.

  defp publish_proof_bearing!(doc_id, scope) do
    mk_task!(doc_id, scope, %{
      "acceptance_criteria" => [
        %{"criterion" => "it works", "met" => true, "evidence" => "run output pasted"}
      ]
    })

    {:ok, pub} = Content.publish_document(doc_id, "task", @dataset, scope)
    assert [%{"met" => true}] = pub.content["acceptance_criteria"]
    pub
  end

  # The erasing mirror payload: same doc, criteria regressed to unproven.
  defp erasing_result(doc_id) do
    %{
      "_id" => "drafts.#{doc_id}",
      "_publishedId" => doc_id,
      "_draft" => false,
      "_type" => "task",
      "doc_id" => "drafts.#{doc_id}",
      "type" => "task",
      "title" => "Gate fixture #{doc_id}",
      "content" =>
        %{"kind" => "task", "lifecycle_status" => "open"}
        |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
        |> Map.put("acceptance_criteria", [
          %{"criterion" => "it works", "met" => false, "evidence" => ""}
        ])
    }
  end

  test "a sync-sourced publish cannot blank a met:true flag or a non-empty evidence " <>
         "string on a published task row",
       %{scope: scope} do
    publish_proof_bearing!("pdg-sync-erase", scope)

    # The regressing draft arrives the way replication really writes it —
    # through the Writer seam under `source: :sync` (exempt there by design).
    assert {:ok, {_tx, _}} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => "pdg-sync-erase",
                     "type" => "task",
                     "set" => %{
                       "acceptance_criteria" => [
                         %{"criterion" => "it works", "met" => false, "evidence" => ""}
                       ]
                     }
                   }
                 }
               ],
               @dataset,
               scope ++ [source: :sync]
             )

    # The erasure is refused AT THE PUBLISH DOOR even from :sync…
    assert {:error, {:invalid_task_content, %{"acceptance_criteria" => [message]}}} =
             Content.publish_document(
               "pdg-sync-erase",
               "task",
               @dataset,
               scope ++ [source: :sync]
             )

    assert message =~ "clear the `met: true` flag"

    # …and the published proof survives, byte-for-byte.
    pub = published!("pdg-sync-erase", scope)

    assert [%{"met" => true, "evidence" => "run output pasted"}] =
             pub.content["acceptance_criteria"]
  end

  test "APPLIER path: the exact createOrReplace+publish batch Sync.Applier synthesizes " <>
         "is refused when it would erase a stamped proof — and the refusal is :terminal, " <>
         "never a retry wedge",
       %{scope: scope} do
    publish_proof_bearing!("pdg-applier-erase", scope)

    # Applier.apply_upsert/4 verbatim: `[%{"createOrReplace" => result}] ++
    # maybe_publish(result, type)` under `source: :sync` (applier.ex:206-208).
    result = erasing_result("pdg-applier-erase")

    mutations = [
      %{"createOrReplace" => result},
      %{"publish" => %{"id" => "pdg-applier-erase", "type" => "task"}}
    ]

    # `{:invalid_task_content, _}` is exactly the shape the Applier classes
    # :terminal (applier.ex error_class/1), so a refused erasure dead-letters
    # instead of wedging the pull loop — the match below pins that shape.
    assert {:error, {:invalid_task_content, _}} =
             Content.apply_mutations(mutations, @dataset, scope ++ [source: :sync])

    # Nothing about the published row moved.
    pub = published!("pdg-applier-erase", scope)

    assert [%{"met" => true, "evidence" => "run output pasted"}] =
             pub.content["acceptance_criteria"]
  end

  test "PUSHER path: the synthesized publish Sync.Pusher ships is refused by the REMOTE " <>
         "door (source: :api there) when it would erase a stamped proof",
       %{scope: scope} do
    publish_proof_bearing!("pdg-pusher-erase", scope)

    # The real payload builder: primary mutation + conditional publish
    # (pusher.ex payload_mutations/3). On the receiving box these run through
    # MutateController, which stamps `source: :api` — the fence applies there.
    result = erasing_result("pdg-pusher-erase")

    mutations = Barkpark.Sync.Pusher.payload_mutations(result, "task", nil)
    assert Enum.any?(mutations, &match?(%{"publish" => _}, &1))

    assert {:error, {:invalid_task_content, _}} =
             Content.apply_mutations(mutations, @dataset, scope ++ [source: :api])

    pub = published!("pdg-pusher-erase", scope)

    assert [%{"met" => true, "evidence" => "run output pasted"}] =
             pub.content["acceptance_criteria"]
  end

  test "mirror-legit control: a :sync publish that PRESERVES the stamped proof still " <>
         "passes (the fence refuses erasure, not replication)",
       %{scope: scope} do
    publish_proof_bearing!("pdg-sync-keep", scope)

    # Upstream reopened the task but kept its proof — the mirror carries the
    # done→open edge (transition-exempt for :sync) AND the intact criteria.
    assert {:ok, {_tx, _}} =
             Content.apply_mutations(
               [
                 %{
                   "patch" => %{
                     "id" => "pdg-sync-keep",
                     "type" => "task",
                     "set" => %{"lifecycle_status" => "open"}
                   }
                 }
               ],
               @dataset,
               scope ++ [source: :sync]
             )

    assert {:ok, pub} =
             Content.publish_document("pdg-sync-keep", "task", @dataset, scope ++ [source: :sync])

    assert pub.content["lifecycle_status"] == "open"
    assert [%{"met" => true}] = pub.content["acceptance_criteria"]
  end
end
