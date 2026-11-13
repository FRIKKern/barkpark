defmodule Barkpark.StudioChat.Runtime.ApprovalAskTest do
  use ExUnit.Case, async: true

  alias Barkpark.StudioChat.Runtime.ApprovalAsk
  alias Barkpark.StudioChat.Runtime.Event

  defp event(native), do: %Event{kind: :approval_requested, approval_id: "a1", native: native}

  test "a Codex approval keeps its method name and params as the ask" do
    params = %{"threadId" => "t1", "command" => "ls"}

    assert ApprovalAsk.from_event(
             event(%{"method" => "item/commandExecution/requestApproval", "params" => params})
           ) == %{request_id: "a1", tool_name: "CommandExecution", input: params, title: nil}

    assert ApprovalAsk.from_event(event(%{"method" => "item/fileChange/requestApproval"})).tool_name ==
             "FileChange"

    assert ApprovalAsk.from_event(event(%{"method" => "item/permissions/requestApproval"})).tool_name ==
             "Permissions"

    assert ApprovalAsk.from_event(event(%{method: "x/y", params: params})) ==
             %{request_id: "a1", tool_name: "x/y", input: params, title: nil}

    assert ApprovalAsk.from_event(event(%{})) ==
             %{request_id: "a1", tool_name: "Approval", input: %{}, title: nil}
  end

  test "a registered Claude host's ask keeps its tool name, input and title" do
    native = %{
      "kind" => "approval_requested",
      "approval_id" => "a1",
      "tool_name" => "Bash",
      "input" => %{"command" => "ls"},
      "title" => "Run ls"
    }

    assert ApprovalAsk.from_event(event(native)) ==
             %{request_id: "a1", tool_name: "Bash", input: %{"command" => "ls"}, title: "Run ls"}

    assert ApprovalAsk.from_event(event(%{native | "input" => nil, "title" => nil})) ==
             %{request_id: "a1", tool_name: "Bash", input: %{}, title: nil}
  end
end
