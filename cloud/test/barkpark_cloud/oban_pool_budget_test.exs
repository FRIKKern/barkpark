defmodule BarkparkCloud.ObanPoolBudgetTest do
  @moduledoc """
  The CONTROL PLANE's half of `mob-lm-guerrilla-pool-storm`: the recorded,
  accepted arithmetic between declared Oban concurrency and `POOL_SIZE`.

  ## What this guards, and why it is a test rather than a comment

  The row's cause criterion was settled by measurement on the api/ side: the
  workload that exhausts the Repo pool is not the SSR build (it holds ZERO Repo
  connections — it runs as a transient systemd unit or an OS `Port`) and not
  build concurrency (already capped at one), but ORDINARY, STRUCTURAL
  oversubscription — every declared Oban job slot and every HTTP door drawing
  from one `POOL_SIZE`.

  `cloud/` is a separate OTP application with its own Repo and its own Oban, and
  it carries the SAME arithmetic. Nothing in the tree stated it, and nothing
  would have reddened if a future queue made it worse: a keyword list grew by
  one line and the control plane quietly lost its last connection of headroom.
  A written finding does not fire by itself, so this is the finding as a
  mechanical check with a named trigger — ANY change to a declared queue's
  concurrency, to the set of declared queues, or to the `POOL_SIZE` default.

  ## The accepted decision this pins

  Declared concurrency EXCEEDS the pool. At full Oban saturation the HTTP doors
  are left with negative headroom, which is precisely the
  `DBConnection.ConnectionError` storm the row records. That is ACCEPTED, not
  fixed, and it is accepted for exactly one reason: a checkout-queue drop no
  longer reaches the caller as an opaque 500. `BarkparkCloud.Web.PoolOverload`
  sheds `reason: :queue_timeout` as a retryable **503**, so the cost of the next
  storm is one retry rather than a stranded session.

  `@accepted_oversubscription` below is that decision written down. The
  assertion is an EQUALITY on purpose — a ratchet has two failure directions.
  It reds when a queue is added or widened (the risk grew past what was
  accepted) AND when the gap closes (the acceptance is stale and should be
  re-recorded or dropped). Either way a human re-reads this module.

  Sizing `POOL_SIZE` itself is live-measurement work against the box and is NOT
  in this tree; it is tracked at `jpf-bl-guerrilla-db-probe-arm` ->
  `jpf-bl-oban-pool-partition`.

  ## How the two numbers are read

  Both come from the CONFIG SOURCES, not from the test environment — `test.exs`
  overrides queues and the sandbox pool, so `Application.get_env/2` here would
  answer about the test run, never about prod.

    * queues: `Config.Reader.read!(env: :prod)` over `config/config.exs`, then
      `Config.Reader.merge/2` with the literal `runtime.exs` binds for
      `oban_queues` — the same merge function the release itself uses, so the
      deep-merge that keeps `site_deploy: 1` alive is exercised, not assumed.
    * pool: the `System.get_env("POOL_SIZE") || "<default>"` literal in
      `config/runtime.exs`, located by walking its AST.

  Reading the EFFECTIVE set rather than `config.exs` alone is load-bearing, and
  a mutation proved it: widening `maintenance:` in `config.exs` changes nothing
  in prod, because `runtime.exs` replaces the value for every key it names. Only
  `site_deploy` — named in `config.exs` and nowhere else — reaches the release
  through the deep merge. A guard written against `config.exs` would have been
  green for a change that could not ship and red for one that could.
  """

  use ExUnit.Case, async: true

  # The config files live at `cloud/`'s root; ExUnit runs from there.
  @config_exs "config/config.exs"
  @runtime_exs "config/runtime.exs"

  # THE RECORDED DECISION (see @moduledoc). declared_slots - pool_size.
  # Positive means Oban alone can take every connection and still have jobs
  # waiting, leaving the HTTP doors nothing.
  @accepted_oversubscription 3

  describe "the declared Oban concurrency / POOL_SIZE budget" do
    test "prod's effective queue set is the config.exs set, deep-merged with runtime.exs" do
      queues = prod_queues()

      # A CONTROL on the reader itself: an empty or missing keyword list would
      # sail through every arithmetic assertion below as a harmless zero.
      assert is_list(queues) and queues != [],
             "read no prod queues at all — the config reader, not the budget, is what failed"

      # `runtime.exs` REPLACES the :queues value with a two-key list. It is a
      # deep merge, so `site_deploy` (declared only in config.exs) survives into
      # the release. If that ever stopped being true, AutoDeployWorker jobs —
      # `queue: :site_deploy` — would sit `available` forever in prod and no
      # site would ever auto-rebuild. That is worth its own assertion.
      assert Keyword.has_key?(queues, :site_deploy),
             "site_deploy vanished from the effective prod queues: AutoDeployWorker " <>
               "(use Oban.Worker, queue: :site_deploy) would never run. Effective set: " <>
               inspect(queues)
    end

    test "declared slots exceed POOL_SIZE by exactly the accepted amount" do
      declared = declared_slots()
      pool = pool_size_default()

      assert pool > 0, "read a non-positive POOL_SIZE default (#{pool}) — the reader failed"

      assert declared - pool == @accepted_oversubscription, """
      The control plane's declared Oban concurrency / POOL_SIZE budget moved.

        declared job slots : #{declared}   (#{inspect(prod_queues())})
        POOL_SIZE default  : #{pool}       (#{@runtime_exs})
        oversubscription   : #{declared - pool}
        accepted (pinned)  : #{@accepted_oversubscription}

      This is not a lint. Every slot above `POOL_SIZE` is a connection the HTTP
      doors cannot have while Oban is saturated, which is the
      mob-lm-guerrilla-pool-storm condition. Re-read this module's @moduledoc,
      decide deliberately, then move @accepted_oversubscription.
      """
    end

    test "the oversubscription is accepted only because a queue drop sheds as a retryable 503" do
      # The coupling, asserted rather than asserted-in-prose: we tolerate
      # negative HTTP headroom BECAUSE the drop is honest. Delete the defimpl
      # and this reds — the acceptance loses its stated reason.
      if declared_slots() > pool_size_default() do
        err = %DBConnection.ConnectionError{message: "dropped", reason: :queue_timeout}

        # Asserted through the PROTOCOL, not through `impl_for/1`: with the
        # defimpl deleted, `@fallback_to_any` answers 500 here and this reds —
        # which is the behaviour that matters, and unlike an `impl_for/1`
        # comparison it is not something the compiler can fold to a constant.
        assert Plug.Exception.status(err) == 503,
               "a pool queue drop no longer renders 503 in cloud/: the accepted " <>
                 "oversubscription above loses the only reason it was accepted"

        # The negative control, on the SAME protocol: a fault that may have
        # touched the database must NOT be advertised as retryable.
        assert Plug.Exception.status(%DBConnection.ConnectionError{
                 message: "closed",
                 reason: :error
               }) == 500
      end
    end
  end

  # ── reading the two numbers off the config sources ──────────────────────────

  defp prod_queues do
    base = Config.Reader.read!(@config_exs, env: :prod)

    merged = Config.Reader.merge(base, [{:barkpark_cloud, [{Oban, [queues: runtime_queues()]}]}])

    merged
    |> Keyword.fetch!(:barkpark_cloud)
    |> Keyword.fetch!(Oban)
    |> Keyword.fetch!(:queues)
  end

  defp declared_slots, do: prod_queues() |> Keyword.values() |> Enum.sum()

  # The literal keyword list `runtime.exs` binds to `oban_queues` on the
  # NOT-disabled arm. Located by AST so a reformat cannot move it out of reach.
  defp runtime_queues do
    lists =
      @runtime_exs
      |> ast()
      |> collect(fn
        {:=, _, [{:oban_queues, _, ctx}, rhs]} when is_atom(ctx) -> {:ok, rhs}
        _ -> :skip
      end)
      |> Enum.flat_map(&keyword_literals/1)

    case lists do
      [queues] ->
        queues

      other ->
        flunk(
          "expected exactly one literal queue keyword list bound to `oban_queues` in " <>
            "#{@runtime_exs}, found #{length(other)}: #{inspect(other)}"
        )
    end
  end

  # `System.get_env("POOL_SIZE") || "10"` — the prod default.
  defp pool_size_default do
    defaults =
      @runtime_exs
      |> ast()
      |> collect(fn
        {:||, _, [{{:., _, [{:__aliases__, _, [:System]}, :get_env]}, _, ["POOL_SIZE"]}, default]}
        when is_binary(default) ->
          {:ok, String.to_integer(default)}

        _ ->
          :skip
      end)

    case defaults do
      [n] ->
        n

      other ->
        flunk(
          "expected exactly one `System.get_env(\"POOL_SIZE\") || \"<n>\"` default in " <>
            "#{@runtime_exs}, found #{length(other)}: #{inspect(other)}"
        )
    end
  end

  defp ast(path), do: path |> File.read!() |> Code.string_to_quoted!()

  defp collect(ast, matcher) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case matcher.(node) do
          {:ok, value} -> {node, [value | acc]}
          :skip -> {node, acc}
        end
      end)

    Enum.reverse(acc)
  end

  # Every keyword-list literal of atom => integer reachable under `node`.
  defp keyword_literals(node) do
    collect(node, fn
      list when is_list(list) ->
        if list != [] and
             Enum.all?(list, &match?({k, v} when is_atom(k) and is_integer(v), &1)),
           do: {:ok, list},
           else: :skip

      _ ->
        :skip
    end)
  end
end
