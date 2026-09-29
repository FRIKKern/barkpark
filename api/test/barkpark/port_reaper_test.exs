defmodule Barkpark.PortReaperTest do
  @moduledoc """
  task-aa975de15eff4e6b — `Barkpark.PortReaper.reap/1` ends the OS process, not
  just the port. The stub (`exec sleep 30`) cannot notice stdin EOF and never
  writes, so it cannot die to SIGPIPE: it is gone only if it was SIGNALLED.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortReaper
  alias Barkpark.Test.OsProcess

  defp spawn_eof_ignorer do
    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        :exit_status,
        args: ["-c", "exec sleep 30"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> OsProcess.kill(os_pid) end)
    {port, os_pid}
  end

  test "POSITIVE CONTROL: a bare Port.close leaves this child running" do
    # Without this arm the reap test below could pass on a stub that exits on
    # EOF by itself, proving nothing about the kill.
    {port, os_pid} = spawn_eof_ignorer()
    Port.close(port)
    Process.sleep(200)
    assert OsProcess.alive?(os_pid), "the stub died on a bare close; it cannot discriminate"
  end

  test "reap/1 closes the port AND the OS process is gone" do
    {port, os_pid} = spawn_eof_ignorer()
    assert PortReaper.reap(port) == :ok
    assert Port.info(port) == nil

    assert OsProcess.gone_within?(os_pid),
           "os pid #{os_pid} survived reap/1 — closing a port sends the child no signal"
  end

  test "Port.close/1 is called in api/lib ONLY by the reaper" do
    lib = Path.expand("../../lib", __DIR__)
    files = Path.wildcard(Path.join(lib, "**/*.ex"))
    # Positive control: the scan reaches the file that MUST contain a call.
    assert Path.join(lib, "barkpark/port_reaper.ex") in files

    callers =
      for file <- files,
          {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not String.starts_with?(String.trim_leading(line), "#"),
          String.contains?(line, "Port.close("),
          do: "#{Path.relative_to(file, lib)}:#{n}"

    only_the_reaper? =
      match?([_], callers) and String.starts_with?(hd(callers), "barkpark/port_reaper.ex:")

    assert only_the_reaper?,
           "a spawned-program port is closed without reaping its OS process: #{inspect(callers)} " <>
             "— route it through Barkpark.PortReaper.reap/1 (task-aa975de15eff4e6b)"
  end

  test "reap/1 on an already-closed port, or a non-port, never raises" do
    {port, _os_pid} = spawn_eof_ignorer()
    PortReaper.reap(port)
    assert PortReaper.reap(port) == :ok
    assert PortReaper.reap(nil) == :ok
  end
end
