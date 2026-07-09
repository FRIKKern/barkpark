defmodule BarkparkWeb.Studio.ChatToolRenderer do
  @moduledoc """
  Pure rendering helpers for the Studio chat's terminal-imitation transcript
  (charter D37/D40). Kept out of the LiveView so the spawn-row heuristics and
  the nested-trace shape are unit-addressable AND shared by the live path and
  the store-replay path (one truth, no drift).

  ## Task / agent spawns (D40)

  A sub-agent SPAWN is any `tool_use` that either (a) is named `Task` or
  `Agent`, or (b) carries the sub-agent input shape
  `{description, prompt, subagent_type}` under ANY tool name — the wire has
  shipped both forms, so dispatch is name- AND shape-tolerant. The spawn row is
  drawn with its `description` prominent (the human headline of the work).

  Every frame the sub-agent emits carries a top-level `parent_tool_use_id` equal
  to the spawn's `tool_use` id; those child rows render INDENTED beneath the
  spawn row (a connecting evergreen gutter), live and on replay.
  """

  @spawn_names ~w(Task Agent)

  @doc """
  True when a tool_use is a sub-agent spawn. Tolerant by design: the tool name
  `Task`/`Agent`, OR the `{description, prompt, subagent_type}` input shape under
  any name.
  """
  @spec spawn?(String.t() | nil, map() | nil) :: boolean()
  def spawn?(name, input) do
    name in @spawn_names or spawn_shape?(input)
  end

  defp spawn_shape?(input) when is_map(input) do
    is_binary(input["description"]) and is_binary(input["prompt"]) and
      is_binary(input["subagent_type"])
  end

  defp spawn_shape?(_), do: false

  @doc """
  The label shown on the ● spawn row: the sub-agent `description` (the human
  headline), suffixed with its `subagent_type` when both are present. Falls back
  to the type, then to the tool name, so a thinner spawn frame still reads
  honestly.
  """
  @spec spawn_label(String.t() | nil, map() | nil) :: String.t()
  def spawn_label(name, input) when is_map(input) do
    desc = input["description"]
    type = input["subagent_type"]

    cond do
      is_binary(desc) and desc != "" and is_binary(type) and type != "" -> "#{desc} · #{type}"
      is_binary(desc) and desc != "" -> desc
      is_binary(type) and type != "" -> type
      true -> name || "Task"
    end
  end

  def spawn_label(name, _input), do: name || "Task"
end
