defmodule Barkpark.Tasks.StageRerunOrphanTest do
  @moduledoc """
  THE RERUN BINDING DOOR and THE RERUN SUBTRACTION DOOR on
  `POST /v1/tasks/:doc_id/stage` — the SERVER half of task-5509618e1868d9f2,
  filed as task-fcc590f205433209 (PDS-D750).

  `content.disposition_rerun` is not free-standing: it is the one command an
  auditor can run to try to prove THIS ROW'S REASON wrong. Superseding the
  reason while saying nothing about the probe therefore leaves the row carrying
  a GREEN, RECENT, SYMBOL-SPECIFIC check attached to a claim it no longer
  makes — strictly worse than carrying no rerun at all, because an absent rerun
  is an honest "this reason refuses to be checked" while an orphaned one passes
  about something nobody asserted. The parent filing measured 136 such rows on
  the ledger, 125 of them minted by exactly this call shape.

  A client-side guard for the same shape shipped in the Go CLI
  (`internal/cli/tasks_stage_rerun_guard.go`, PR #18784). It lives in the
  CLIENT, so every other door walks past it: `/v1/tasks/:id/stage` called
  directly, the MCP task tools, and any older `bp` on a box. This file is the
  door at the WRITE SEAM.

  Proves, in this order:

    * a `--supersede`d `--note` over a row carrying a rerun is a 409
      `rerun_would_orphan` quoting the rerun IN FULL — and the row reads back
      byte-identical on BOTH keys, because the refusal runs under the advisory
      lock BEFORE the CAS;
    * `--supersede` ALONE never satisfies it; `--rerun`, `--clear-rerun` and
      `--keep-rerun` each do, and each leaves the field in the state it names;
    * `--clear-rerun` REMOVES the key (absent, not `nil`) — the only door that
      can, since `--rerun ""` is blank-is-absent and `/v1/data/mutate` refuses
      the key by name;
    * `--rerun` and `--clear-rerun` in one call is a 422 `contradictory_rerun`
      with nothing written;
    * the QUIET shapes stay green: no note, a blank/absent existing reason, a
      same-text re-stage, a row with no rerun;
    * NO distinctness refusal is added — a SHARED rerun across two distinct
      rows still writes (PDS-D391b(b) / PDS-D336(a)).
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}

  @token "barkpark-test-stage-rerun-orphan-token"
  @dataset "production"

  # A rerun of exactly the shape the filing measured: green, recent, and
  # symbol-specific, so an orphaned one reads as a live check.
  @rerun "git cat-file -e origin/main:internal/cli/tasks_adjudication.go"
  @other_rerun "git grep -n guardStageRerunOrphan origin/main -- internal/cli"

  @reason_a "REASON A: tasks_adjudication.go exists on origin/main, so the vocabulary screen ships."
  @reason_c "REASON C: THE RULING — pick it up. Nothing here turns on any file or symbol."

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-stage-rerun-orphan", "test", ["read", "write", "admin"])

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

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ],
          "lifecycle_status" => "open"
        },
        content_extra
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp stage(conn, doc_id, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/tasks/#{doc_id}/stage", Jason.encode!(body))
  end

  defp reload(%Document{id: id}), do: Repo.get!(Document, id)

  defp staged_events(%Document{doc_id: doc_id}) do
    Repo.all(
      from(e in MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == "task.staged",
        order_by: [asc: e.id]
      )
    )
  end

  # The fixture the whole file turns on: a row that has BOTH a reason and the
  # probe that binds it. Asserting the setup rather than trusting the create —
  # a door tested against a row that never carried a rerun measures nothing.
  defp task_with_bound_rerun!(prefix, scope) do
    doc_id = uniq(prefix)

    task =
      mk_task!(doc_id, scope, %{
        "disposition_reason" => @reason_a,
        "disposition_rerun" => @rerun
      })

    assert task.content["disposition_reason"] == @reason_a
    assert task.content["disposition_rerun"] == @rerun
    {doc_id, task}
  end

  describe "superseding a reason over a bound rerun" do
    test "is REFUSED 409, quotes the rerun IN FULL, and writes NOTHING on either key",
         %{conn: conn, scope: scope} do
      {doc_id, task} = task_with_bound_rerun!("rerun-orphan-refuse", scope)

      resp = stage(conn, doc_id, %{state: "open", note: @reason_c, supersede: true})

      assert resp.status == 409
      body = json_response(resp, 409)
      assert body["ok"] == false
      assert body["reason"] == "rerun_would_orphan"
      assert body["field"] == "disposition_rerun"

      # (a) THE REFUSAL CARRIES THE PROBE, IN FULL. A truncated command cannot
      # be judged, and judging whether it still binds is the entire decision.
      assert body["existing_rerun"] == @rerun
      assert body["message"] =~ @rerun

      # (b) ...and names all three doors that leave the row honest.
      assert body["message"] =~ "--rerun"
      assert body["message"] =~ "--clear-rerun"
      assert body["message"] =~ "--keep-rerun"

      # (c) NOTHING WAS WRITTEN. The check runs under the advisory lock and
      # BEFORE the CAS, so the row is byte-identical on BOTH keys — and on the
      # status, which this stage also asked to change.
      after_doc = reload(task)
      assert after_doc.content["disposition_rerun"] == @rerun
      assert after_doc.content["disposition_reason"] == @reason_a
      assert after_doc.content["lifecycle_status"] == "open"
      assert staged_events(task) == []
    end

    test "--supersede ALONE never satisfies it — the note guard is a different lock",
         %{conn: conn, scope: scope} do
      {doc_id, task} = task_with_bound_rerun!("rerun-orphan-supersede-alone", scope)

      # WITHOUT --supersede the NOTE guard answers first: one refusal per call,
      # and the note is the thing the caller must read first.
      no_flag = stage(conn, doc_id, %{state: "open", note: @reason_c})
      assert json_response(no_flag, 409)["reason"] == "note_would_supersede"

      # WITH --supersede the note guard steps aside and this door refuses. That
      # is the point: one key to both locks is one slot wearing a costume.
      with_flag = stage(conn, doc_id, %{state: "open", note: @reason_c, supersede: true})
      assert json_response(with_flag, 409)["reason"] == "rerun_would_orphan"

      assert reload(task).content["disposition_rerun"] == @rerun
    end
  end

  describe "the three doors through" do
    test "--rerun re-binds the probe and the stage lands", %{conn: conn, scope: scope} do
      {doc_id, task} = task_with_bound_rerun!("rerun-orphan-rebind", scope)

      resp =
        stage(conn, doc_id, %{
          state: "open",
          note: @reason_c,
          supersede: true,
          rerun: @other_rerun
        })

      assert resp.status == 200
      after_doc = reload(task)
      assert after_doc.content["disposition_reason"] == @reason_c
      assert after_doc.content["disposition_rerun"] == @other_rerun
    end

    test "--keep-rerun lands and leaves the EXISTING probe byte-identical",
         %{conn: conn, scope: scope} do
      {doc_id, task} = task_with_bound_rerun!("rerun-orphan-keep", scope)

      resp =
        stage(conn, doc_id, %{
          state: "open",
          note: @reason_c,
          supersede: true,
          keep_rerun: true
        })

      assert resp.status == 200
      after_doc = reload(task)
      assert after_doc.content["disposition_reason"] == @reason_c
      assert after_doc.content["disposition_rerun"] == @rerun
    end

    test "--clear-rerun REMOVES the key — it is ABSENT, not nil", %{conn: conn, scope: scope} do
      {doc_id, task} = task_with_bound_rerun!("rerun-orphan-clear", scope)

      resp =
        stage(conn, doc_id, %{
          state: "open",
          note: @reason_c,
          supersede: true,
          clear_rerun: true
        })

      assert resp.status == 200
      after_doc = reload(task)
      assert after_doc.content["disposition_reason"] == @reason_c

      # ABSENCE, not a stored null: a rerun written as nil reads as
      # present-and-null to every consumer that tests for the key, and
      # PDS-D750's REMOVE arm needs the key gone.
      refute Map.has_key?(after_doc.content, "disposition_rerun")

      # The subtraction says its own name on the receipt — a payload that only
      # echoes what was WRITTEN cannot show a removal.
      [event] = staged_events(task)
      assert event.document["staged"]["disposition_rerun_cleared"] == true
    end

    test "--clear-rerun works with no note at all, and is the only door that can subtract",
         %{conn: conn, scope: scope} do
      {doc_id, task} = task_with_bound_rerun!("rerun-clear-bare", scope)

      # THE CONTROL, measured on guerrilla 2026-09-17 and re-measured here: a
      # BLANK --rerun is a no-op, not a clear. Without --clear-rerun there is
      # no subtraction anywhere.
      blank = stage(conn, doc_id, %{state: "open", rerun: ""})
      assert blank.status == 200
      assert reload(task).content["disposition_rerun"] == @rerun

      cleared = stage(conn, doc_id, %{state: "open", clear_rerun: true})
      assert cleared.status == 200
      refute Map.has_key?(reload(task).content, "disposition_rerun")
    end
  end

  describe "one key, two intentions" do
    test "--rerun WITH --clear-rerun is a 422 contradictory_rerun and writes nothing",
         %{conn: conn, scope: scope} do
      {doc_id, task} = task_with_bound_rerun!("rerun-contradiction", scope)

      resp =
        stage(conn, doc_id, %{
          state: "open",
          rerun: @other_rerun,
          clear_rerun: true
        })

      assert resp.status == 422
      body = json_response(resp, 422)
      assert body["reason"] == "contradictory_rerun"
      assert body["message"] =~ "--clear-rerun"

      assert reload(task).content["disposition_rerun"] == @rerun
      assert staged_events(task) == []
    end
  end

  describe "the quiet shapes" do
    test "a stage with NO note over a bound rerun is untouched", %{conn: conn, scope: scope} do
      {doc_id, task} = task_with_bound_rerun!("rerun-quiet-nonote", scope)

      assert stage(conn, doc_id, %{state: "considering"}).status == 200
      after_doc = reload(task)
      assert after_doc.content["disposition_rerun"] == @rerun
      assert after_doc.content["disposition_reason"] == @reason_a
    end

    test "a same-text re-stage is not a displacement", %{conn: conn, scope: scope} do
      {doc_id, task} = task_with_bound_rerun!("rerun-quiet-sametext", scope)

      assert stage(conn, doc_id, %{state: "open", note: @reason_a}).status == 200
      assert reload(task).content["disposition_rerun"] == @rerun
    end

    test "a row whose reason is blank/absent has nothing to displace",
         %{conn: conn, scope: scope} do
      doc_id = uniq("rerun-quiet-noreason")
      task = mk_task!(doc_id, scope, %{"disposition_rerun" => @rerun})

      assert stage(conn, doc_id, %{state: "open", note: @reason_c, supersede: true}).status == 200
      after_doc = reload(task)
      assert after_doc.content["disposition_reason"] == @reason_c
      assert after_doc.content["disposition_rerun"] == @rerun
    end

    test "a row carrying NO rerun supersedes exactly as it does today",
         %{conn: conn, scope: scope} do
      doc_id = uniq("rerun-quiet-norerun")
      task = mk_task!(doc_id, scope, %{"disposition_reason" => @reason_a})

      assert stage(conn, doc_id, %{state: "open", note: @reason_c, supersede: true}).status == 200
      assert reload(task).content["disposition_reason"] == @reason_c
    end
  end

  describe "no distinctness refusal (PDS-D391b(b) / PDS-D336(a))" do
    test "the SAME rerun over two distinct rows still writes", %{conn: conn, scope: scope} do
      one = uniq("rerun-shared-one")
      two = uniq("rerun-shared-two")
      task_one = mk_task!(one, scope)
      task_two = mk_task!(two, scope)

      assert stage(conn, one, %{state: "open", note: @reason_a, rerun: @rerun}).status == 200
      assert stage(conn, two, %{state: "open", note: @reason_c, rerun: @rerun}).status == 200

      assert reload(task_one).content["disposition_rerun"] == @rerun
      assert reload(task_two).content["disposition_rerun"] == @rerun
    end
  end
end
