defmodule Barkpark.StudioChat.TestTmpTest do
  @moduledoc """
  The cleanup half of the fixture-ownership invariant that `Barkpark.TestTmp`
  exists to hold: every studio_chat fixture now lands under the build tree, so
  *something* has to remove it, and "the helper cleans up" must be proven by a
  run rather than asserted by a comment.

  The trick is callback ordering. `on_exit/1` callbacks run LIFO, so the
  assertion below is registered in `setup` — BEFORE the test body calls
  `TestTmp.dir/0` and registers the removal — which puts it LAST in the queue,
  after the directory has actually been torn down. A raise inside `on_exit/1`
  fails the test, so a leaked directory is a red.
  """
  use ExUnit.Case, async: false

  alias Barkpark.TestTmp

  @probe_key :studio_chat_test_tmp_probe_path

  setup do
    # Registered first => runs LAST, after TestTmp's own removal callback.
    on_exit(fn ->
      path = Application.get_env(:barkpark, @probe_key)
      Application.delete_env(:barkpark, @probe_key)

      # A nil path would make the refute below vacuous: the test body never ran.
      assert is_binary(path),
             "expected the test body to record the minted directory, got: #{inspect(path)}"

      refute File.exists?(path),
             "TestTmp left #{path} behind after the test that created it exited"
    end)

    :ok
  end

  test "the per-test directory is minted under the build tree and removed when the test exits" do
    dir = TestTmp.dir()
    Application.put_env(:barkpark, @probe_key, dir)

    assert File.dir?(dir)
    assert dir =~ Mix.Project.build_path()
    assert String.starts_with?(dir, TestTmp.root())

    # A fixture written into it is real, and is carried away with the directory.
    file = TestTmp.path("fixture.txt")
    File.write!(file, "payload")
    assert File.read!(file) == "payload"
    assert Path.dirname(file) == dir

    # Repeated calls in one test share one directory — the fixtures of a single
    # test stay together, and only one cleanup callback is registered.
    assert TestTmp.dir() == dir
  end

  test "root/0 is a stable, existing, absolute directory the run owns" do
    Application.put_env(:barkpark, @probe_key, TestTmp.dir())

    root = TestTmp.root()
    assert File.dir?(root)
    assert Path.type(root) == :absolute
    assert root == TestTmp.root()

    # The whole point: the root is NOT the shared, reaper-visible TMPDIR.
    refute String.starts_with?(root, System.get_env("TMPDIR") || "/tmp")
  end
end
