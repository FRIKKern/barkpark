defmodule Barkpark.Tasks.PrimeTest do
  @moduledoc """
  `GET /v1/tasks/prime`'s counts read (ttw20-bl-prime-counts-collapse-twins).

  A task can exist TWICE — `t1` (published) and `drafts.t1` (its shadow; every
  `/v1/data/mutate` write lands there). `Tasks.Query.collapse_twins/1` calls
  itself "the ONE owner of the 'count a twinned task once' law for every task
  READ path", and `/v1/tasks` applies it — but `Prime.lifecycle_counts/2`
  grouped the RAW rows. A twinned task whose halves carry DIFFERENT lifecycle
  statuses therefore landed a `+1` in EACH bucket. Live repro 2026-08-17: prime
  said `in_progress = 11` while the collapsed listing returned 10.

  ## Why a workspace this test mints

  The tasks table is written by every other suite and, in this repo, by other
  agents against the SAME database. A count assertion against the default scope
  would measure the neighbourhood: an exact-map assertion would be
  nondeterministic, and a `>=` assertion cannot see a DOUBLE-count at all — the
  only failure mode there is. Every row here lives in a workspace + project
  minted in `setup`, and prime is called with that scope, so the expected map is
  exhaustive by construction and `10 vs 11` becomes `1 vs 2`.

  ## Why the twins are built through publish, not hand-written

  `Content.create_document/4` always lands a `drafts.` row, and the writer reads
  a twin pair as ONE logical task — writing `drafts.X` as `in_progress` beside a
  `done` published `X` is refused outright:

      illegal lifecycle transition "done" → "in_progress": no document write may
      perform it — a live claim is minted only by the claim primitive

  So a divergent pair can only be built the way production builds one: draft →
  publish (the draft is consumed) → a fresh mutate write recreates the shadow →
  each half claimed through the claim primitive → only the published half closed.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @dataset "production"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    ws = TenancyFixtures.create_workspace!("prime-ws-#{System.unique_integer([:positive])}")

    project =
      TenancyFixtures.create_project!(ws, "prime-proj-#{System.unique_integer([:positive])}")

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

  # Always lands `drafts.<doc_id>`. Two store rules shape this helper: the
  # published label spine needs a `description` ("A published document requires
  # a description"), and the dedup wall refuses a second publish that
  # near-duplicates the first — so every fixture carries its OWN wording, not a
  # shared boilerplate string.
  defp mk_draft!(doc_id, status, description, scope) do
    content =
      %{"kind" => "task", "lifecycle_status" => status, "description" => description}
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp mk_published!(doc_id, status, description, scope) do
    mk_draft!(doc_id, status, description, scope)
    {:ok, published} = Content.publish_document(doc_id, "task", @dataset, scope)
    published
  end

  defp uniq(stem), do: "#{stem}-#{System.unique_integer([:positive])}"

  # The divergent pair from the live repro: published `done`, draft `in_progress`.
  # Publishing CONSUMES the draft, so the shadow is recreated afterwards — which
  # is exactly how a real twin appears (a published row plus a later mutate
  # write). Both halves are then claimed through the claim primitive, and only
  # the published half is closed.
  defp divergent_pair!(base, scope) do
    desc = "#{base}: two halves of one ledger row drifting apart across lifecycle buckets"
    mk_published!(base, "open", desc, scope)
    mk_draft!(base, "open", desc, scope)
    draft_id = "drafts." <> base

    {:ok, _draft} = Tasks.claim_by_id(draft_id, "w-draft-" <> base, scope)
    {:ok, published} = Tasks.claim_by_id(base, "w-pub-" <> base, scope)

    {:ok, closed} =
      Tasks.close(published.id, "w-pub-" <> base,
        observed_epoch: published.content["claim"]["epoch"]
      )

    # The premise, asserted rather than assumed.
    assert closed.doc_id == base
    assert closed.content["lifecycle_status"] == "done"
    assert raw_status(draft_id, scope) == "in_progress"

    draft_id
  end

  # Deliberately a RAW row read, not `docs_for_query/2` — that read collapses
  # twins, so it cannot see the shadow whose status this asserts.
  defp raw_status(doc_id, scope) do
    from(d in Document,
      where: d.type == "task" and d.doc_id == ^doc_id and d.project_id == ^scope[:project_id],
      select: fragment("?->>'lifecycle_status'", d.content)
    )
    |> Repo.one()
  end

  defp counts(scope), do: Tasks.prime(scope ++ [limit: 5]).counts

  describe "lifecycle_counts — twin collapse" do
    test "a twin-divergent pair counts ONCE, in the PUBLISHED row's bucket", %{scope: scope} do
      base = uniq("twinned-ledger-row")
      desc = "#{base}: two halves of one ledger row drifting apart across lifecycle buckets"
      mk_published!(base, "open", desc, scope)
      mk_draft!(base, "open", desc, scope)
      draft_id = "drafts." <> base

      {:ok, _} = Tasks.claim_by_id(draft_id, "w-draft-" <> base, scope)
      {:ok, published} = Tasks.claim_by_id(base, "w-pub-" <> base, scope)

      {:ok, _} =
        Tasks.close(published.id, "w-pub-" <> base,
          observed_epoch: published.content["claim"]["epoch"]
        )

      # RED BEFORE THE FIX: %{"done" => 1, "in_progress" => 1} — ONE task in TWO
      # buckets. Published wins; the shadow contributes nothing.
      assert counts(scope) == %{"done" => 1}
    end

    test "the collapsed corpus is the SUM the listing sees, not the raw population",
         %{scope: scope} do
      # A divergent twinned pair (2 rows → 1), a plain published row, and an
      # UNPAIRED `drafts.` row — the whole mutate-created population lives at
      # `drafts.<id>` with no published twin and MUST still count. Without that
      # third row a blanket `NOT LIKE 'drafts.%'` would pass this test while
      # trading the over-count for an under-count.
      divergent_pair!(uniq("twinned-ledger-row"), scope)

      mk_published!(
        uniq("solitary-published-card"),
        "open",
        "an ordinary backlog entry carrying no shadow sibling anywhere in this dataset",
        scope
      )

      mk_draft!(
        uniq("orphan-shadow-note"),
        "blocked",
        "a mutate-created shadow document that never gained a published sibling",
        scope
      )

      got = counts(scope)

      # RED BEFORE: 4 rows in 4 buckets —
      # %{"done" => 1, "in_progress" => 1, "open" => 1, "blocked" => 1}.
      assert got == %{"done" => 1, "open" => 1, "blocked" => 1}
      assert got |> Map.values() |> Enum.sum() == 3

      # And the buckets agree row-for-row with the LISTING read over the same
      # scope — the drift this row was filed for, in one assertion.
      listed =
        %{"dataset" => @dataset}
        |> Tasks.Query.docs_for_query(scope)
        |> Enum.frequencies_by(&Map.get(&1.content, "lifecycle_status"))

      assert listed == got
    end

    test "an UNPAIRED drafts. row counts on its own", %{scope: scope} do
      # The under-count guard, standalone: nothing suppresses a shadow that has
      # no distinct published twin.
      mk_draft!(
        uniq("orphan-shadow-note"),
        "open",
        "a mutate-created shadow document that never gained a published sibling",
        scope
      )

      assert counts(scope) == %{"open" => 1}
    end

    test "in_progress stays RAW — a live claim on a draft twin survives its done twin",
         %{scope: scope} do
      # The deliberate asymmetry, pinned. `in_progress` is a CLAIM-RECOVERY read,
      # not a population read: collapsing it too would suppress the very row an
      # agent is rehydrating, because its published twin is already `done`. So
      # the pair counts ONCE while the claim is still handed back — asserted
      # together so a later "make prime internally consistent" edit has to face
      # the trade instead of stumbling into it.
      base = uniq("twinned-ledger-row")
      draft_id = divergent_pair!(base, scope)

      assert counts(scope) == %{"done" => 1}

      primed = Tasks.prime(scope ++ [limit: 5, worker: "w-draft-" <> base])
      assert Enum.map(primed.in_progress, & &1.doc_id) == [draft_id]
    end
  end
end
