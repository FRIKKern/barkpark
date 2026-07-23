defmodule BarkparkCloud.PushFakeAdapter do
  @moduledoc """
  Process-local fake `BarkparkCloud.Push.Adapter` (push-relay spike).

  Wired as `:push_adapter` in config/test.exs. Worker tests execute jobs
  IN-PROCESS (`Oban.Testing.perform_job/2`), so programming the verdict and
  recording sends in the test process's dictionary is async-safe — no global
  mutable state, no cross-test bleed (each ExUnit test is its own process).

      PushFakeAdapter.program({:error, :unregistered})
      perform_job(PushDeliveryWorker, args)
      assert [{%DevicePushToken{}, notification}] = PushFakeAdapter.sent()

  Unprogrammed default: `{:ok, :sent}` (the happy 2xx path).
  """

  @behaviour BarkparkCloud.Push.Adapter

  @verdict_key {__MODULE__, :verdict}
  @sent_key {__MODULE__, :sent}

  @doc "Program the verdict every subsequent `send_push/2` in this process returns."
  def program(verdict), do: Process.put(@verdict_key, verdict)

  @doc "Every `{device_token, notification}` sent in this process, oldest first."
  def sent, do: Process.get(@sent_key, []) |> Enum.reverse()

  @impl true
  def send_push(device_token, notification) do
    Process.put(@sent_key, [{device_token, notification} | Process.get(@sent_key, [])])
    Process.get(@verdict_key, {:ok, :sent})
  end
end
