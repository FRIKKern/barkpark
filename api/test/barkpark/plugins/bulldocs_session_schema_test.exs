defmodule Barkpark.Plugins.BulldocsSessionSchemaTest do
  use ExUnit.Case, async: true

  test "register_schemas includes the session schema" do
    schemas = Barkpark.Plugins.Bulldocs.register_schemas([])
    session = Enum.find(schemas, &(&1.name == "session"))
    assert session, "session schema not registered"
    field_names = Enum.map(session.fields, & &1["name"])

    for f <-
          ~w(harness session_uuid cwd machine git_head git_branch started_at ended_at transcript status events) do
      assert f in field_names, "missing field #{f}"
    end

    events = Enum.find(session.fields, &(&1["name"] == "events"))
    assert events["type"] == "arrayOf"
    assert events["of"]["type"] == "composite"
    kind = Enum.find(events["of"]["fields"], &(&1["name"] == "kind"))

    assert kind["options"] == [
             "paper-published",
             "task-closed",
             "epic-wave-complete",
             "push",
             "note"
           ]

    status = Enum.find(session.fields, &(&1["name"] == "status"))
    assert status["options"] == ["open", "closed", "resumed", "superseded"]
  end
end
