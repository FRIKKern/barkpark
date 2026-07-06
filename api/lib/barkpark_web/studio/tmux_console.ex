defmodule BarkparkWeb.Studio.TmuxConsole do
  @moduledoc """
  Gate + PTY seam for the Studio **tmux console** (`/studio/tmux`).

  A browser terminal attached to a real `tmux` session on the host Studio runs
  on — by construction an arbitrary-code-execution surface. It is **ON by
  default on every Studio**, held safe by three controls:

    1. **Admin-only.** The `/studio/tmux` route rides the `:admin_studio`
       live_session, so its `on_mount` requires an admin token / account.
       Reaching the shell requires an admin credential ON THAT HOST. The nav
       tab is likewise shown only to admins (`shares_admin?`).
    2. **Public-demo hard refuse.** `enabled?/0` returns false whenever
       `public_demo_studio` is on — a host that opens Studio to anonymous
       visitors must NEVER expose a shell. This is fail-closed and not
       overridable by the enable flag.
    3. **Per-host opt-out.** `BARKPARK_TMUX_CONSOLE=0` (runtime.exs) disables
       it on a given host; `enabled?/0` also requires a compiled PTY backend.

  The PTY backend module is read from config and invoked via `apply/3` (no
  static `ExPTY.*` reference), so the seam stays swappable — tests inject a
  fake backend the same way.
  """

  require Logger

  @default_session "barkpark-studio"
  @default_cols 80
  @default_rows 24
  @min_dim 1
  @max_dim 1000

  @doc """
  Whether the console may run on this host. ON by default; requires a compiled
  PTY backend and the enable flag (default on, opt out via env), and is
  HARD-REFUSED whenever anonymous Studio is on (`public_demo_studio`). Both the
  nav tab (admin-only) and the LiveView mount gate on this.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    backend() != nil and flag_on?() and not public_demo?()
  end

  # Enable flag defaults ON; only an explicit `enabled: false` (base config or
  # BARKPARK_TMUX_CONSOLE=0 via runtime.exs) turns it off.
  defp flag_on?, do: Keyword.get(config(), :enabled, true) != false

  # Fail-closed: a host that serves Studio to anonymous visitors must never
  # expose a shell, regardless of the enable flag.
  defp public_demo?, do: Application.get_env(:barkpark, :public_demo_studio, false) == true

  @doc "The configured PTY backend module (e.g. `ExPTY`), or nil if none."
  @spec backend() :: module() | nil
  def backend, do: Keyword.get(config(), :backend)

  @doc "Shared tmux session name — one persistent session across reconnects."
  @spec session_name() :: String.t()
  def session_name, do: Keyword.get(config(), :session, @default_session)

  @doc """
  Spawn a `tmux` client attached to (or creating) the shared session.

  `sink` is the pid that receives `{:pty_out, binary}` for every chunk of
  terminal output and `:pty_exit` when the client process ends. Returns
  `{:ok, pty}` or `{:error, reason}`.

  `tmux new-session -A` attaches when the session already exists and creates
  it otherwise — so a LiveView reconnect re-attaches to the SAME session with
  scrollback and running programs intact.
  """
  @spec start_terminal(%{cols: integer(), rows: integer(), sink: pid()}) ::
          {:ok, term()} | {:error, atom()}
  def start_terminal(%{cols: cols, rows: rows, sink: sink}) when is_pid(sink) do
    {exe, args} = command()

    cond do
      backend() == nil ->
        {:error, :disabled}

      System.find_executable(exe) == nil ->
        {:error, :tmux_not_found}

      true ->
        tmux = System.find_executable(exe)

        opts = [
          name: "xterm-256color",
          cols: clamp_dim(cols, @default_cols),
          rows: clamp_dim(rows, @default_rows),
          env: term_env(),
          cwd: default_cwd(),
          on_data: fn _, _, data -> send(sink, {:pty_out, data}) end,
          on_exit: fn _, _, _code, _sig -> send(sink, :pty_exit) end
        ]

        safe(fn -> apply(backend(), :spawn, [tmux, args, opts]) end, {:error, :spawn_failed})
    end
  end

  @doc "Forward user keystrokes to the PTY."
  @spec send_input(term(), binary()) :: :ok
  def send_input(pty, data) when is_binary(data) do
    safe(fn -> apply(backend(), :write, [pty, data]) end, :ok)
    :ok
  end

  @doc "Resize the PTY (SIGWINCH) so tmux repaints at the new geometry."
  @spec resize(term(), integer(), integer()) :: :ok
  def resize(pty, cols, rows) do
    c = clamp_dim(cols, @default_cols)
    r = clamp_dim(rows, @default_rows)
    safe(fn -> apply(backend(), :resize, [pty, c, r]) end, :ok)
    :ok
  end

  @doc "Kill the tmux CLIENT (SIGKILL). The tmux SESSION survives — detach, not destroy."
  @spec close(term()) :: :ok
  def close(pty) do
    safe(fn -> apply(backend(), :kill, [pty, 9]) end, :ok)
    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp config, do: Application.get_env(:barkpark, :tmux_console, [])

  # The process the PTY launches. Defaults to attaching (or creating) the
  # shared tmux session; `-A` = attach-if-exists, else new. Overridable via
  # config (tests inject a trivial command so they don't require tmux).
  defp command do
    case Keyword.get(config(), :command) do
      {exe, args} when is_binary(exe) and is_list(args) -> {exe, args}
      _ -> {"tmux", ["new-session", "-A", "-s", session_name()]}
    end
  end

  defp clamp_dim(n, _default) when is_integer(n), do: n |> max(@min_dim) |> min(@max_dim)
  defp clamp_dim(_n, default), do: default

  defp term_env do
    System.get_env()
    |> Map.put("TERM", "xterm-256color")
  end

  defp default_cwd do
    Keyword.get(config(), :cwd) || File.cwd!()
  end

  # The PTY backend is native code; never let a backend crash take the caller
  # (LiveView) down. Log and return the fallback.
  defp safe(fun, fallback) do
    fun.()
  rescue
    e ->
      Logger.warning("tmux console PTY op failed: #{inspect(e)}")
      fallback
  catch
    kind, reason ->
      Logger.warning("tmux console PTY op threw: #{inspect({kind, reason})}")
      fallback
  end
end
