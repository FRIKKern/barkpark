defmodule BarkparkWeb.ChatQuestionAnswerStoredTest do
  @moduledoc """
  task-70baa54b6bc7b54f: `POST /v1/chat/sessions/:id/answer` delivered the
  answers to the runtime and flipped the question row to "allowed", but stored
  only the flip. A reader of the row after a reload saw the questions and the
  status, never what was chosen. The row now keeps the validated answers
  (`metadata.answers`), merged with the delivered flip and only with it.

  A plain approval answer keeps its old row shape (control), and an answer
  that is not delivered stores nothing.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.StudioChat

  defmodule EchoRuntime do
    @moduledoc false
    def capabilities, do: %{modes: ["default"], models: ["gpt-5.6"], efforts: ["high"]}
    def cwd, do: "/tmp/answer-stored"
    def answer_approval(_ref, _request_id, _decision), do: :ok
  end

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
    def handle_call(:session_pid, _from, state), do: {:reply, {:ok, :stub_ref}, state}
  end

  @ask %{
    "questions" => [
      %{"question" => "Which color?", "options" => [%{"label" => "Blue"}, %{"label" => "Red"}]}
    ]
  }

  setup do
    {ws, _} = ensure_default_scope!()

    keys = [
      :public_demo_studio,
      :studio_chat_runtime_adapters,
      :operator_emails,
      :operator_token_ids
    ]

    prev = Map.new(keys, &{&1, Application.get_env(:barkpark, &1)})

    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [])

    Application.put_env(
      :barkpark,
      :studio_chat_runtime_adapters,
      Map.put(prev.studio_chat_runtime_adapters || %{}, :claude, EchoRuntime)
    )

    on_exit(fn ->
      for {key, val} <- prev do
        if is_nil(val),
          do: Application.delete_env(:barkpark, key),
          else: Application.put_env(:barkpark, key, val)
      end
    end)

    raw = "answer-stored-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(raw, "answer stored", "production", ["read", "write", "admin"], ws.id)

    {:ok, session} =
      StudioChat.create_session(
        %{id: Ecto.UUID.generate(), provider: "claude", mode: "plan"},
        {:workspace, ws.id}
      )

    %{raw: raw, sid: session.id}
  end

  defp as(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp ask!(sid, role, request_id, input) do
    {:ok, _} =
      StudioChat.append_message(StudioChat.get_session(sid), %{
        role: role,
        source_markdown: "ask",
        metadata: %{"request_id" => request_id, "input" => input, "approval_status" => "pending"}
      })
  end

  defp stored(sid, request_id),
    do:
      Enum.find(
        StudioChat.list_messages(sid, :global),
        &(&1.metadata["request_id"] == request_id)
      )

  test "an answered question's row keeps the answers that were sent", %{raw: raw, sid: sid} do
    ask!(sid, "question", "q-1", @ask)
    start_supervised!({RecorderStub, sid})
    sent = %{"Which color?" => "Blue"}

    conn =
      as(raw)
      |> post(
        "/v1/chat/sessions/#{sid}/answer",
        Jason.encode!(%{request_id: "q-1", answers: sent})
      )

    assert conn.status == 204, conn.resp_body

    row = stored(sid, "q-1")
    assert row.metadata["approval_status"] == "allowed"
    assert row.metadata["answers"] == sent
    assert row.metadata["input"] == @ask

    # The session read carries it to a reader (the #28844 door already passed).
    body = as(raw) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)
    message = Enum.find(body["messages"], &(&1["metadata"]["request_id"] == "q-1"))
    assert message["metadata"]["answers"] == sent
  end

  test "CONTROL: an allowed approval row gains no answers field", %{raw: raw, sid: sid} do
    ask!(sid, "approval", "a-1", %{"command" => "ls"})
    start_supervised!({RecorderStub, sid})

    conn =
      as(raw)
      |> post(
        "/v1/chat/sessions/#{sid}/approval",
        Jason.encode!(%{request_id: "a-1", decision: "allow"})
      )

    assert conn.status == 204, conn.resp_body
    row = stored(sid, "a-1")
    assert row.metadata["approval_status"] == "allowed"
    refute Map.has_key?(row.metadata, "answers")
  end

  test "an answer that reaches no runtime stores no answers", %{raw: raw, sid: sid} do
    ask!(sid, "question", "q-2", @ask)

    conn =
      as(raw)
      |> post(
        "/v1/chat/sessions/#{sid}/answer",
        Jason.encode!(%{request_id: "q-2", answers: %{"Which color?" => "Red"}})
      )

    assert conn.status == 404, conn.resp_body
    refute Map.has_key?(stored(sid, "q-2").metadata, "answers")
  end
end
