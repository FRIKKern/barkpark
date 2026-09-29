defmodule Barkpark.TestTmp do
  @moduledoc """
  Fixture scratch space that the test run alone owns.

  `System.tmp_dir!/0` honours `TMPDIR`, and on a developer box `TMPDIR` is
  routinely a SHARED scratch root that some other process reaps on a timer. A
  test that mints a fake provider binary or a JSONL wire log there can have the
  file deleted between `File.write!/2` and `System.cmd/3`:

      /bin/sh: /…/probe_fake_3266.sh: No such file or directory

  which the runtime reports as `reason: :version_failed` / `:timeout` and the
  assertion reports as a real product failure. It never reds in CI (private
  runner tmp) and reds intermittently everywhere else — the worst possible
  signal.

  The invariant this module exists to hold: **a test's fixture files live
  somewhere only that test run writes and only that test run deletes**, so a
  fixture that vanishes can only be the test's own doing.

  Everything lives under the build tree (`Mix.Project.build_path/0`), which is
  per-`MIX_ENV` and per-`MIX_TEST_PARTITION`, so concurrent partitions on one
  box never share a root and no external reaper is pointed at it.

      binary = Barkpark.TestTmp.path("probe_fake.sh")   # per-test dir, auto-removed
      root   = Barkpark.TestTmp.root()                  # the stable owned root
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  The stable, test-owned root directory. Created if missing.

  Use this only where a *directory* is the subject (an approved root, a cwd).
  For fixture files use `path/1`, which is cleaned up per test.
  """
  @spec root() :: String.t()
  def root do
    path = Path.join([Mix.Project.build_path(), "test_tmp", partition()])
    File.mkdir_p!(path)
    path
  end

  @doc """
  A directory private to the calling test, created on first use and removed by
  an `on_exit/1` callback registered at that moment.

  Must be called from a process ExUnit owns (a test, `setup`, or `setup_all`
  body) — that is what makes the cleanup callback registerable.
  """
  @spec dir() :: String.t()
  def dir do
    case Process.get(__MODULE__) do
      nil ->
        path = Path.join(root(), unique_segment())
        File.mkdir_p!(path)
        Process.put(__MODULE__, path)
        on_exit(fn -> File.rm_rf!(path) end)
        path

      path when is_binary(path) ->
        path
    end
  end

  @doc """
  An absolute path to `name` inside this test's private directory (`dir/0`).

  The file itself is not created; the directory holding it is, and the whole
  directory is removed when the test exits.
  """
  @spec path(String.t()) :: String.t()
  def path(name) when is_binary(name), do: Path.join(dir(), name)

  defp unique_segment do
    "t#{System.unique_integer([:positive, :monotonic])}-#{:erlang.phash2(self())}"
  end

  defp partition do
    case System.get_env("MIX_TEST_PARTITION") do
      nil -> "0"
      "" -> "0"
      value -> String.replace(value, ~r/[^A-Za-z0-9_.-]/, "_")
    end
  end
end
