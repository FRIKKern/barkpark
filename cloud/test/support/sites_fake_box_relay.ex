defmodule BarkparkCloud.Sites.FakeBoxRelay do
  @moduledoc """
  An in-memory BOX — the test double for `BarkparkCloud.Sites.BoxRelay`
  (site-spawner D22). Wired in via `config/test.exs`.

  A static deploy really happens on the instance: `deploy/site-deploy.sh` walks
  PLAN → BUILD → STAGE → HEALTH → SWITCH → RETIRE, and the control plane drives it
  over the admin relay. This fake stands in for that box so the driver's whole
  contract — the stage CAS stream, the honest failure at HEALTH, the sub-second
  rollback, an unreachable instance — is proven with ZERO network, zero shell, and
  zero npm.

  Owner-keyed like `StudioLinkFakeHttpClient`: the store lives in one Agent keyed
  by the programming process's pid, and a child process (a driver Task) finds its
  owner by walking `$callers`. `async: true` tests never bleed into each other.

  ## Programming

      # The happy path: six stages, all done, then live.
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE))])

      # A build that dies at HEALTH — SWITCH never happens, visitors keep the old build.
      FakeBoxRelay.program(
        polls: [
          FakeBoxRelay.failed_at("HEALTH", "health probe returned 500 — the build marker was missing")
        ]
      )

      # Poll responses are consumed in order; the LAST one repeats, so a driver
      # that polls more times than programmed sees a stable terminal state.

  Every call is recorded (`calls/0`) so a test can prove WHAT was sent to the box —
  the deploy payload's scrubbed env, the rollback mode — not merely that something
  was.
  """

  @behaviour BarkparkCloud.Sites.BoxRelay

  @store __MODULE__.Store

  ## ---------------------------------------------------------------------------
  ## Programming API (test process)
  ## ---------------------------------------------------------------------------

  @doc """
  Program the fake box for the calling process.

  Options:

    * `:start` — the reply to `start_deploy/2` (default `{:ok, 202, %{"status" => "started"}}`).
      A LIST is consumed in order and the last entry repeats — the same semantics
      `:polls` has, so a test can drive a start RETRY (deploy-truth W2: a
      transient 5xx on the trigger, then the 409 the box answers once the run it
      already took is in flight).
    * `:polls` — a list of `poll_deploy/3` replies, consumed in order; the last repeats
    * `:rollback` — the reply to `rollback/2` (default: a successful flip)
  """
  def program(opts) when is_list(opts) do
    ensure_store()
    # Captured OUT HERE: inside an Agent callback `self()` is the agent, so
    # programming would land under the agent's own pid and every test would share
    # (and clobber) one entry.
    owner = self()

    Agent.update(@store, fn state ->
      Map.put(state, owner, %{
        start: Keyword.get(opts, :start, {:ok, 202, %{"status" => "started"}}),
        polls: Keyword.get(opts, :polls, []),
        rollback: Keyword.get(opts, :rollback, {:ok, 200, %{"status" => "rolled_back"}}),
        teardown: Keyword.get(opts, :teardown, {:ok, 200, %{"status" => "torn_down"}}),
        calls: []
      })
    end)

    :ok
  end

  @doc "Every call the box received, oldest first: `{:start_deploy | :poll_deploy | :rollback, payload}`."
  def calls do
    ensure_store()
    key = owner()

    @store
    |> Agent.get(fn state -> get_in(state, [key, :calls]) || [] end)
    |> Enum.reverse()
  end

  @doc """
  A box report in which `done` names every stage that finished. A terminal RETIRE
  makes the run succeeded; anything short of that is still running.
  """
  def walk(stage_names, opts \\ []) do
    stages =
      Enum.map(stage_names, fn n ->
        %{"name" => n, "status" => "done", "detail" => "#{n} ok"}
      end)

    state = if "RETIRE" in stage_names, do: "succeeded", else: "running"

    {:ok, 200,
     %{
       "state" => Keyword.get(opts, :state, state),
       "stages" => stages,
       "url" => Keyword.get(opts, :url)
     }}
  end

  @doc """
  A box report in which the run died AT `stage` — everything before it is done,
  `stage` is failed, and nothing after it ran. This is the shape that proves a
  broken build never reaches visitors: a HEALTH failure means SWITCH never happened.
  """
  def failed_at(stage, reason) do
    order = BarkparkCloud.Sites.Deploy.stages()
    idx = Enum.find_index(order, &(&1 == stage))

    stages =
      order
      |> Enum.take(idx + 1)
      |> Enum.map(fn n ->
        if n == stage do
          %{"name" => n, "status" => "failed", "detail" => reason}
        else
          %{"name" => n, "status" => "done", "detail" => "#{n} ok"}
        end
      end)

    {:ok, 200, %{"state" => "failed", "stages" => stages, "failure_reason" => reason}}
  end

  ## ---------------------------------------------------------------------------
  ## BoxRelay behaviour
  ## ---------------------------------------------------------------------------

  @impl true
  def start_deploy(_bp, payload) do
    record({:start_deploy, payload})

    case fetch(:start, {:ok, 202, %{"status" => "started"}}) do
      replies when is_list(replies) -> next_start(replies)
      reply -> reply
    end
  end

  @impl true
  def poll_deploy(_bp, slug, build_id) do
    record({:poll_deploy, %{slug: slug, build_id: build_id}})
    next_poll()
  end

  @impl true
  def rollback(_bp, payload) do
    record({:rollback, payload})
    fetch(:rollback, {:ok, 200, %{"status" => "rolled_back"}})
  end

  @impl true
  def teardown(_bp, payload) do
    record({:teardown, payload})
    fetch(:teardown, {:ok, 200, %{"status" => "torn_down"}})
  end

  ## ---------------------------------------------------------------------------
  ## Store
  ## ---------------------------------------------------------------------------

  # A sequenced `:start`, same contract as `:polls` — consumed in order, the last
  # entry repeats so a driver that retries more than the test programmed sees a
  # stable answer rather than a surprise default. `replies` is never empty here
  # (an empty list would have been fetched as the falsy-safe default).
  defp next_start(replies) do
    key = owner()

    Agent.get_and_update(@store, fn state ->
      case get_in(state, [key, :start]) do
        [only] -> {only, state}
        [next | rest] -> {next, put_in(state, [key, :start], rest)}
        _ -> {List.last(replies), state}
      end
    end)
  end

  defp next_poll do
    ensure_store()
    key = owner()

    Agent.get_and_update(@store, fn state ->
      case get_in(state, [key, :polls]) do
        # The last programmed reply REPEATS: a driver that polls once more than the
        # test programmed sees a stable terminal state, not a surprise default.
        [only] ->
          {only, state}

        [next | rest] ->
          {next, put_in(state, [key, :polls], rest)}

        _ ->
          {{:ok, 200, %{"state" => "running", "stages" => []}}, state}
      end
    end)
  end

  defp fetch(field, default) do
    ensure_store()
    key = owner()
    Agent.get(@store, fn state -> get_in(state, [key, field]) || default end)
  end

  defp record(call) do
    ensure_store()
    key = owner()

    Agent.update(@store, fn state ->
      case state[key] do
        %{calls: calls} = entry -> Map.put(state, key, %{entry | calls: [call | calls]})
        _ -> state
      end
    end)
  end

  # The programming process: this process if it programmed, else the nearest
  # `$callers` ancestor that did (a driver Task inherits its test's programming —
  # the same ancestry the DataCase sandbox drain rides).
  #
  # Resolved in the CALLING process, never inside an Agent callback: an
  # Agent.get/2 function runs in the AGENT, where `self()` is the agent and
  # `$callers` is the agent's — so an owner resolved in there would answer for the
  # wrong process (and, for `calls/0`, make the agent call itself).
  defp owner do
    keys = Agent.get(@store, &Map.keys/1)
    Enum.find([self() | Process.get(:"$callers", [])], self(), &(&1 in keys))
  end

  defp ensure_store do
    case Process.whereis(@store) do
      nil ->
        case Agent.start(fn -> %{} end, name: @store) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
