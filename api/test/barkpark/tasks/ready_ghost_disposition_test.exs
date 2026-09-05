defmodule Barkpark.Tasks.ReadyGhostDispositionTest do
  @moduledoc """
  task-052f74f2cac22b76 — a row can advertise itself as ready while its own
  adjudication says the question is closed.

  `lifecycle_status` and `content.disposition` are written by SEPARATE verbs and
  nothing makes them atomic. The known control, task-38786b2edab15955, carried
  `disposition: "closed"`, a `close_reason` naming the merged PR, and a
  `claim.closed_at` — and `lifecycle_status: "open"`. The orchestrator handed it
  out as a P0 seed row ELEVEN DAYS after the fix merged, because the ready queue
  only ever read the lifecycle half.

  ## The arm that matters most is the NULL one

  Most rows carry no disposition at all — 5,443 of the 6,579 terminal rows on
  the live ledger, and the great majority of live ones. In SQL, `NULL != 'closed'`
  is NULL, not TRUE, so a predicate written with `!=` would drop every one of
  them from the queue and empty the board.

  That failure is silent in the worst way: the queue still returns rows (the ones
  that happen to carry a disposition), so nothing looks broken until someone
  notices the board is short. `IS DISTINCT FROM` is what makes NULL behave, and
  the third test here exists to red if anyone "simplifies" it back.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks}

  @dataset "production"

  setup do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
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

  defp mk_task!(scope, extra) do
    doc_id = uniq("ghost")

    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => [
            %{"criterion" => "the thing is done", "met" => false, "evidence" => ""}
          ]
        },
        extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp ready_ids(scope) do
    scope
    |> Keyword.put(:dataset, @dataset)
    |> Tasks.ready()
    |> Enum.map(& &1.doc_id)
  end

  describe "the ready queue and a settled adjudication" do
    test "a row whose disposition is closed is NOT handed out as ready", %{scope: scope} do
      ghost =
        mk_task!(scope, %{
          "disposition" => "closed",
          "disposition_reason" =>
            "RECONCILIATION FINDING - OBSOLETE, not built: this row is closed."
        })

      live = mk_task!(scope, %{})

      ids = ready_ids(scope)

      # THE DEFECT: before this, the ghost came back as claimable work — a row
      # somebody had already settled, handed to the next agent as a seed.
      refute ghost.doc_id in ids,
             "a row carrying disposition=closed was offered as ready work"

      # NON-VACUITY: if the queue returned nothing at all, the refute above would
      # pass for free and prove nothing.
      assert live.doc_id in ids,
             "the queue returned no live rows, so the refutation above is vacuous"
    end

    test "an ABSENT disposition is not a closed one — the row stays ready",
         %{scope: scope} do
      # The overwhelmingly common shape: no disposition key at all.
      plain = mk_task!(scope, %{})

      assert plain.doc_id in ready_ids(scope),
             "a row with no disposition at all was dropped from the queue"
    end

    test "an OPEN or PARKED disposition stays ready", %{scope: scope} do
      open_row = mk_task!(scope, %{"disposition" => "open"})

      ids = ready_ids(scope)

      assert open_row.doc_id in ids,
             "a row adjudicated open was dropped from the queue"
    end

    test "the NULL arm: a disposition-less row and a closed one are split correctly",
         %{scope: scope} do
      # This is the arm that catches `!=` replacing `IS DISTINCT FROM`. Under
      # `!=`, the NULL row's predicate evaluates to NULL rather than TRUE and it
      # silently leaves the queue, while the closed row is excluded either way —
      # so a test that only checks the closed row would stay green through the
      # regression that empties the board.
      plain_a = mk_task!(scope, %{})
      plain_b = mk_task!(scope, %{"disposition" => "open"})
      closed = mk_task!(scope, %{"disposition" => "closed"})

      ids = ready_ids(scope)

      present = Enum.filter([plain_a.doc_id, plain_b.doc_id], &(&1 in ids))

      assert length(present) == 2,
             """
             a row that carries no disposition, or one adjudicated open, was
             dropped from the ready queue. This is what `!=` does to NULL: the
             predicate is NULL, not TRUE, so the row vanishes.

             expected both #{plain_a.doc_id} and #{plain_b.doc_id} to be ready,
             saw: #{inspect(present)}
             """

      refute closed.doc_id in ids
    end
  end
end
