# FIXTURE SOURCE — SCANNED AS TEXT, NEVER COMPILED, NEVER RUN.
#
# hook_payload_shape_test.exs reads this file with the SAME source scanner it
# points at api/lib/barkpark/plugins/*.ex. Its three handlers are the positive
# control: each one is a clause-head shape whose verdict is known in advance, so
# a scanner that has gone blind (always-green or always-red) is caught before its
# verdict about the real plugins is believed.
#
#   forbidden_string_keyed_gate/1 — the shape the Tasks gate carried: matches a
#     string-keyed map ONLY. MUST fail on the struct payload, MUST pass on the
#     string-keyed one.
#   struct_only_gate/1 — matches %Document{} ONLY. The mirror: MUST pass on the
#     struct payload, MUST fail on the string-keyed one.
#   both_shapes_gate/1 — the shape Grip and Bulldocs carry. MUST pass on both.
#
# The file is .exs and is not named *_test.exs, so ExUnit never loads it.
defmodule Barkpark.Plugins.HookPayloadShapeFixtures do
  def lifecycle_hooks do
    %{
      before_publish: [
        &forbidden_string_keyed_gate/1,
        &struct_only_gate/1,
        &both_shapes_gate/1
      ]
    }
  end

  defp forbidden_string_keyed_gate(%{doc: %{"type" => "task"} = doc}) do
    {:halt, "string-keyed head reached with #{inspect(doc)}"}
  end

  defp forbidden_string_keyed_gate(_payload), do: :ok

  defp struct_only_gate(%{doc: %Barkpark.Content.Document{} = doc}) do
    {:halt, "struct head reached with #{inspect(doc)}"}
  end

  defp struct_only_gate(_payload), do: :ok

  defp both_shapes_gate(%{doc: doc}) when is_map(doc) do
    {:halt, "shape-agnostic head reached with #{inspect(doc)}"}
  end

  defp both_shapes_gate(_payload), do: :ok
end
