defmodule Barkpark.ApplicationEnvIsolationTest do
  @moduledoc """
  Protective proof for the async-env-mutation fix (task-435b89bfa992a58a).

  Three test modules — `MediaTest`, `StudioChatTest`, `Barkpark.Plugins.GithubTest`
  — mutate a PROCESS-GLOBAL `Application` env key in setup and restore it via
  `on_exit`. Those modules were previously `async: true` with a comment claiming
  the SQL sandbox made that safe. It does NOT: the sandbox isolates the DB
  connection, never the VM-global Application env.

  This module DEMONSTRATES the leak channel that made `async: true` unsafe: an
  `Application.put_env` in one process is IMMEDIATELY visible to a concurrently
  running process reading the same key, with zero isolation. That is exactly why
  an async:true env-mutating module can leak into a concurrent async reader and
  race its `on_exit` restore — an order-dependent flake.

  Itself `async: false` so its own probe key can't be seen by a concurrent test.
  """
  use ExUnit.Case, async: false

  test "Application env is GLOBAL VM state — a concurrent process sees the mutation with no sandbox isolation" do
    key = String.to_atom("barkpark_env_leak_probe_#{System.unique_integer([:positive])}")
    refute Application.get_env(:barkpark, key)

    Application.put_env(:barkpark, key, :mutated_by_this_test)
    on_exit(fn -> Application.delete_env(:barkpark, key) end)

    # A SEPARATE, concurrently-running process (the stand-in for a concurrent
    # async test) observes the mutation instantly. If the SQL sandbox — or any
    # per-process isolation — covered Application env, this would read `nil`.
    # It reads the mutated value, proving the leak channel is real. THIS is why
    # the three env-mutating modules must be `async: false`: serialization is the
    # only thing that stops a concurrent reader from observing a mid-test write.
    observed =
      Task.async(fn -> Application.get_env(:barkpark, key) end)
      |> Task.await()

    assert observed == :mutated_by_this_test
  end
end
