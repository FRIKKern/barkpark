defmodule Barkpark.Tasks.DependencySatisfactionTest do
  @moduledoc """
  cch-w3-task-birth-attribution — a task BIRTH carries no attribution, so a
  forged fresh create with `lifecycle_status: "done"` unblocked a dependent
  with nobody recorded as having claimed it was finished.

  That is worse than the disposition bug this campaign fixed earlier: that one
  LOST a term, this one MANUFACTURES a completion.

  ## Why the tests carry the whole weight here

  Four rows in 8,580 carry dependencies at all, and seven dependency links
  exist in total. The corpus cannot protect this rule — there is almost nothing
  in it to break. If these tests are wrong or absent, nothing else will notice.

  So both directions are pinned explicitly: a done row WITHOUT provenance does
  not satisfy, and an honestly-closed row does.

  ## And the three call sites must agree

  The predicate is evaluated in three places — the ready queue (SQL), the claim
  door (Elixir) and close's cascade-unblock (Elixir). A change applied to two of
  three leaves the hole open in the third, which is exactly how this repo ended
  up with three verbs answering "is this a merge gate" three different ways.

  The SQL cannot literally share code with the Elixir, so the last describe
  block drives BOTH over the same fixtures and asserts they agree row for row.
  That test is the only thing keeping them from drifting.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks}
  alias Barkpark.Tasks.DependencySatisfaction, as: DS

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

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  # A FORGED birth: exactly what a fresh create can write, and nothing more.
  @forged %{"kind" => "task", "lifecycle_status" => "done"}

  describe "the forgery does not satisfy" do
    test "a done row with NO provenance is not satisfied" do
      refute DS.satisfied?(@forged)
    end

    test "done? still says yes — the forgeable half is unchanged" do
      # Kept separate on purpose: a refusal has to be able to say WHICH half
      # failed, or a dependent stays not-ready with nobody able to say why.
      assert DS.done?(@forged)
      refute DS.has_provenance?(@forged)
    end

    test "an empty or whitespace close_reason is not provenance" do
      refute DS.satisfied?(Map.put(@forged, "close_reason", ""))
      refute DS.satisfied?(Map.put(@forged, "close_reason", "   \n  "))
    end

    test "an empty claim map is not provenance" do
      refute DS.satisfied?(Map.put(@forged, "claim", %{}))
      refute DS.satisfied?(Map.put(@forged, "claim", %{"worker" => "w"}))
    end

    test "a non-map content is never satisfied" do
      refute DS.satisfied?(nil)
      refute DS.satisfied?("done")
      refute DS.satisfied?(%{})
    end
  end

  describe "an honest close does satisfy — each arm on its own" do
    test "claim.closed_by alone" do
      assert DS.satisfied?(Map.put(@forged, "claim", %{"closed_by" => "w-1"}))
    end

    test "claim.closed_at alone" do
      assert DS.satisfied?(Map.put(@forged, "claim", %{"closed_at" => "2026-09-06T00:00:00Z"}))
    end

    test "close_reason alone — the arm that makes a legacy row survivable" do
      # 7 of 7 live blockers carry all three, which is what earns this arm: a
      # row closed before the claim machinery still reads as finished, while a
      # forged create carries none of them by accident.
      assert DS.satisfied?(Map.put(@forged, "close_reason", "shipped in PR #1"))
    end

    test "a row that is NOT done is never satisfied, however much provenance it carries" do
      live = %{
        "kind" => "task",
        "lifecycle_status" => "in_progress",
        "claim" => %{"closed_by" => "w-1", "closed_at" => "2026-09-06T00:00:00Z"},
        "close_reason" => "not actually closed"
      }

      refute DS.satisfied?(live)
    end
  end

  describe "the refusal teaches" do
    test "it names the blocker, the half that failed, and the fix" do
      msg = DS.explain("task-abc", @forged)

      assert msg =~ "task-abc"
      assert msg =~ "NO record that a close"
      assert msg =~ "content.claim.closed_by"
      assert msg =~ "content.claim.closed_at"
      assert msg =~ "content.close_reason"
      assert msg =~ "bp task close task-abc"
    end

    test "a not-done blocker gets a DIFFERENT sentence naming its status" do
      msg = DS.explain("task-xyz", %{"lifecycle_status" => "blocked"})
      assert msg =~ "task-xyz is blocked, not done"
      refute msg =~ "NO record that a close"
    end
  end

  describe "the SQL and the Elixir agree — the anti-drift arm" do
    test "both forms return the same verdict on the same fixtures", %{scope: scope} do
      fixtures = [
        {"forged", @forged, false},
        {"closed_by", Map.put(@forged, "claim", %{"closed_by" => "w"}), true},
        {"closed_at", Map.put(@forged, "claim", %{"closed_at" => "2026-09-06T00:00:00Z"}), true},
        {"close_reason", Map.put(@forged, "close_reason", "shipped"), true},
        {"blank_reason", Map.put(@forged, "close_reason", "  "), false},
        {"empty_claim", Map.put(@forged, "claim", %{}), false},
        {"not_done", %{"kind" => "task", "lifecycle_status" => "open"}, false}
      ]

      disagreements =
        for {name, content, _expected} <- fixtures do
          doc_id = uniq("ds-#{name}")

          {:ok, _} =
            Content.create_document(
              "task",
              %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
              @dataset,
              scope
            )

          elixir = DS.satisfied?(content)

          # `Content.create_document/4` stores a `drafts.<id>` row, so a bare
          # `doc_id = $1` finds NOTHING and every SQL answer comes back false.
          # The first run of this test agreed on three fixtures for exactly that
          # reason — false matching false, for different reasons. Match the way
          # queue.ex itself does, prefix-agnostically.
          sql =
            Repo.query!(
              """
              SELECT EXISTS (
                SELECT 1 FROM documents AS done
                WHERE done.type = 'task'
                  AND regexp_replace(done.doc_id, '^drafts\\.', '') = $1
                  AND #{DS.sql_fragment()}
              )
              """,
              [doc_id]
            ).rows
            |> List.first()
            |> List.first()

          {name, elixir, sql}
        end
        |> Enum.reject(fn {_n, e, s} -> e == s end)

      assert disagreements == [],
             """
             the SQL fragment and satisfied?/1 disagree, which means the ready
             queue and the claim door would answer the same question two
             different ways — the exact drift this module exists to prevent.

             {fixture, elixir, sql}: #{inspect(disagreements)}
             """
    end

    test "the SQL side returns BOTH answers — non-vacuity, on the side that failed",
         %{scope: scope} do
      # THE FIRST VERSION OF THIS ARM CHECKED THE WRONG SIDE. It asserted the
      # ELIXIR predicate produced both answers, which it always did — while the
      # SQL half was returning false for EVERY fixture because the query could
      # not find the rows at all. Two predicates agreeing on "no" is not
      # agreement, and the arm that was supposed to catch that was pointed at
      # the half that was working.
      mk = fn content ->
        doc_id = uniq("ds-nv")

        {:ok, _} =
          Content.create_document(
            "task",
            %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
            @dataset,
            scope
          )

        Repo.query!(
          """
          SELECT EXISTS (
            SELECT 1 FROM documents AS done
            WHERE done.type = 'task'
              AND regexp_replace(done.doc_id, '^drafts\\.', '') = $1
              AND #{DS.sql_fragment()}
          )
          """,
          [doc_id]
        ).rows
        |> List.first()
        |> List.first()
      end

      assert mk.(Map.put(@forged, "claim", %{"closed_by" => "w"})),
             "the SQL fragment matched NOTHING — it cannot return true, so any agreement is vacuous"

      refute mk.(@forged),
             "the SQL fragment matched a forged birth — it cannot return false"
    end
  end

  describe "THE CALL SITES — the predicate must be reached, not merely correct" do
    # Mutation 1 on the first attempt reverted queue.ex's SQL and reddened
    # NOTHING, because every test above drove the module directly. A correct
    # predicate that a call site does not reach is not a fix; it is a fix's
    # decoration. These arms drive the SITES.

    defp dep_pair!(scope, blocker_content) do
      blocker = uniq("ds-blocker")
      dependent = uniq("ds-dependent")

      {:ok, b} =
        Content.create_document(
          "task",
          %{"doc_id" => blocker, "title" => blocker, "content" => blocker_content},
          @dataset,
          scope
        )

      {:ok, d} =
        Content.create_document(
          "task",
          %{
            "doc_id" => dependent,
            "title" => dependent,
            "content" => %{
              "kind" => "task",
              "lifecycle_status" => "open",
              "dependencies" => [blocker],
              "acceptance_criteria" => [
                %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "f"}
              ]
            }
          },
          @dataset,
          scope
        )

      # THE TWO SITES READ DIFFERENT SOURCES, which this test discovered the
      # hard way: queue.ex reads `content.dependencies` (a JSON array) while
      # claim.ex reads task_edges via `Edges.dependencies/2`. A fixture that
      # sets only one reaches only one site, and the arm for the other passes
      # while proving nothing. Both are created here.
      {:ok, _} = Barkpark.Tasks.Edges.add_dep(d.id, b.id, :blocks)

      {blocker, dependent}
    end

    defp ready_ids(scope) do
      scope |> Keyword.put(:dataset, @dataset) |> Tasks.ready() |> Enum.map(& &1.doc_id)
    end

    test "QUEUE: a forged done blocker does NOT make its dependent ready", %{scope: scope} do
      {_b, dependent} = dep_pair!(scope, @forged)
      {_b2, free} = dep_pair!(scope, Map.put(@forged, "claim", %{"closed_by" => "w"}))

      ids = ready_ids(scope)

      refute Enum.any?(ids, &String.ends_with?(&1, dependent)),
             "a dependent was made READY by a blocker that only claims to be done"

      # NON-VACUITY: the queue must be returning rows at all, or the refutation
      # above passes for free — the exact accidental agreement this file already
      # caught once between its own SQL and Elixir halves.
      assert Enum.any?(ids, &String.ends_with?(&1, free)),
             "the queue returned no ready dependents at all — the refutation above is vacuous"
    end

    test "CLAIM: the claim door refuses on a forged blocker and allows on an honest one",
         %{scope: scope} do
      {_b, dependent} = dep_pair!(scope, @forged)
      assert {:error, :blocked_by_unsatisfied_deps} = Tasks.claim_by_id(dependent, "w-ds", scope)

      {_b2, ok_dep} = dep_pair!(scope, Map.put(@forged, "close_reason", "shipped in PR #1"))
      assert {:ok, _} = Tasks.claim_by_id(ok_dep, "w-ds", scope)
    end

    test "CLOSE cascade: a dependent stays BLOCKED when a co-blocker is only forged",
         %{scope: scope} do
      # cascade_unblock_dependents!/1 flips a dependent blocked -> open once
      # ALL its blockers are done. With the old predicate a forged co-blocker
      # counted, so closing the honest one unblocked work whose other
      # prerequisite had never been finished by anyone.
      forged = uniq("ds-cb-forged")
      honest = uniq("ds-cb-honest")
      dependent = uniq("ds-cb-dep")

      {:ok, f} =
        Content.create_document(
          "task",
          %{"doc_id" => forged, "title" => forged, "content" => @forged},
          @dataset,
          scope
        )

      {:ok, h} =
        Content.create_document(
          "task",
          %{
            "doc_id" => honest,
            "title" => honest,
            "content" => %{
              "kind" => "task",
              "lifecycle_status" => "open",
              "acceptance_criteria" => [
                %{"criterion" => "bar", "met" => true, "evidence" => "f"}
              ]
            }
          },
          @dataset,
          scope
        )

      {:ok, d} =
        Content.create_document(
          "task",
          %{
            "doc_id" => dependent,
            "title" => dependent,
            "content" => %{"kind" => "task", "lifecycle_status" => "blocked"}
          },
          @dataset,
          scope
        )

      {:ok, _} = Barkpark.Tasks.Edges.add_dep(d.id, f.id, :blocks)
      {:ok, _} = Barkpark.Tasks.Edges.add_dep(d.id, h.id, :blocks)

      {:ok, claimed} = Tasks.claim_by_id(honest, "w-cb", scope)

      {:ok, _} =
        Tasks.close(h.id, "w-cb",
          observed_epoch: claimed.content["claim"]["epoch"],
          lifecycle_status: "done",
          reason: "shipped in PR #1 abc1234"
        )

      after_close = Repo.get!(Barkpark.Content.Document, d.id)

      assert after_close.content["lifecycle_status"] == "blocked",
             """
             the dependent was UNBLOCKED while one of its blockers is a forged
             birth that nobody ever closed. The cascade counted a row that only
             claims to be done.
             """
    end
  end
end
