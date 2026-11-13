defmodule Barkpark.StudioChat.Runtime.ApprovalAsk do
  @moduledoc """
  The ask a runtime `:approval_requested` event stands for: the same
  `%{request_id, tool_name, input, title}` map the in-process Claude adapter
  sends as `{:claude_chat_permission, ask}`, so the Recorder stores and
  broadcasts both the same way.

  Two providers put the ask in different places of `event.native`:

    * Codex (app-server JSON-RPC, in-process or on a registered host): the
      JSON-RPC `method` names the approval, `params` is its input.
    * Claude on a registered host: the Go host lifts Claude's `can_use_tool`
      control request to top-level `tool_name`, `input` and `title`.

  Reading only the Codex places turned every registered-host Claude ask into
  an empty `"Approval"` (task-1c727b482160ddbc): an AskUserQuestion was stored
  as an approval row with no questions, so `/answer` found no question to
  answer, and an ExitPlanMode lost its plan.
  """

  alias Barkpark.StudioChat.Runtime.Event

  @spec from_event(Event.t()) :: %{
          request_id: String.t() | nil,
          tool_name: String.t(),
          input: map(),
          title: String.t() | nil
        }
  def from_event(%Event{approval_id: request_id, native: native}) do
    native = native || %{}

    case field(native, :tool_name) do
      tool_name when is_binary(tool_name) and tool_name != "" ->
        %{
          request_id: request_id,
          tool_name: tool_name,
          input: map_or_empty(field(native, :input)),
          title: string_or_nil(field(native, :title))
        }

      _ ->
        %{
          request_id: request_id,
          tool_name: codex_name(field(native, :method)),
          input: map_or_empty(field(native, :params)),
          title: nil
        }
    end
  end

  defp codex_name("item/fileChange/requestApproval"), do: "FileChange"
  defp codex_name("item/permissions/requestApproval"), do: "Permissions"
  defp codex_name("item/commandExecution/requestApproval"), do: "CommandExecution"
  defp codex_name(method) when is_binary(method), do: method
  defp codex_name(_), do: "Approval"

  # Host events arrive with string keys; in-process events may carry atoms.
  defp field(native, key), do: Map.get(native, Atom.to_string(key), Map.get(native, key))

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_), do: %{}

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil
end
