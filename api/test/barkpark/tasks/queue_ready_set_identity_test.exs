defmodule Barkpark.Tasks.QueueReadySetIdentityTest do
  @moduledoc """
  THE READY SET IS THE CONTRACT — the protective test for the `ready_query/1`
  rewrite filed as task-9a2e75098a62cf45.

  That change deleted two `MATERIALIZED` CTEs and re-expressed the
  `content.dependencies` gate as a correlated probe, and guarded the twin
  collapse behind `doc_id LIKE 'drafts.%'`. Every one of those moves is a
  PERFORMANCE move, and every one of them touches the WHERE clause of the query
  that decides which task a worker is handed next. A faster board that answers a
  different question is a worse defect than a slow one, so the thing this file
  pins is not the speed — it is that the answer did not move.

  ## Why an EXACT ORDERED LIST and not a set of `assert x in ready`

  `assert doc in ready` cannot see an ordering regression, and it cannot see an
  EXTRA row appearing — the two failure modes a query rewrite actually has. The
  assertion here is `ready_doc_ids == [...]`: an authored list, in an authored
  order, covering both the rows that must be there and (by exhaustiveness) every
  row that must not. It goes RED on:

    * a flipped or dropped ORDER BY key — the list order changes;
    * a dropped blocks-edge gate — `blocked_by_open` appears;
    * a dropped or loosened dependency gate — `deps_unsatisfied` and/or
      `deps_dangling` appear;
    * a dropped twin collapse — the `drafts.` shadow of `twin` appears;
    * an over-tightened gate — a row that should be ready goes missing.

  Section (2) makes that claim CHECKABLE rather than asserted: it re-runs the
  same fixture through mutated copies of the real ordering and blocker clauses
  and requires each mutant to produce a DIFFERENT answer. A gate that cannot go
  red on a deliberate mutation is decoration.

  ## Why a dedicated workspace

  The tasks table is written by every other suite and, in this repo, by other
  agents against the SAME database. An exact-list assertion against the default
  scope would measure the neighbourhood. Every row here lives in a workspace
  this test mints, so the list is exhaustive by construction.

  ## Why `inserted_at` is stamped by hand

  `documents.inserted_at` has second resolution, so nine rows created in a burst
  tie on it and the third sort key (`id`, a random uuid) decides — a test whose
  expected order is nondeterministic. Stamping distinct timestamps after the
  fact makes the second ordering key observable AND the expectation stable.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.{Edge, Queue}

  @dataset "production"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    ws = TenancyFixtures.create_workspace!("rsi-ws-#{System.unique_integer([:positive])}")

    project =
      TenancyFixtures.create_project!(ws, "rsi-proj-#{System.unique_integer([:positive])}")

    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope, fixture: build_fixture(scope)}
  end

  # ── the fixture: every readiness axis, in one scope ───────────────────────
  #
  # `at:` is the stamped `inserted_at` offset in minutes; the expected order is
  # (priority ASC NULLS LAST, inserted_at ASC), so `no_priority` is authored
  # EARLIEST and must still come LAST.
  defp build_fixture(scope) do
    u = System.unique_integer([:positive])

    top = mk!("rsi-top-#{u}", scope, %{"priority" => 0}, at: 100)
    mid_a = mk!("rsi-mid-a-#{u}", scope, %{"priority" => 1}, at: 200)
    mid_b = mk!("rsi-mid-b-#{u}", scope, %{"priority" => 1}, at: 300)

    # axis 2 — a dependency that IS satisfied (a same-scope `done` task).
    done_dep = mk!("rsi-done-dep-#{u}", scope, %{"lifecycle_status" => "done"}, at: 50)

    deps_ok =
      mk!(
        "rsi-deps-ok-#{u}",
        scope,
        %{"priority" => 1, "dependencies" => [normalized(done_dep)]},
        at: 400
      )

    # axis 2 — an UNSATISFIED dependency (target is open) and a DANGLING one.
    open_dep = mk!("rsi-open-dep-#{u}", scope, %{"priority" => 1}, at: 700)

    deps_unsatisfied =
      mk!(
        "rsi-deps-unsat-#{u}",
        scope,
        %{"priority" => 0, "dependencies" => [normalized(open_dep)]},
        at: 120
      )

    deps_dangling =
      mk!(
        "rsi-deps-dangling-#{u}",
        scope,
        %{"priority" => 0, "dependencies" => ["rsi-no-such-task-#{u}"]},
        at: 130
      )

    # axis 1 — the blocks-edge gate, in both directions.
    done_target = mk!("rsi-edge-done-target-#{u}", scope, %{"lifecycle_status" => "done"}, at: 60)
    open_target = mk!("rsi-edge-open-target-#{u}", scope, %{"priority" => 1}, at: 800)

    edge_ok = mk!("rsi-edge-ok-#{u}", scope, %{"priority" => 1}, at: 500)
    blocked_by_open = mk!("rsi-blocked-#{u}", scope, %{"priority" => 0}, at: 110)

    blocks!(edge_ok, done_target)
    blocks!(blocked_by_open, open_target)

    # axis 3 — a genuine draft/published twin pair. `create_document` writes the
    # `drafts.<id>` shadow; publishing promotes it to the bare id, and creating
    # it again leaves the shadow behind. Published wins.
    twin_base = "rsi-twin-#{u}"
    _first = mk!(twin_base, scope, %{"priority" => 1}, at: 600)
    {:ok, twin_published} = Content.publish_document(twin_base, "task", @dataset, scope)
    twin_shadow = mk!(twin_base, scope, %{"priority" => 1}, at: 600)
    stamp_at!(twin_published, 600)

    no_priority = mk!("rsi-no-priority-#{u}", scope, %{}, at: 10)

    %{
      expected: [
        top,
        mid_a,
        mid_b,
        deps_ok,
        edge_ok,
        twin_published,
        open_dep,
        open_target,
        no_priority
      ],
      excluded: [
        deps_unsatisfied,
        deps_dangling,
        blocked_by_open,
        twin_shadow,
        done_dep,
        done_target
      ]
    }
  end

  defp mk!(doc_id, scope, content_extra, at: minutes) do
    content =
      %{"kind" => "task", "lifecycle_status" => "open"}
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    stamp_at!(doc, minutes)
  end

  # Distinct, deterministic `inserted_at` so the SECOND ordering key is
  # observable. Returns the reloaded row so callers hold the stamped value.
  defp stamp_at!(doc, minutes) do
    at = NaiveDateTime.add(~N[2020-01-01 00:00:00], minutes * 60, :second)
    {1, _} = Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [inserted_at: at])
    Repo.get!(Document, doc.id)
  end

  defp blocks!(from_doc, to_doc) do
    Repo.insert!(
      Edge.changeset(%Edge{}, %{from_id: from_doc.id, to_id: to_doc.id, kind: "blocks"})
    )
  end

  defp normalized(doc), do: String.replace_prefix(doc.doc_id, "drafts.", "")

  defp ready_doc_ids(scope, opts \\ []) do
    (scope ++ [dataset: @dataset, limit: 100])
    |> Keyword.merge(opts)
    |> Queue.ready()
    |> Enum.map(& &1.doc_id)
  end

  # ─── (1) the ready set, exactly ───────────────────────────────────────────

  describe "ready/1 — the ready set and its order" do
    test "returns exactly the ready rows, in (priority NULLS LAST, inserted_at) order",
         %{scope: scope, fixture: fixture} do
      assert ready_doc_ids(scope) == Enum.map(fixture.expected, & &1.doc_id)
    end

    test "every excluded row is excluded, and each for its own reason",
         %{scope: scope, fixture: fixture} do
      ready = ready_doc_ids(scope)

      for doc <- fixture.excluded do
        refute doc.doc_id in ready,
               "#{doc.doc_id} must not be ready — it is gated by blocks/dependencies/twin/lifecycle"
      end
    end

    test "the LIMIT takes the HEAD of that order, and offset walks it",
         %{scope: scope, fixture: fixture} do
      expected = Enum.map(fixture.expected, & &1.doc_id)

      assert ready_doc_ids(scope, limit: 1) == Enum.take(expected, 1)
      assert ready_doc_ids(scope, limit: 4) == Enum.take(expected, 4)
      assert ready_doc_ids(scope, limit: 3, offset: 2) == expected |> Enum.drop(2) |> Enum.take(3)
    end
  end

  # ─── (2) the non-vacuity check: the mutants must NOT agree ────────────────
  #
  # Section (1) is only worth its runtime if a wrong query would fail it. These
  # arms take the REAL `ready_query/1` and mutate exactly the two clauses the
  # criterion names — the ordering, and the blocker filter — then require a
  # DIFFERENT answer. If a mutant still matches, section (1) is measuring
  # nothing and this file says so out loud.

  describe "the assertion is not vacuous" do
    test "a flipped ordering produces a DIFFERENT list", %{scope: scope, fixture: fixture} do
      expected = Enum.map(fixture.expected, & &1.doc_id)

      mutant =
        (scope ++ [dataset: @dataset, limit: 100])
        |> Queue.ready_query()
        |> exclude(:order_by)
        |> order_by([d],
          desc_nulls_first: fragment("(?->>'priority')::int", d.content),
          desc: d.inserted_at,
          desc: d.id
        )
        |> Repo.all()
        |> Enum.map(& &1.doc_id)

      assert Enum.sort(mutant) == Enum.sort(expected),
             "the mutation must change only the ORDER, so the membership check stays honest"

      refute mutant == expected,
             "a reversed ORDER BY produced the same list — section (1) cannot see ordering"
    end

    test "dropping the blocks-edge gate lets the blocked row through",
         %{scope: scope, fixture: fixture} do
      expected = Enum.map(fixture.expected, & &1.doc_id)

      blocked = Enum.find(fixture.excluded, &String.contains?(&1.doc_id, "rsi-blocked-"))

      # The same query with ONLY the blocks-edge NOT EXISTS removed. Ecto has no
      # "drop one where clause", so the gate is re-expressed as its complement
      # and OR-ed back in: `NOT EXISTS(e) OR EXISTS(e)` is a tautology, which is
      # exactly "this gate no longer filters".
      mutant =
        (scope ++ [dataset: @dataset, limit: 100])
        |> Queue.ready_query()
        |> or_where(
          [doc: d],
          exists(
            from(e in Edge,
              join: b in Document,
              on: b.id == e.to_id,
              where:
                e.from_id == parent_as(:doc).id and e.kind == "blocks" and
                  fragment("COALESCE(?->>'lifecycle_status', '')", b.content) != "done",
              select: 1
            )
          )
        )
        |> Repo.all()
        |> Enum.map(& &1.doc_id)

      refute blocked.doc_id in expected,
             "instrument self-test: the blocked row must be absent from the real answer"

      assert blocked.doc_id in mutant,
             "with the blocks-edge gate defeated the blocked row must appear — " <>
               "if it does not, section (1) cannot see a blocker-filter regression"
    end
  end
end
