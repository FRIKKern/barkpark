defmodule Barkpark.Tenancy.WorkspaceBundle.InvalidBundleError do
  @moduledoc """
  The request body is not a readable bp-export-v1 bundle (PDS-D50).

  Raised — never coerced to a partial import — when the bytes cannot be a
  bundle at all: empty, truncated mid-stream, not a tar, or a tar carrying no
  `manifest.json`. Before this existed `Archive.unpack/1` hard-matched
  `{:ok, entries} = :erl_tar.extract(…)`, so a zero-byte or truncated body
  (exactly what a streamed pull produces on a dropped connection) raised
  `MatchError` and the caller got an opaque 500 with a request_id it could not
  resolve. The HTTP edge turns this into an honest 422 `invalid_bundle`.

  `code` is stable and machine-branchable: `"invalid_bundle"`.
  """
  defexception [:code, :message]

  @type t :: %__MODULE__{code: String.t(), message: String.t()}
end

defmodule Barkpark.Tenancy.WorkspaceBundle.Archive do
  @moduledoc """
  The bp-export-v1 container: a tar carrying a `manifest.json` plus one
  `tables/<name>.copy` member per exported table (charter D1). The `.copy`
  members are the RAW `COPY … TO STDOUT` text bytes — the byte carrier
  (charter D2), never `Envelope.render` output (charter D9).

  Packing is FILE-TO-FILE and constant-memory (PDS-D199 + PDS-D204): each table
  member is a per-table SPILL file the producer streamed to disk, added to the
  tar by PATH — `:erl_tar` reads an added file in bounded 64 KiB chunks — and
  deleted the moment it is in. (PDS-D207 is the BYTE-IDENTITY gate on that
  packing, not the constant-memory ruling; the moduledoc used to mis-credit it.)

  Unpacking has TWO shapes and they are not interchangeable:

    * `unpack/1` takes the whole bundle as a BINARY and answers
      `%{table => copy_bytes}`. Peak is ~3x the archive. It is kept — not
      deprecated — because it is the contract the bundle test suite asserts
      against: twenty `refute dumps[table] =~ "<marker>"` CROSS-TENANT
      ISOLATION tripwires read those bytes directly, and under a path-valued
      map every one of them would pass VACUOUSLY (a path does not contain the
      marker; the bytes it names do). Small bundles and tests use this.
    * `unpack_to_dir/2` takes a bundle PATH and extracts to a directory,
      answering `%{table => member_path}`. This is the production import path.
      Peak is **1x the largest single member** — measured, and deliberately NOT
      called "constant memory": `:erl_tar` has no chunked EXTRACT API, so the
      largest member is still materialised once inside `:erl_tar` while it is
      written out. On guerrilla today that residual is ~1.31 GB
      (`mutation_events`), down from ~7.8 GB of BEAM for the binary shape.

  Extracting to a directory writes ATTACKER-SUPPLIED MEMBER NAMES to disk,
  which `[:memory]` extraction was immune to by construction. `unpack_to_dir/2`
  therefore validates the tar's table of contents BEFORE a single byte lands:
  only `manifest.json` and `tables/<name>.copy` with a name carrying no path
  separator and no `..` are accepted, every member must be a REGULAR file (no
  symlinks, no directories), and anything else is refused BY NAME.
  """

  alias Barkpark.Tenancy.WorkspaceBundle.InvalidBundleError
  # Archive ⇄ Janitor is a deliberate two-way collaboration, not a layering
  # slip: Archive asks the Janitor to MARK liveness on files it creates, and the
  # Janitor asks Archive WHERE those files live (`spill_dir_config/0`) and what
  # they are named (`scratch_prefix/0`). Both directions are plain runtime
  # function calls — no macros, no structs — so there is no compile cycle.
  alias Barkpark.Tenancy.WorkspaceBundle.Janitor

  @format "bp-export-v1"
  @grain "workspace"
  @manifest_name ~c"manifest.json"

  # The janitor's contract (pds-w11-spill-janitor sweeps by prefix): a per-table
  # streamed dump is `bp-ws-spill-*`, the assembled tar is `bp-ws-bundle-*`.
  # Every name carries `System.unique_integer/1` because the blue and green
  # slots share ONE real /tmp (`PrivateTmp=no`), so two concurrent exports on
  # the same box must never collide on a filename.
  @spill_prefix "bp-ws-spill-"
  @bundle_prefix "bp-ws-bundle-"
  # A THIRD prefix, and the first that names a DIRECTORY: the import scratch
  # holding the spilled request body plus the extracted members. The janitor's
  # `remove/1` already `File.rm_rf`s, so a directory is collectable — but its
  # `candidates/1` sweeps by prefix, so an unregistered prefix is invisible to
  # it. Registered there in the same commit that introduced this one.
  @scratch_prefix "bp-ws-import-"

  # A memory-backed filesystem defeats the entire point of spilling: the bytes
  # we "wrote to disk" would still be resident, and a ~941 MB export would
  # reproduce the RSS peak it exists to remove.
  @memory_backed_fstypes ~w(tmpfs ramfs devtmpfs)

  @doc """
  Pack a manifest map + a `%{table => spill_path}` map into a bundle tar ON
  DISK, returning the tar's path. The caller owns the returned file and must
  delete it.

  Each spill is deleted the MOMENT it has been added, so peak transient disk is
  `tar-so-far + the largest single table` rather than twice the bundle.

  ## Byte-identity (PDS-D207)

  Four conditions, each independently proven necessary on OTP 27, keep the tar
  byte-identical to what the old in-memory `:erl_tar.create/3` produced:

    1. `manifest.json` is added FIRST — manifest-last diverges at char 1.
    2. `{:mtime, _}` / `{:atime, _}` / `{:ctime, _}` / `{:uid, 0}` / `{:gid, 0}`
       are passed EXPLICITLY on every add; without them the real stat uid of
       the running user (501 locally, 0 in prod) leaks into the header.
    3. `File.chmod(spill, 0o644)` — mode is the one header field with no
       add-option, and a 0600 spill diverges at byte offsets 105/106/153.
    4. Paths are CHARLISTS. `:erl_tar.add/4` treats a binary as CONTENT and a
       charlist as a FILENAME, so an Elixir string path silently archives the
       path TEXT as the member body, with no error.

  ## Options

    * `:mtime` — the header timestamp stamped on every member (default: now).
      Pinning it is what makes two packs of the same members byte-identical;
      the engine itself does NOT pin (it stamps the real export time), so a
      two-export `cmp` is NOT a valid regression test — see the transport
      parity test.
    * `:dir` — where to create the tar (default: `spill_dir/0`).

  ## Ownership: the tar is OWNED and deliberately NOT disowned on success

  The tar is marked live (`Janitor.own/1`) before its first byte and disowned
  only when this function DELETES it — the `catch` path. On the success path it
  keeps its sidecar, because `pack/3` hands the path to a caller that still has
  to read or stream it. `export_to_file/2` documents that the caller owns the
  returned path; disowning at hand-off would tell the janitor the file is
  unattended while it is being downloaded, which is exactly the reap-mid-send
  the derived `max_age_seconds` cutoff exists to make survivable. Whoever
  deletes the tar disowns it — for `export/2` that is the engine, for
  `export_to_file/2` it is the caller.
  """
  # File.chmod!/File.rm act on `spill` (caller-supplied table_files values,
  # engine-built via Archive.spill_path from catalog-derived table names) and on
  # `path` (engine-built bp-ws-bundle-<int>.tar, fetch_env! spill dir); no
  # request/manifest input reaches either. PR #5083 security review.
  # sobelow_skip ["Traversal.FileModule"]
  def pack(manifest, table_files, opts \\ []) when is_map(manifest) and is_map(table_files) do
    mtime = Keyword.get(opts, :mtime, :os.system_time(:second))
    dir = Keyword.get_lazy(opts, :dir, &spill_dir/0)
    path = Path.join(dir, "#{@bundle_prefix}#{System.unique_integer([:positive])}.tar")

    # Claim the tar BEFORE the first byte: the sidecar's whole job is to say "a
    # live pid is working here", and the window that needs covering starts at
    # creation, not at completion. Best-effort by construction (`own/1` swallows
    # its own IO result) — ownership marking must never be able to fail a pack.
    Janitor.own(path)

    try do
      {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write])

      try do
        # A BINARY source — erl_tar archives it as the member's content.
        :ok =
          :erl_tar.add(
            tar,
            Jason.encode!(manifest, pretty: true),
            @manifest_name,
            add_opts(mtime)
          )

        Enum.each(table_files, fn {table, spill} ->
          File.chmod!(spill, 0o644)
          member = ~c"tables/" ++ String.to_charlist(table) ++ ~c".copy"
          # A CHARLIST source — erl_tar streams it from disk, 64 KiB at a time.
          :ok = :erl_tar.add(tar, String.to_charlist(spill), member, add_opts(mtime))
          File.rm(spill)
          # The spill is gone, so its sidecar must go with it. The janitor
          # REJECTS `.owner` files as sweep candidates (they are collected with
          # their subject, never alone), so a sidecar outliving its subject is
          # never reclaimed — it squats forever. Small, but it is litter the
          # sweep is structurally unable to clean.
          Janitor.disown(spill)
        end)
      after
        :erl_tar.close(tar)
      end

      path
    catch
      # Never strand a half-written multi-hundred-MB tar on a raise, a throw,
      # or an exit. (SIGKILL is out of reach here by construction — that is the
      # janitor's job, pds-w11-spill-janitor.)
      kind, reason ->
        File.rm(path)
        Janitor.disown(path)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp add_opts(mtime) do
    [{:mtime, mtime}, {:atime, mtime}, {:ctime, mtime}, {:uid, 0}, {:gid, 0}]
  end

  @doc """
  The directory streamed spills and assembled tars are written to, created if
  absent and ASSERTED not to be memory-backed.

  Configured via `:bundle_spill_dir` (`BARKPARK_BUNDLE_SPILL_DIR` at runtime),
  defaulting under the app's own data dir rather than a bare
  `System.tmp_dir!/0` — on a systemd box `/tmp` is a plausible tmpfs, and a
  tmpfs spill silently reinstates the RSS peak this whole path exists to
  remove.
  """
  # File.mkdir_p! creates `dir`, which is
  # Application.fetch_env!(:barkpark, :bundle_spill_dir): operator config, not
  # attacker-influenced. PR #5083 security review.
  # sobelow_skip ["Traversal.FileModule"]
  def spill_dir do
    # fetch_env!, not get_env with a `System.tmp_dir!()` fallback: an unset key
    # must fail loudly at the top of the export, never quietly pick the one
    # directory most likely to BE the tmpfs the assertion below exists to
    # refuse. Same idiom as `Barkpark.Media.upload_dir/0`.
    dir =
      case spill_dir_config() do
        {:ok, dir} ->
          dir

        :error ->
          raise ArgumentError,
                "the :bundle_spill_dir key is unset — an export has nowhere disk-backed to " <>
                  "spill to. Set :bundle_spill_dir / BARKPARK_BUNDLE_SPILL_DIR."
      end

    File.mkdir_p!(dir)
    assert_not_tmpfs!(dir)
    dir
  end

  @doc """
  What configuration says the spill directory is — `{:ok, dir}` or `:error`.

  THE SINGLE RESOLUTION SITE (`pds-w11-janitor-engine-handshake`). The engine
  and `WorkspaceBundle.Janitor` must agree on this directory to the byte or the
  janitor sweeps somewhere nothing is written and reports a clean green forever
  while the spills pile up elsewhere. They used to agree by both spelling the
  same atom in two places, which is agreement by coincidence — one rename away
  from a silent divergence that no test would catch. Now the key and its name
  are decided HERE, once, and `Janitor.spill_dir/0` calls this.

  What deliberately stays split is the MISSING-key policy, because the two
  callers want opposite things and both are right:

    * `spill_dir/0` (engine) RAISES — an export with nowhere to spill must fail
      at the top, never quietly pick the one directory most likely to be tmpfs;
    * `Janitor.spill_dir/0` falls back — the janitor is a boot-time, one-shot,
      `restart: :temporary` task, and a reclaim sweep must never be the thing
      that breaks a boot.

  Returning `{:ok, dir} | :error` is what lets one resolver serve both: the
  decision "what does config say" happens once, and each caller applies its own
  policy to `:error` explicitly, in the open.
  """
  @spec spill_dir_config() :: {:ok, String.t()} | :error
  def spill_dir_config do
    case Application.get_env(:barkpark, :bundle_spill_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> :error
    end
  end

  @doc """
  Raise unless `dir` lives on a disk-backed filesystem.

  `mounts` is injectable — as `[{mount_point, fstype}]` — precisely so this
  decision is testable on a host with no `/proc/mounts` (macOS), where the
  live reader returns `[]` and the assertion abstains rather than guessing.
  Guerrilla's `/tmp` is ext4 on sda1 with 13.27 GiB free; this is the code
  KNOWING that rather than the operator remembering it.
  """
  def assert_not_tmpfs!(dir, mounts \\ read_mounts()) do
    dir = Path.expand(dir)

    case fstype_for(dir, mounts) do
      {mount_point, fstype} when fstype in @memory_backed_fstypes ->
        raise ArgumentError,
              "bundle spill dir #{dir} is on #{fstype} (#{mount_point}) — a memory-backed " <>
                "filesystem defeats spilling entirely (the export would pay full RSS again). " <>
                "Point :bundle_spill_dir / BARKPARK_BUNDLE_SPILL_DIR at disk-backed storage."

      _ ->
        :ok
    end
  end

  @doc """
  The janitor-visible filename prefix of an import scratch DIRECTORY.
  """
  def scratch_prefix, do: @scratch_prefix

  @doc """
  Create a fresh import scratch directory under `spill_dir/0` and return it.

  The caller OWNS it and must `File.rm_rf/1` it in an `after` clause. It lives
  under `spill_dir/0` for two reasons that are both load-bearing: that path is
  asserted disk-backed (a tmpfs scratch would reinstate the very RSS peak
  disk-backed extraction removes — `assert_not_tmpfs!/2`), and it is the one
  directory the janitor sweeps, so a SIGKILL mid-import leaves a scratch the
  next boot collects instead of a permanent multi-GB squatter.
  """
  # File.mkdir_p! creates a path built from spill_dir/0 (operator config) plus
  # System.unique_integer/1 — no request input reaches it.
  # sobelow_skip ["Traversal.FileModule"]
  def open_scratch_dir! do
    dir = scratch_path(spill_dir())
    File.mkdir_p!(dir)
    Janitor.own(dir)
    dir
  end

  @doc """
  The path of a fresh scratch directory under `parent` — THE one namer.

  Every extraction directory the engine creates gets its name here, so "is this
  directory something the janitor can collect?" has a single answer instead of
  one answer per call site. It had two, and they disagreed: `open_scratch_dir!/0`
  used the swept `bp-ws-import-` prefix while `import_bundle_file/2` hardcoded
  `members-<int>`, which matches none of the janitor's three prefixes. That made
  `import_bundle_file/2`'s own documented promise — "a SIGKILL that outruns both
  is collected by `Janitor` via the `bp-ws-import-` prefix" — false, and a killed
  import left a multi-GB extraction directory the sweep could never see.

  `parent` is a caller-chosen directory (the spill dir, or the directory holding
  a bundle already spilled there); the BASENAME is engine-generated and carries
  no request input.
  """
  @spec scratch_path(Path.t()) :: String.t()
  def scratch_path(parent) do
    Path.join(parent, "#{@scratch_prefix}#{System.unique_integer([:positive])}")
  end

  @doc """
  Remove a scratch directory and its ownership sidecar.

  Pair for `open_scratch_dir!/0`. A bare `File.rm_rf/1` at the call site removes
  the directory and STRANDS its `.owner` sidecar, which the janitor can never
  collect on its own (it rejects `.owner` files as sweep candidates, by design —
  they are collected with their subject). One helper so the pairing cannot drift
  apart the way `own/1` and the engine did.
  """
  # `dir` is engine-built by open_scratch_dir!/0 under the fetch_env! spill dir;
  # no request input reaches it.
  # sobelow_skip ["Traversal.FileModule"]
  @spec discard_scratch_dir(Path.t()) :: :ok
  def discard_scratch_dir(dir) do
    File.rm_rf(dir)
    Janitor.disown(dir)
    :ok
  end

  @doc """
  Bytes currently available on the filesystem carrying `dir`.

  `{:ok, bytes}` or `{:error, reason}` — never a guess. There is no BIF for
  statvfs, so this shells out to POSIX `df -Pk` (`-P` guarantees one line per
  filesystem, so a long device name cannot wrap the columns apart).
  """
  @spec free_space(Path.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  # `df` is resolved by System.find_executable/1 and every argument is passed as
  # a separate argv element; no shell parses `dir` or any caller-controlled text.
  # sobelow_skip ["CI.System"]
  def free_space(dir) do
    case System.find_executable("df") do
      nil ->
        {:error, :df_unavailable}

      df ->
        case System.cmd(df, ["-Pk", dir], stderr_to_stdout: true) do
          {out, 0} -> parse_df(out)
          {_out, _status} -> {:error, :df_failed}
        end
    end
  rescue
    _ -> {:error, :df_unavailable}
  end

  defp parse_df(out) do
    # Header line, then `<fs> <1024-blocks> <used> <available> <capacity> <mount>`.
    case String.split(out, "\n", trim: true) do
      [_header | [line | _]] ->
        case String.split(line, ~r/\s+/, trim: true) do
          [_fs, _blocks, _used, avail | _] ->
            case Integer.parse(avail) do
              {kb, ""} -> {:ok, kb * 1024}
              _ -> {:error, :df_unparsable}
            end

          _ ->
            {:error, :df_unparsable}
        end

      _ ->
        {:error, :df_unparsable}
    end
  end

  @doc """
  Refuse BEFORE the spill opens when `dir`'s filesystem cannot hold
  `required_bytes`.

  Disk is the risk this whole slice INTRODUCES. Extraction-to-disk trades a
  diagnosable BEAM OOM for an ENOSPC that surfaces as a half-written member and
  an opaque failure, and there was ZERO free-space precondition anywhere in the
  bundle path before this. guerrilla carries `/`, `/tmp` AND `/opt/barkpark` on
  ONE filesystem, so an import that fills it takes the box down with it.

  Three answers, and the middle one is the point — a precondition that cannot
  be performed SAYS SO rather than printing a tick (the wave's law):

    * `{:ok, {:verified, free_bytes}}` — measured, and sufficient.
    * `{:ok, {:unverified, reason}}` — `df` is absent/unreadable, or the caller
      could not derive a requirement (no Content-Length). The import proceeds,
      and the receipt carries the reason so nobody reads it as "checked".
    * `{:error, {:insufficient_disk_space, info}}` — measured, and short.

  The margin is the caller's to add. NOT covered, stated rather than hidden:
  the import's `CREATE TEMP TABLE` + COPY holds another ~1x the largest member
  inside Postgres, which on a single-filesystem box is the SAME disk.
  """
  @spec check_free_space(Path.t(), non_neg_integer()) ::
          {:ok, {:verified, non_neg_integer()} | {:unverified, atom()}}
          | {:error, {:insufficient_disk_space, map()}}
  def check_free_space(dir, required_bytes) do
    case free_space(dir) do
      {:ok, free} when free >= required_bytes ->
        {:ok, {:verified, free}}

      {:ok, free} ->
        {:error,
         {:insufficient_disk_space, %{dir: dir, free_bytes: free, required_bytes: required_bytes}}}

      {:error, reason} ->
        {:ok, {:unverified, reason}}
    end
  end

  @doc false
  def spill_path(dir, table) do
    Path.join(dir, "#{@spill_prefix}#{table}-#{System.unique_integer([:positive])}.copy")
  end

  # Longest matching mount point wins — /dev/shm must beat / for /dev/shm/x,
  # and the boundary is a path SEGMENT, so /dev/shmx never matches /dev/shm.
  defp fstype_for(dir, mounts) do
    mounts
    |> Enum.filter(fn {mount_point, _fstype} ->
      dir == mount_point or
        String.starts_with?(dir, String.trim_trailing(mount_point, "/") <> "/")
    end)
    |> Enum.max_by(fn {mount_point, _} -> String.length(mount_point) end, fn -> nil end)
  end

  defp read_mounts do
    case File.read("/proc/mounts") do
      {:ok, body} ->
        for line <- String.split(body, "\n", trim: true),
            [_dev, mount_point, fstype | _] <- [String.split(line, " ", trim: true)],
            do: {mount_point, fstype}

      {:error, _} ->
        []
    end
  end

  @doc """
  Extract a bundle binary into `{manifest_map, %{table => copy_bytes}}`.
  """
  def unpack(bundle) when is_binary(bundle) do
    entries = extract!(bundle)

    {manifest_bytes, dumps} =
      Enum.reduce(entries, {nil, %{}}, fn {name, content}, {mf, acc} ->
        name = to_string(name)

        cond do
          name == "manifest.json" ->
            {content, acc}

          String.starts_with?(name, "tables/") and String.ends_with?(name, ".copy") ->
            table =
              name |> String.replace_prefix("tables/", "") |> String.replace_suffix(".copy", "")

            {mf, Map.put(acc, table, content)}

          true ->
            {mf, acc}
        end
      end)

    if is_nil(manifest_bytes) do
      raise InvalidBundleError,
        code: "invalid_bundle",
        message:
          "bundle carries no manifest.json — not a #{@format} bundle " <>
            "(#{byte_size(bundle)} bytes read)"
    end

    {decode_manifest!(manifest_bytes, bundle), dumps}
  end

  @doc """
  Extract the bundle tar at `bundle_path` into `dir`, returning
  `{manifest_map, %{table => member_path}}`.

  The disk-backed twin of `unpack/1` — same manifest, same member set, same
  `InvalidBundleError` refusals, but the members stay ON DISK and the caller
  streams them. Peak is 1x the largest single member (`:erl_tar` has no chunked
  extract), NOT constant memory.

  ## The traversal gate (new surface)

  `[:memory]` extraction cannot write anywhere, so member names were inert.
  `{:cwd, dir}` writes them. The table of contents is therefore validated in
  full BEFORE extraction — it is a read of the tar's headers, not of its
  bodies — and one bad name refuses the WHOLE bundle by name rather than
  extracting the good members first and discovering the escape afterwards.
  Accepted: `manifest.json`, and `tables/<name>.copy` where `<name>` carries no
  `/`, no `\\`, no NUL and is not `.`/`..`. Every member must be a REGULAR file:
  a symlink member is how a tar escapes a cwd even with clean names.
  """
  @spec unpack_to_dir(Path.t(), Path.t()) :: {map(), %{optional(String.t()) => Path.t()}}
  # `manifest_path` is the fixed manifest filename under the caller-owned
  # scratch directory. All archive member names are validated before extraction.
  # sobelow_skip ["Traversal.FileModule"]
  def unpack_to_dir(bundle_path, dir) when is_binary(bundle_path) and is_binary(dir) do
    members = Enum.map(table!(bundle_path), &classify_member!(&1, bundle_path))

    extract_to_dir!(bundle_path, dir)

    manifest_path = Path.join(dir, "manifest.json")

    unless File.regular?(manifest_path) do
      raise InvalidBundleError,
        code: "invalid_bundle",
        message:
          "bundle carries no manifest.json — not a #{@format} bundle " <>
            "(#{bundle_size(bundle_path)} bytes read)"
    end

    dumps =
      for {:table, table, name} <- members, into: %{} do
        {table, Path.join(dir, name)}
      end

    # manifest.json is the ONLY member ever read whole: it is the few-KB index,
    # not a dump. No table member is ever File.read!/1'd on this path — that is
    # the invariant the whole slice exists to hold.
    {decode_manifest!(File.read!(manifest_path), bundle_path), dumps}
  end

  def format, do: @format
  def grain, do: @grain

  defp bundle_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  # PDS-D50 again, from the file side: an empty or truncated body is a caller
  # fault answered honestly, never a MatchError-driven 500.
  defp table!(bundle_path) do
    case :erl_tar.table(String.to_charlist(bundle_path), [:verbose]) do
      {:ok, entries} ->
        entries

      {:error, reason} ->
        raise InvalidBundleError,
          code: "invalid_bundle",
          message:
            "request body is not a readable tar (#{bundle_size(bundle_path)} bytes, " <>
              "#{inspect(reason)}) — the bundle is empty or truncated"
    end
  end

  # `:verbose` entries are {name, type, size, mtime, mode, uid, gid}.
  defp classify_member!({name, type, _size, _mtime, _mode, _uid, _gid}, bundle_path) do
    name = to_string(name)

    cond do
      type != :regular ->
        refuse_member!(name, bundle_path, "member type #{inspect(type)} is not a regular file")

      name == "manifest.json" ->
        {:manifest, name}

      String.starts_with?(name, "tables/") and String.ends_with?(name, ".copy") ->
        table =
          name |> String.replace_prefix("tables/", "") |> String.replace_suffix(".copy", "")

        if safe_table_name?(table) do
          {:table, table, name}
        else
          refuse_member!(name, bundle_path, "table member name escapes the extraction root")
        end

      true ->
        refuse_member!(name, bundle_path, "not a manifest.json or tables/<name>.copy member")
    end
  end

  defp classify_member!(other, bundle_path) do
    refuse_member!(inspect(other), bundle_path, "unreadable tar header")
  end

  defp safe_table_name?(table) do
    table != "" and table not in [".", ".."] and
      not String.contains?(table, ["/", "\\", <<0>>]) and
      not String.contains?(table, "..")
  end

  defp refuse_member!(name, bundle_path, why) do
    raise InvalidBundleError,
      code: "invalid_bundle",
      message:
        "bundle member #{inspect(name)} refused: #{why} — a #{@format} bundle carries " <>
          "manifest.json plus tables/<name>.copy members and nothing else " <>
          "(#{bundle_size(bundle_path)} bytes read)"
  end

  # `dir` is engine-built (open_scratch_dir!/0 under the fetch_env! spill dir)
  # and every member name has already been proven separator-free and regular by
  # classify_member!/2 above — the traversal gate IS that validation, run before
  # a byte is written. PDS wave 23 security review.
  # sobelow_skip ["Traversal.FileModule"]
  defp extract_to_dir!(bundle_path, dir) do
    File.mkdir_p!(dir)

    case :erl_tar.extract(String.to_charlist(bundle_path), [{:cwd, String.to_charlist(dir)}]) do
      :ok ->
        :ok

      {:error, reason} ->
        raise InvalidBundleError,
          code: "invalid_bundle",
          message:
            "bundle could not be extracted (#{bundle_size(bundle_path)} bytes, " <>
              "#{inspect(reason)}) — the bundle is truncated or corrupt"
    end
  end

  # PDS-D50: :erl_tar answers {:error, :eof} for BOTH an empty body and a
  # truncated one — the two cases a streamed pull actually produces. Refuse
  # honestly instead of letting a MatchError surface as a 500.
  defp extract!(bundle) do
    case :erl_tar.extract({:binary, bundle}, [:memory]) do
      {:ok, entries} ->
        entries

      {:error, reason} ->
        raise InvalidBundleError,
          code: "invalid_bundle",
          message:
            "request body is not a readable tar (#{byte_size(bundle)} bytes, " <>
              "#{inspect(reason)}) — the bundle is empty or truncated"
    end
  end

  defp decode_manifest!(manifest_bytes, bundle) do
    case Jason.decode(manifest_bytes) do
      {:ok, manifest} when is_map(manifest) ->
        manifest

      _ ->
        raise InvalidBundleError,
          code: "invalid_bundle",
          message:
            "bundle manifest.json is not decodable JSON object " <>
              "(#{byte_size(bundle)} bytes read)"
    end
  end
end
