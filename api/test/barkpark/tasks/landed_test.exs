defmodule Barkpark.Tasks.LandedTest do
  @moduledoc """
  Unit tests for `Barkpark.Tasks.Landed` — the NON-HOLDER landing mark
  (`bp task landed` / `POST /v1/tasks/:doc_id/landed`).

  Covers, one describe per behaviour:

    1. The digest: a fresh row gets `content.landed` with commits/prs/notes;
       a SECOND call ACCUMULATES (union, deduped) rather than clobbering; and
       a pre-existing close-shaped digest (`prs`/`files`) survives a landing
       mark that adds a commit — the two write the same key by ONE rule.
    2. NO HOLDER, NO EPOCH — the whole point. A task claimed by someone ELSE,
       at any epoch, still takes a landing mark, and the claim is byte-identical
       afterwards. This is the case `Tasks.Stamp` refuses 409 not_holder.
    3. The criterion flip: a merge-shaped criterion flips met=true with the
       note as evidence; the OTHER criteria are untouched.
    4. THE THREE REFUSALS, each of which is the guard's whole reason to exist:
         * a criterion that is not merge-shaped        → :criterion_not_merge_shaped
         * a criterion already met                     → :criterion_already_met
         * an index past the end of the list           → :criteria_index_out_of_range
       Each also asserts NOTHING WAS WRITTEN — the digest and the criteria are
       byte-identical after the refusal, because the flip and the digest ride
       one CAS.
    5. Merge-shape vocabulary: `merge_gate: true` (structural), the MERGE-GATED
       wording (`Criteria.merge_gated?/1`), and each of the three landing
       spellings the request named. Plus the VETO: an explicit
       `merge_gate: false` refuses even when the prose matches — here the
       predicate gates a PERMIT, so the author's declaration wins.
    6. Shape refusals before any DB work: nothing to record; a criterion with
       no note to use as evidence.
    7. The event: exactly one `task.landed` mutation_event, carrying the
       caller token id and the landed_mark payload.
  """

  use Barkpark.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}

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

  defp task!(scope, content_extra \\ %{}) do
    doc_id = uniq("landed")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" =>
            Map.merge(
              %{
                "kind" => "task",
                "acceptance_criteria" => [
                  %{
                    "criterion" => "the fixture states its bar",
                    "met" => true,
                    "evidence" => "fixture"
                  }
                ],
                "lifecycle_status" => "open"
              },
              content_extra
            )
        },
        @dataset,
        scope
      )

    doc
  end

  defp reload(doc), do: Repo.get!(Document, doc.id)

  defp landed_events(doc_id) do
    Repo.all(
      from(e in MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == "task.landed",
        order_by: e.id
      )
    )
  end

  defp criteria(doc), do: reload(doc).content["acceptance_criteria"]

  # A criterion that is merge-shaped by the request's own wording arm.
  defp merge_criterion(text \\ "LEAD-OWNED: PR merged to main"),
    do: %{"criterion" => text, "met" => false, "evidence" => ""}

  defp plain_criterion(text \\ "the gate is green"),
    do: %{"criterion" => text, "met" => false, "evidence" => ""}

  # ── 1. The digest ────────────────────────────────────────────────────────

  describe "content.landed — the union digest" do
    test "a fresh row records commits/prs/notes", %{scope: scope} do
      doc = task!(scope)

      assert {:ok, _} =
               Tasks.record_landing(doc.id,
                 commit: "a1b2c3d",
                 pr: "14993",
                 note: "merged to main"
               )

      assert reload(doc).content["landed"] == %{
               "commits" => ["a1b2c3d"],
               "prs" => ["14993"],
               "notes" => ["merged to main"]
             }
    end

    test "a second call ACCUMULATES rather than clobbering, and dedupes", %{scope: scope} do
      doc = task!(scope)

      assert {:ok, _} = Tasks.record_landing(doc.id, commit: "aaa", pr: "1")
      assert {:ok, _} = Tasks.record_landing(doc.id, commit: "bbb", pr: "1", note: "second")

      assert reload(doc).content["landed"] == %{
               # union, in arrival order
               "commits" => ["aaa", "bbb"],
               # "1" arrived twice and appears once
               "prs" => ["1"],
               "notes" => ["second"]
             }
    end

    test "a pre-existing close-shaped digest survives — ONE merge rule, not two",
         %{scope: scope} do
      doc = task!(scope, %{"landed" => %{"prs" => ["100"], "files" => ["api/lib/x.ex"]}})

      assert {:ok, _} = Tasks.record_landing(doc.id, commit: "deadbee")

      landed = reload(doc).content["landed"]
      assert landed["files"] == ["api/lib/x.ex"], "a landing mark must not erase a close's files"
      assert landed["prs"] == ["100"]
      assert landed["commits"] == ["deadbee"]
    end

    test "blank strings are absent, not entries", %{scope: scope} do
      doc = task!(scope)

      assert {:ok, _} = Tasks.record_landing(doc.id, commit: "   ", pr: "", note: "only this")
      assert reload(doc).content["landed"] == %{"notes" => ["only this"]}
    end
  end

  # ── 2. No holder, no epoch ───────────────────────────────────────────────

  describe "the non-holder fence — what is deliberately ABSENT" do
    test "a task claimed by SOMEONE ELSE takes a landing mark, claim untouched",
         %{scope: scope} do
      doc = task!(scope)
      {:ok, claimed} = Tasks.claim_by_id(doc.doc_id, "some-other-worker", scope)
      claim_before = claimed.content["claim"]

      # The control: stamp — the verb CI could not use — refuses this exact row.
      assert {:error, :not_holder} =
               Tasks.stamp(doc.id, "ci",
                 observed_epoch: claim_before["epoch"],
                 criterion: 0,
                 outcome: {:met, "x"}
               )

      assert {:ok, _} = Tasks.record_landing(doc.id, commit: "a1b2c3d", note: "merged to main")

      after_doc = reload(doc)
      assert after_doc.content["landed"]["commits"] == ["a1b2c3d"]

      assert after_doc.content["claim"] == claim_before,
             "a landing mark must not touch the claim"

      assert after_doc.content["lifecycle_status"] == "in_progress",
             "a landing mark must not touch lifecycle_status"
    end
  end

  # ── 3. The criterion flip ────────────────────────────────────────────────

  describe "the criterion flip" do
    test "a merge-shaped criterion flips met=true with the note as evidence", %{scope: scope} do
      doc =
        task!(scope, %{
          "acceptance_criteria" => [plain_criterion(), merge_criterion()]
        })

      assert {:ok, _} =
               Tasks.record_landing(doc.id,
                 commit: "a1b2c3d",
                 note: "PR #14993 merged to main as a1b2c3d",
                 criterion: 1
               )

      [first, second] = criteria(doc)

      assert second["met"] == true
      assert second["evidence"] == "PR #14993 merged to main as a1b2c3d"
      assert second["criterion"] == "LEAD-OWNED: PR merged to main", "the text is never rewritten"

      assert first == plain_criterion(), "the OTHER criteria are byte-identical"
      assert reload(doc).content["landed"]["commits"] == ["a1b2c3d"]
    end
  end

  # ── 4. The three refusals ────────────────────────────────────────────────

  describe "refusals — each one is a guard, and each writes NOTHING" do
    test "a criterion that is not merge-shaped is refused", %{scope: scope} do
      doc = task!(scope, %{"acceptance_criteria" => [plain_criterion()]})
      before = reload(doc).content

      assert {:error, :criterion_not_merge_shaped} =
               Tasks.record_landing(doc.id, commit: "aaa", note: "merged", criterion: 0)

      assert reload(doc).content == before,
             "the flip and the digest ride ONE CAS — a refused flip records no landing either"
    end

    test "an ALREADY-MET criterion is never overwritten", %{scope: scope} do
      met = %{
        "criterion" => "LEAD-OWNED (merge-gated): PR merged to main",
        "met" => true,
        "evidence" => "the original proof"
      }

      doc = task!(scope, %{"acceptance_criteria" => [met]})
      before = reload(doc).content

      assert {:error, :criterion_already_met} =
               Tasks.record_landing(doc.id, commit: "aaa", note: "a merge notice", criterion: 0)

      assert reload(doc).content == before
      assert hd(criteria(doc))["evidence"] == "the original proof"
    end

    test "an index past the end of the list is refused", %{scope: scope} do
      doc = task!(scope, %{"acceptance_criteria" => [merge_criterion()]})
      before = reload(doc).content

      assert {:error, :criteria_index_out_of_range} =
               Tasks.record_landing(doc.id, commit: "aaa", note: "merged", criterion: 7)

      assert reload(doc).content == before
    end

    test "a task with no criteria at all refuses any index", %{scope: scope} do
      # EXPLICITLY criteria-less: the default fixture now states a bar, because
      # the claim-time gate (task-9554c64bf51a0f81) refuses a criteria-less work
      # row and a fixture that omits them is a row nobody can claim. This test is
      # about the landing verb's index bounds on a row that HAS none, so it opts
      # back out by name rather than relying on the default.
      doc = task!(scope, %{"acceptance_criteria" => []})

      assert {:error, :criteria_index_out_of_range} =
               Tasks.record_landing(doc.id, note: "merged to main", criterion: 0)

      refute Map.has_key?(reload(doc).content, "landed")
    end

    test "a merge-shaped criterion with NO stored text cannot be flipped by anyone",
         %{scope: scope} do
      # merge_gate: true makes it merge-shaped structurally, but merge_criteria's
      # D56 rule refuses a met-flip with no text to CAS against — and this verb
      # rides that rule rather than routing around it.
      doc =
        task!(scope, %{
          "acceptance_criteria" => [%{"merge_gate" => true, "met" => false}]
        })

      assert {:error, :criterion_text_required} =
               Tasks.record_landing(doc.id, note: "merged to main", criterion: 0)
    end

    test "an unknown task is :not_found", %{scope: _scope} do
      assert {:error, :not_found} =
               Tasks.record_landing(Ecto.UUID.generate(), note: "merged to main")
    end
  end

  # ── 5. The merge-shape vocabulary ────────────────────────────────────────

  describe "merge_shaped? — the permit predicate" do
    for {label, text} <- [
          {"pr merged", "the PR merged and the gate is green"},
          {"merged to main", "LEAD: merged to main"},
          {"merged into main", "closed when merged into main"},
          {"MERGE-GATED marker", "MERGE-GATED: the lead seals this"},
          {"MERGE GATE marker", "MERGE GATE — lead closes"}
        ] do
      test "the wording arm accepts #{label}", %{scope: scope} do
        doc = task!(scope, %{"acceptance_criteria" => [plain_criterion(unquote(text))]})

        assert {:ok, _} =
                 Tasks.record_landing(doc.id, note: "landed", criterion: 0)

        assert hd(criteria(doc))["met"] == true
      end
    end

    test "the structural flag accepts a row whose prose says nothing", %{scope: scope} do
      doc =
        task!(scope, %{
          "acceptance_criteria" => [
            %{"criterion" => "ship it", "met" => false, "merge_gate" => true}
          ]
        })

      assert {:ok, _} = Tasks.record_landing(doc.id, note: "landed", criterion: 0)
      assert hd(criteria(doc))["met"] == true
    end

    test "an explicit merge_gate:false VETOES a matching prose row", %{scope: scope} do
      # The permit/refusal asymmetry: `Tasks.Stamp` reads the same row through
      # the deliberately-WIDE Criteria.merge_gated?/1 because there a false
      # positive is a loud, overridable refusal. Here it would be a SILENT
      # met=true, so the author's own `false` wins over the wording.
      doc =
        task!(scope, %{
          "acceptance_criteria" => [
            %{
              "criterion" => "explain why MERGE-GATED rows exist; PR merged is not the point",
              "met" => false,
              "merge_gate" => false
            }
          ]
        })

      assert {:error, :criterion_not_merge_shaped} =
               Tasks.record_landing(doc.id, note: "landed", criterion: 0)
    end
  end

  # ── 5b. Merge-SHAPED is not merge-DISCHARGED (task-48ff3f84e68aecbb) ──────
  #
  # `merge_gate: true` means "THE LEAD closes this row, not the builder" — the
  # same sentence `Tasks.Stamp` and `Tasks.Close.autostamp_merge_gate/6` read
  # it as. It never meant "a merge discharges this", and leads set it on rows
  # demanding far more than a merge. Until `merge_discharges?/1` existed, this
  # verb read the one boolean for both questions and flipped criteria a merge
  # could not have satisfied — claimlessly, with the caller's own `--note` left
  # behind as the evidence.
  #
  # BOTH DIRECTIONS LIVE IN THIS DESCRIBE ON PURPOSE. A permit that refuses
  # everything is the same defect with the sign flipped, so every refusal test
  # here is paired with a flip that must still succeed. The five parametrised
  # wording tests above are the wider positive control: over-broadening the
  # demonstration vocabulary reds them by name.
  describe "merge_discharges? — the permit's second question" do
    # The row this defect was found from: task-6d80c6cc7d97b1d1 criterion 6.
    # Merge-shaped TWICE (the flag and the MERGE-GATED marker), and a merge
    # cannot produce one syllable of what it asks for.
    @live_example "MERGE-GATED -- THE LEAD CLOSES THIS, AND ONLY ON THE DEMO. " <>
                    "An editor completes the full round trip -- open, edit rich text, " <>
                    "set alt text, preview, publish -- in a NON-DEFAULT workspace, " <>
                    "WITHOUT touching the API, with the run shown."

    test "the live example is REFUSED, and nothing is written", %{scope: scope} do
      doc =
        task!(scope, %{
          "acceptance_criteria" => [
            %{"criterion" => @live_example, "met" => false, "merge_gate" => true}
          ]
        })

      assert {:error, :criterion_demands_demonstration} =
               Tasks.record_landing(doc.id,
                 note: "PROBE: a landing notice claiming a live demo happened. It did not.",
                 pr: "99999",
                 criterion: 0
               )

      # The flip and the landing sentence ride ONE CAS, so a refused flip must
      # leave the row completely untouched — not merely unflipped.
      after_row = hd(criteria(doc))
      assert after_row["met"] == false
      assert after_row["evidence"] in [nil, ""]
      refute Map.has_key?(reload(doc).content, "landed")
      assert landed_events(doc.doc_id) == []
    end

    for {label, text} <- [
          {"a demo", "the lead closes this ON THE DEMO"},
          {"the run shown", "MERGE-GATED: lead seals it, with the run shown"},
          {"a screenshot", "PR merged to main and a screenshot of the result"},
          {"an operator", "merged to main, then an operator confirms the switch"},
          {"by hand", "MERGE GATE — the lead reruns it by hand first"},
          {"production", "merged into main and read back in production"}
        ] do
      test "a merge-shaped row demanding #{label} is refused", %{scope: scope} do
        doc =
          task!(scope, %{
            "acceptance_criteria" => [
              %{"criterion" => unquote(text), "met" => false, "merge_gate" => true}
            ]
          })

        assert {:error, :criterion_demands_demonstration} =
                 Tasks.record_landing(doc.id, note: "landed", criterion: 0)

        assert hd(criteria(doc))["met"] == false
      end
    end

    # ── and the other direction ──
    test "a genuinely merge-discharged criterion is STILL PERMITTED", %{scope: scope} do
      doc =
        task!(scope, %{
          "acceptance_criteria" => [
            %{
              "criterion" =>
                "MERGE-GATED: the lead seals this when the PR is merged to main with CI green.",
              "met" => false,
              "merge_gate" => true
            }
          ]
        })

      assert {:ok, _} =
               Tasks.record_landing(doc.id, note: "#15001 merged", pr: "15001", criterion: 0)

      after_row = hd(criteria(doc))
      assert after_row["met"] == true
      assert after_row["evidence"] == "#15001 merged"
    end

    test "merge_discharges:true clears a false veto permanently", %{scope: scope} do
      # The escape hatch that keeps the veto honest: it is allowed to be a
      # little eager BECAUSE the author can clear it in one key, per row, for
      # good. Without this door an eager phrase would be a permanent wall.
      doc =
        task!(scope, %{
          "acceptance_criteria" => [
            %{
              "criterion" => "merged to main — this is the demo branch's gate",
              "met" => false,
              "merge_gate" => true,
              "merge_discharges" => true
            }
          ]
        })

      assert {:ok, _} = Tasks.record_landing(doc.id, note: "landed", criterion: 0)
      assert hd(criteria(doc))["met"] == true
    end

    test "merge_discharges:false vetoes while merge_gate:true is KEPT", %{scope: scope} do
      # THE SHAPE THE LIVE EXAMPLE WANTED AND COULD NOT SPELL. Today the only
      # way to stop a landing notice on that row is `merge_gate: false` — which
      # also tells `Tasks.Stamp` to stop refusing the builder and tells
      # `Close.autostamp_merge_gate/6` the row is not a gate. Two signals means
      # the lead keeps every one of those and still bars the landing notice.
      doc =
        task!(scope, %{
          "acceptance_criteria" => [
            %{
              "criterion" => "the lead seals this when the PR merged",
              "met" => false,
              "merge_gate" => true,
              "merge_discharges" => false
            }
          ]
        })

      assert {:error, :criterion_demands_demonstration} =
               Tasks.record_landing(doc.id, note: "landed", criterion: 0)

      # The row is still a merge gate for every OTHER reader — that is the
      # whole point of splitting the signal, and the assertion that proves the
      # split is real rather than a rename.
      assert Barkpark.Tasks.Criteria.merge_gated?(hd(criteria(doc))) == true
    end

    test "the veto only ever SUBTRACTS — a non-merge row keeps its own refusal",
         %{scope: scope} do
      # Ordering guard: a row that is not merge-shaped must still answer
      # :criterion_not_merge_shaped, not the newer reason. Otherwise the new
      # arm would be silently reclassifying every existing refusal.
      doc =
        task!(scope, %{
          "acceptance_criteria" => [
            %{"criterion" => "an operator runs the demo", "met" => false}
          ]
        })

      assert {:error, :criterion_not_merge_shaped} =
               Tasks.record_landing(doc.id, note: "landed", criterion: 0)
    end
  end

  # ── 6. Shape refusals, before any DB work ────────────────────────────────

  describe "shape refusals" do
    test "nothing to record is :empty_landing", %{scope: scope} do
      doc = task!(scope)
      assert {:error, :empty_landing} = Tasks.record_landing(doc.id, [])
      assert {:error, :empty_landing} = Tasks.record_landing(doc.id, commit: "  ", note: "")
      refute Map.has_key?(reload(doc).content, "landed")
    end

    test "a criterion with no note is :note_required — a flip needs evidence", %{scope: scope} do
      doc = task!(scope, %{"acceptance_criteria" => [merge_criterion()]})

      assert {:error, :note_required} =
               Tasks.record_landing(doc.id, commit: "aaa", criterion: 0)

      assert hd(criteria(doc))["met"] == false
      refute Map.has_key?(reload(doc).content, "landed")
    end

    test "a negative index is :invalid_criteria", %{scope: scope} do
      doc = task!(scope, %{"acceptance_criteria" => [merge_criterion()]})
      assert {:error, :invalid_criteria} = Tasks.record_landing(doc.id, note: "x", criterion: -1)
    end
  end

  # ── 7. The event ─────────────────────────────────────────────────────────

  describe "the task.landed mutation_event" do
    test "exactly one event, carrying the caller token id and the mark", %{scope: scope} do
      doc = task!(scope, %{"acceptance_criteria" => [merge_criterion()]})

      assert {:ok, _} =
               Tasks.record_landing(doc.id,
                 commit: "a1b2c3d",
                 note: "merged to main",
                 criterion: 0,
                 caller_token_id: "tok-ci-1"
               )

      assert [ev] = landed_events(doc.doc_id)
      assert ev.mutation == "task.landed"
      assert ev.document["caller_token_id"] == "tok-ci-1"
      assert ev.document["landed_mark"]["criterion"] == 0
      assert ev.document["landed_mark"]["flipped"] == true
      assert ev.document["landed_mark"]["landed"]["commits"] == ["a1b2c3d"]
    end

    test "a tokenless caller emits NO caller_token_id key", %{scope: scope} do
      doc = task!(scope)
      assert {:ok, _} = Tasks.record_landing(doc.id, note: "merged to main")

      assert [ev] = landed_events(doc.doc_id)
      refute Map.has_key?(ev.document, "caller_token_id")
      assert ev.document["landed_mark"]["flipped"] == false
    end

    test "a REFUSED landing emits no event at all", %{scope: scope} do
      doc = task!(scope, %{"acceptance_criteria" => [plain_criterion()]})

      assert {:error, :criterion_not_merge_shaped} =
               Tasks.record_landing(doc.id, note: "merged", criterion: 0)

      assert landed_events(doc.doc_id) == []
    end
  end
end
