defmodule Barkpark.Tasks.StageNoteSupersedeTest do
  @moduledoc """
  THE DISPLACEMENT DOOR on `POST /v1/tasks/:doc_id/stage` — the ruling on
  task-d6f3e66b1b829e6e criterion 3.

  `--note` writes `content.disposition_reason` with an unconditional `Map.put`:
  one disposition holds ONE reason, so a second annotator replaced the first's
  text and the row kept no trace. PR #13722 made that RECOVERABLE (the
  `task.staged` event carries `superseded_note`) without making it VISIBLE at
  the moment it happens — and roughly 19 annotations, several reading "do not
  execute this row as written", had already been written through the field by
  agents who did not know the next stage would erase them.

  The ruling: REFUSE the displacing write unless the caller passes
  `--supersede`, and make the refusal SHOW the note it saved. A refusal that
  only said "no" would send the caller straight back with the destructive flag
  without ever reading what they were about to destroy, which is the failure
  the door exists to prevent.

  Proves, in this order:

    * a `--note` over a DIFFERENT non-blank reason, without `--supersede`, is a
      409 whose body carries the existing note's TEXT and names the flag — and
      the row's `disposition_reason` is byte-identical afterwards;
    * a long note is EXCERPTED, not dropped: the refusal still carries real
      text plus the true length and a truncation marker;
    * `--supersede` replaces, and the `task.staged` event carries
      `superseded_note` (the receipt arms themselves live in `stage_test.exs`
      — "task.staged carries the note it SUPERSEDED" and its note-less control
      — and are NOT duplicated here; this arm proves only that the flag is what
      re-opens that path);
    * a stage over a BLANK or ABSENT reason is NOT refused (a blank overwrites
      nothing);
    * a stage with NO note is NOT refused, on a row that carries a reason (a
      note-less stage never touches the field);
    * a RE-STAGE WITH THE SAME TEXT is NOT refused — the door protects text,
      and rewriting a string with itself loses none.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}

  @token "barkpark-test-stage-supersede-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-stage-supersede", "test", ["read", "write", "admin"])
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

  @caution "DO NOT EXECUTE THIS ROW AS WRITTEN — the fixture it names was deleted in #14201."

  describe "a --note that would displace a non-blank reason" do
    test "is REFUSED, SHOWS the note it would have destroyed, and names --supersede",
         %{conn: conn, scope: scope} do
      doc_id = uniq("supersede-refuse")
      task = mk_task!(doc_id, scope, %{"disposition_reason" => @caution})

      resp = stage(conn, doc_id, %{state: "considering", note: "re-adjudicated: looks fine to me"})

      assert resp.status == 409
      body = json_response(resp, 409)
      assert body["ok"] == false
      assert body["reason"] == "note_would_supersede"

      # (a) THE REFUSAL CARRIES THE TEXT. This is the whole point: a bare "no"
      # makes the caller re-run with --supersede without reading what they are
      # about to destroy.
      assert body["existing_note"] == @caution
      assert body["existing_note_length"] == String.length(@caution)
      assert body["existing_note_truncated"] == false
      assert body["message"] =~ @caution

      # ...and the remedy, and the recovery channel, by name.
      assert body["message"] =~ "--supersede"
      assert body["message"] =~ "bp task events --payload"
      assert body["message"] =~ "payload.staged.superseded_note"

      # NOTHING WAS WRITTEN. The refusal happens before the CAS update, so the
      # row is exactly as it was — reason, and lifecycle_status too.
      row = reload(task)
      assert row.content["disposition_reason"] == @caution
      assert row.content["lifecycle_status"] == "open"
      refute Map.has_key?(row.content, "engagement")

      # A refused stage emits no receipt either.
      assert staged_events(task) == []
    end

    test "EXCERPTS a long existing note rather than dropping or inlining it whole",
         %{conn: conn, scope: scope} do
      # Notes of 1228 chars are on the live ledger. The refusal must still be
      # readable AND still tell the truth about the length.
      long = String.duplicate("caution ", 200)
      doc_id = uniq("supersede-long")
      task = mk_task!(doc_id, scope, %{"disposition_reason" => long})

      body =
        conn
        |> stage(doc_id, %{state: "considering", note: "replacing the long one"})
        |> json_response(409)

      assert body["reason"] == "note_would_supersede"
      assert body["existing_note_truncated"] == true
      assert body["existing_note_length"] == String.length(long)
      # Bounded, but NOT empty — the caller sees real text, not a placeholder.
      assert String.length(body["existing_note"]) < String.length(long)
      assert String.starts_with?(body["existing_note"], "caution caution")
      assert String.ends_with?(body["existing_note"], "…")
      assert body["message"] =~ "shown truncated"

      assert reload(task).content["disposition_reason"] == long
    end
  end

  describe "what --supersede buys, and what is never refused" do
    test "--supersede replaces, and the receipt carries superseded_note",
         %{conn: conn, scope: scope} do
      # The receipt's OWN arms live in stage_test.exs ("task.staged carries the
      # note it SUPERSEDED" + the note-less control). This arm proves only the
      # new gate: the flag is what re-opens that path.
      doc_id = uniq("supersede-allow")
      task = mk_task!(doc_id, scope, %{"disposition_reason" => @caution})

      assert stage(conn, doc_id, %{
               state: "considering",
               note: "SECOND: superseded on purpose",
               supersede: true
             }).status == 200

      assert reload(task).content["disposition_reason"] == "SECOND: superseded on purpose"

      [ev] = staged_events(task)
      assert ev.document["staged"]["note"] == "SECOND: superseded on purpose"
      assert ev.document["staged"]["superseded_note"] == @caution
    end

    test "a stage over a BLANK or ABSENT reason is not refused",
         %{conn: conn, scope: scope} do
      absent = mk_task!(uniq("supersede-absent"), scope)
      assert stage(conn, absent.doc_id, %{state: "considering", note: "first reason"}).status == 200
      assert reload(absent).content["disposition_reason"] == "first reason"

      blank = mk_task!(uniq("supersede-blank"), scope, %{"disposition_reason" => "   "})

      assert stage(conn, blank.doc_id, %{
               state: "considering",
               note: "a blank reason held nothing to destroy"
             }).status == 200

      assert reload(blank).content["disposition_reason"] ==
               "a blank reason held nothing to destroy"
    end

    test "a stage with NO note never refuses, even on a row carrying a reason",
         %{conn: conn, scope: scope} do
      doc_id = uniq("supersede-nonote")
      task = mk_task!(doc_id, scope, %{"disposition_reason" => @caution})

      assert stage(conn, doc_id, %{state: "considering", worker: "cycle-9"}).status == 200
      assert reload(task).content["disposition_reason"] == @caution

      # A BLANK note is no note either — normalize_note collapsed it long
      # before the door, so there is nothing to refuse.
      assert stage(conn, doc_id, %{state: "researching", note: "   "}).status == 200
      assert reload(task).content["disposition_reason"] == @caution
    end

    test "a re-stage with the SAME text is not refused (it destroys nothing)",
         %{conn: conn, scope: scope} do
      doc_id = uniq("supersede-same")
      task = mk_task!(doc_id, scope, %{"disposition_reason" => @caution})

      assert stage(conn, doc_id, %{state: "considering", note: @caution}).status == 200
      assert reload(task).content["disposition_reason"] == @caution
    end
  end

  describe "the manifest tells callers about the door" do
    test "the --note and --supersede flag help state the refusal, the remedy and the recovery" do
      stage_cmd =
        Barkpark.Plugins.Tasks.cli_commands()
        |> Enum.find(&(&1.id == "task.stage"))

      flags = Map.new(stage_cmd.flags, &{&1.name, &1})

      note = Map.fetch!(flags, "note").summary
      # (b) The BREAKING CHANGE is stated in the help, not only in a PR body.
      assert note =~ "BREAKING CHANGE"
      assert note =~ "note_would_supersede"
      assert note =~ "--supersede"
      # The recovery sentence #16557's parser reads: a backticked bp command
      # and a backticked payload path, both intact.
      assert note =~ "recoverable from `bp task events --payload` as `payload.staged.superseded_note`"

      supersede = Map.fetch!(flags, "supersede")
      assert supersede.type == "bool"
      assert supersede.summary =~ "note_would_supersede"
      assert supersede.summary =~ "payload.staged.superseded_note"
    end
  end
end
