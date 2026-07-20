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

  Packing is FILE-TO-FILE and constant-memory (PDS-D207): each table member is
  a per-table SPILL file the producer streamed to disk, added to the tar by
  PATH — `:erl_tar` reads an added file in bounded 64 KiB chunks — and deleted
  the moment it is in. Extraction is still fully in-memory from the bundle
  binary (the import path is deliberately unchanged, PDS-D214).
  """

  alias Barkpark.Tenancy.WorkspaceBundle.InvalidBundleError

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
    dir = Application.fetch_env!(:barkpark, :bundle_spill_dir)

    File.mkdir_p!(dir)
    assert_not_tmpfs!(dir)
    dir
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

  def format, do: @format
  def grain, do: @grain

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
