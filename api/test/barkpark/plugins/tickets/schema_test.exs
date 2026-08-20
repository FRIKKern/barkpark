defmodule Barkpark.Plugins.Tickets.SchemaTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Tickets

  defp field(name) do
    Tickets.ticket_schema("production").fields
    |> Enum.find(fn f -> f["name"] == name end)
  end

  test "status is a select with a FLAT option list (canonical shape)" do
    status = field("status")

    # Decision 3: derived, never client-set.
    assert status["readOnly"] == true

    # The canonical select shape is `"type" => "select"` + a FLAT list —
    # the same shape field_inputs.ex pattern-matches and seeds/demo.ex /
    # tasks/schema.ex ship. The old `"string"` + `%{"list" => [..]}` object
    # was the sole outlier among 22 options-bearing fields and aborted strict
    # client schema decoders (Go apiclient LoadSchemas), killing TUI boot.
    assert status["type"] == "select"
    assert status["options"] == ["open", "answered", "closed"]

    # The object shape must be gone — no field may carry the outlier form.
    refute is_map(status["options"])
  end

  test "no ticket field ships the object-shaped options outlier" do
    for f <- Tickets.ticket_schema("production").fields, opts = f["options"], opts != nil do
      assert is_list(opts),
             "field #{f["name"]} options must be a flat list, got: #{inspect(opts)}"
    end
  end
end
