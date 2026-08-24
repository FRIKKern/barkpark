defmodule Barkpark.Tenancy.WorkspaceBundle.Janitor do
  @moduledoc """
  Boot-time collector for workspace-bundle temp files a dead BEAM left behind.

  ## Why this exists (measured, not argued — PDS-D210)

  The export engine wraps every spill file and the tar in `try/after File.rm/1`,
  and that cover is real: a socket killed mid-transfer of a 300 MB `send_file`
  raises a CATCHABLE `Bandit.TransportError` and the `after` clause FIRES. What
  it does not cover is a brutal `Process.exit(pid, :kill)` — measured, the file
  leaked — and, one level worse, the scenario the spill exists to survive at
  all: the Linux OOM killer, which SIGKILLs the entire BEAM OS process so that
  no `after` clause anywhere in the VM runs.

  Before the spill, one stray tar leaked per crash. With the spill, a crash
  strands up to one file per copied table (62 on the full set) on exactly the
  box whose disk headroom is the premise of the streaming design. The mechanism
  that still works when `after` cannot run is: **a crashed BEAM's leftovers are
  collected by its successor.**

  ## Shape: boot-only, not periodic

  The sweep runs once, asynchronously, as a temporary child of the application
  supervisor. It is deliberately NOT periodic. A periodic sweeper buys very
  little extra coverage — the leak is created by a crash, and a crash is
  followed by a boot — while permanently exposing a live concurrent export to
  the sweep's delete path. Boot-only keeps the dangerous window to the one
  moment when this node, by definition, owns no in-flight export of its own.

  ## The contract with the engine: filenames and one config key

  This module deliberately imports nothing from the export engine. It depends
  on exactly two things, both stable across the engine's own refactors:

    * the **filename prefixes** `bp-ws-bundle-` (the tar, already produced by
      `WorkspaceBundle.Archive`), `bp-ws-spill-` (the per-table spill files) and
      `bp-ws-import-` (the import scratch — the FIRST candidate that is a
      DIRECTORY, holding the spilled request body plus the extracted members).
      `remove/1` has always been `File.rm_rf/1`, so a directory was already
      collectable; what it was NOT is visible — `candidates/1` sweeps by prefix,
      so an unregistered prefix leaves a multi-GB scratch stranded forever;
    * the **config key** `:bundle_spill_dir`, the directory both sides agree
      the files live in — the SAME key `WorkspaceBundle.Archive.spill_dir/0`
      reads (set in `config/config.exs`, overridable by
      `BARKPARK_BUNDLE_SPILL_DIR`). The janitor must sweep exactly where the
      engine writes, or it greens forever over an empty directory while spills
      pile up out of its sight — the silent-wrong-answer this epic keeps killing.

  ## The staleness threshold is DERIVED

  A naive "stale after five minutes" would delete a *completed* tar out from
  under a slow but healthy client mid-`send_file`. The default here is derived
  from measurement instead:

    * Wave 7 measured a full guerrilla export at **~130 s server-side alone** —
      the COPY + tar phase, before a single byte reaches the client.
    * That export produces a **~941 MB** bundle (PDS-D41: 941,046,272 bytes).
      A slow-but-healthy client draining it at a pessimistic 1 MB/s spends a
      further **~941 s** inside `send_file`.

  Worst-case legitimate lifetime of a temp file is therefore ~130 + ~941 ≈
  **~1071 s (~18 min)**. The default cutoff is **3600 s**, a ~3.4x margin over
  that worst case, which also absorbs a client an order of magnitude slower
  than the derivation's floor on the tar's tail. It is configurable via
  `:workspace_bundle_spill_max_age_seconds` for boxes whose links or datasets
  differ from the ones that were measured.

  ## The liveness guard

  Nothing in code enforces single-flight on the export route —
  `pipe_through([:api, :require_admin])` is an auth gate, not a concurrency
  gate — and blue/green slots share one real `/tmp` (`PrivateTmp=no`). So an
  mtime cutoff alone is not sufficient: the GREEN slot booting could delete
  files a live BLUE export still owns.

  The guard is a **pid-liveness sidecar**, chosen over a lockfile because a
  lockfile answers "was a lock taken?" while the question that actually
  matters here is "is the owner still running?" — and the whole premise of
  this module is an owner that died without cleaning up, i.e. exactly the case
  where a lockfile is still present and lies. A sidecar at `<path>.owner`
  carries the OS pid of the BEAM that created the file; `sweep/1` skips any
  candidate whose sidecar names a live OS process, however old the file is.

  Fail-safe direction is deliberate: an unreadable, malformed or
  undeterminable sidecar counts as ALIVE and the file is left alone. Missing a
  collection costs disk that the next boot reclaims; a wrong collection costs a
  live export. Sidecar-less files (everything the engine writes today) are
  governed by the derived mtime cutoff alone, which is why that cutoff has to
  be derived rather than guessed.

  Known limit, stated rather than hidden: OS pid reuse can make a dead owner
  look alive. That direction is the safe one — the file survives one extra boot.
  """

  require Logger

  alias Barkpark.Tenancy.WorkspaceBundle.Archive

  @bundle_prefix "bp-ws-bundle-"
  @spill_prefix "bp-ws-spill-"
  @scratch_prefix "bp-ws-import-"
  @owner_suffix ".owner"

  # See the moduledoc's derivation: ~130 s measured server-side (wave 7) plus
  # ~941 s to drain a ~941 MB bundle to a 1 MB/s client ≈ ~1071 s worst case;
  # 3600 s is a ~3.4x margin over it. Not a guess, and not five minutes.
  @default_max_age_seconds 3600

  # Bound on one `ps -p` liveness probe. `ps` normally answers in
  # milliseconds; a probe that takes longer than this is wedged (dead /proc,
  # NFS-backed procfs, a stopped port) and the sweep must ADVANCE rather than
  # hang the whole collection behind it — the rescue around sweep/1 never
  # fires for a blocked synchronous port read, because a hang raises nothing
  # (task-felix-w21-bl-janitor-ps-bound). Generous on purpose: the cost of a
  # timeout is one file kept until the next boot, so the bound only needs to
  # beat "forever", not be tight.
  @ps_probe_timeout_ms 5_000

  @doc """
  Child spec for the boot-time sweep.

  `:temporary` — the sweep runs once and is done. A one-shot child that has
  finished its work must never be restarted, and its exit must never count
  against the supervisor's restart budget.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> sweep(opts) end]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  The directory both the engine and this janitor agree the temp files live in.

  Configured via `:bundle_spill_dir` — the SAME key the engine's
  `WorkspaceBundle.Archive.spill_dir/0` reads, set in `config/config.exs` and
  overridable at runtime by `BARKPARK_BUNDLE_SPILL_DIR`. Reading the identical
  key is the whole handshake: the janitor sweeps precisely where the engine
  writes. The fallback below is defensive only — the key is always set in
  `config.exs`, and if it somehow were not, the engine's `fetch_env!` would
  raise before any spill is ever written, so there is nothing for the janitor
  to miss.
  """
  @spec spill_dir() :: String.t()
  def spill_dir do
    # ONE resolution site, `Archive.spill_dir_config/0` — not a second copy of
    # the same atom. Two modules spelling one key in two places is agreement by
    # coincidence: it survives until someone renames one of them, and then the
    # sweep goes quiet instead of going red (pds-w11-janitor-engine-handshake).
    # The FALLBACK stays here rather than in the shared resolver, because it is
    # this caller's policy and not the engine's: the janitor is a boot-time
    # `restart: :temporary` task and must never be what breaks a boot, whereas
    # an export with nowhere to spill must fail loudly. If the key really is
    # unset the engine raises before writing anything, so there is nothing here
    # for the janitor to miss — this branch keeps the sweep harmless, it is not
    # a second opinion about where spills live.
    case Archive.spill_dir_config() do
      {:ok, dir} -> dir
      :error -> Path.join(default_data_dir(), "bundle-spill")
    end
  end

  defp default_data_dir do
    case Application.get_env(:barkpark, :media_upload_dir) do
      dir when is_binary(dir) and dir != "" -> Path.dirname(dir)
      _ -> System.tmp_dir!()
    end
  end

  @doc """
  Seconds after which an unowned bundle/spill file is considered abandoned.

  Override with `:workspace_bundle_spill_max_age_seconds`. See the moduledoc
  for the derivation of the default; lowering it below the longest export +
  transfer this box actually serves will delete healthy exports mid-flight.
  """
  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds do
    case Application.get_env(:barkpark, :workspace_bundle_spill_max_age_seconds) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_age_seconds
    end
  end

  @doc """
  Claim ownership of `path` for the current OS process.

  Writes the pid sidecar the sweep's liveness guard reads. The export engine
  calls this beside each temp file it creates; `disown/1` removes the sidecar
  on the normal path. Both are best-effort by design — ownership marking must
  never be able to fail an export.
  """
  @spec own(Path.t()) :: :ok
  # Internal export/import callers provide engine-generated spill paths; the
  # sidecar suffix is fixed and never derived from request text.
  # sobelow_skip ["Traversal.FileModule"]
  def own(path) do
    File.write(owner_path(path), System.pid())
    :ok
  end

  @doc """
  Drop the ownership sidecar for `path`. Best-effort; see `own/1`.
  """
  @spec disown(Path.t()) :: :ok
  # Same engine-generated spill-path contract as own/1.
  # sobelow_skip ["Traversal.FileModule"]
  def disown(path) do
    File.rm(owner_path(path))
    :ok
  end

  @doc """
  Sweep the spill directory once, deleting abandoned bundle/spill files.

  Options (all defaulted from config; passed explicitly by tests so the sweep
  is exercisable without touching global application env):

    * `:dir` — directory to sweep (default `spill_dir/0`)
    * `:max_age_seconds` — staleness cutoff (default `max_age_seconds/0`)
    * `:now` — unix seconds treated as "now" (default `System.os_time/1`)
    * `:ps_path` — the `ps` executable the liveness probe runs (default
      `System.find_executable("ps")`; tests inject a stub here)
    * `:ps_timeout_ms` — bound on one liveness probe (default
      #{@ps_probe_timeout_ms} ms); a probe that exceeds it answers ALIVE

  Returns `{:ok, %{removed: [path], kept: n, skipped_live: n}}`. Never raises:
  this runs on the boot path and reclaiming disk is strictly best-effort.
  """
  @spec sweep(keyword()) :: {:ok, map()}
  def sweep(opts \\ []) do
    dir = Keyword.get(opts, :dir) || spill_dir()
    max_age = Keyword.get(opts, :max_age_seconds) || max_age_seconds()
    now = Keyword.get(opts, :now) || System.os_time(:second)
    probe_opts = Keyword.take(opts, [:ps_path, :ps_timeout_ms])

    result =
      dir
      |> candidates()
      |> Enum.reduce(%{removed: [], kept: 0, skipped_live: 0}, fn path, acc ->
        cond do
          owner_alive?(path, probe_opts) ->
            %{acc | skipped_live: acc.skipped_live + 1}

          stale?(path, now, max_age) ->
            remove(path)
            %{acc | removed: [path | acc.removed]}

          true ->
            %{acc | kept: acc.kept + 1}
        end
      end)

    result = %{result | removed: Enum.reverse(result.removed)}

    case result.removed do
      [] ->
        Logger.debug(
          "[WorkspaceBundle.Janitor] #{dir}: nothing to collect " <>
            "(#{result.kept} recent, #{result.skipped_live} live-owned)"
        )

      removed ->
        # Loud on purpose: every collected file is evidence that a previous
        # BEAM died without running its `after` clauses — an OOM kill, most
        # likely. That is an operational signal, not routine housekeeping.
        Logger.warning(
          "[WorkspaceBundle.Janitor] collected #{length(removed)} abandoned " <>
            "workspace-bundle temp file(s) from #{dir} — a previous run was " <>
            "killed without cleanup: #{Enum.map_join(removed, ", ", &Path.basename/1)}"
        )
    end

    {:ok, result}
  rescue
    error ->
      # A janitor that can fail a boot is worse than the leak it collects.
      Logger.warning("[WorkspaceBundle.Janitor] sweep skipped: #{Exception.message(error)}")
      {:ok, %{removed: [], kept: 0, skipped_live: 0}}
  end

  # Every bundle/spill entry in `dir`, excluding the `.owner` sidecars (which
  # match the same prefixes and are collected with their subject, never on
  # their own).
  defp candidates(dir) do
    [@bundle_prefix, @spill_prefix, @scratch_prefix]
    |> Enum.flat_map(fn prefix -> Path.wildcard(Path.join(dir, prefix <> "*")) end)
    |> Enum.reject(&String.ends_with?(&1, @owner_suffix))
    |> Enum.uniq()
  end

  defp stale?(path, now, max_age) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> now - mtime > max_age
      # Cannot tell how old it is → leave it. Fail-safe direction.
      _ -> false
    end
  end

  # `path` comes only from candidates/1, whose glob is rooted in the configured
  # spill directory and restricted to Barkpark's three fixed temp prefixes.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove(path) do
    File.rm_rf(path)
    File.rm(owner_path(path))
    :ok
  end

  defp owner_path(path), do: to_string(path) <> @owner_suffix

  # True when the sidecar names an OS process that still exists. Everything
  # undeterminable answers TRUE (= leave the file alone): a missed collection
  # costs disk the next boot reclaims, a wrong one costs a live export.
  # `path` is a candidates/1 result under the configured spill root; the owner
  # filename adds only the fixed sidecar suffix.
  # sobelow_skip ["Traversal.FileModule"]
  defp owner_alive?(path, probe_opts) do
    case File.read(owner_path(path)) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {pid, _} when pid > 0 -> os_process_alive?(pid, probe_opts)
          # A sidecar exists but is unreadable as a pid: assume live.
          _ -> true
        end

      {:error, :enoent} ->
        false

      # Sidecar present but unreadable (permissions, races): assume live.
      {:error, _} ->
        true
    end
  end

  # `ps -p` rather than `kill -0`: `kill -0` against a process owned by another
  # user answers EPERM, which is indistinguishable from "gone" by exit status
  # alone and would make us delete a live foreign slot's spill. `ps -p` reports
  # existence regardless of ownership on both Darwin and Linux.
  #
  # BOUNDED via the repo-standard async_nolink + `Task.yield || Task.shutdown`
  # shape (task-felix-w21-bl-janitor-ps-bound): a synchronous `System.cmd`
  # here had no bound, and a blocked port read raises nothing, so a wedged
  # `ps` silently hung the one-shot sweep Task forever and every remaining
  # candidate went unevaluated. Every undeterminable outcome — timeout, task
  # crash, TaskSupervisor unavailable — answers TRUE (alive), the fail-safe
  # direction: a hung probe must never let the janitor delete a bundle.
  # Requires `Barkpark.TaskSupervisor`, which application.ex starts BEFORE
  # this janitor's one-shot child.
  #
  # `ps` is resolved by System.find_executable/1 (tests may inject a stub path
  # via sweep's `:ps_path`) and pid is converted to one argv element; no shell
  # or command-string interpolation is involved.
  # sobelow_skip ["CI.System"]
  defp os_process_alive?(pid, probe_opts) do
    case Keyword.get(probe_opts, :ps_path) || System.find_executable("ps") do
      nil ->
        true

      ps ->
        timeout = Keyword.get(probe_opts, :ps_timeout_ms) || @ps_probe_timeout_ms

        task =
          Task.Supervisor.async_nolink(Barkpark.TaskSupervisor, fn ->
            System.cmd(ps, ["-p", Integer.to_string(pid)], stderr_to_stdout: true)
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {_out, 0}} -> true
          {:ok, {_out, _}} -> false
          # Timeout (nil), task crash ({:exit, _}): undeterminable → alive.
          _ -> true
        end
    end
  rescue
    _ -> true
  catch
    # async_nolink against a not-yet-started supervisor exits rather than
    # raises; an exit must degrade to "alive", never kill the sweep.
    :exit, _ -> true
  end
end
