defmodule BarkparkWeb.TasksDischargesTest do
  @moduledoc """
  Contract tests for `POST /v1/tasks/:doc_id/discharges` — the BACK-LINK mark
  (task-29781d0921e5a885), written as the WIRE the push-to-main workflow calls:
  a plain write-capable bearer, NO worker_id and NO observed_epoch, over HTTP.

  Two properties carry this suite, and they pull in opposite directions:

    * NON-VACUITY — a PR citing TWO rows marks BOTH; a PR citing ONE marks ONE.
      A fan-out that silently stopped after the first citation would leave the
      sibling row exactly as blind as it is today, and every "the endpoint
      answers 200" assertion would still pass. So the counts are asserted, and
      the failure messages name the row that is missing.

    * THE FENCE — the mark NEVER sets `met`, never writes evidence, never moves
      lifecycle_status, the claim or the disposition. That is asserted
      STRUCTURALLY: the stored content after the write must equal the content
      before it, byte for byte, once the one `discharge_marks` key is removed.
      Any extra key this handler learns to write reds that assertion, which is
      what makes "it cannot touch met" a measurement instead of a promise.

  Assertions read the STORE, never the envelope alone — this ledger has watched
  a task verb return a 2xx over a write the store did not hold.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-tasks-discharges-token"
  @dataset "production"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-tasks-discharges", "test", ["read", "write", "admin"])

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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(scope, content_extra \\ %{}) do
    doc_id = uniq("discharge-conn")

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
                "assignee" => "builder-x",
                "acceptance_criteria" => [
                  %{"criterion" => "the first bar", "met" => true, "evidence" => "fixture"},
                  %{"criterion" => "the second bar", "met" => false, "evidence" => ""}
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

  defp stored(task), do: Repo.get!(Document, task.id)
  defp content_of(task), do: stored(task).content

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp post_discharges(conn, primary, body) do
    resp =
      conn
      |> authed()
      |> post("/v1/tasks/#{primary.doc_id}/discharges", Jason.encode!(body))

    {resp.status, Jason.decode!(resp.resp_body)}
  end

  defp marks_at(task, index) do
    task
    |> content_of()
    |> Map.fetch!("acceptance_criteria")
    |> Enum.at(index)
    |> Map.get("discharge_marks", [])
  end

  defp statuses(body), do: Map.new(body["marks"], &{&1["task"], &1["status"]})

  describe "NON-VACUITY: the number of rows marked is the number of rows cited" do
    test "a PR citing TWO rows marks BOTH", %{conn: conn, scope: scope} do
      primary = mk_task!(scope)
      a = mk_task!(scope)
      b = mk_task!(scope)

      pr_body = """
      fix(tasks): the thing (#16640)

      Discharges: #{a.doc_id} c1
      Discharges: `#{b.doc_id}` c1

      Task: #{primary.doc_id}
      """

      assert {200, body} =
               post_discharges(conn, primary, %{
                 pr: "16640",
                 commit: "b897f1889abcdef",
                 body: pr_body
               })

      assert body["ok"] == true
      assert body["cited"] == 2
      assert body["marked"] == 2, "expected both cited rows marked, got #{inspect(body["marks"])}"

      assert statuses(body) == %{a.doc_id => "marked", b.doc_id => "marked"}

      for row <- [a, b] do
        [mark] = marks_at(row, 1)

        assert mark["pr"] == "16640",
               "row #{row.doc_id} carries no PR number on its back-link mark"

        assert mark["commit"] == "b897f1889abcdef"
        assert mark["primary"] == primary.doc_id

        assert mark["note"] =~
                 "possibly discharged by PR #16640 (b897f1889a) under row " <>
                   primary.doc_id

        assert mark["note"] =~ "verify against origin/main"
        assert is_binary(mark["at"])
      end
    end

    test "a PR citing ONE row marks exactly ONE — the other row is untouched",
         %{conn: conn, scope: scope} do
      primary = mk_task!(scope)
      a = mk_task!(scope)
      b = mk_task!(scope)

      before_b = content_of(b)

      assert {200, body} =
               post_discharges(conn, primary, %{
                 pr: "16641",
                 commit: "deadbeef1234",
                 body: "Discharges: #{a.doc_id} c1\n\nTask: #{primary.doc_id}\n"
               })

      assert body["cited"] == 1
      assert body["marked"] == 1
      assert statuses(body) == %{a.doc_id => "marked"}

      assert length(marks_at(a, 1)) == 1
      assert marks_at(b, 1) == [], "row #{b.doc_id} was never cited and must carry no mark"
      assert content_of(b) == before_b
    end

    test "a PR citing NO row marks nothing and is still a 200", %{conn: conn, scope: scope} do
      primary = mk_task!(scope)

      assert {200, body} =
               post_discharges(conn, primary, %{
                 pr: "16642",
                 commit: "cafebabe0001",
                 body: "fix: an ordinary PR (#16642)\n\nTask: #{primary.doc_id}\n"
               })

      assert body["cited"] == 0
      assert body["marked"] == 0
      assert body["marks"] == []
    end
  end

  describe "THE FENCE: a back-link is evidence, never a verdict" do
    test "the mark does NOT set met, does NOT write evidence, and changes NOTHING else",
         %{conn: conn, scope: scope} do
      primary = mk_task!(scope)
      # A LIVE, NON-REAPABLE claim: `ts_iso` is fresh on purpose. A claim map
      # with no ts_iso is exactly what `Tasks.TtlSweeper` reaps as malformed,
      # and a fixture that invites the shared-database sweeper to touch it is a
      # fixture that can fail for a reason this suite is not about.
      a =
        mk_task!(scope, %{
          "claim" => %{
            "worker" => "builder-x",
            "epoch" => 3,
            "ts_iso" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        })

      before_content = content_of(a)

      assert {200, _} =
               post_discharges(conn, primary, %{
                 pr: "16643",
                 commit: "0123456789ab",
                 body: "Discharges: #{a.doc_id} c1\n"
               })

      after_content = content_of(a)

      # The criterion the citation named: met and evidence are the holder's,
      # and they did not move.
      cited = after_content |> Map.fetch!("acceptance_criteria") |> Enum.at(1)
      assert cited["met"] == false
      assert cited["evidence"] == ""

      # The met COUNT over the whole row is unchanged — the number `bp task get`
      # prints and a lead reads as progress.
      met_count = fn c ->
        c |> Map.fetch!("acceptance_criteria") |> Enum.count(&(&1["met"] == true))
      end

      assert met_count.(after_content) == met_count.(before_content)

      # Lifecycle, claim, disposition, assignee, labels: untouched.
      assert after_content["lifecycle_status"] == before_content["lifecycle_status"]
      assert after_content["claim"] == before_content["claim"]
      assert after_content["assignee"] == before_content["assignee"]
      assert after_content["disposition_reason"] == before_content["disposition_reason"]
      assert after_content["labels"] == before_content["labels"]

      # THE STRUCTURAL ARM. Strip the one key this verb is allowed to add and
      # the content must be IDENTICAL to what it was. A handler that learns to
      # write anything else — met, a label, a lifecycle move — reds here even if
      # every named assertion above is somehow satisfied.
      stripped =
        Map.update!(after_content, "acceptance_criteria", fn list ->
          Enum.map(list, &Map.delete(&1, "discharge_marks"))
        end)

      assert stripped == before_content
    end

    test "a citation with NO criterion index lands a note and leaves the criteria alone",
         %{conn: conn, scope: scope} do
      primary = mk_task!(scope)
      a = mk_task!(scope)

      before_criteria = content_of(a)["acceptance_criteria"]

      assert {200, body} =
               post_discharges(conn, primary, %{
                 pr: "16644",
                 commit: "abcdef012345",
                 body: "Discharges: #{a.doc_id}\n"
               })

      assert statuses(body) == %{a.doc_id => "marked"}

      after_content = content_of(a)
      assert after_content["acceptance_criteria"] == before_criteria

      [note] = after_content["landed"]["notes"]
      assert note =~ "possibly discharged by PR #16644"
      assert note =~ "under row #{primary.doc_id}"

      # `commits` is NOT written by a back-link: that key means "THIS row's work
      # landed as this sha", which is a different and stronger claim.
      refute Map.has_key?(after_content["landed"], "commits")
    end
  end

  describe "the edges" do
    test "the SAME landing posted twice marks once — the second is `already`",
         %{conn: conn, scope: scope} do
      primary = mk_task!(scope)
      a = mk_task!(scope)

      payload = %{
        pr: "16645",
        commit: "feedface0001",
        body: "Discharges: #{a.doc_id} c1\n"
      }

      assert {200, first} = post_discharges(conn, primary, payload)
      assert statuses(first) == %{a.doc_id => "marked"}

      assert {200, second} = post_discharges(conn, primary, payload)
      assert statuses(second) == %{a.doc_id => "already"}
      assert second["marked"] == 0

      assert length(marks_at(a, 1)) == 1, "a re-run must not stack a duplicate mark"
    end

    test "a SECOND, different PR accumulates a second mark", %{conn: conn, scope: scope} do
      primary = mk_task!(scope)
      a = mk_task!(scope)

      assert {200, _} =
               post_discharges(conn, primary, %{
                 pr: "1",
                 commit: "aaaaaaaaaaaa",
                 body: "Discharges: #{a.doc_id} c1\n"
               })

      assert {200, _} =
               post_discharges(conn, primary, %{
                 pr: "2",
                 commit: "bbbbbbbbbbbb",
                 body: "Discharges: #{a.doc_id} c1\n"
               })

      assert Enum.map(marks_at(a, 1), & &1["pr"]) == ["1", "2"]
    end

    test "a cited row that does not exist is reported, and does not lose the marks that landed",
         %{conn: conn, scope: scope} do
      primary = mk_task!(scope)
      a = mk_task!(scope)

      assert {200, body} =
               post_discharges(conn, primary, %{
                 pr: "16646",
                 commit: "0f0f0f0f0f0f",
                 body: "Discharges: task-does-not-exist-anywhere c1\nDischarges: #{a.doc_id} c1\n"
               })

      assert statuses(body) == %{
               "task-does-not-exist-anywhere" => "not_found",
               a.doc_id => "marked"
             }

      assert body["marked"] == 1
      assert length(marks_at(a, 1)) == 1
    end

    test "a criterion index past the end of the row is reported, not written",
         %{conn: conn, scope: scope} do
      primary = mk_task!(scope)
      a = mk_task!(scope)
      before_content = content_of(a)

      assert {200, body} =
               post_discharges(conn, primary, %{
                 pr: "16647",
                 commit: "1a1a1a1a1a1a",
                 body: "Discharges: #{a.doc_id} c99\n"
               })

      assert statuses(body) == %{a.doc_id => "criteria_index_out_of_range"}
      assert content_of(a) == before_content
    end

    test "a PR citing its OWN trailer row marks nothing on it", %{conn: conn, scope: scope} do
      primary = mk_task!(scope)
      before_content = content_of(primary)

      assert {200, body} =
               post_discharges(conn, primary, %{
                 pr: "16648",
                 commit: "2b2b2b2b2b2b",
                 body: "Discharges: #{primary.doc_id} c1\n"
               })

      assert statuses(body) == %{primary.doc_id => "self"}
      assert content_of(primary) == before_content
    end

    test "an unknown PRIMARY row is a 404", %{conn: conn, scope: scope} do
      a = mk_task!(scope)

      resp =
        conn
        |> authed()
        |> post(
          "/v1/tasks/task-no-such-primary/discharges",
          Jason.encode!(%{pr: "1", commit: "c", body: "Discharges: #{a.doc_id} c1\n"})
        )

      assert resp.status == 404
      assert marks_at(a, 1) == []
    end

    test "neither a PR nor a commit is refused per row — a mark that names nothing is useless",
         %{conn: conn, scope: scope} do
      primary = mk_task!(scope)
      a = mk_task!(scope)

      assert {200, body} =
               post_discharges(conn, primary, %{body: "Discharges: #{a.doc_id} c1\n"})

      assert statuses(body) == %{a.doc_id => "empty_discharge"}
      assert marks_at(a, 1) == []
    end
  end
end
