defmodule BarkparkWeb.ChatAnswerClaimTest do
  @moduledoc """
  `POST /v1/chat/sessions/:id/answer` claims the question through
  `ApprovalAnswer.settle/4` before it sends anything (task-52de5429fbdcb68c).

  The route reads the pending question to validate the answer, with no lock.
  Before, it then sent the answer and flipped the row, so a cancel that
  committed after that read still had the answer sent, and the route said 204
  over a canceled ask. Now the claim takes the row lock and re-reads it: a
  question canceled since the read is the route's 404, and nothing is sent.

  The sandbox puts every process on ONE connection, so this runs `unboxed_run`
  on real connections and removes its rows itself. A holder connection cancels
  the question and keeps its transaction open, so the request is provably
  waiting on the row lock before the cancel commits.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.LockWaiter
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Message, Session}

  @ask %{
    "questions" => [%{"question" => "Which color?", "options" => [%{"label" => "Blue"}]}]
  }

  test "an answer whose question is canceled while it waits is a 404 and leaves it canceled" do
    with_question(fn raw, sid ->
      holder = hold(fn -> 1 = StudioChat.cancel_pending_approvals(sid) end)
      {request, backend} = LockWaiter.start(fn -> answer(raw, sid) end)

      LockWaiter.await_lock!(backend)
      release(holder)

      resp = Task.await(request, 10_000)
      assert resp.status == 404, "a canceled question answered #{resp.status}: #{resp.resp_body}"

      assert StudioChat.get_needs_you_message(sid, "q-1").metadata["approval_status"] ==
               "canceled"
    end)
  end

  test "an answer to a pending question with no live runtime still records it and 204s" do
    # Already on with_question's unboxed connection: a nested unboxed_run would
    # check it in and roll this test's cleanup back (task-23b6ba92b28c809a).
    with_question(fn raw, sid ->
      assert answer(raw, sid).status == 204
      assert StudioChat.get_needs_you_message(sid, "q-1").metadata["approval_status"] == "allowed"
    end)
  end

  defp answer(raw, sid) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/chat/sessions/#{sid}/answer",
      Jason.encode!(%{request_id: "q-1", answers: %{"Which color?" => "Blue"}})
    )
  end

  defp with_question(fun) do
    unboxed(fn ->
      raw = "answer-claim-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "answer-claim", "production", ~w(read write admin))
      {:ok, session} = StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: "/tmp/x"})

      {:ok, _} =
        StudioChat.append_message(session, %{
          role: "question",
          source_markdown: "AskUserQuestion",
          metadata: %{
            "request_id" => "q-1",
            "tool_name" => "AskUserQuestion",
            "input" => @ask,
            "approval_status" => "pending"
          }
        })

      try do
        fun.(raw, session.id)
      after
        Repo.delete_all(from m in Message, where: m.session_id == ^session.id)
        Repo.delete_all(from s in Session, where: s.id == ^session.id)
        Repo.delete_all(from t in ApiToken, where: t.id == ^token.id)
      end
    end)
  end

  defp hold(take) do
    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            take.()
            send(parent, :held)

            receive do
              :release -> :ok
            after
              10_000 -> :timeout
            end
          end)
        end)
      end)

    assert_receive :held, 5_000
    holder
  end

  defp release(holder) do
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
  end

  defp unboxed(fun), do: Barkpark.Unboxed.run(Repo, fun)
end
