defmodule Barkpark.MixStrictTestPathsTest do
  @moduledoc """
  Guards the `test` alias's argv validator (api/mix.exs).

  `mix test <missing path>` exits 0 and runs only the paths that exist, so a
  gate prescription naming a renamed test file prints a green trailer that
  proves nothing (task-9dc1b0aaf43797df). `Barkpark.MixProject.missing_test_paths/1`
  is what turns that into a refusal, and these are its two obligations:
  it must NAME a path that is not there, and it must stay silent on every
  argv shape that is not a path — or it would refuse legitimate runs.
  """
  use ExUnit.Case, async: true

  alias Barkpark.MixProject

  @real "test/mix_strict_test_paths_test.exs"
  @fake "test/barkpark_web/controllers/share_link_controller_test.exs"

  describe "names what is missing" do
    test "the exact filing: a fake path riding alongside a real one is reported" do
      assert MixProject.missing_test_paths(["test", @real, @fake]) == [@fake]
    end

    test "every missing path is named, not just the first" do
      assert MixProject.missing_test_paths(["test", "test/a_test.exs", "test/b_test.exs"]) ==
               ["test/a_test.exs", "test/b_test.exs"]
    end

    test "a `path:line` argument is checked against the file, suffix stripped" do
      assert MixProject.missing_test_paths(["test", @fake <> ":42"]) == [@fake]
      assert MixProject.missing_test_paths(["test", @real <> ":42"]) == []
      assert MixProject.missing_test_paths(["test", @real <> ":42:99"]) == []
    end

    test "a missing directory argument is reported too" do
      assert MixProject.missing_test_paths(["test", "test/no_such_dir/"]) == ["test/no_such_dir/"]
    end

    test "the same missing path named twice is reported once" do
      assert MixProject.missing_test_paths(["test", @fake, @fake]) == [@fake]
    end
  end

  describe "stays silent on shapes that are not paths" do
    test "a bare `mix test` checks nothing" do
      assert MixProject.missing_test_paths(["test"]) == []
    end

    test "a real file and a real directory pass" do
      assert MixProject.missing_test_paths(["test", @real, "test/support"]) == []
    end

    test "flags and their values are never treated as paths" do
      # `--only boot_test` and friends: the value is a tag, not a file.
      assert MixProject.missing_test_paths(["test", "--only", "boot_test"]) == []
      assert MixProject.missing_test_paths(["test", "--include", "flaky", "--seed", "0"]) == []
      assert MixProject.missing_test_paths(["test", "--slowest", "50"]) == []
      assert MixProject.missing_test_paths(["test", "--trace", "--cover"]) == []
    end

    test "a flag value that looks like a path is still not checked" do
      assert MixProject.missing_test_paths(["test", "--formatter", "Some/Module"]) == []
    end

    test "the real invocation elixir.yml uses today is accepted" do
      assert MixProject.missing_test_paths([
               "test",
               "--only",
               "boot_test",
               "test/barkpark/plugin_free_boot_test.exs"
             ]) == []
    end
  end
end
