defmodule BarkparkWeb.Studio.TmuxConsoleTest do
  # Flips the global :tmux_console config, so not async.
  use ExUnit.Case, async: false

  alias BarkparkWeb.Studio.TmuxConsole

  defmodule PresentPty do
    def spawn(_exe, _args, _opts), do: {:ok, :pty}
  end

  setup do
    prev = Application.get_env(:barkpark, :tmux_console)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :tmux_console, prev),
        else: Application.delete_env(:barkpark, :tmux_console)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end

  test "a backend module that is in the build is the backend, and the console is enabled" do
    Application.put_env(:barkpark, :tmux_console, enabled: true, backend: PresentPty)
    assert TmuxConsole.backend() == PresentPty
    assert TmuxConsole.enabled?()
  end

  # The Windows build: config.exs names ExPTY, but the :expty dep is left out.
  test "a configured backend module that is not in the build reads as no backend, and the console is not enabled" do
    Application.put_env(:barkpark, :tmux_console,
      enabled: true,
      backend: NoSuchPtyBackendInThisBuild
    )

    assert TmuxConsole.backend() == nil
    refute TmuxConsole.enabled?()

    assert TmuxConsole.start_terminal(%{cols: 80, rows: 24, sink: self()}) == {:error, :disabled}
  end

  test "no backend configured reads as no backend" do
    Application.put_env(:barkpark, :tmux_console, enabled: true)
    assert TmuxConsole.backend() == nil
    refute TmuxConsole.enabled?()
  end
end
