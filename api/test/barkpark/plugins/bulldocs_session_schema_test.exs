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

  describe "the session schema's desk icon" do
    # session.json shipped an emoji (🧵) with no entry in `@emoji_map`, so it
    # was unrenderable in BOTH environments: `icon/1` RAISED under :test (any
    # table-driven Studio test carrying a session row died before asserting
    # anything) and warned + painted the "file" document glyph in dev/prod.
    # `session` is the second blocks type, so an unrenderable icon blocked any
    # session-covering guard from existing at all.
    #
    # These assertions read the icon off the SHIPPED schema, not off a literal,
    # so re-introducing an unmapped name in session.json reds them.
    setup do
      schemas = Barkpark.Plugins.Bulldocs.register_schemas([])
      %{icon: Enum.find(schemas, &(&1.name == "session")).icon}
    end

    test "resolves through BarkparkWeb.Icons without raising under :test", %{icon: icon} do
      assert BarkparkWeb.Icons.known_icon?(icon),
             "session.json's icon #{inspect(icon)} names no glyph in BarkparkWeb.Icons — " <>
               "icon/1 raises on it under :test and falls back to \"file\" in dev/prod"

      # The raising policy is what :test compiles in; call it explicitly so the
      # assertion does not depend on MIX_ENV being read correctly at run time.
      assert is_binary(BarkparkWeb.Icons.resolve_paths(icon, :raise))
    end

    test "paints its own picture rather than the \"file\" fallback", %{icon: icon} do
      # `known_icon?/1` alone would still pass for the literal name "file"; this
      # is the assertion that the desk shows something meant for a session.
      assert BarkparkWeb.Icons.resolve_paths(icon, :warn) !=
               BarkparkWeb.Icons.resolve_paths("no-such-glyph-anywhere", :warn)
    end
  end
end
