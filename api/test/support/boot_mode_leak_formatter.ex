defmodule Barkpark.BootModeLeakFormatter do
  @moduledoc """
  A PER-MODULE runtime probe for the node-global `:barkpark, :boot_mode`
  (task-086261728f14c078).

  ## Why a formatter and not another guard

  Three arms existed before this one and all three were green while the leak was
  live:

    1. `scripts/test-env-leak-gate.sh` — reads "an `on_exit` restoring this key
       exists in the module". It reads a module that never types
       `Application.put_env` at all as clean, and correctly so.
    2. the single-writer walk in `application_one_shot_boot_mode_test.exs` —
       same blind spot: it greps `api/test` for RAW writes of the key.
    3. `ExUnit.after_suite/1` in `test_helper.exs` — fires, but only once the
       whole suite has run, and names NOTHING. It says a key leaked; it cannot
       say which of 1800 modules leaked it.

  The 09-20 run of PR #19480 (run 35509163543) printed exactly that: arm 3 said
  `value left behind: :one_shot`, and the module that did it had to be found by
  reading `api/lib`. The write is in `Barkpark.OneShot.boot!/0`, reached from
  `Mix.Tasks.Barkpark.Preview.Backfill.run/1` and
  `Mix.Tasks.Barkpark.Workspace.ProvisionSchemas.run/1` — two frames below any
  test source a static reader of `api/test` can see.

  A formatter sees `:module_finished` for EVERY module, whatever it typed and
  whatever it called. That is the only place in an ExUnit run where "this
  module left the node dirty" is a question that can be asked at all.

  ## What it does

  At each `:module_finished` it reads the key. The first module that finishes
  with the key set becomes the SUSPECT; a later module that finishes with the
  key clean clears it. At `:suite_finished`, if the key is still set, it prints
  the suspect and arms a non-zero exit. It reports once: the key is still set
  for every module after the suspect, and a detector that names 1799 innocent
  modules is a detector nobody reads.

  Why it waits for the end (task-e6a070e903a72c37). A formatter gets its
  events by `cast`, so it reads the key when it gets to the event, not when the
  module finished. By then the NEXT module may be running, and
  `Barkpark.ApplicationBootModeTest` sets the key on purpose inside
  `BootModeSandbox.sandboxed/1` (`:nope`, `:seed`) and puts it back. Read at
  that moment, a sandbox's own value looked like a leak: PR #25908's run
  43390762489 blamed `Barkpark.Bench.PaperReadLatencyBenchTest`, which never
  touches the key, for `:nope`, and exited 1 over 12018 passing tests. A real
  leak is never put back, so it is still set when the suite ends; a sandbox's
  value is gone by then.

  It WRITES NOTHING. Restoring the key here would repair the leak and make the
  run green again, which is a fix dressed as a probe; and it would also make
  this module a writer of the key, which the single-writer guard exists to
  forbid. `Barkpark.BootModeSandbox` stays the only writer.

  ## Honest limits

    * It attributes the leak to the first module of the run of modules that
      all finished with the key set. Under `async: true` several modules are in flight, so the
      name is the best available witness, not a proof of authorship. Every
      known writer is in an `async: false` module, where the attribution is
      exact.
    * A key written and restored WITHIN a module is invisible to it — by
      design. That transient is caught at the source, by
      `BootModeSandbox`'s verified `try … after`.
  """

  use GenServer

  # `:on_leak` is for the formatter's own test, which drives this process with
  # the real key and must not arm the run's exit. ExUnit passes its config,
  # which has no such key, so a run always prints and fails.
  @impl GenServer
  def init(opts) do
    on_leak = if is_list(opts), do: Keyword.get(opts, :on_leak)
    {:ok, %{suspect: nil, on_leak: on_leak || (&report_and_fail/2)}}
  end

  @impl GenServer
  def handle_cast({:module_finished, %{name: name}}, state) do
    {state, nil} = step(state, {:module_finished, name}, Barkpark.BootModeSandbox.current())
    {:noreply, state}
  end

  def handle_cast({:suite_finished, _times}, state) do
    case step(state, :suite_finished, Barkpark.BootModeSandbox.current()) do
      {state, nil} ->
        {:noreply, state}

      {state, {name, mode}} ->
        state.on_leak.(name, mode)
        {:noreply, state}
    end
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @doc """
  One event against the key as read now. Returns the new state and, at
  `:suite_finished` with the key still set, the `{module, value}` to report.
  Pure, so the cases are testable without arming an exit.
  """
  @spec step(map(), {:module_finished, module()} | :suite_finished, {:ok, term()} | :error) ::
          {map(), {module(), term()} | nil}
  def step(state, {:module_finished, _name}, :error), do: {%{state | suspect: nil}, nil}

  def step(%{suspect: nil} = state, {:module_finished, name}, {:ok, mode}),
    do: {%{state | suspect: {name, mode}}, nil}

  def step(state, {:module_finished, _name}, {:ok, _mode}), do: {state, nil}

  def step(%{suspect: {name, _}} = state, :suite_finished, {:ok, mode}),
    do: {state, {name, mode}}

  def step(state, :suite_finished, _now), do: {state, nil}

  defp report_and_fail(name, mode) do
    IO.puts(:stderr, report(name, mode))
    System.at_exit(fn _ -> exit({:shutdown, 1}) end)
  end

  defp report(module, mode) do
    """

    ================================================================
    NODE-GLOBAL LEAK: :barkpark, :boot_mode left set by a MODULE
    ================================================================

      module:            #{inspect(module)}
      value left behind: #{inspect(mode)}

    That module finished with `:barkpark, :boot_mode` set. The key is ONE value
    for the WHOLE NODE, so every module the shuffle runs after it reads
    #{inspect(mode)} from `Barkpark.Application.boot_mode/0` — and the one that
    asserts `:full` fails, in a file nobody touched, on some seeds and not
    others.

    The write need not be in the test source. `Barkpark.OneShot.boot!/0` and
    `Barkpark.Release.seed_boot!/0` both write it PERSISTENTLY, and several
    `mix barkpark.*` tasks call them, so invoking such a task from a test is a
    write of this key.

    THE FIX: wrap the call.

        BootModeSandbox.protecting(fn -> SomeTask.run(argv) end)

    Only this module is reported; the key stays set for everything after it, so
    later modules are witnesses, not suspects.
    ================================================================
    """
  end
end
