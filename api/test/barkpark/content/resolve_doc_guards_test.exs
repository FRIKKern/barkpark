defmodule Barkpark.Content.ResolveDocGuardsTest do
  @moduledoc """
  task-c10be8a9ad8f0145: `Content.Graph.resolve_doc/3` reaches the Tasks twin
  rule through the content-owned `ResolveDocGuards` seam, and
  `Content.Errors` renders the twin refusal through the `ErrorEnvelope`
  behaviour instead of matching a Tasks struct. The rule's behaviour is pinned
  by the unchanged twin tests (`graph_twin_one_rule_test.exs`,
  `errors_envelope_table_test.exs` and friends); this file pins the wiring.
  The kill-switch half (`list/0 == []`) is in `plugin_free_boot_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.{ErrorEnvelope, Errors, ResolveDocGuards}

  @twin_guard {Barkpark.Tasks.TwinResolver, :refuse_ambiguous_task!}

  defmodule PlainError do
    defexception message: "plain"
  end

  test "the Tasks plugin declares the twin rule as a resolve-doc guard" do
    assert Barkpark.Plugins.Tasks.resolve_doc_guards() == [@twin_guard]
  end

  test "with the Tasks plugin registered the seam publishes the twin guard" do
    assert @twin_guard in ResolveDocGuards.list()
  end

  test "run!/3 raises the twin refusal for an ambiguous task and passes a named dataset" do
    rows = [
      %Barkpark.Content.Document{doc_id: "t-1", type: "task", dataset: "production"},
      %Barkpark.Content.Document{doc_id: "t-1", type: "task", dataset: "staging"}
    ]

    assert_raise Barkpark.Tasks.AmbiguousTwinError, fn ->
      ResolveDocGuards.run!(rows, "t-1", nil)
    end

    assert ResolveDocGuards.run!(rows, "t-1", "staging") == :ok
  end

  test "the twin exception renders through the ErrorEnvelope behaviour" do
    e = Barkpark.Tasks.AmbiguousTwinError.new("t-1", ["staging", "production"])
    assert ErrorEnvelope.implemented_by?(e)

    assert %{
             code: "ambiguous_dataset",
             status: 409,
             details: %{doc_id: "t-1", datasets: ["production", "staging"]}
           } = Errors.to_envelope({:error, e})
  end

  test "an exception that does not implement the behaviour still renders internal_error" do
    e = %PlainError{}
    refute ErrorEnvelope.implemented_by?(e)
    assert %{code: "internal_error", status: 500} = Errors.to_envelope({:error, e})
  end
end
