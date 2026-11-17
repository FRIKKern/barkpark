defmodule BarkparkWeb.Studio.CodexFailureLine do
  @moduledoc """
  The transcript's system line for a codex runtime failure event
  (`:protocol_error`, `:error`, `:process_failed`; codex/protocol.ex). Names
  the failure class, then the scrubbed reason from the event's `error` map
  (message/detail, with the machine code in parens) when one is present. A
  registered host forwards the notification's params, so its reason sits one
  level down, under `error["error"]` (task-1ea3bfbe6d47e2bb).

  A codex `error` that will retry (`Runtime.Event.retrying_error?/1`) is not
  the end of the turn: the Recorder keeps it open and the reply follows, so
  its line says the turn is retrying (task-4644f29b5663bc5f).
  """

  alias Barkpark.StudioChat.Runtime.Event

  @spec line(Event.t()) :: String.t()
  def line(%Event{kind: kind, error: error} = event) do
    label =
      cond do
        Event.retrying_error?(event) -> "The codex turn hit an error and is retrying"
        kind == :process_failed -> "The codex process exited unexpectedly"
        kind == :protocol_error -> "The codex stream hit a protocol error"
        true -> "The codex turn ended with an error"
      end

    case detail(error) do
      "" -> label <> "."
      detail -> label <> " — " <> detail <> "."
    end
  end

  defp detail(%{"error" => nested}) when is_map(nested), do: detail(nested)

  defp detail(error) when is_map(error) do
    reason =
      [error["message"], error["detail"]]
      |> Enum.map(&text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.join(" — ")

    code = text(error["code"])

    cond do
      reason != "" and code != "" -> reason <> " (" <> code <> ")"
      reason != "" -> reason
      code != "" -> code
      true -> ""
    end
  end

  defp detail(_), do: ""

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_), do: ""
end
