defmodule Barkpark.Content.DispositionTriggerGateTest do
  @moduledoc """
  PDS wave 24, slice S4 — "hollowness becomes unwritable".

  A parked adjudication with no reopen trigger is a row that SAYS it was
  decided and cannot say when it would be reconsidered. The epic writes ~168 of
  these, and before this slice BOTH doors onto `content.disposition` were open:

    * the RAW door — `Content.apply_mutations` accepted any `disposition` value
      on a `type:task`, because the field had ZERO code writers repo-wide and
      therefore, by construction, no normaliser and no requirement; and
    * the VERB door — `Barkpark.Tasks.stage/3`, the sole sanctioned writer of a
      durable adjudication reason, could write the REASON
      (`content.disposition_reason`) but could never write the VOCABULARY TERM
      it is a reason for.

  This file is the probe that measured both, kept as the regression fence. The
  four PROBE cases below are quoted from the pre-fix measurement; three of them
  RED on pre-fix code, and case (c) pinned an inherited exemption that wave 24
  could not close at its own seam.

  PDS wave 28 closed case (c). It now asserts the REFUSAL its own comment asked
  for — "if this test ever inverts, that is the intended signal that the birth
  fence landed" — against `Writer.ensure_task_born_adjudicated/5`, and a
  companion case proves the fence did not become a ban on filing an
  already-adjudicated row. The rest of the birth/adoption surface lives in
  `Barkpark.Content.TaskBirthFenceTest`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-disposition-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-disposition", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp set_patch(doc_id, set), do: %{"patch" => %{"id" => doc_id, "type" => "task", "set" => set}}

  defp mutate(ops, scope, extra \\ []) do
    Content.apply_mutations(ops, @dataset, Keyword.merge([source: :api] ++ scope, extra))
  end

  defp content_of(doc_id, scope) do
    {:ok, doc} = Content.get_document("drafts." <> doc_id, "task", @dataset, scope)
    doc.content
  end

  defp reload(%Document{id: id}), do: Repo.get!(Document, id)

  # ── PROBE (a) — the raw door ───────────────────────────────────────────────

  describe "PROBE (a): the raw door onto content.disposition" do
    test "a patch setting disposition=parked with NO reopen trigger is REFUSED, naming the verb",
         %{scope: scope} do
      id = uniq("disp-raw-a")
      mk_task!(id, scope)

      # MEASURED PRE-FIX: this returned {:ok, ...} and the row read back
      # `disposition = "parked"` verbatim, with no trigger and no reason. There
      # was no guard, because there was no writer.
      assert {:error, {:invalid_task_content, %{"disposition" => [message]}}} =
               mutate([set_patch(id, %{"disposition" => "parked"})], scope)

      # The refusal TEACHES: it names the sanctioned verb as the retry
      # instruction, exactly as the close/claim siblings do.
      assert message =~ "bp task stage"
      assert message =~ "reopen"

      # And it wrote NOTHING — the whole batch is one transaction.
      refute Map.has_key?(content_of(id, scope), "disposition")
    end

    test "the refusal is scoped to ANY raw disposition write, not just a hollow park",
         %{scope: scope} do
      id = uniq("disp-raw-scope")
      mk_task!(id, scope)

      # SCOPE, STATED. Refusing only `parked`-without-a-trigger would have a
      # near-zero fire rate: under the charter's own recipe a park is usually
      # written as `PARKED`/`parked` alongside a reason, and an `open` or
      # `closed` term written raw is exactly the ungoverned two-case vocabulary
      # this slice exists to normalise. So EVERY raw change of the term is
      # refused and routed to the verb, which owns the triple atomically.
      for term <- ["open", "OPEN", "closed", "CLOSED", "parked", "banana"] do
        result = mutate([set_patch(id, %{"disposition" => term})], scope)

        assert match?({:error, {:invalid_task_content, %{"disposition" => _}}}, result),
               "raw disposition write #{inspect(term)} should be refused, got #{inspect(result)}"
      end
    end

    test "the guard runs on the compound-patch, replace and createOrReplace doors too",
         %{scope: scope} do
      # A patch-only guard leaves `createOrReplace` open, and createOrReplace is
      # the fleet's file-order shape (D53's lesson, re-derived).
      id = uniq("disp-raw-doors")
      %Document{} = doc = mk_task!(id, scope)

      compound = %{
        "patch" => %{
          "id" => id,
          "type" => "task",
          "set" => %{"disposition" => "parked"},
          "setIfMissing" => %{"disposition_owner" => "wave-24"}
        }
      }

      assert {:error, {:invalid_task_content, %{"disposition" => _}}} = mutate([compound], scope)

      replace = %{
        "replace" => %{
          "_id" => id,
          "_type" => "task",
          "title" => id,
          "content" => Map.put(doc.content, "disposition", "parked")
        }
      }

      assert {:error, {:invalid_task_content, %{"disposition" => _}}} = mutate([replace], scope)

      cor = %{
        "createOrReplace" => %{
          "_id" => id,
          "_type" => "task",
          "title" => id,
          "content" => Map.put(doc.content, "disposition", "parked")
        }
      }

      assert {:error, {:invalid_task_content, %{"disposition" => _}}} = mutate([cor], scope)
    end

    test "an unrelated patch on a row that ALREADY carries a disposition passes untouched",
         %{scope: scope} do
      id = uniq("disp-raw-nochange")
      mk_task!(id, scope, %{"disposition" => "parked", "reopen_trigger" => "when X ships"})

      # `now == was` is not a write. Bookkeeping on adjudicated rows (digests,
      # github sync fingerprints, compaction) must not be collateral damage —
      # this is the same shape that made the close guard safe.
      assert {:ok, _} = mutate([set_patch(id, %{"description" => "still parked"})], scope)
      assert content_of(id, scope)["description"] == "still parked"
      assert content_of(id, scope)["disposition"] == "parked"
    end

    test "erasing the reopen_trigger of a parked row is refused (hollowness by two steps)",
         %{scope: scope} do
      id = uniq("disp-raw-hollow")
      mk_task!(id, scope, %{"disposition" => "parked", "reopen_trigger" => "when X ships"})

      unset = %{"patch" => %{"id" => id, "type" => "task", "unset" => ["reopen_trigger"]}}

      assert {:error, {:invalid_task_content, %{"reopen_trigger" => _}}} = mutate([unset], scope)

      assert {:error, {:invalid_task_content, %{"reopen_trigger" => _}}} =
               mutate([set_patch(id, %{"reopen_trigger" => "   "})], scope)

      assert content_of(id, scope)["reopen_trigger"] == "when X ships"
    end

    test "replication is not collateral damage: the same write with source: :sync applies",
         %{scope: scope} do
      id = uniq("disp-raw-sync")
      mk_task!(id, scope)

      assert {:ok, _} =
               mutate([set_patch(id, %{"disposition" => "parked"})], scope, source: :sync)

      assert content_of(id, scope)["disposition"] == "parked"

      # Control on a FRESH row, so the assertion above cannot pass because the
      # guard never fires at all.
      control = uniq("disp-raw-sync-control")
      mk_task!(control, scope)

      assert {:error, {:invalid_task_content, _}} =
               mutate([set_patch(control, %{"disposition" => "parked"})], scope)
    end
  end

  # ── PROBE (b) / (b') — the verb door ───────────────────────────────────────

  describe "PROBE (b): Tasks.stage owns the triple atomically" do
    test "a stage writes disposition, disposition_reason and reopen_trigger in ONE write",
         %{scope: scope} do
      id = uniq("disp-stage-triple")
      doc = mk_task!(id, scope)

      # MEASURED PRE-FIX: after a stage the persisted content keys were exactly
      # ["description","disposition_reason","engagement","kind",
      #  "lifecycle_status","tags"] — there was NO disposition key at all. The
      # sanctioned reason-writer wrote the REASON and could never write the
      # VOCABULARY TERM. That is what settles the two-door judgment: a
      # stage-only guard cannot even SEE a parked disposition.
      assert {:ok, %Document{}} =
               Tasks.stage(doc.id, "considering",
                 disposition: "parked",
                 note: "waiting on the cap lift",
                 reopen_trigger: "when the spend cap lifts 2026-07-31"
               )

      content = reload(doc).content

      assert content["disposition"] == "parked"
      assert content["disposition_reason"] == "waiting on the cap lift"
      assert content["reopen_trigger"] == "when the spend cap lifts 2026-07-31"
      assert content["lifecycle_status"] == "considering"
    end

    test "PROBE (b'): a parked stage with NO reopen trigger is REFUSED", %{scope: scope} do
      id = uniq("disp-stage-hollow")
      doc = mk_task!(id, scope)

      # MEASURED PRE-FIX: this returned {:ok, ...}. The one sanctioned
      # reason-writer had zero content requirements.
      assert {:error, {:missing_reopen_trigger, "parked"}} =
               Tasks.stage(doc.id, "considering",
                 disposition: "parked",
                 note: "parked because the vendor went quiet"
               )

      # It wrote NOTHING — the refusal is inside the advisory-locked
      # transaction, before the CAS update.
      content = reload(doc).content
      assert content["lifecycle_status"] == "open"
      refute Map.has_key?(content, "disposition")
      refute Map.has_key?(content, "disposition_reason")
    end

    test "a blank trigger is no trigger", %{scope: scope} do
      id = uniq("disp-stage-blank")
      doc = mk_task!(id, scope)

      assert {:error, {:missing_reopen_trigger, "parked"}} =
               Tasks.stage(doc.id, "considering", disposition: "parked", reopen_trigger: "   ")
    end

    test "a trigger already ON the row satisfies a re-park", %{scope: scope} do
      id = uniq("disp-stage-carried")
      doc = mk_task!(id, scope, %{"reopen_trigger" => "when the cap lifts"})

      assert {:ok, _} = Tasks.stage(doc.id, "considering", disposition: "parked")
      assert reload(doc).content["disposition"] == "parked"
    end

    test "the vocabulary is normalised and an unknown term is refused", %{scope: scope} do
      id = uniq("disp-stage-vocab")
      doc = mk_task!(id, scope)

      # The census read OPEN 57 / open 47 — a field with no writer has no
      # normaliser by construction. The verb is now that normaliser.
      assert {:ok, _} = Tasks.stage(doc.id, "considering", disposition: "OPEN")
      assert reload(doc).content["disposition"] == "open"

      assert {:error, {:invalid_disposition, "banana"}} =
               Tasks.stage(doc.id, "considering", disposition: "banana")
    end

    test "a stage with NO disposition still succeeds and erases nothing", %{scope: scope} do
      id = uniq("disp-stage-absent")

      doc =
        mk_task!(id, scope, %{"disposition" => "parked", "reopen_trigger" => "when X ships"})

      # BACKWARD COMPATIBILITY, PINNED. The refusal fires on what THIS stage
      # writes, never on what the row already carries — every existing stage
      # call site passes no disposition at all and must stay green.
      assert {:ok, _} = Tasks.stage(doc.id, "considering", note: "still thinking")

      content = reload(doc).content
      assert content["disposition"] == "parked"
      assert content["reopen_trigger"] == "when X ships"
      assert content["disposition_reason"] == "still thinking"
    end

    test "the task.staged event names the keys the adjudication landed on", %{scope: scope} do
      id = uniq("disp-stage-event")
      doc = mk_task!(id, scope)

      {:ok, _} =
        Tasks.stage(doc.id, "considering",
          disposition: "parked",
          note: "vendor quiet",
          reopen_trigger: "vendor replies"
        )

      [ev] =
        Repo.all(
          from(e in Barkpark.Content.MutationEvent,
            where: e.doc_id == ^doc.doc_id and e.mutation == ^Tasks.Stage.event_kind()
          )
        )

      staged = ev.document["staged"]
      assert staged["disposition"] == "parked"
      assert staged["note_key"] == "disposition_reason"
      assert staged["reopen_trigger_key"] == "reopen_trigger"
    end
  end

  # ── PROBE (c) — the inherited exemption, NOW CLOSED (PDS wave 28) ──────────

  describe "PROBE (c): the fresh-create exemption, closed" do
    test "a createOrReplace on a BRAND-NEW id carrying a hollow park is now REFUSED",
         %{scope: scope} do
      id = uniq("disp-fresh")

      # THIS TEST IS THE INVERSION THE PRE-WAVE-28 VERSION ASKED FOR, VERBATIM:
      # "If this test ever inverts, that is the intended signal that the birth
      # fence landed — not a regression." It used to assert {:ok, _} and pin the
      # residual harm named in mutations.ex — a fleet file-order minting rows
      # with createOrReplace could birth a hollow park, and because the term
      # never changed again the update-path fence could never see it.
      #
      # The fence is `Writer.ensure_task_born_adjudicated/5`, a sibling of
      # `Tasks.Dedup.check_new_task/5` in do_create_document's `with` chain —
      # the one place where prev_doc is resolved (so "birth" is expressible) and
      # opts is in hand (so replication keeps its carve-out). It did NOT become
      # "a ban on FILING an already-adjudicated row": the importer shape the old
      # comment defends still works — a COMPLETE adjudication is born (see
      # Barkpark.Content.TaskBirthFenceTest), and only a hollow or
      # off-vocabulary one is refused. What changed is that the birth door now
      # refuses exactly what the sanctioned verb refuses.
      assert {:error, {:invalid_task_content, %{"reopen_trigger" => [message]}}} =
               mutate(
                 [
                   %{
                     "createOrReplace" => %{
                       "_id" => id,
                       "_type" => "task",
                       "title" => id,
                       "content" => %{
                         "kind" => "task",
                         "lifecycle_status" => "open",
                         "disposition" => "parked"
                       }
                     }
                   }
                 ],
                 scope
               )

      assert message =~ "required when a task is BORN"
      assert message =~ "bp task stage"

      # And the refusal is side-effect-free — no half-born row.
      assert {:error, _} = Content.get_document("drafts." <> id, "task", @dataset, scope)
    end

    test "the SAME birth with a reopen trigger is accepted — a fence, not a ban", %{scope: scope} do
      id = uniq("disp-fresh-ok")

      assert {:ok, _} =
               mutate(
                 [
                   %{
                     "createOrReplace" => %{
                       "_id" => id,
                       "_type" => "task",
                       "title" => id,
                       "content" => %{
                         "kind" => "task",
                         "lifecycle_status" => "open",
                         "disposition" => "parked",
                         "reopen_trigger" => "when the importer's upstream row moves"
                       }
                     }
                   }
                 ],
                 scope
               )

      assert content_of(id, scope)["disposition"] == "parked"
      assert content_of(id, scope)["reopen_trigger"] == "when the importer's upstream row moves"
    end
  end
end
