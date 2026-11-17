defmodule BarkparkWeb.ChatAnswerClaimTest do
  @moduledoc """
  `POST /v1/chat/sessions/:id/answer` claims the question through
  `ApprovalAnswer.settle/4` before it sends anything (task-52de5429fbdcb68c).

  The route reads the pending question to validate the answer, with no lock.
  Before, it then sent the answer and flipped the row, so a cancel that
  committed after that read still had the answer sent, and the route said 204
  over a canceled ask. Now the claim takes the row lock and re-reads it: a
  question canceled since the read is the route's 404, and nothing is sent.

  The claim runs only when a runtime holds the session, so those tests stub one:
  a process holding the session's Recorder name, and a codex adapter that
  reports each delivery to the test. With no Recorder and no live execution
  lease the route cancels the question, as Studio does on reopen (D11,
  task-dc4980982da790c9): it answers 404, and the store never says "allowed"
  over an answer nothing received. A live lease with no Recorder, or a Recorder
  that does not answer, is a 503 instead (`chat_registered_host_ask_test.exs`).

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

  defmodule RecorderStub do
    @moduledoc false
    use GenServer

    def start_link(sid),
      do:
        GenServer.start_link(__MODULE__, nil,
          name: {:via, Registry, {Barkpark.StudioChat.RecorderRegistry, sid}}
        )

    @impl true
    def init(_), do: {:ok, nil}

    @impl true
    def handle_call(:session_pid, _from, state), do: {:reply, {:ok, :stub_runtime}, state}
  end

  defmodule RecordingAdapter do
    @moduledoc false
    def answer_approval(:stub_runtime, request_id, decision) do
      send(
        Application.fetch_env!(:barkpark, :answer_claim_test_pid),
        {:delivered, request_id, decision}
      )

      :ok
    end
  end

  setup do
    prev = Application.get_env(:barkpark, :studio_chat_runtime_adapters)
    adapters = Map.put(prev || %{}, :codex, RecordingAdapter)
    Application.put_env(:barkpark, :studio_chat_runtime_adapters, adapters)
    Application.put_env(:barkpark, :answer_claim_test_pid, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :studio_chat_runtime_adapters, prev),
        else: Application.delete_env(:barkpark, :studio_chat_runtime_adapters)

      Application.delete_env(:barkpark, :answer_claim_test_pid)
    end)
  end

  test "with a live runtime an answer is delivered once, recorded and 204s" do
    with_question(fn raw, sid ->
      start_supervised!({RecorderStub, sid})

      assert unboxed(fn -> answer(raw, sid) end).status == 204
      assert_received {:delivered, "q-1", {:allow, _server_rebuilt_input}}
      refute_received {:delivered, _, _}
      assert StudioChat.get_needs_you_message(sid, "q-1").metadata["approval_status"] == "allowed"
    end)
  end

  test "an answer whose question is canceled while it waits is a 404 and leaves it canceled" do
    with_question(fn raw, sid ->
      start_supervised!({RecorderStub, sid})
      holder = hold(fn -> 1 = StudioChat.cancel_pending_approvals(sid) end)
      {request, backend} = LockWaiter.start(fn -> answer(raw, sid) end)

      LockWaiter.await_lock!(backend)
      release(holder)

      resp = Task.await(request, 10_000)
      assert resp.status == 404, "a canceled question answered #{resp.status}: #{resp.resp_body}"

      assert StudioChat.get_needs_you_message(sid, "q-1").metadata["approval_status"] ==
               "canceled"

      refute_received {:delivered, _, _}
    end)
  end

  test "an answer to a pending question with no live runtime cancels it and 404s" do
    with_question(fn raw, sid ->
      resp = unboxed(fn -> answer(raw, sid) end)
      assert resp.status == 404, "an unsent answer answered #{resp.status}: #{resp.resp_body}"

      assert StudioChat.get_needs_you_message(sid, "q-1").metadata["approval_status"] ==
               "canceled"

      assert StudioChat.get_session(sid).pending_approvals == 0
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

      {:ok, session} =
        StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: "/tmp/x", provider: "codex"})

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

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
