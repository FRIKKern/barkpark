defmodule BarkparkWeb.LiveSettle do
  @moduledoc """
  MAILBOX QUIESCENCE for a LiveViewTest `view` — the thing `render/1` is not.

  `Phoenix.LiveViewTest.render/1` is ONE BARRIER, NOT A DRAIN. It is a single
  `GenServer.call(pid, {:phoenix, :ping})`
  (`deps/phoenix_live_view/lib/phoenix_live_view/channel.ex:53-55`), so it
  orders only against the messages that were ALREADY IN THE MAILBOX when the
  ping arrived. A LiveView that enqueues to ITSELF while handling the current
  message — `send(self(), {:paper_op, …})` in
  `BarkparkWeb.Studio.PaperFieldBlock.persist/4` is the canonical one here —
  leaves that generation BEHIND the ping, and `render/1` returns with the write
  still pending. `:sys.get_state/1` has exactly the same property: it is also a
  `GenServer.call`, so it is also one barrier, not a drain.

  `settle!/2` converges instead: barrier, read
  `:erlang.process_info(pid, :message_queue_len)`, barrier, and require TWO
  CONSECUTIVE quiet readings before declaring the process settled. One empty
  reading can be the window between a message arriving and the process
  dequeuing it; two, with a full barrier between them, cannot be the middle of
  a self-send chain — every generation is enqueued strictly before the barrier
  that precedes the second reading is answered. Fuel is bounded and exhaustion
  is a NAMED `flunk`, never a silent give-up, and never a sleep.

  ## The barrier is a PARAMETER, not a constant

  `render/1` is the right barrier almost everywhere and is the default. It is
  the WRONG barrier inside a measurement window that counts what happens in it
  (PR #19712's `derives_during/2` measures `Caps.derive/1` calls and therefore
  uses `:sys.get_state/1`, which does not run the render pipeline). Pass
  `barrier: &:sys.get_state(&1.pid)` — or any 1-arity fun over the view — when
  the render itself would perturb what is being measured.

  ## SCOPE LIMIT — a timer-armed generation is invisible here

  A message armed with `Process.send_after/3` is NOT in the mailbox until it
  fires. `message_queue_len` reads 0 and this function calls the process quiet
  while that generation is still pending. `settle!/2` covers ZERO-DELAY
  self-send chains (`send(self(), …)` / `send_update/2`) only. A timer chain
  needs its own wait keyed on the effect, not on the mailbox — e.g.
  `lib/barkpark_web/live/chat_live.ex:661` arms `{:interrupt_timeout, …}` via
  `Process.send_after/3` from `handle_event("stop_turn", …)`.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @default_fuel 50

  @doc """
  Barrier until `view`'s LiveView process reports an empty mailbox on two
  consecutive readings.

  Options:

    * `:barrier` — 1-arity fun run against the view between readings.
      Default `&Phoenix.LiveViewTest.render/1`.
    * `:fuel` — maximum barrier/reading rounds before flunking. Default 50.
    * `:label` — what the caller was doing, quoted in the flunk so a wedged
      process names the chain that wedged it.
  """
  def settle!(view, opts \\ []) do
    barrier = Keyword.get(opts, :barrier, &Phoenix.LiveViewTest.render/1)
    fuel = Keyword.get(opts, :fuel, @default_fuel)
    label = Keyword.get(opts, :label, "settle!/2")

    converge(view, barrier, label, fuel, 0, fuel)
  end

  defp converge(_view, _barrier, _label, _fuel0, 2, _fuel), do: :ok

  defp converge(_view, _barrier, label, fuel0, _quiet, 0) do
    flunk("""
    the LiveView never went quiet after #{label}: #{fuel0} barriers and its \
    mailbox was still non-empty. Either the chain grew a repeating self-message, \
    or the process is wedged, or it is no longer alive.\
    """)
  end

  defp converge(view, barrier, label, fuel0, quiet, fuel) do
    barrier.(view)

    case :erlang.process_info(view.pid, :message_queue_len) do
      {:message_queue_len, 0} -> converge(view, barrier, label, fuel0, quiet + 1, fuel - 1)
      _ -> converge(view, barrier, label, fuel0, 0, fuel - 1)
    end
  end
end
