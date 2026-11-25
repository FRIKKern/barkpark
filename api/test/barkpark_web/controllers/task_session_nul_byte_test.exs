defmodule BarkparkWeb.TaskSessionNulByteTest do
  @moduledoc """
  task-b456c48d916f7cbc (#28712 review): the task verbs' write door
  (`Tasks.Internal.fenced_content_write/4`) and the session trail's
  (`Content.Sessions.append_event/5`, `touch_conversation/5`) skip
  `Document.changeset/2`, so a NUL in a stamp's evidence, a label or a
  session note still reached Postgres (22P05) and answered 500. They now
  refuse it as the changeset does: 422 `validation_failed` naming the field
  and the path, and nothing is written.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.{NulByteError, Sessions}

  @dataset "production"
  @token "nul-byte-task-session-write"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    {:ok, _} = Auth.create_token(@token, "nul-byte", @dataset, ["write"], ws.id)

    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "nul-byte-task-#{System.unique_integer([:positive])}",
          "title" => "nul byte",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [
              %{"criterion" => "it holds", "met" => false, "evidence" => ""}
            ]
          }
        },
        @dataset,
        scope
      )

    %{task: task, scope: scope}
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp stored(task, scope) do
    {:ok, doc} = Content.get_document(task.doc_id, "task", @dataset, scope)
    doc
  end

  test "a stamp whose evidence holds a NUL is a 422 naming the path, not a 500",
       %{conn: conn, task: task, scope: scope} do
    claim = post_json(conn, "/v1/tasks/#{task.doc_id}/claim", %{worker_id: "builder"})
    epoch = claim.resp_body |> Jason.decode!() |> get_in(["doc", "claim", "epoch"])
    before = stored(task, scope)

    {422, _headers, raw} =
      assert_error_sent(422, fn ->
        post_json(build_conn(), "/v1/tasks/#{task.doc_id}/stamp", %{
          worker_id: "builder",
          observed_epoch: epoch,
          criterion: 0,
          criterion_text: "it holds",
          met: true,
          evidence: "landed a\u0000b"
        })
      end)

    error = Jason.decode!(raw)["error"]
    assert error["code"] == "validation_failed"
    assert %{"content" => [message]} = error["details"]
    assert message =~ ~r|^holds a NUL byte at /acceptance_criteria/0/|
    refute message =~ "\u0000"

    after_ = stored(task, scope)
    assert after_.rev == before.rev
    assert after_.content["acceptance_criteria"] == before.content["acceptance_criteria"]
  end

  test "a label holding a NUL is refused at its path", %{task: task, scope: scope} do
    error =
      assert_raise NulByteError, fn -> Tasks.relabel_by_id(task.id, ["bad\u0000label"], []) end

    assert error.field == :content
    assert error.message =~ ~r|^holds a NUL byte at /labels/\d+$|
    assert stored(task, scope).rev == task.rev
  end

  describe "a session" do
    setup do
      slug = "session-nul-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_blocks_doc("session", %{"slug" => slug, "title" => "N", "status" => "open"})

      %{slug: slug}
    end

    test "an event whose note holds a NUL is refused, and the trail is kept", %{slug: slug} do
      assert {:ok, %{count: 1}} = Sessions.append_event(slug, "note", %{"note" => "ok"})

      error =
        assert_raise NulByteError, fn ->
          Sessions.append_event(slug, "note", %{"note" => "a\u0000b"})
        end

      assert error.message == "holds a NUL byte at /events/1/note"

      assert [%{"note" => "ok"}] =
               Content.get_blocks_doc(slug, "session", @dataset).content["events"]
    end

    test "a conversation whose machine holds a NUL is refused", %{slug: slug} do
      error =
        assert_raise NulByteError, fn ->
          Sessions.touch_conversation(slug, "conv-1", %{"machine" => "mbp\u0000"})
        end

      assert error.message == "holds a NUL byte at /conversations/0/machine"

      assert Content.get_blocks_doc(slug, "session", @dataset).content["conversations"] in [
               nil,
               []
             ]
    end
  end
end
