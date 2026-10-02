defmodule Barkpark.Dedup.ScanSeam do
  @moduledoc """
  The ONE fault-injection point that lets a test prove the `catch :exit` arm of
  the two dedup candidate fetches — `Barkpark.Content.DedupWall` and
  `Barkpark.Tasks.Dedup` — actually converts pool-checkout death into the
  fail-LOUD `{:error, {:dedup_unavailable, _}}` refusal.

  ## Why it exists

  Both fetches carry a `catch :exit` beside their `rescue`, because a
  DBConnection pool checkout that dies arrives as an EXIT, not an exception, and
  a rescue-only clause lets it through as a 500. That arm was landed UNPROVEN:
  inside the Ecto SQL sandbox every failure mode that can be staged from a test
  (dead or live dummy dynamic repo, ownership timeout, unallowed process,
  `pg_terminate_backend`, query/transaction timeout 0 and 1) surfaces as an
  EXCEPTION and lands in the `rescue`, never the `catch`. Deleting BOTH catch
  clauses on `main` left all 119 dedup tests green.

  ## What it can do — and what it provably cannot

  The whole surface is `exit(reason)`. It takes no function, returns no value a
  caller branches on, and touches no query, no connection and no candidate set.
  So the strongest thing an armed seam can do to a dedup check is make it
  REFUSE — the same conservative verdict the module already produces for a real
  outage. It cannot fabricate candidates, flip a verdict, or fail the gate OPEN.

  ## Why it cannot change production behaviour when unset

  Three independent layers, none of them convention:

    1. **Compile-time gate.** `enabled?` is `Application.compile_env/3`. The
       whole armed implementation — including the process-dictionary read — sits
       inside `if @enabled do … else … end` at the MODULE BODY, so under any
       configuration that does not set the key the compiler emits only
       `def check!(_surface), do: :ok`. The arming functions are not slow in
       production; they are ABSENT from the BEAM. `compile_env` also makes the
       runtime disagreement detectable: a release whose runtime config sets a
       different value refuses to boot rather than diverging silently.
    2. **The key lives in exactly one config file.** Only `config/test.exs` sets
       `:dedup_scan_seam`. `config.exs`, `dev.exs`, `prod.exs` and `runtime.exs`
       do not, and `Barkpark.Dedup.ScanSeamInertnessTest` reds if that changes
       — including if someone downgrades `compile_env` to a runtime
       `get_env`/`fetch_env`, which would reopen the door this closes.
    3. **The arming is PROCESS-LOCAL and defaults to absent.** Even in the test
       build, `check!/1` on a process that never called `arm/2` returns `:ok`
       and the fetch proceeds exactly as it always did — there is no global,
       no ETS table and no application env to leave dirty, so an armed test
       cannot leak into an `async: true` neighbour.

  This is deliberately stronger than the pre-existing
  `:dedup_wall_post_check_barrier` seam, which is a plain runtime
  `Application.get_env` and therefore IS reachable on a production node.

  ## Using it

      ScanSeam.arm(:content_dedup_wall, {:shutdown, :pool_checkout_died})
      assert {:error, {:dedup_unavailable, msg}} = DedupWall.check(doc, type, ds)

  `arm/2` is scoped to one surface, so arming the wall never perturbs the task
  gate and the two surfaces stay INDEPENDENTLY covered.
  """

  @typedoc "Which dedup candidate fetch the seam is armed for."
  @type surface :: :content_dedup_wall | :tasks_dedup

  @enabled Application.compile_env(:barkpark, :dedup_scan_seam, false)

  if @enabled do
    @key :barkpark_dedup_scan_seam

    @doc """
    Exits with the armed reason when this process armed the seam for `surface`.

    Returns `:ok` otherwise — which is every call on an unarmed process, and
    EVERY call at all in a build that did not compile the seam in.
    """
    @spec check!(surface()) :: :ok
    def check!(surface) do
      case Process.get(@key) do
        {^surface, reason} -> exit(reason)
        _ -> :ok
      end
    end

    @doc """
    Arms the seam for the CALLING process only. The next `check!/1` for
    `surface` exits with `reason`; nothing else is affected.
    """
    @spec arm(surface(), term()) :: :ok
    def arm(surface, reason) when surface in [:content_dedup_wall, :tasks_dedup] do
      Process.put(@key, {surface, reason})
      :ok
    end

    @doc "Disarms the seam for the calling process."
    @spec disarm() :: :ok
    def disarm do
      Process.delete(@key)
      :ok
    end

    @doc """
    Whether this build compiled the armed implementation in.

    `false` in every build that does not set `:dedup_scan_seam` — which is every
    build but `MIX_ENV=test`.
    """
    @spec enabled?() :: boolean()
    def enabled?, do: true
  else
    @spec check!(surface()) :: :ok
    def check!(_surface), do: :ok

    @spec enabled?() :: boolean()
    def enabled?, do: false
  end
end
