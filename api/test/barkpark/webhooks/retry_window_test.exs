defmodule Barkpark.Webhooks.RetryWindowTest do
  @moduledoc """
  task-ebb207785fcb75ec: the twin's webhook was switched off after 52 failed
  deliveries during a receiver restart of about 2 minutes. Each delivery gave
  up after about 6 seconds, so every event in the outage counted toward the
  20-failure auto-disable latch.

  These tests pin the default retry table: one delivery must keep retrying
  longer than a short outage, and no retry may wait long enough for the
  stuck-delivery sweeper to take the row.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Webhooks.{Dispatcher, StuckDeliverySweeper}

  # The shortest time a delivery spends retrying before it gives up: each
  # tier's jitter is at least half its base, capped at the ceiling.
  defp shortest_retry_window_ms do
    Dispatcher.retry_delays()
    |> Enum.take(Dispatcher.max_attempts() - 1)
    |> Enum.map(&min(div(&1, 2), Dispatcher.jitter_ceiling_ms()))
    |> Enum.sum()
  end

  test "a delivery retries for longer than a 2-minute outage before it gives up" do
    assert length(Dispatcher.retry_delays()) >= Dispatcher.max_attempts() - 1
    assert shortest_retry_window_ms() > 4 * 60_000
  end

  test "the jitter ceiling sits strictly below the sweeper's stuck threshold" do
    assert Dispatcher.jitter_ceiling_ms() < StuckDeliverySweeper.stuck_after_seconds() * 1000
  end
end
