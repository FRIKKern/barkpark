defmodule Barkpark.Plugins.EnvConfigTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.EnvConfig

  describe "parse/1 — kill-switch semantics" do
    test "nil (env unset) -> :unset so :plugins stays unconfigured (discover-all)" do
      assert EnvConfig.parse(nil) == :unset
    end

    test "empty string -> [] (the kill switch: register nothing)" do
      assert EnvConfig.parse("") == []
    end

    test "comma list -> trimmed, blank-stripped name list (whitelist)" do
      assert EnvConfig.parse("a, b") == ["a", "b"]
      assert EnvConfig.parse("bulldocs,onixedit") == ["bulldocs", "onixedit"]
    end

    test "drops blank entries and trims surrounding whitespace" do
      assert EnvConfig.parse("  bulldocs ,, onixedit ,") == ["bulldocs", "onixedit"]
    end

    test "whitespace-only string collapses to the kill switch []" do
      assert EnvConfig.parse("   ") == []
      assert EnvConfig.parse(" , , ") == []
    end
  end
end
