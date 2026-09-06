defmodule Barkpark.Tasks.TwinOneRuleTest do
  @moduledoc """
  THE ONE RULE (task-49eef068420df918 + task-baf9b74a0ffc83f4) — the rule is
  stated once in `Barkpark.Tasks.TwinResolver`'s moduledoc; this file is its
  proof, one describe block per rule.

  What is RED on origin/main, measured (see the PR body for the pasted mutation
  output):

    * rule 3 — the cross-dataset refusal: the old `asc: d.dataset` tiebreak
      SILENTLY claimed the alphabetically-first dataset's copy, which for the
      eleven live twins is the empty one.
    * rule 4 — the sweeper: `TtlSweeper` reaped the `drafts.<id>` twin of a task
      whose published row exists (the 10:27:00Z reap on task-49b5c183f10ad0fc,
      31 minutes after that row was closed by its holder).
    * the producer — a second create of the same task doc_id into a sibling
      dataset used to succeed silently; it is the 2026-08-07 sequence verbatim.

  What is NOT red here, stated so nobody reads green as coverage it does not
  have: the by-id task doors were ALREADY published-spelling-first, so rule 1 is
  a REGRESSION pin on those doors, not a repair of them. The door that reads
  draft-first is the GitHub mirror's `Link.fetch_task/3` (link.ex:228-232, out of
  this fence) — see the PR body.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{AmbiguousTwinError, TtlSweeper}

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

  defp content(extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "acceptance_criteria" => [
          %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
        ]
      },
      extra
    )
  end

  # A DRAFT row: `Content.create_document/4` always lands `drafts.<id>`.
  defp mk_draft!(doc_id, dataset, scope, extra \\ %{}) do
    {:ok, draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          # Titles must DIFFER across the twins: `Tasks.Dedup.check_new_task/5` runs
          # on every birth and refuses a near-duplicate title in the same dataset.
          "title" => "#{doc_id} (#{dataset} #{System.unique_integer([:positive])})",
          "content" => content(extra)
        },
        dataset,
        scope
      )

    draft
  end

  # A PUBLISHED row. Publishing through the real door would have to satisfy the
  # authoring wall's label spine (a registered `type:tag` set a test database does
  # not carry — the reason `claim_cross_dataset_test.exs` seeds two drafts), so
  # the draft is renamed to the published spelling in place. That produces
  # EXACTLY the stored shape the resolver reads: bare doc_id, `status:
  # "published"`, real `dataset_id` — which is what the eleven live twins are.
  defp mk_published!(doc_id, dataset, scope, extra \\ %{}) do
    draft = mk_draft!(doc_id, dataset, scope, extra)

    {1, _} =
      from(d in Document, where: d.id == ^draft.id)
      |> Repo.update_all(set: [doc_id: doc_id, status: "published"])

    Repo.get!(Document, draft.id)
  end

  defp age_claim!(doc, seconds_ago) do
    iso = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.to_iso8601()

    claim =
      (doc.content["claim"] || %{})
      |> Map.merge(%{"ts_iso" => iso, "worker" => "worker-crashed", "epoch" => 1})

    new_content =
      doc.content
      |> Map.put("claim", claim)
      |> Map.put("lifecycle_status", "in_progress")

    {1, _} =
      from(d in Document, where: d.id == ^doc.id)
      |> Repo.update_all(set: [content: new_content])

    Repo.get!(Document, doc.id)
  end

  # ── RULE 3: an unnamed cross-dataset tie is REFUSED, never picked ──────────

  describe "rule 3 — a doc_id in two datasets" do
    test "a targeted claim REFUSES and names every dataset, instead of picking one",
         %{scope: scope} do
      doc_id = uniq("twin-refusal")
      _a = mk_published!(doc_id, @primary, scope)
      _b = mk_published!(doc_id, @secondary, scope, %{"dataset_twin_intended" => true})

      # RED on origin/main: `asc: d.dataset` under `limit: 1` returned the
      # @secondary copy ("aker-brygge" < "production") and CLAIMED it — the
      # silent wrong row this rule exists to end.
      e =
        assert_raise AmbiguousTwinError, fn ->
          Tasks.claim_by_id(doc_id, "worker-twin", scope)
        end

      assert e.doc_id == doc_id
      assert e.datasets == Enum.sort([@primary, @secondary])
      assert e.message =~ @primary
      assert e.message =~ @secondary
      assert Plug.Exception.status(e) == 409
    end

    test "the refusal does not fire for a doc_id with ONE row in scope", %{scope: scope} do
      doc_id = uniq("single-dataset")
      only = mk_published!(doc_id, @primary, scope)

      assert {:ok, %Document{id: id}} = Tasks.claim_by_id(doc_id, "worker-twin", scope)
      assert id == only.id
    end
  end

  # ── RULE 1: a drafts.<id> twin never outranks a published row ──────────────

  describe "rule 1 — a published row beside its draft twin" do
    test "every task verb resolves the PUBLISHED row, and the twin is untouched",
         %{scope: scope} do
      doc_id = uniq("draft-twin")
      published = mk_published!(doc_id, @primary, scope)
      twin = mk_draft!(doc_id, @primary, scope, %{"lifecycle_status" => "open"})
      twin_before = Repo.get!(Document, twin.id)

      assert {:ok, %Document{id: claimed_id}} = Tasks.claim_by_id(doc_id, "worker-pub", scope)
      assert claimed_id == published.id, "a task verb resolved the drafts.<id> twin"

      twin_after = Repo.get!(Document, twin.id)
      assert twin_after.content == twin_before.content
      assert twin_after.rev == twin_before.rev
    end

    test "an UNPAIRED draft is still the row of record (the carve-out)", %{scope: scope} do
      doc_id = uniq("unpaired-draft")
      draft = mk_draft!(doc_id, @primary, scope)

      assert {:ok, %Document{id: id}} = Tasks.claim_by_id(doc_id, "worker-unpaired", scope)
      assert id == draft.id
    end
  end

  # ── RULE 4: the sweeper never writes to a shadowed draft ───────────────────

  describe "rule 4 — TtlSweeper" do
    test "does NOT reap the drafts.<id> twin of a task whose published row exists",
         %{scope: scope} do
      doc_id = uniq("sweep-twin")
      published = mk_published!(doc_id, @primary, scope)
      twin = mk_draft!(doc_id, @primary, scope)

      aged_published = age_claim!(published, 3600)
      aged_twin = age_claim!(twin, 3600)

      assert {:ok, %{swept: swept}} = TtlSweeper.perform(%Oban.Job{})
      assert swept >= 1

      # The published row IS reaped — non-vacuity: the sweep ran and did work.
      reaped = Repo.get!(Document, aged_published.id)
      assert reaped.content["lifecycle_status"] == "open"
      assert reaped.content["claim"]["expired_at"]

      # RED on origin/main: the twin was reaped too — epoch bumped, lifecycle
      # flipped, `expired_at` stamped on a row nobody can ever close.
      after_sweep = Repo.get!(Document, aged_twin.id)
      assert after_sweep.content == aged_twin.content
      assert after_sweep.rev == aged_twin.rev
      refute after_sweep.content["claim"]["expired_at"]
    end

    test "still reaps an UNPAIRED draft — the exclusion is not a blanket drafts. skip",
         %{scope: scope} do
      doc_id = uniq("sweep-unpaired")
      draft = doc_id |> mk_draft!(@primary, scope) |> age_claim!(3600)

      assert {:ok, %{swept: swept}} = TtlSweeper.perform(%Oban.Job{})
      assert swept >= 1

      reaped = Repo.get!(Document, draft.id)
      assert reaped.content["lifecycle_status"] == "open"
      assert reaped.content["claim"]["expired_at"]
    end

    test "does not exempt a draft whose published twin lives in ANOTHER dataset",
         %{scope: scope} do
      doc_id = uniq("sweep-other-dataset")
      _elsewhere = mk_published!(doc_id, @secondary, scope)

      draft =
        doc_id
        |> mk_draft!(@primary, scope, %{"dataset_twin_intended" => true})
        |> age_claim!(3600)

      assert {:ok, _} = TtlSweeper.perform(%Oban.Job{})

      reaped = Repo.get!(Document, draft.id)

      assert reaped.content["claim"]["expired_at"],
             "a published row in a DIFFERENT dataset exempted this draft from its own reap"
    end
  end

  # ── THE PRODUCER: no new dataset twins ─────────────────────────────────────

  describe "the producer (task-49eef068420df918 C2)" do
    test "a task birth into a sibling dataset of an existing id is REFUSED", %{scope: scope} do
      doc_id = uniq("producer-twin")
      _first = mk_draft!(doc_id, @primary, scope)

      # The 2026-08-07 sequence verbatim: the same doc_id created a second time
      # into another dataset of the same workspace+project. RED on origin/main —
      # it returned {:ok, _} and minted twin number twelve.
      assert {:error, {:dataset_twin, details}} =
               Content.create_document(
                 "task",
                 %{"doc_id" => doc_id, "title" => doc_id, "content" => content()},
                 @secondary,
                 scope
               )

      assert details.doc_id == doc_id
      assert details.dataset == @secondary
      assert details.datasets == [@primary]
      assert details.advise =~ "dataset_twin_intended"

      # The refusal WROTE NOTHING.
      assert Repo.aggregate(
               from(d in Document,
                 where: d.type == "task" and d.dataset == ^@secondary,
                 where: d.doc_id in [^doc_id, ^("drafts." <> doc_id)]
               ),
               :count
             ) == 0
    end

    test "the stated intent passes, and the unique index is unchanged", %{scope: scope} do
      doc_id = uniq("producer-intended")
      _first = mk_draft!(doc_id, @primary, scope)

      assert {:ok, %Document{}} =
               Content.create_document(
                 "task",
                 %{
                   "doc_id" => doc_id,
                   "title" => doc_id,
                   "content" => content(%{"dataset_twin_intended" => true})
                 },
                 @secondary,
                 scope
               )
    end

    test "a NON-task type is untouched — the rule is task-scoped", %{scope: scope} do
      doc_id = uniq("producer-post")

      for dataset <- [@primary, @secondary] do
        {:ok, _} =
          Content.create_document(
            "post",
            %{"doc_id" => doc_id, "title" => doc_id, "content" => %{"body" => "x"}},
            dataset,
            scope
          )
      end
    end

    test "an UPDATE of an existing row is untouched — the guard is a birth guard",
         %{scope: scope} do
      doc_id = uniq("producer-update")
      _first = mk_draft!(doc_id, @primary, scope)
      _twin = mk_draft!(doc_id, @secondary, scope, %{"dataset_twin_intended" => true})

      assert {:ok, %Document{}} =
               Content.upsert_document(
                 "task",
                 %{
                   "doc_id" => doc_id,
                   "title" => "#{doc_id} (edited)",
                   "content" => content(%{"dataset_twin_intended" => true})
                 },
                 @secondary,
                 scope
               )
    end
  end
end
