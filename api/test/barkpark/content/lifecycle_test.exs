defmodule Barkpark.Content.LifecycleTest do
  @moduledoc """
  Behaviour tests for `Barkpark.Content.Lifecycle` — the core CMS verbs
  (publish / unpublish / discard-draft / delete).

  The load-bearing guarantees under test:

  - Happy path moves the row exactly (published row appears, draft row gone,
    and vice-versa) and returns `{:ok, doc}`.
  - A row that has already been consumed by another writer surfaces as
    `{:error, :not_found}` — NEVER an uncaught `Ecto.StaleEntryError` (a 500)
    and never a phantom/partial state.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Exemptions, Warnings, Writer}
  alias Barkpark.Repo

  @dataset "lifecycle_unit_test"
  @type_name "lpost"

  # A label-spine-compliant content map (charter §Label model): non-trivial
  # description, weighted tags with distinct strengths and ≥20-char rationales.
  @good_labels %{
    "description" => "A deliberately non-trivial description used by the publish wall tests.",
    "tags" => [
      %{
        "tag" => "publish-wall",
        "strength" => 90,
        "rationale" => "This document exists to exercise the fail-closed publish wall."
      },
      %{
        "tag" => "lifecycle",
        "strength" => 40,
        "rationale" => "Publish lifecycle mechanics are the secondary axis here."
      }
    ]
  }

  setup do
    Content.upsert_schema(
      %{"name" => @type_name, "title" => "LPost", "visibility" => "public", "fields" => []},
      @dataset
    )

    # A walled type (the publish wall scopes to paper/task) registered in this
    # test dataset with a bare schema — the wall is type-scoped, not
    # schema-scoped, so the empty field list is irrelevant to it.
    Content.upsert_schema(
      %{"name" => "paper", "title" => "Paper", "visibility" => "public", "fields" => []},
      @dataset
    )

    # E3 tag registry: the hand-rolled weighted tags these wall tests publish
    # must resolve to PUBLISHED type:tag docs in the dataset scope.
    Barkpark.LabelFixtures.register_tags!(@dataset, [
      "publish-wall",
      "lifecycle",
      "solitary-axis"
    ])

    :ok
  end

  defp draft!(id, title \\ "Title") do
    {:ok, _} =
      Content.create_document(@type_name, %{"_id" => id, "title" => title}, @dataset)

    {:ok, draft} = Content.get_document("drafts." <> id, @type_name, @dataset)
    draft
  end

  defp paper_draft!(id, content, title \\ "P") do
    {:ok, _} =
      Content.create_document(
        "paper",
        %{"_id" => id, "title" => title, "content" => content},
        @dataset
      )

    {:ok, draft} = Content.get_document("drafts." <> id, "paper", @dataset)
    draft
  end

  # Simulate a LEGACY published document — a row that was already published
  # when the wall's migration ran: insert the published row directly (the
  # pre-wall world had no gate) and its exemption-ledger row (what the
  # migration's INSERT … SELECT would have seeded).
  defp legacy_published!(id, content, title \\ "Legacy") do
    %Document{}
    |> Document.changeset(%{
      "doc_id" => id,
      "type" => "paper",
      "dataset" => @dataset,
      "title" => title,
      "status" => "published",
      "content" => content,
      "rev" => Writer.generate_rev()
    })
    |> Repo.insert!()

    Repo.insert_all("authoring_exemptions", [
      %{doc_id: id, dataset: @dataset, type: "paper", exempted_at: DateTime.utc_now()}
    ])

    :ok
  end

  defp task_draft!(doc_id, scope, extra) do
    content =
      %{"kind" => "task", "lifecycle_status" => "open"}
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => "Criteria fence #{doc_id}", "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp published_task!(doc_id, scope) do
    {:ok, doc} = Content.get_document(doc_id, "task", @dataset, scope)
    doc
  end

  # What `bp doc patch` does: mint `drafts.<id>` from the CURRENT published
  # content. The twin is claim-IDENTICAL by construction — that is exactly
  # why `stale_claim?/2` cannot see the erasure it enables.
  defp mint_twin_from_published!(doc_id, scope, mutate) do
    pub = published_task!(doc_id, scope)

    {:ok, draft} =
      Content.upsert_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => pub.title,
          "content" => mutate.(pub.content)
        },
        @dataset,
        scope
      )

    draft
  end

  @c0 "the fence refuses a publish that would clear a landed stamp"
  @c1 "a publish that preserves the criteria still succeeds"

  defp two_criteria do
    [
      %{"criterion" => @c0, "met" => false, "evidence" => ""},
      %{"criterion" => @c1, "met" => false, "evidence" => ""}
    ]
  end

  # create → publish → claim → mint the twin → stamp criterion 0 on the
  # PUBLISHED row. Returns {claimed_uuid, epoch}.
  defp claim_and_stamp!(doc_id, scope, worker) do
    task_draft!(doc_id, scope, %{"acceptance_criteria" => two_criteria()})
    {:ok, _} = Content.publish_document(doc_id, "task", @dataset, scope)

    {:ok, claimed} = Barkpark.Tasks.claim_by_id(doc_id, worker, scope)
    epoch = claimed.content["claim"]["epoch"]

    # The twin is minted HERE — after the claim, before the stamp. This is
    # the live exposure window.
    mint_twin_from_published!(doc_id, scope, & &1)

    {:ok, _} =
      Barkpark.Tasks.stamp(claimed.id, worker,
        observed_epoch: epoch,
        criterion: 0,
        criterion_text: @c0,
        outcome: {:met, "gate green: mix test lifecycle_test.exs"}
      )

    stamped = published_task!(doc_id, scope)
    assert %{"met" => true, "evidence" => evidence} = hd(stamped.content["acceptance_criteria"])
    assert evidence =~ "gate green"

    {claimed.id, epoch}
  end

  defp published_inserted_at!(id) do
    {:ok, doc} = Content.get_document(id, @type_name, @dataset)
    doc.inserted_at
  end

  # ── publish ─────────────────────────────────────────────────────────────────

  test "publish moves draft→published: published row exists, draft row gone" do
    draft!("pub-happy", "Hello")

    assert {:ok, published} = Content.publish_document("pub-happy", @type_name, @dataset)
    assert published.doc_id == "pub-happy"
    assert published.status == "published"

    assert {:ok, _} = Content.get_document("pub-happy", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.pub-happy", @type_name, @dataset)
  end

  test "publish on a draft already deleted by a concurrent writer → :not_found, no raise" do
    draft = draft!("pub-stale")
    # Simulate the race winner having already consumed the draft row.
    {:ok, _} = Repo.delete(draft)

    assert {:error, :not_found} = Content.publish_document("pub-stale", @type_name, @dataset)
    # And no phantom published row was left behind.
    assert {:error, :not_found} = Content.get_document("pub-stale", @type_name, @dataset)
  end

  # ── unpublish ───────────────────────────────────────────────────────────────

  test "unpublish moves published→draft: draft row exists, published row gone" do
    draft!("unpub-happy")
    {:ok, _} = Content.publish_document("unpub-happy", @type_name, @dataset)

    assert {:ok, draft} = Content.unpublish_document("unpub-happy", @type_name, @dataset)
    assert draft.status == "draft"

    assert {:ok, _} = Content.get_document("drafts.unpub-happy", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("unpub-happy", @type_name, @dataset)
  end

  test "unpublish on a published row already deleted → :not_found, no raise" do
    draft!("unpub-stale")
    {:ok, published} = Content.publish_document("unpub-stale", @type_name, @dataset)
    {:ok, _} = Repo.delete(published)

    assert {:error, :not_found} = Content.unpublish_document("unpub-stale", @type_name, @dataset)
  end

  # ── discard draft ───────────────────────────────────────────────────────────

  test "discard_draft removes the draft and returns {:ok, _}" do
    draft!("disc-happy")

    assert {:ok, _} = Content.discard_draft("disc-happy", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.disc-happy", @type_name, @dataset)
  end

  test "discard_draft on an already-deleted draft → :not_found, no raise" do
    draft = draft!("disc-stale")
    {:ok, _} = Repo.delete(draft)

    assert {:error, :not_found} = Content.discard_draft("disc-stale", @type_name, @dataset)
  end

  # ── delete ──────────────────────────────────────────────────────────────────

  test "delete on a doc with BOTH variants: both rows gone, returns {:ok, _}" do
    # Publish once (creates published, removes draft), then re-create the draft
    # so the doc carries both a published row and a pending-changes draft.
    draft!("del-both")
    {:ok, _} = Content.publish_document("del-both", @type_name, @dataset)
    draft!("del-both", "Edited")

    assert {:ok, _} = Content.delete_document("del-both", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("del-both", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.del-both", @type_name, @dataset)
  end

  test "delete on a draft-only doc removes the draft" do
    draft!("del-draft")

    assert {:ok, _} = Content.delete_document("del-draft", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.del-draft", @type_name, @dataset)
  end

  test "delete when every variant is already gone → :not_found, no raise" do
    draft = draft!("del-stale")
    {:ok, _} = Repo.delete(draft)

    assert {:error, :not_found} = Content.delete_document("del-stale", @type_name, @dataset)
  end

  # ── republish: the {:ok, existing} update branch ────────────────────────────

  # Deliberate pin on the previously-untested republish branch: when a
  # published row already exists, publish must UPDATE it in place (same
  # physical row), never insert a second published row.
  test "republish after an edit updates the published row IN PLACE" do
    draft!("repub", "First")
    assert {:ok, first} = Content.publish_document("repub", @type_name, @dataset)

    # Edit: a fresh draft on top of the published doc, then publish again.
    draft!("repub", "Second")
    assert {:ok, second} = Content.publish_document("repub", @type_name, @dataset)

    # Same physical row (the {:ok, existing} → Repo.update branch), new title,
    # and still exactly one published row.
    assert second.id == first.id
    assert second.title == "Second"

    published_rows =
      Repo.all(
        from(d in Document,
          where: d.doc_id == "repub" and d.dataset == @dataset and d.status == "published"
        )
      )

    assert length(published_rows) == 1
  end

  # ── the publish wall (label spine + exemption ledger) ──────────────────────

  describe "publish wall" do
    test "non-walled types publish label-free, exactly as before" do
      # The whole test file above IS this proof (every lpost publish is
      # unlabeled); this pins it explicitly so a future widening of
      # @walled_types is a deliberate red, not a surprise.
      draft!("wall-lpost")
      assert {:ok, _} = Content.publish_document("wall-lpost", @type_name, @dataset)
    end

    test "first publish of an unlabeled paper → {:error, {:label_spine, details}}, draft preserved" do
      paper_draft!("wall-bare", %{})

      assert {:error, {:label_spine, details}} =
               Content.publish_document("wall-bare", "paper", @dataset)

      # The rejection reads like documentation: field, rule, fix.
      assert %{field: field, rule: rule, fix: fix} = details
      assert is_binary(field) and is_binary(rule) and is_binary(fix)

      # Fail-closed means NOTHING moved: no published row, draft intact.
      assert {:error, :not_found} = Content.get_document("wall-bare", "paper", @dataset)
      assert {:ok, _} = Content.get_document("drafts.wall-bare", "paper", @dataset)
    end

    test "a well-labeled paper publishes; a legal-but-off-norm tag count rides the warnings channel" do
      Warnings.reset()

      paper_draft!("wall-good", @good_labels)
      assert {:ok, _} = Content.publish_document("wall-good", "paper", @dataset)

      # 2 tags is inside the 2–4 norm — no advisory.
      assert Warnings.drain() == []

      # A single tag DISJOINT from wall-good's, so only the norm advisory
      # fires (an overlapping tag set would legitimately add the E4 dedup
      # wall's possible_duplicate advise entry — pinned in its own test below).
      one_tag =
        Map.put(@good_labels, "tags", [
          %{
            "tag" => "solitary-axis",
            "strength" => 77,
            "rationale" => "A single unrelated tag to exercise the count norm."
          }
        ])

      paper_draft!("wall-one", one_tag)

      Warnings.reset()
      assert {:ok, _} = Content.publish_document("wall-one", "paper", @dataset)

      assert [%{code: "label_norm", severity: "advisory", message: message}] = Warnings.drain()
      assert message =~ "wall-one"
      assert message =~ "norm is 2–4"
    end

    test "grandfathered near-twins republish freely — the exemption covers the WHOLE wall, E4 included" do
      # Two pre-wall docs with IDENTICAL titles (the legacy corpus holds
      # legitimately similar titles). Post-wall these would 409 each other;
      # grandfathered, a republish-unchanged must pass (charter D6).
      legacy_published!("wall-twin-a", %{"body" => "one"}, "Legacy Wall Corpus Paper")
      legacy_published!("wall-twin-b", %{"body" => "two"}, "Legacy Wall Corpus Paper")

      paper_draft!("wall-twin-b", %{"body" => "two, revised"}, "Legacy Wall Corpus Paper")
      assert {:ok, _} = Content.publish_document("wall-twin-b", "paper", @dataset)

      # Contrast: a NEW well-labeled doc with the same title is NOT exempt —
      # the dedup wall refuses it with the incumbent's id.
      paper_draft!("wall-fresh", @good_labels, "Legacy Wall Corpus Paper")

      assert {:error, {:duplicate_of, payload}} =
               Content.publish_document("wall-fresh", "paper", @dataset)

      assert payload.duplicate_of in ["wall-twin-a", "wall-twin-b"]
    end

    test "a gray-zone near-duplicate publishes with a possible_duplicate warning (E4 advise → warnings channel)" do
      paper_draft!("wall-incumbent", @good_labels)
      assert {:ok, _} = Content.publish_document("wall-incumbent", "paper", @dataset)

      # Shares one of two tags with the incumbent (Jaccard 2/3 ≈ 0.67 on tag
      # tokens, shared tokens < 3) — the advise band: never blocks, but the
      # warning rides the channel with DedupWall's own severity.
      overlapping = Map.put(@good_labels, "tags", Enum.take(@good_labels["tags"], 1))
      paper_draft!("wall-grayzone", overlapping)

      Warnings.reset()
      assert {:ok, _} = Content.publish_document("wall-grayzone", "paper", @dataset)

      warnings = Warnings.drain()
      assert Enum.any?(warnings, &(&1.code == "possible_duplicate"))

      assert %{severity: "warning", message: message} =
               Enum.find(warnings, &(&1.code == "possible_duplicate"))

      assert message =~ "wall-incumbent"
    end

    test "legacy republish-unchanged succeeds via exemption AND pins the {:ok, existing} branch" do
      legacy_published!("wall-legacy", %{"body" => "old, unlabeled"})
      {:ok, original} = Content.get_document("wall-legacy", "paper", @dataset)

      # Republish-unchanged is mechanically patch-then-publish: the draft copy
      # carries the published row's tag-less content.
      paper_draft!("wall-legacy", %{"body" => "old, unlabeled"})

      assert {:ok, republished} = Content.publish_document("wall-legacy", "paper", @dataset)

      # Grandfathered publish went through, updating the SAME physical row —
      # the previously-untested {:ok, existing} → Repo.update branch.
      assert republished.id == original.id
      # And the exemption survives (only a validate PASS clears it).
      assert Exemptions.member?("wall-legacy", @dataset)
    end

    test "the migration's seed predicate snapshots exactly the published corpus (never a literal)" do
      # The exemption seed is `INSERT … SELECT FROM documents WHERE status =
      # 'published'` AT MIGRATION RUN. Prove the predicate against the live
      # schema: published rows land in the ledger, drafts do not, and re-running
      # is conflict-absorbed (idempotent).
      %Document{}
      |> Document.changeset(%{
        "doc_id" => "seed-pub",
        "type" => "paper",
        "dataset" => @dataset,
        "status" => "published",
        "content" => %{},
        "rev" => Writer.generate_rev()
      })
      |> Repo.insert!()

      paper_draft!("seed-draft", %{})

      seed_sql = """
      INSERT INTO authoring_exemptions (doc_id, dataset, type, exempted_at)
      SELECT doc_id, dataset, type, now()
      FROM documents
      WHERE status = 'published'
      ON CONFLICT (doc_id, dataset) DO NOTHING
      """

      Repo.query!(seed_sql)
      # Idempotent — a re-run (or a shared (doc_id, dataset) leaf) is absorbed.
      Repo.query!(seed_sql)

      assert Exemptions.member?("seed-pub", @dataset)
      refute Exemptions.member?("drafts.seed-draft", @dataset)
      refute Exemptions.member?("seed-draft", @dataset)
    end

    test "ratchet: a validate-pass clears the exemption; stripping the labels re-hits the wall" do
      legacy_published!("wall-ratchet", %{"body" => "unlabeled legacy"})
      assert Exemptions.member?("wall-ratchet", @dataset)

      # The doc proves itself well-labeled once…
      paper_draft!("wall-ratchet", @good_labels)
      assert {:ok, _} = Content.publish_document("wall-ratchet", "paper", @dataset)

      # …the ratchet shrinks (DELETE-only ledger)…
      refute Exemptions.member?("wall-ratchet", @dataset)

      # …so the strip-and-republish loophole is CLOSED: publishing a tag-less
      # draft of the same doc now fails the wall instead of riding the ledger.
      paper_draft!("wall-ratchet", %{"body" => "labels stripped back off"})

      assert {:error, {:label_spine, _}} =
               Content.publish_document("wall-ratchet", "paper", @dataset)
    end

    test "E3 is NEVER exempted: a grandfathered doc adopting an UNREGISTERED weighted tag still 422s (D25)" do
      # A pre-wall doc in the ledger — grandfathered for its FLAT shape.
      legacy_published!("e3-pin", %{"tags" => ["legacy-flat"]})
      assert Exemptions.member?("e3-pin", @dataset)

      # It ADOPTS the weighted shape, but with a tag no one ever registered.
      # `TagRegistry.validate_publish` runs unconditionally (exempt? feeds
      # only authoring_wall + dedup_wall), so the exemption cannot carry an
      # unknown tag past the registry gate.
      adopting = %{
        "description" => "A grandfathered document adopting weighted labels for the first time.",
        "tags" => [
          %{
            "tag" => "never-registered-e3",
            "strength" => 77,
            "rationale" => "Deliberately absent from the E3 registry to pin the gate."
          }
        ]
      }

      paper_draft!("e3-pin", adopting)

      assert {:error, {:unknown_tag, payload}} =
               Content.publish_document("e3-pin", "paper", @dataset)

      assert "never-registered-e3" in payload.unknown

      # Fail-closed: the published row still carries the OLD flat content.
      {:ok, published} = Content.get_document("e3-pin", "paper", @dataset)
      assert published.content["tags"] == ["legacy-flat"]

      # BUG (b) pin (charter D28): the exemption SURVIVES the failed publish.
      # The label spine passed (one syntactically-valid weighted tag), so the
      # OLD code cleared the ledger row at spine-pass — then E3 rejected. That
      # spent the doc's grandfathering on a publish that FAILED. The ratchet
      # must fire only after the WHOLE wall passes.
      assert Exemptions.member?("e3-pin", @dataset)
    end
  end

  # ── Declared supersession (content.supersedes) ──────────────────────────────
  #
  # A correction is BY DEFINITION a near-duplicate of the row it replaces, so
  # without a first-class path the E4 wall structurally blocks it (measured on
  # a live p0 security packet — task-ccc1e5573598b91b). The exemption is
  # pairwise: `content.supersedes: X` exempts the successor against X ONLY.

  describe "declared supersession at the publish wall" do
    test "a superseding publish passes E4 against exactly its predecessor and stamps superseded_by" do
      paper_draft!("ss-pred", @good_labels, "Wall Supersession Corpus Paper")
      assert {:ok, _} = Content.publish_document("ss-pred", "paper", @dataset)

      # Arm one of the mutation proof: WITHOUT the declaration the identical
      # successor is the hard-refuse shape — and the refusal now offers the
      # supersession verb, never "differentiate this one's title/tags".
      paper_draft!("ss-undeclared", @good_labels, "Wall Supersession Corpus Paper")

      assert {:error, {:duplicate_of, payload}} =
               Content.publish_document("ss-undeclared", "paper", @dataset)

      assert payload.duplicate_of == "ss-pred"
      assert payload.message =~ ~s(content.supersedes: "ss-pred")
      refute payload.message =~ "differentiate"

      # WITH the declaration the same near-duplicate content publishes.
      successor = Map.put(@good_labels, "supersedes", "ss-pred")
      paper_draft!("ss-succ", successor, "Wall Supersession Corpus Paper")
      assert {:ok, _} = Content.publish_document("ss-succ", "paper", @dataset)

      # And the predecessor's PUBLISHED row now points at its correction — a
      # correction nobody can find from the row they are reading is not a
      # correction.
      {:ok, predecessor} = Content.get_document("ss-pred", "paper", @dataset)
      assert predecessor.content["superseded_by"] == "ss-succ"
    end

    test "a supersession claim against a DIFFERENT document buys no pass" do
      paper_draft!("ss-wrong-pred", @good_labels, "Wall Wrong Target Corpus Paper")
      assert {:ok, _} = Content.publish_document("ss-wrong-pred", "paper", @dataset)

      # Arm two of the mutation proof: declaring supersession of an UNRELATED
      # doc must not defeat the wall against the real near-duplicate.
      mis_declared = Map.put(@good_labels, "supersedes", "some-unrelated-doc")
      paper_draft!("ss-mis", mis_declared, "Wall Wrong Target Corpus Paper")

      assert {:error, {:duplicate_of, payload}} =
               Content.publish_document("ss-mis", "paper", @dataset)

      assert payload.duplicate_of == "ss-wrong-pred"
      # The message names the mismatch so the author sees WHY the declaration
      # did not exempt this refusal.
      assert payload.message =~ "some-unrelated-doc"

      # Nothing published, nothing stamped.
      assert {:error, :not_found} = Content.get_document("ss-mis", "paper", @dataset)
    end

    test "a supersedes pointer at a nonexistent doc publishes (inert exemption) without a stamp crash" do
      # The declared predecessor does not exist: the exemption is inert (no
      # candidate matches it), the publish proceeds on its own merits, and the
      # best-effort stamp logs-and-skips instead of failing the publish.
      content = Map.put(@good_labels, "supersedes", "never-existed")
      paper_draft!("ss-ghost", content, "Wall Ghost Predecessor Paper")
      assert {:ok, _} = Content.publish_document("ss-ghost", "paper", @dataset)
    end
  end

  # ── main_tag denormalization (charter D7/D20) ───────────────────────────────

  describe "main_tag stamp at the publish chokepoint" do
    test "publish stamps the strength argmax as content.main_tag" do
      paper_draft!("mt-stamp", @good_labels)

      assert {:ok, published} = Content.publish_document("mt-stamp", "paper", @dataset)

      # @good_labels: publish-wall@90 > lifecycle@40 — the unique max.
      assert published.content["main_tag"] == "publish-wall"

      # The stamp lands on the PUBLISHED row only; the draft's content was
      # never mutated (drafts stay free — the stamp is a publish artifact).
      assert published.content["tags"] == @good_labels["tags"]
    end

    test "a non-walled type publishes without a main_tag key (derives only from weighted tags)" do
      draft!("mt-lpost")

      assert {:ok, published} = Content.publish_document("mt-lpost", @type_name, @dataset)
      refute Map.has_key?(published.content, "main_tag")
    end

    test "a grandfathered flat-tag republish passes through UNSTAMPED — never a nil key" do
      legacy_published!("mt-legacy", %{"tags" => ["old-flat"]})

      paper_draft!("mt-legacy", %{"tags" => ["old-flat"]})

      assert {:ok, republished} = Content.publish_document("mt-legacy", "paper", @dataset)
      refute Map.has_key?(republished.content, "main_tag")
    end

    test "a grandfathered republish DROPS a stale main_tag key — recompute-else-drop (bug a)" do
      # The draft content pre-carries a STALE main_tag (copied from a backfilled
      # row) alongside flat legacy tags that no longer support it. The old
      # :error branch passed the content through UNCHANGED, republishing WITH
      # the stale key; recompute-else-drop deletes it.
      stale = %{"main_tag" => "stale-was-strongest", "tags" => ["legacy-flat"]}
      legacy_published!("mt-stale", stale)

      paper_draft!("mt-stale", stale)

      assert {:ok, republished} = Content.publish_document("mt-stale", "paper", @dataset)
      refute Map.has_key?(republished.content, "main_tag")
    end
  end

  # ── wall telemetry (charter D28) ────────────────────────────────────────────

  describe "wall rejection telemetry" do
    test "a label_spine rejection emits [:barkpark, :authoring, :wall_rejection]" do
      test_pid = self()
      handler_id = "wall-rejection-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:barkpark, :authoring, :wall_rejection],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:wall_rejection, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # An unlabeled paper first-publish → label_spine 422 → one wall_rejection.
      paper_draft!("tele-bare", %{})

      assert {:error, {:label_spine, _}} =
               Content.publish_document("tele-bare", "paper", @dataset)

      assert_receive {:wall_rejection, [:barkpark, :authoring, :wall_rejection], %{count: 1},
                      %{code: :label_spine, type: "paper", dataset: @dataset}}
    end
  end

  # ── the acceptance_criteria fence at the publish door (PDS wave 26) ─────────
  #
  # MECHANISM, observed end-to-end (PDS-D360/D362), not derived: `bp task
  # stamp` writes the PUBLISHED row (`Tasks.Stamp`, `Repo.update_all`) and
  # never touches the draft twin, and a draft NEVER rebases. A draft minted
  # DURING an active claim therefore carries that claim VERBATIM, sails past
  # `stale_claim?/2` (the only fence this door had), and publish then replaces
  # the published content WHOLESALE — `met: true` → `met: false`, evidence →
  # `""`, rc=0, no warning.
  #
  # MUTATION-PROVEN, not merely green (run 2026-07-31 in this worktree):
  # collapsing the new `criteria_regression/2` branch of `gate_task_publish/2`
  # back to `:ok` (≈ origin/main's door) turns the refusal test red in the
  # OTHER direction — the publish returns `{:ok, _}` and the read-back shows
  # `met: false, evidence: ""`. The erasure is real and this fence is what
  # stops it.
  describe "publish door — the acceptance_criteria fence" do
    setup do
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]

      # The fixture weighted tags every task publish carries.
      Barkpark.LabelFixtures.register_tags!(@dataset)

      for schema_def <- Barkpark.Tasks.schema_definitions(@dataset) do
        attrs =
          schema_def
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
      end

      %{scope: scope}
    end

    test "a claim-identical stale draft that would clear a met:true flag is REFUSED, " <>
           "and the stamp survives",
         %{scope: scope} do
      claim_and_stamp!("fence-erase", scope, "fence-worker")

      # The twin still carries the pre-stamp criteria (met:false, no evidence)
      # AND the claim byte-identical — the pre-fix erasure shape.
      {:ok, twin} = Content.get_document("drafts.fence-erase", "task", @dataset, scope)
      assert hd(twin.content["acceptance_criteria"])["met"] == false
      assert twin.content["claim"]["worker"] == "fence-worker"

      # THE PROBE (measured pre-fix: {:ok, _} and the stamp gone).
      assert {:error, {:invalid_task_content, %{"acceptance_criteria" => [message]}}} =
               Content.publish_document("fence-erase", "task", @dataset, scope)

      assert message =~ "stale draft"
      assert message =~ "clear the `met: true` flag"
      assert message =~ "acceptance criterion 0"
      assert message =~ @c0
      # The refusal TEACHES the recovery, not just the refusal.
      assert message =~ "Re-derive the draft from the published row"
      assert message =~ "bp task stamp"

      # The published row never moved.
      pub = published_task!("fence-erase", scope)
      assert %{"met" => true, "evidence" => evidence} = hd(pub.content["acceptance_criteria"])
      assert evidence =~ "gate green"
    end

    test "a draft that DROPS the proof-bearing row entirely is REFUSED", %{scope: scope} do
      claim_and_stamp!("fence-drop", scope, "fence-worker")

      # The whole list goes: criterion 0 has no counterpart by text OR by
      # position, so the proof is not merely cleared — the row holding it is
      # gone. (A SHORTENED list that still has a row at index 0 is reported as
      # a met-clear, not a drop — refused either way; only the verb differs.)
      mint_twin_from_published!("fence-drop", scope, fn content ->
        Map.put(content, "acceptance_criteria", [])
      end)

      assert {:error, {:invalid_task_content, %{"acceptance_criteria" => [message]}}} =
               Content.publish_document("fence-drop", "task", @dataset, scope)

      assert message =~ "drop the proof-bearing row"

      assert hd(published_task!("fence-drop", scope).content["acceptance_criteria"])["met"] ==
               true
    end

    test "a draft that keeps met:true but BLANKS the evidence is REFUSED", %{scope: scope} do
      claim_and_stamp!("fence-blank", scope, "fence-worker")

      mint_twin_from_published!("fence-blank", scope, fn content ->
        blanked =
          content["acceptance_criteria"]
          |> List.update_at(0, &Map.put(&1, "evidence", "   "))

        Map.put(content, "acceptance_criteria", blanked)
      end)

      assert {:error, {:invalid_task_content, %{"acceptance_criteria" => [message]}}} =
               Content.publish_document("fence-blank", "task", @dataset, scope)

      assert message =~ "blank the recorded evidence"

      assert hd(published_task!("fence-blank", scope).content["acceptance_criteria"])["evidence"] =~
               "gate green"
    end

    # ── the flip risk: the fence must NOT refuse legitimate publishes ────────

    test "a draft that PRESERVES the criteria and advances another field publishes cleanly",
         %{scope: scope} do
      claim_and_stamp!("fence-legit", scope, "fence-worker")

      # Re-derive from the published row — the sanctioned recovery the refusal
      # message names — and change something else entirely.
      mint_twin_from_published!("fence-legit", scope, &Map.put(&1, "priority", 2))

      assert {:ok, _} = Content.publish_document("fence-legit", "task", @dataset, scope)

      pub = published_task!("fence-legit", scope)
      assert pub.content["priority"] == 2
      assert hd(pub.content["acceptance_criteria"])["met"] == true
      assert hd(pub.content["acceptance_criteria"])["evidence"] =~ "gate green"
    end

    test "a draft that ADVANCES a second criterion publishes cleanly", %{scope: scope} do
      claim_and_stamp!("fence-advance", scope, "fence-worker")

      mint_twin_from_published!("fence-advance", scope, fn content ->
        advanced =
          content["acceptance_criteria"]
          |> List.update_at(1, &Map.merge(&1, %{"met" => true, "evidence" => "also proven"}))

        Map.put(content, "acceptance_criteria", advanced)
      end)

      assert {:ok, _} = Content.publish_document("fence-advance", "task", @dataset, scope)

      pub = published_task!("fence-advance", scope)
      assert Enum.map(pub.content["acceptance_criteria"], & &1["met"]) == [true, true]
    end

    test "a legitimate reopen (done → open) that keeps its evidence is NOT refused",
         %{scope: scope} do
      {uuid, epoch} = claim_and_stamp!("fence-reopen", scope, "fence-worker")

      # `close` seals the FULL criteria set, so the second row needs its proof
      # before the row can legitimately reach `done`.
      {:ok, _} =
        Barkpark.Tasks.stamp(uuid, "fence-worker",
          observed_epoch: epoch,
          criterion: 1,
          criterion_text: @c1,
          outcome: {:met, "second proof, also from the gate"}
        )

      {:ok, closed} = Barkpark.Tasks.close(uuid, "fence-worker", observed_epoch: epoch)
      assert closed.content["lifecycle_status"] == "done"

      # The reopen recipe: re-derive from the published row, flip only the
      # lifecycle. Criteria (and the claim) ride along untouched.
      mint_twin_from_published!("fence-reopen", scope, &Map.put(&1, "lifecycle_status", "open"))

      assert {:ok, _} = Content.publish_document("fence-reopen", "task", @dataset, scope)

      pub = published_task!("fence-reopen", scope)
      assert pub.content["lifecycle_status"] == "open"
      assert hd(pub.content["acceptance_criteria"])["met"] == true
      assert hd(pub.content["acceptance_criteria"])["evidence"] =~ "gate green"
    end

    test "an UNMET, evidence-less criteria list stays freely editable — the fence is " <>
           "keyed on proof, not on content equality",
         %{scope: scope} do
      task_draft!("fence-unmet", scope, %{"acceptance_criteria" => two_criteria()})
      {:ok, _} = Content.publish_document("fence-unmet", "task", @dataset, scope)

      mint_twin_from_published!("fence-unmet", scope, fn content ->
        Map.put(content, "acceptance_criteria", [
          %{"criterion" => "a completely rewritten criterion", "met" => false, "evidence" => ""}
        ])
      end)

      assert {:ok, _} = Content.publish_document("fence-unmet", "task", @dataset, scope)
      assert length(published_task!("fence-unmet", scope).content["acceptance_criteria"]) == 1
    end
  end

  # ── the census anchor: what `inserted_at` (`_createdAt`) survives ───────────
  #
  # `inserted_at` is absent from `Document.changeset`'s cast list and from
  # `Content.Writer` entirely, so a REPUBLISH over an existing published row
  # (the `Repo.update` branch of `publish_after_gate/5`) preserves the original
  # birth — which is what makes it usable as a census anchor. Its ONE evasion
  # path is `unpublish_document/4`: it `fenced_delete`s the published row, so a
  # later publish takes the `Repo.insert` branch and mints a FRESH birth.
  # Neither half was pinned by any test before PDS wave 26.
  describe "inserted_at as the census anchor" do
    test "inserted_at SURVIVES a patch + republish cycle (the Repo.update branch)" do
      draft!("anchor-keep", "v1")
      {:ok, _} = Content.publish_document("anchor-keep", @type_name, @dataset)
      born = published_inserted_at!("anchor-keep")

      # Backdate the birth so a preserved value is unmistakable: a fresh insert
      # would land ~now, an hour away from this.
      one_hour_ago =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      {1, _} =
        Repo.update_all(
          from(d in Document,
            where: d.doc_id == "anchor-keep" and d.type == ^@type_name and d.dataset == ^@dataset
          ),
          set: [inserted_at: one_hour_ago]
        )

      assert DateTime.compare(published_inserted_at!("anchor-keep"), born) == :lt

      # Patch (mint a draft from the published row) and republish.
      {:ok, _} =
        Content.upsert_document(
          @type_name,
          %{"doc_id" => "anchor-keep", "title" => "v2", "content" => %{"note" => "patched"}},
          @dataset
        )

      assert {:ok, republished} =
               Content.publish_document("anchor-keep", @type_name, @dataset)

      assert republished.title == "v2"
      assert DateTime.compare(published_inserted_at!("anchor-keep"), one_hour_ago) == :eq
    end

    test "inserted_at is RESET by an unpublish + republish cycle (the Repo.insert branch)" do
      draft!("anchor-reset", "v1")
      {:ok, _} = Content.publish_document("anchor-reset", @type_name, @dataset)

      one_hour_ago =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      {1, _} =
        Repo.update_all(
          from(d in Document,
            where: d.doc_id == "anchor-reset" and d.type == ^@type_name and d.dataset == ^@dataset
          ),
          set: [inserted_at: one_hour_ago]
        )

      assert DateTime.compare(published_inserted_at!("anchor-reset"), one_hour_ago) == :eq

      {:ok, _} = Content.unpublish_document("anchor-reset", @type_name, @dataset)
      assert {:ok, _} = Content.publish_document("anchor-reset", @type_name, @dataset)

      # A FRESH birth: the published row was deleted, so publish took the
      # insert branch. This is the anchor's one evasion path.
      assert DateTime.compare(published_inserted_at!("anchor-reset"), one_hour_ago) == :gt
    end
  end
end
