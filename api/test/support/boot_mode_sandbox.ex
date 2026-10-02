defmodule Barkpark.BootModeSandbox do
  @moduledoc """
  The ONLY place a test may write `:barkpark, :boot_mode` (task-086261728f14c078).

  ## The defect this replaces

  `elixir-nightly` run 35323296944 (2026-09-18, main `d28e16420`) failed with
  exactly two failures — `application_boot_mode_test.exs:136` and `:165` — both
  `assert App.boot_mode() == :full` with `left: :one_shot`. `:boot_mode` is ONE
  value for the WHOLE NODE and `mix test` is one node, so a module that writes
  it makes an unrelated module fail, later, depending only on which ran first.
  The nightly pins no seed and ran at `max_cases: 1`; the writer module ran at
  08:26:52 and the reader reddened at 08:27:36, 43 modules later.

  Both files were already `async: false` with an `on_exit` restore keyed off
  `Application.fetch_env/2`. That guard was present and it did not hold, which
  is why this module exists: adding another `on_exit` is adding more of the
  thing that failed.

  ## Why `try … after` and not `on_exit`

  Four properties an `on_exit` restore does not have:

    1. **It is synchronous and in-process.** `on_exit` runs in a DIFFERENT
       process, after the test process has died. The restore is therefore not
       ordered against the test's own completion — the `after` clause is.

    2. **It cannot be unregistered.** `on_exit/2`'s first argument is a KEY: a
       second registration with the same ref REPLACES the first rather than
       stacking, so a restore can be silently dropped by a later callback.
       `scripts/test-env-leak-gate.sh` names exactly this blind spot in its own
       moduledoc and still reads such a module as CLEAN. A lexical `after`
       clause has no registry, no ref, and nothing that can replace it.

    3. **It cannot fail to be registered.** `on_exit` registration is a runtime
       call: anything that raises between capturing `original` and reaching it
       leaves the write unguarded. `after` is bound at compile time to the
       block it protects.

    4. **It VERIFIES.** `restore!/1` re-reads the key and raises if it did not
       land, so a broken restore reds THIS test — the writer — instead of a
       module chosen by the shuffle three minutes later. A restore nobody
       checks is a wish.

  An `on_exit` is ALSO registered, as a backstop for the one case `after` does
  not cover: a brutal kill of the test process. It is registered HERE, once, so
  no caller can ref-replace it.

  ## Why `persistent: true` on BOTH sides

  MEASURED, not reasoned (2026-09-20). With `app` loaded:

      Application.put_env(app, :k, :one_shot, persistent: true)
      Application.delete_env(app, :k)              # NON-persistent
      Application.fetch_env(app, :k)               #=> :error      (looks clean)
      :application.load(app_spec)
      Application.fetch_env(app, :k)               #=> {:ok, :one_shot}   RESURRECTED

  A non-persistent delete does NOT retract a persistent record: OTP keeps it in
  its own table and re-applies it the next time the application is loaded. The
  production writer, `Barkpark.OneShot.boot!/0`, is persistent. So a restore
  that is not also persistent is not a restore — it is a restore that holds
  until the next `Application.load/1` and then hands `:one_shot` to whoever is
  running.

  ## Honest limit

  If the whole VM dies, neither arm runs — and neither does `on_exit`. Nothing
  in a single-node ExUnit run can do better than that; what this removes is
  every failure mode SHORT of it.
  """

  @app :barkpark
  @key :boot_mode

  @doc """
  Run `fun` with `:boot_mode` sandboxed, restoring it before returning.

  `fun` is given a one-arity setter — the only sanctioned way to change the key
  inside the block — so a test that needs two successive values still makes
  zero raw global writes of its own:

      BootModeSandbox.sandboxed(fn set ->
        set.(:one_shot)
        assert App.boot_mode() == :one_shot

        set.(:one_shot_typo)
        assert_raise ArgumentError, fn -> App.boot_mode() end
      end)

  Returns whatever `fun` returns. Re-raises anything `fun` raises, AFTER
  restoring.
  """
  @spec sandboxed(((term() -> :ok) -> result)) :: result when result: term()
  def sandboxed(fun) when is_function(fun, 1) do
    original = Application.fetch_env(@app, @key)
    backstop!(original)

    try do
      # THE SETTER IS INLINE, not a `&put/1` capture, and the `after` clause
      # calls `write_back/1` DIRECTLY rather than through `restore!/1`. Both are
      # concessions to scripts/test-env-leak-gate.sh, which reds a helper the
      # restore reaches only at two removes: its local-helper credit is ONE
      # level deep (pass A harvests the names an `on_exit`/`after` clause calls,
      # pass B credits those clause BODIES — and stops). Measured on this file:
      # the two-removes version reported "2 unrestored mutation(s) of
      # :barkpark/:boot_mode", exit 1, on the mechanism that FIXES the leak.
      # Written this way the gate reads the pairing it really is. Reported, not
      # worked around silently.
      fun.(fn value -> Application.put_env(:barkpark, :boot_mode, value, persistent: true) end)
    after
      write_back(original)
      verify_restored!(original)
    end
  end

  @doc """
  Run `fun` — which writes `:boot_mode` INDIRECTLY — with the key protected.

  For the case `sandboxed/1` does not cover and which is what actually leaked
  into `elixir-nightly`: a test that never types `Application.put_env` at all,
  because the write happens in `api/lib` on its behalf.

  `Mix.Tasks.Barkpark.Preview.Backfill.run/1` and
  `Mix.Tasks.Barkpark.Workspace.ProvisionSchemas.run/1` both call
  `Barkpark.OneShot.boot!/0`, whose FIRST line is a PERSISTENT
  `put_env(:barkpark, :boot_mode, :one_shot)`. That is correct for an operator
  one-shot and wrong for a test process, which shares the key with 1800 other
  modules. A grep for raw writes under `api/test` finds nothing here — the call
  site is two frames away — so the single-writer guard below, and
  `scripts/test-env-leak-gate.sh`, both read these modules as CLEAN.

      out = capture_io(fn -> BootModeSandbox.protecting(fn -> Task.run(argv) end) end)

  Same `try … after`, same verified restore as `sandboxed/1`; it only withholds
  the setter, because a caller of this arm has no business writing the key
  itself.
  """
  @spec protecting((-> result)) :: result when result: term()
  def protecting(fun) when is_function(fun, 0) do
    sandboxed(fn _set -> fun.() end)
  end

  @doc """
  Run `fun` with `:boot_mode` ESTABLISHED as absent, restoring it afterwards.

  For the readers, which must assert what an ordinary boot does. An absent key
  is the state every ordinary boot is in, and deleting it is the only way to BE
  in that state regardless of what else this node has run — reading whatever
  the node happens to hold is what made the two nightly assertions report a
  defect in `config/*.exs` that `config/*.exs` does not have.
  """
  @spec absent((-> result)) :: result when result: term()
  def absent(fun) when is_function(fun, 0) do
    sandboxed(fn _set ->
      Application.delete_env(:barkpark, :boot_mode, persistent: true)

      # PRECONDITION, asserted rather than assumed: if this is not :error the
      # delete did not take, and everything `fun` concludes is about some other
      # state than "an ordinary boot".
      case Application.fetch_env(@app, @key) do
        :error ->
          :ok

        other ->
          raise "BootModeSandbox.absent/1 could not establish an absent :boot_mode — " <>
                  "fetch_env answered #{inspect(other)} after a persistent delete"
      end

      fun.()
    end)
  end

  @doc """
  The node-global state of the key, for a leak probe.

  `test/test_helper.exs` calls this in an `ExUnit.after_suite/1` hook: anything
  other than `:error` at the end of a run is a write that outlived the whole
  suite.
  """
  @spec current() :: {:ok, term()} | :error
  def current, do: Application.fetch_env(@app, @key)

  # Registered ONCE, from inside this module, so no caller can replace it with
  # a same-ref registration. Idempotent with the `after` clause: restoring an
  # already-restored key is a no-op write of the same value.
  defp backstop!(original) do
    if function_exported?(ExUnit.Callbacks, :on_exit, 1) do
      try do
        ExUnit.Callbacks.on_exit(fn -> write_back(original) end)
      catch
        # on_exit/1 raises when called outside a test process. That is not a
        # reason to refuse the sandbox — the `after` clause is the mechanism,
        # this is only the backstop.
        _, _ -> :ok
      end
    end

    :ok
  end

  defp verify_restored!(original) do
    now = Application.fetch_env(@app, @key)

    if now != original do
      raise """
      BootModeSandbox FAILED TO RESTORE :barkpark, :boot_mode.

          before the block: #{inspect(original)}
          after the restore: #{inspect(now)}

      This value is NODE-GLOBAL. Left as it is, the next module to read
      `Barkpark.Application.boot_mode/0` fails an assertion about code it does
      not touch, and which module that is depends on the ExUnit seed.

      This assertion exists so that failure is reported HERE, in the test that
      caused it, instead of three minutes later in a file nobody changed.
      """
    end

    :ok
  end

  defp write_back({:ok, mode}),
    do: Application.put_env(:barkpark, :boot_mode, mode, persistent: true)

  defp write_back(:error), do: Application.delete_env(:barkpark, :boot_mode, persistent: true)
end
