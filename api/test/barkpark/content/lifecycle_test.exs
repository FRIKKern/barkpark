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

    :ok
  end

  defp draft!(id, title \\ "Title") do
    {:ok, _} =
      Content.create_document(@type_name, %{"_id" => id, "title" => title}, @dataset)

    {:ok, draft} = Content.get_document("drafts." <> id, @type_name, @dataset)
    draft
  end

  defp paper_draft!(id, content) do
    {:ok, _} =
      Content.create_document(
        "paper",
        %{"_id" => id, "title" => "P", "content" => content},
        @dataset
      )

    {:ok, draft} = Content.get_document("drafts." <> id, "paper", @dataset)
    draft
  end

  # Simulate a LEGACY published document — a row that was already published
  # when the wall's migration ran: insert the published row directly (the
  # pre-wall world had no gate) and its exemption-ledger row (what the
  # migration's INSERT … SELECT would have seeded).
  defp legacy_published!(id, content) do
    %Document{}
    |> Document.changeset(%{
      "doc_id" => id,
      "type" => "paper",
      "dataset" => @dataset,
      "title" => "Legacy",
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
  end
end
