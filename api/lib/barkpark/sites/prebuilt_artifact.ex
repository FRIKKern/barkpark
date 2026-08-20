defmodule Barkpark.Sites.PrebuiltArtifact do
  @moduledoc """
  Ingest an ALREADY-BUILT site bundle onto the serving box: digest-verify, then
  validate-and-write it in ONE streaming pass, then swap it into place
  (site-spawner charter D86/D87/D89/D90 — "the build leaves the serving box").

  This module is the box's half of the prebuilt handshake. Its input is
  attacker-influenced in the strongest sense — a `.tar.gz` produced somewhere
  the box does not control — and its output is a directory the web server will
  SERVE. So it refuses far more than a typical extractor:

    * **Digest FIRST.** The decoded bytes are hashed and compared to the
      caller's `artifact_sha256` before a single byte is inflated. A mismatch
      is `E_DIGEST_MISMATCH` and nothing is written. That certifies INTEGRITY
      and IDENTITY — these are the bytes the caller named — and NOT PROVENANCE
      (that those bytes are a faithful build of any particular source). The
      charter's numbered decision on what HEALTH may claim for off-box bytes
      owns that distinction; this module claims only the narrow thing it proves.

    * **Never `:erl_tar` on the gzip stream.** `:erl_tar` inflates the whole
      member before any guard of ours could fire, so a 50 KB body that inflates
      to 40 GB would OOM the box before we ever saw an entry. Instead the
      budget is enforced on the `:zlib` stream DURING inflation
      (`safeInflate/2` returns BOUNDED output pieces), and the tar is parsed by
      the 512-byte-block state machine below as those pieces arrive. One pass:
      the same loop validates and writes.

    * **Symlinks are REFUSED, not sanitized.** A staged symlink is SERVED: the
      static site root is `root * $ROOT/current` + `file_server`, and
      `disable_symlinks` appears NOWHERE in this repo — so `leak.txt ->
      /opt/barkpark/.env` becomes an HTTP GET. There is no safe rewrite of a
      symlink here, only refusal.

    * **Regular files and directories ONLY.** Hard links, fifos, devices, the
      pax GLOBAL header (`g`) and the GNU long-name headers (`L`/`K`) are
      refused — the extension headers in particular exist to OVERRIDE the fields
      we just validated.

    * **The pax `x` header is the ONE narrow exception, and it is APPLIED then
      RE-VALIDATED — never trusted.** Refusing it outright was wrong on real
      bytes: `archive/tar` (this repo's OWN packer, `packPrebuiltDir` in
      `internal/cli/sites_tarball.go`) emits an `x` block for ANY non-ASCII name
      and for any single path component over 100 bytes, so `bp cloud site deploy
      --prebuilt` could not deploy a `café/` slug at all — while GNU tar, which
      writes such a name RAW into an ordinary ustar header, sailed through. Our
      own first-party client was the stricter, dead-on-arrival one.

      SKIPPING the `x` block is not a fix either, measured on the packer's bytes:
      Go writes a ustar shadow header after each `x` with the name pushed through
      an ASCII fallback, so `café/index.html` becomes `caf/index.html` (the
      accented byte DROPPED, not escaped) and a 121-byte component TRUNCATES to
      100 — the directory's shadow name then no longer matches the leaf's prefix.
      A skip stages plausible-looking ASCII paths that 404, silently. Only
      apply-then-re-validate is correct.

      So exactly two records are honoured — `path` and `size` — and EVERY other
      record is discarded (`linkpath`, `uid`, `gid`, `mode`, `mtime`, `atime`,
      every `SCHILY.*`): those are precisely the fields whose purpose is to
      override a validated one. The effective name then re-enters the WHOLE of
      `name/1` **and** `safe_path/2` unchanged, because the five `name/1` arms are
      not the rule set — ABSOLUTE and TRAVERSAL live in `safe_path/2`, on the
      cleaned joined path.

      Why a `path`+`size` allowlist cannot re-open the override path this module
      refuses extension headers for: `type/1` reads **byte 156 of the FILE
      header**, and no standard pax keyword overrides a typeflag — there is no
      pax `mode` keyword either. So the symlink, hardlink, device and
      setuid/setgid refusals stay UN-BYPASSABLE no matter what an `x` block
      carries. The `x` entry's own name (Go writes `caf/PaxHeaders.0/index.html`,
      bsdtar nests deeper) never reaches `name/1`, `safe_path/2` or the disk.

      The record block gets its OWN small budget — `@max_pax_block_bytes` plus
      `@max_extension_records` and a per-record byte cap — and NOT a share of the
      entry counter: an `x` block must never `count_entry/1`, because Go emits one
      per non-ASCII entry and counting them halves the effective entry cap
      (measured: a legitimate 10 001-file accented `dist/` refused
      `E_TOO_MANY_ENTRIES`).

    * **Modes are sanitized, and setuid/setgid/sticky is a REFUSAL.** We write
      0644/0755 ourselves and ignore Uid/Gid; an archive that asks for a setuid
      bit is not asking for something a static bundle needs.

    * **The CLEANED JOINED path is what gets validated** — never the header
      name. `Path.expand/1` of the destination-joined name must stay strictly
      under the staging root.

    * **The archive must be WHOLE, and framing is the only proof of that.** A
      tar ends with two zero blocks and a gzip member ends with a CRC32/ISIZE
      trailer; both are the ONLY evidence that the bytes handed to us are all
      the bytes there were. A transfer cut on a 512-byte boundary parses
      cleanly and is silently SHORT — for a site that is not a half-written
      file but MISSING PAGES, going live under the team's domain. So a stream
      with no end-of-archive marker, and a gzip member that never terminates,
      are both `E_MALFORMED`. Bytes PAST the marker are not parsed (a real
      writer pads there) but they are still BUDGETED — a bomb appended after
      the marker must not ride in free.

    * **A bundle with nothing to serve is refused (`E_NO_INDEX`).** An archive
      that stages no regular files at all, or stages files but no root
      `index.html`, deploys green and then 404s at the domain. This is the
      server half of a contract the CLI already states one hop earlier
      (`validatePrebuiltDir` in `internal/cli/sites_tarball.go`, same message);
      the box is the only place that sees what the archive actually CONTAINS.
      This is NOT a widening of what the lane refuses: the engine's own PLAN arm
      already refuses a staged tree with no root `index.html`
      (`deploy/site-deploy.sh:1371`, `exit 11`) — and so does HEALTH one stage
      later. What moves is WHERE the answer comes from: a typed `E_NO_INDEX`
      naming the caller's archive, instead of a PLAN detail telling the operator
      to "check the ingest step ran", two hops from the mistake.

    * **Extract aside, then swap.** Everything lands in a sibling
      `<dest>.staging-<n>` directory; only a fully-accepted archive is renamed
      into place, so a refusal leaves NO partial tree. That is the idiom
      `scripts/fetch-prebuilt.sh` uses (verify → extract aside → swap), this
      repo's one working precedent.

  Every refusal is a typed code (`E_*`) with a human message. The caller maps it
  to a 400 — a refused artifact is a CALLER error, never a box error, and never
  a silent fallback to a box build.

  ## Caps

  | Cap | Value | Basis |
  |---|---|---|
  | entries | 20 000 | an Astro `dist/` is ~10²; a Next standalone ~10⁴ |
  | total bytes | 64 MiB | 2x the 32 MiB request cap, so a legitimate body can inflate |
  | bytes per entry | 64 MiB | no single file in a site bundle approaches this |
  | compression ratio | 200:1 | only judged past 32 MiB of output, so real bundles are never ratio-judged |
  | name bytes | 255 | one POSIX filename budget for the WHOLE path |
  | path segments | 32 | site bundles are shallow; 32 is already generous |
  | pax block bytes | 8 KiB | a real record block is tens of bytes; 8 KiB is generous |
  | pax records | 32 | Go writes 1–2 per entry; 32 leaves room for every writer |
  | pax record bytes | 1 KiB | a `path` record cannot beat the 255-byte name cap |
  """

  @max_entries 20_000
  @max_total_bytes 64 * 1024 * 1024
  @max_entry_bytes 64 * 1024 * 1024
  @max_ratio 200
  # A bundle is ratio-judged only once it has produced more output than any
  # legitimate site bundle would — below the floor a small, highly compressible
  # (and honest) `dist/` must never be mistaken for a bomb.
  @ratio_floor_bytes 32 * 1024 * 1024
  @max_name_bytes 255
  @max_segments 32

  # The pax record block's OWN budget — deliberately NOT a share of
  # `@max_entries`. It trips at the `x` HEADER (before a single record byte is
  # buffered) and then again per record, so a 64 MiB "extension header" is refused
  # on its size field rather than accumulated.
  @max_pax_block_bytes 8 * 1024
  @max_extension_records 32
  @max_extension_record_bytes 1024

  # The only two pax keywords this module applies. Everything else is DISCARDED —
  # see the moduledoc: an extension record's whole purpose is to override a field
  # that was just validated, and these two are the only ones that must survive
  # re-validation for a legitimate archive to stage at all.
  @pax_applied_keys ["path", "size"]

  # zlib window bits 31 = 16 + 15 = "gzip only". NOT 47 (auto-detect
  # zlib-or-gzip): the contract says `.tar.gz` and that is what is accepted.
  @gzip_window_bits 31
  @inflate_chunk_bytes 64 * 1024

  @block 512

  @typedoc "A refusal: a typed code plus a human message."
  @type refusal :: {:error, String.t(), String.t()}

  @typedoc "What a successful ingest produced."
  @type summary :: %{
          dir: Path.t(),
          sha256: String.t(),
          entries: non_neg_integer(),
          bytes: non_neg_integer()
        }

  @doc """
  Stage `raw_b64` (a base64 `.tar.gz`) into `dest` after verifying it hashes to
  `expected_sha256`.

  On success the previous `dest` is gone and `dest` holds exactly the archive's
  regular files and directories. On ANY refusal `dest` is untouched and no
  partial tree survives.

  `opts` may override the caps (`:max_entries`, `:max_total_bytes`,
  `:max_entry_bytes`, `:max_ratio`) — used by the tests to exercise a cap
  without materializing 64 MiB, and by nothing else.
  """
  @spec stage(String.t(), String.t(), Path.t(), keyword()) :: {:ok, summary()} | refusal()
  def stage(raw_b64, expected_sha256, dest, opts \\ [])
      when is_binary(raw_b64) and is_binary(expected_sha256) and is_binary(dest) do
    with {:ok, raw} <- decode(raw_b64),
         :ok <- verify_digest(raw, expected_sha256),
         :ok <- gzip?(raw) do
      extract_aside_and_swap(raw, expected_sha256, dest, opts)
    end
  end

  @doc "The caps this module enforces — read by the tests, so a silent cap edit reds."
  @spec caps() :: map()
  def caps do
    %{
      max_entries: @max_entries,
      max_total_bytes: @max_total_bytes,
      max_entry_bytes: @max_entry_bytes,
      max_ratio: @max_ratio,
      max_name_bytes: @max_name_bytes,
      max_segments: @max_segments,
      max_pax_block_bytes: @max_pax_block_bytes,
      max_extension_records: @max_extension_records,
      max_extension_record_bytes: @max_extension_record_bytes
    }
  end

  # ── digest + envelope ─────────────────────────────────────────────────────

  defp decode(raw_b64) do
    case Base.decode64(raw_b64, ignore: :whitespace) do
      {:ok, ""} -> {:error, "E_MALFORMED", "artifact is empty"}
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, "E_NOT_BASE64", "artifact is not valid base64"}
    end
  end

  # Constant-time compare (the repo idiom, `Plug.Crypto.secure_compare/2`): the
  # expected digest is caller-supplied and compared against one we computed.
  defp verify_digest(raw, expected) do
    actual = :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(actual, expected) do
      :ok
    else
      {:error, "E_DIGEST_MISMATCH",
       "artifact sha256 is #{actual}, not the #{expected} the caller declared"}
    end
  end

  defp gzip?(<<0x1F, 0x8B, _rest::binary>>), do: :ok

  defp gzip?(_raw),
    do: {:error, "E_NOT_GZIP", "artifact is not a gzip stream (expected a .tar.gz)"}

  # ── extract aside, then swap ──────────────────────────────────────────────

  defp extract_aside_and_swap(raw, sha256, dest, opts) do
    staging = "#{dest}.staging-#{System.unique_integer([:positive])}"

    case mkdir(staging) do
      :ok ->
        case run_stream(raw, staging, opts) do
          {:ok, summary} ->
            case swap(staging, dest) do
              :ok ->
                {:ok, Map.merge(summary, %{dir: dest, sha256: sha256})}

              {:error, reason} ->
                _ = rm_rf(staging)

                {:error, "E_SWAP_FAILED",
                 "the artifact validated but could not be swapped into place: #{inspect(reason)}"}
            end

          {:error, _code, _message} = refusal ->
            # A refusal leaves NO partial tree — staging aside is what makes
            # this single rm_rf the whole of the cleanup story.
            _ = rm_rf(staging)
            refusal
        end

      {:error, reason} ->
        {:error, "E_STAGING_FAILED",
         "could not create the staging dir #{staging}: #{inspect(reason)}"}
    end
  end

  # Reachability: `path` is `<dest>.staging-<unique_integer>`, where `dest` is
  # named by DeployRunner from `run_state_dir()` + a slug already validated
  # against ^[a-z0-9][a-z0-9-]{0,62}$ — no request-supplied path component ever
  # reaches this argument.
  # sobelow_skip ["Traversal.FileModule"]
  defp mkdir(path), do: File.mkdir_p(path)

  # Reachability: the same two module-named paths as `mkdir/1` — the staging dir
  # this module just created and the DeployRunner-named destination. NEVER an
  # archive-supplied name (those are only ever joined UNDER the staging root).
  # sobelow_skip ["Traversal.FileModule"]
  defp swap(staging, dest) do
    _ = File.rm_rf(dest)

    case File.rename(staging, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Reachability: the argument is always the staging dir this module named.
  # sobelow_skip ["Traversal.FileModule"]
  defp rm_rf(path), do: File.rm_rf(path)

  # ── the single streaming validate-and-write pass ──────────────────────────

  defp run_stream(raw, staging, opts) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z, @gzip_window_bits)

      case feed_all(z, raw, initial_state(staging, opts)) do
        {:ok, state} ->
          case stream_complete(z) do
            :ok -> finish(state)
            {:error, code, message} -> close_io(state, {:error, code, message})
          end

        {:error, code, message, state} ->
          close_io(state, {:error, code, message})
      end
    catch
      # zlib raises on a corrupt member. Caught NARROWLY (only zlib's own
      # errors) so a bug in the parser above surfaces as a crash, not as a
      # misleading "the archive is malformed".
      :error, %ErlangError{original: original}
      when original in [:data_error, :stream_error, :buf_error] ->
        {:error, "E_MALFORMED", "the gzip stream is corrupt (#{original})"}

      :error, original when original in [:data_error, :stream_error, :buf_error] ->
        {:error, "E_MALFORMED", "the gzip stream is corrupt (#{original})"}
    after
      _ = :zlib.close(z)
    end
  end

  # Did the gzip MEMBER terminate? `inflateEnd/1` is the only thing that answers
  # that: it raises `data_error` when the last inflate was not for the end of the
  # stream — i.e. when the CRC32/ISIZE trailer never arrived. Every deflate block
  # of a trailer-cut body still inflates, so the tar underneath looks whole and
  # the truncation is otherwise INVISIBLE.
  #
  # Called from inside `run_stream/3`'s `try`, so anything outside zlib's own
  # narrow error set still surfaces through that existing catch rather than being
  # mistranslated here.
  defp stream_complete(z) do
    :zlib.inflateEnd(z)
    :ok
  catch
    :error, %ErlangError{original: original}
    when original in [:data_error, :stream_error, :buf_error] ->
      truncated_in_transit(original)

    :error, original when original in [:data_error, :stream_error, :buf_error] ->
      truncated_in_transit(original)
  end

  defp truncated_in_transit(original) do
    {:error, "E_MALFORMED",
     "the gzip stream never terminates — the artifact was truncated in transit (#{original})"}
  end

  defp initial_state(staging, opts) do
    %{
      root: staging,
      # The expanded root, computed ONCE: every entry path must sit under it.
      root_prefix: Path.expand(staging) <> "/",
      buf: <<>>,
      phase: :header,
      io: nil,
      remaining: 0,
      padding: 0,
      # The pending pax override, `nil` when there is none: a map carrying at most
      # `:path` and `:size`, consumed by the NEXT file/dir header and cleared the
      # moment it is applied. `pax_buf`/`pax_remaining` hold the record block while
      # it streams in.
      pax: nil,
      pax_buf: <<>>,
      pax_remaining: 0,
      entries: 0,
      # `entries` counts directories too; `files` is what would actually be
      # SERVED, and `root_index` is whether one of them is the root `index.html`.
      files: 0,
      root_index: false,
      bytes: 0,
      out_bytes: 0,
      in_bytes: 0,
      zero_blocks: 0,
      halted: false,
      max_entries: Keyword.get(opts, :max_entries, @max_entries),
      max_total_bytes: Keyword.get(opts, :max_total_bytes, @max_total_bytes),
      max_entry_bytes: Keyword.get(opts, :max_entry_bytes, @max_entry_bytes),
      max_ratio: Keyword.get(opts, :max_ratio, @max_ratio)
    }
  end

  # Feed the COMPRESSED bytes in bounded chunks so `in_bytes` — the ratio's
  # denominator — advances honestly, and drain each chunk's inflated output
  # through the parser before feeding the next.
  #
  # Feeding does NOT stop at the end-of-archive marker. The parser stops PARSING
  # there (see `parse/1`'s halted clause), but every remaining byte still goes
  # through `absorb/2`, so `max_total_bytes` and the ratio guard keep judging a
  # tail appended after the marker instead of letting it ride in free.
  defp feed_all(_z, <<>>, state), do: {:ok, state}

  defp feed_all(z, raw, state) do
    {chunk, rest} =
      case raw do
        <<c::binary-size(@inflate_chunk_bytes), r::binary>> -> {c, r}
        c -> {c, <<>>}
      end

    state = %{state | in_bytes: state.in_bytes + byte_size(chunk)}

    case drain(z, chunk, state) do
      {:ok, state} -> feed_all(z, rest, state)
      {:error, _code, _msg, _state} = refusal -> refusal
    end
  end

  # `safeInflate/2` hands back BOUNDED output pieces — that bound is exactly
  # what makes the byte budget enforceable DURING inflation rather than after
  # it. The documented continuation is a call with empty data.
  defp drain(z, chunk, state) do
    case :zlib.safeInflate(z, chunk) do
      {:continue, out} ->
        case absorb(out, state) do
          {:ok, state} -> drain(z, [], state)
          {:error, _c, _m, _s} = refusal -> refusal
        end

      # `{:finished, _}` means THIS CHUNK is fully consumed — NOT that the
      # archive is over. The archive ends at its two zero blocks (which set
      # `halted`) or when the input runs out; treating a consumed chunk as the
      # end silently truncates every artifact bigger than one chunk, and the
      # truncation is INVISIBLE (a short but valid-looking tree).
      {:finished, out} ->
        absorb(out, state)
    end
  end

  defp absorb(out, state) do
    bin = IO.iodata_to_binary(out)
    out_bytes = state.out_bytes + byte_size(bin)
    state = %{state | out_bytes: out_bytes}

    cond do
      out_bytes > state.max_total_bytes ->
        refuse(
          state,
          "E_TOTAL_TOO_LARGE",
          "artifact inflates past the #{state.max_total_bytes} byte total cap"
        )

      ratio_exceeded?(out_bytes, state) ->
        refuse(
          state,
          "E_COMPRESSION_RATIO",
          "artifact inflates at over #{state.max_ratio}:1 — refused as a compression bomb"
        )

      true ->
        parse(%{state | buf: state.buf <> bin})
    end
  end

  defp ratio_exceeded?(out_bytes, state) do
    out_bytes > @ratio_floor_bytes and state.in_bytes > 0 and
      out_bytes > state.max_ratio * state.in_bytes
  end

  defp refuse(state, code, message), do: {:error, code, message, state}

  # ── the tar state machine ─────────────────────────────────────────────────

  # File-body phase: drain what we have, then fall back to header parsing.
  defp parse(%{phase: :body, remaining: remaining} = state) when remaining > 0 do
    take = min(byte_size(state.buf), remaining)

    if take == 0 do
      {:ok, state}
    else
      <<data::binary-size(take), rest::binary>> = state.buf

      case IO.binwrite(state.io, data) do
        :ok ->
          parse(%{state | buf: rest, remaining: remaining - take, bytes: state.bytes + take})

        {:error, reason} ->
          refuse(state, "E_WRITE_FAILED", "could not write an artifact entry: #{inspect(reason)}")
      end
    end
  end

  # Pax-record phase: the `x` entry's body is a record block, so it is BUFFERED
  # (bounded by `@max_pax_block_bytes`, already enforced on the header) instead of
  # written — nothing about an extension header ever reaches the disk.
  defp parse(%{phase: :pax_body, pax_remaining: remaining} = state) when remaining > 0 do
    take = min(byte_size(state.buf), remaining)

    if take == 0 do
      {:ok, state}
    else
      <<data::binary-size(take), rest::binary>> = state.buf

      parse(%{
        state
        | buf: rest,
          pax_buf: state.pax_buf <> data,
          pax_remaining: remaining - take
      })
    end
  end

  # The record block is whole: parse it, keep `path`/`size`, discard the rest, and
  # hand the pending override to the NEXT header through the shared padding phase.
  defp parse(%{phase: :pax_body, pax_remaining: 0} = state) do
    case pax_records(state.pax_buf) do
      {:ok, overrides} ->
        parse(%{state | phase: :padding, pax_buf: <<>>, pax: overrides})

      {:error, code, message} ->
        refuse(state, code, message)
    end
  end

  # Body done — close the file, then skip the entry's 512-block padding.
  defp parse(%{phase: :body, remaining: 0} = state) do
    _ = File.close(state.io)
    parse(%{state | phase: :padding, io: nil})
  end

  defp parse(%{phase: :padding, padding: padding} = state) do
    if byte_size(state.buf) < padding do
      {:ok, state}
    else
      <<_pad::binary-size(padding), rest::binary>> = state.buf
      parse(%{state | phase: :header, padding: 0, buf: rest})
    end
  end

  # Past the end-of-archive marker. GNU tar pads to its 20-block blocking factor
  # and `:erl_tar` to 2, so there is normally zero padding of interest here — the
  # bytes are DROPPED rather than parsed (the archive is over) but they have
  # already been counted by `absorb/2`, which is what keeps a post-marker bomb
  # inside the budget.
  defp parse(%{phase: :header, halted: true} = state), do: {:ok, %{state | buf: <<>>}}

  defp parse(%{phase: :header} = state) do
    if byte_size(state.buf) < @block do
      {:ok, state}
    else
      <<header::binary-size(@block), rest::binary>> = state.buf
      state = %{state | buf: rest}

      if zero_block?(header) do
        if state.pax do
          # An extension header describes the entry that FOLLOWS it. One followed
          # by the end-of-archive marker describes nothing — refuse rather than
          # let a pending override sit there.
          refuse(state, "E_MALFORMED", pax_dangling_message())
        else
          # Two consecutive zero blocks END the archive; whatever follows them is
          # padding this parser deliberately never looks at. `halted` is the flag
          # `finish/1` requires — an archive that never sets it was cut before its
          # marker was written.
          zero_blocks = state.zero_blocks + 1
          state = %{state | zero_blocks: zero_blocks, halted: state.halted or zero_blocks >= 2}
          parse(state)
        end
      else
        case entry(header, %{state | zero_blocks: 0}) do
          {:ok, state} -> parse(state)
          {:error, code, message} -> refuse(state, code, message)
        end
      end
    end
  end

  defp zero_block?(block), do: block == <<0::size(@block)-unit(8)>>

  # One header: checksum, then TYPE, then the name, then mode, then size, then
  # the CLEANED path — each refusal typed.
  #
  # Type comes before name for one reason: an `x` extension header's own name is
  # the writer's pseudo-path (`caf/PaxHeaders.0/index.html` from Go, a nested
  # `./x/PaxHeaders/y` from bsdtar) and it must never reach `name/1`, `safe_path/2`
  # or the disk. Knowing the type first is what keeps it out.
  defp entry(header, state) do
    with :ok <- checksum(header),
         {:ok, type} <- type(header) do
      place_entry(type, header, state)
    end
  end

  defp place_entry(:pax, header, state), do: pax_begin(header, state)

  defp place_entry(type, header, state) do
    with {:ok, name} <- effective_name(header, state),
         :ok <- mode_bits(header),
         {:ok, size} <- effective_size(header, type, state),
         {:ok, path} <- safe_path(name, type, state) do
      # The pending override has now been applied AND re-validated: drop it so it
      # can never leak onto a second entry.
      state = %{state | pax: nil}

      case {type, path} do
        # `tar czf - -C dist .` emits the root itself as a `./` DIRECTORY entry.
        # It is not an escape and it is not a file to write — it is the staging
        # dir this module already created, so it is counted and skipped. Without
        # this, a perfectly ordinary hand-rolled tarball is refused as
        # "escapes the artifact root", which is both wrong and unactionable.
        {:dir, :root} -> count_entry(state)
        {:dir, path} -> place_dir(path, state)
        {:regular, path} -> place_file(path, size, state)
      end
    end
  end

  # A tar checksum is the octal sum of the header with the checksum field read
  # as spaces. A header that fails it is not a header — call the archive
  # malformed rather than guess at its fields.
  defp checksum(header) do
    <<pre::binary-size(148), stored::binary-size(8), post::binary-size(356)>> = header
    want = sum_bytes(pre) + sum_bytes(post) + 8 * ?\s

    case octal(stored) do
      {:ok, ^want} -> :ok
      _ -> {:error, "E_MALFORMED", "tar header checksum mismatch — this is not a tar archive"}
    end
  end

  defp sum_bytes(bin), do: bin |> :binary.bin_to_list() |> Enum.sum()

  # The EFFECTIVE name: a pending pax `path` record when one arrived, otherwise
  # the header's own ustar name/prefix pair. Either way it goes through the SAME
  # `validate_name/1` — and then, in `place_entry/3`, through `safe_path/2`, which
  # is where ABSOLUTE and TRAVERSAL are caught. Both halves matter: `validate_name/1`
  # has five arms and NONE of them is a traversal check.
  defp effective_name(header, state) do
    case pax_override(state, :path) do
      nil -> name(header)
      path -> validate_name(path)
    end
  end

  defp name(header) do
    <<name::binary-size(100), _mid::binary-size(245), prefix::binary-size(155),
      _tail::binary-size(12)>> = header

    name = trim_nul(name)
    prefix = trim_nul(prefix)
    full = if prefix == "", do: name, else: prefix <> "/" <> name

    validate_name(full)
  end

  defp validate_name(full) do
    cond do
      full == "" ->
        {:error, "E_BAD_NAME", "the archive has an entry with an empty name"}

      byte_size(full) > @max_name_bytes ->
        {:error, "E_BAD_NAME", "entry name exceeds #{@max_name_bytes} bytes"}

      not String.valid?(full) ->
        {:error, "E_BAD_NAME", "entry name is not valid UTF-8"}

      Enum.any?(String.to_charlist(full), &(&1 < 0x20)) ->
        {:error, "E_BAD_NAME", "entry name contains a control character"}

      length(String.split(full, "/", trim: true)) > @max_segments ->
        {:error, "E_BAD_NAME", "entry path is deeper than #{@max_segments} segments"}

      true ->
        {:ok, full}
    end
  end

  # The typeflag picks which refusal applies. `0`/NUL is a regular file and `5`
  # a directory; `x` is the pax record block, whose `path`/`size` are applied and
  # then RE-VALIDATED (moduledoc). Nothing else is stageable, and the OTHER
  # extension headers (`g`, `L`, `K`) stay refused precisely because their job is
  # to override the fields validated here.
  #
  # This function reads BYTE 156 of the FILE header, and no pax keyword overrides
  # a typeflag — which is exactly why admitting `x` under a `path`+`size`
  # allowlist cannot re-open the symlink/hardlink/device/setuid refusals below.
  # There is no pax `mode` keyword either, so `mode_bits/1` is equally
  # un-bypassable. Keep it that way.
  defp type(<<_::binary-size(156), flag::binary-size(1), _::binary>>) do
    case flag do
      "0" ->
        {:ok, :regular}

      <<0>> ->
        {:ok, :regular}

      "5" ->
        {:ok, :dir}

      "x" ->
        {:ok, :pax}

      "1" ->
        {:error, "E_HARDLINK", "the archive contains a hard link — refused"}

      "2" ->
        {:error, "E_SYMLINK",
         "the archive contains a symlink — refused (a staged symlink is SERVED)"}

      "3" ->
        {:error, "E_SPECIAL_FILE", "the archive contains a character device — refused"}

      "4" ->
        {:error, "E_SPECIAL_FILE", "the archive contains a block device — refused"}

      "6" ->
        {:error, "E_SPECIAL_FILE", "the archive contains a fifo — refused"}

      # A GLOBAL pax header sets defaults for EVERY following entry, including
      # entries in a later member. A site bundle has no use for that, and honouring
      # it would mean carrying override state across the whole archive — the exact
      # thing the per-entry `x` handling refuses to do.
      "g" ->
        {:error, "E_UNKNOWN_TYPE",
         "the archive contains a pax GLOBAL extension header (type \"g\"), which sets " <>
           "defaults for every following entry — refused; repack with per-entry headers " <>
           "(e.g. `tar --format=posix -czf site.tar.gz -C ./dist .`)"}

      # GNU's long-name/long-linkname headers, and the reason they are a REFUSAL
      # rather than a skip: measured on GNU tar 1.35, an `L` block's two shadow
      # headers carry BYTE-IDENTICAL truncated 100-byte names, so skipping `L`
      # would stage a directory and a regular file at the SAME effective path.
      # There is no honest way to recover the real name from the ustar blocks.
      flag when flag in ["L", "K"] ->
        {:error, "E_UNKNOWN_TYPE", gnu_longname_message(flag)}

      other ->
        {:error, "E_UNKNOWN_TYPE", "unsupported tar entry type #{inspect(other)}"}
    end
  end

  # We write 0644/0755 ourselves and ignore Uid/Gid, so a mode is only ever READ
  # here in order to REFUSE one: a static bundle has no business carrying
  # setuid, setgid or the sticky bit, and an archive asking for one is telling
  # us something about itself.
  defp mode_bits(<<_::binary-size(100), mode::binary-size(8), _::binary>>) do
    case octal(mode) do
      {:ok, m} ->
        if Bitwise.band(m, 0o7000) == 0 do
          :ok
        else
          {:error, "E_MODE_BITS",
           "entry mode #{Integer.to_string(m, 8)} carries setuid/setgid/sticky — refused"}
        end

      :error ->
        {:error, "E_MALFORMED", "entry mode field is not octal"}
    end
  end

  # A pax `size` record REPLACES the header's size field — it is how a writer
  # expresses a body the octal field cannot hold — so it is applied and then run
  # through the very same per-entry and total caps.
  defp effective_size(_header, :dir, _state), do: {:ok, 0}

  defp effective_size(header, :regular, state) do
    case pax_override(state, :size) do
      nil -> size(header, :regular, state)
      declared -> check_size(declared, state)
    end
  end

  defp size(<<_::binary-size(124), field::binary-size(12), _::binary>>, :regular, state) do
    case octal(field) do
      {:ok, size} -> check_size(size, state)
      :error -> {:error, "E_MALFORMED", "entry size field is not octal"}
    end
  end

  defp check_size(size, state) do
    cond do
      size > state.max_entry_bytes ->
        {:error, "E_ENTRY_TOO_LARGE",
         "an entry declares #{size} bytes, over the #{state.max_entry_bytes} byte per-entry cap"}

      state.bytes + size > state.max_total_bytes ->
        {:error, "E_TOTAL_TOO_LARGE",
         "the archive's entries declare more than the #{state.max_total_bytes} byte total cap"}

      true ->
        {:ok, size}
    end
  end

  # THE path check: validate the CLEANED, JOINED, EXPANDED path — never the
  # header name. `Path.expand/1` resolves `.`/`..` textually, so an entry
  # survives only if the place it would actually land is strictly under the
  # staging root.
  # Returns `{:ok, :root}` for the archive's own root DIRECTORY entry (`.` /
  # `./`), which is not a path to write; every other accepted entry returns the
  # absolute path it will occupy.
  defp safe_path(name, type, state) do
    cond do
      String.starts_with?(name, "/") ->
        {:error, "E_ABSOLUTE_PATH", "entry #{inspect(name)} is an absolute path — refused"}

      ".." in String.split(name, "/") ->
        {:error, "E_PATH_TRAVERSAL", "entry #{inspect(name)} escapes the artifact root"}

      true ->
        joined = Path.expand(Path.join(state.root, name))
        root = String.trim_trailing(state.root_prefix, "/")

        cond do
          String.starts_with?(joined, state.root_prefix) ->
            {:ok, joined}

          joined == root and type == :dir ->
            {:ok, :root}

          joined == root ->
            {:error, "E_BAD_NAME",
             "entry #{inspect(name)} names the artifact root itself as a file"}

          true ->
            {:error, "E_PATH_TRAVERSAL",
             "entry #{inspect(name)} resolves outside the artifact root"}
        end
    end
  end

  # ── the pax extension header: narrow, budgeted, RE-VALIDATED ──────────────

  # An `x` header. Note what does NOT happen here: `count_entry/1` is never
  # called (an extension header is not an entry — Go emits one per non-ASCII
  # entry, and counting them would halve the effective `@max_entries`),
  # `name/1` never sees the block's own pseudo-path, and nothing is opened or
  # written. The block's declared size is capped BEFORE a byte is buffered.
  defp pax_begin(_header, %{pax: pax}) when not is_nil(pax) do
    {:error, "E_MALFORMED",
     "the archive has two pax extension headers in a row — an extension header must be " <>
       "followed by the file or directory entry it describes"}
  end

  defp pax_begin(<<_::binary-size(124), field::binary-size(12), _::binary>>, state) do
    case octal(field) do
      {:ok, size} when size > @max_pax_block_bytes ->
        {:error, "E_ENTRY_TOO_LARGE",
         "a pax extension header declares #{size} bytes of records, over the " <>
           "#{@max_pax_block_bytes} byte extension-header cap"}

      {:ok, size} ->
        {:ok,
         %{
           state
           | phase: :pax_body,
             pax_buf: <<>>,
             pax_remaining: size,
             padding: padding_for(size)
         }}

      :error ->
        {:error, "E_MALFORMED", "pax extension header size field is not octal"}
    end
  end

  defp pax_override(%{pax: nil}, _key), do: nil
  defp pax_override(%{pax: pax}, key), do: Map.get(pax, key)

  defp pax_dangling_message do
    "the archive ends with a pax extension header that describes no entry — an extension " <>
      "header must be followed by the file or directory it describes"
  end

  defp gnu_longname_message(flag) do
    kind = if flag == "L", do: "long NAME", else: "long LINK NAME"

    "the archive uses a GNU #{kind} extension header (type #{inspect(flag)}) — refused, " <>
      "because its shadow headers carry only a TRUNCATED name and two entries can collapse " <>
      "onto the same path. Repack in POSIX/pax format, which the box does accept: " <>
      "`tar --format=posix -czf site.tar.gz -C ./dist .` (GNU tar defaults to " <>
      "`--format=gnu`), or shorten the path component that is over 100 bytes."
  end

  # Parse a pax record block: a run of `"<len> <key>=<value>\n"` records where
  # `<len>` counts the WHOLE record, digits and newline included. Length-driven on
  # purpose — a value may itself contain `=` or a newline, so scanning for
  # delimiters would be wrong.
  #
  # Only `path` and `size` survive; every other key is DISCARDED but still counted
  # against `@max_extension_records`, so a block padded with 10 000 `SCHILY.*`
  # records is refused rather than walked.
  defp pax_records(block), do: pax_records(block, %{}, 0)

  defp pax_records(<<>>, acc, _count), do: {:ok, acc}

  defp pax_records(_rest, _acc, count) when count >= @max_extension_records do
    {:error, "E_MALFORMED",
     "a pax extension header holds more than #{@max_extension_records} records — refused"}
  end

  defp pax_records(block, acc, count) do
    with {:ok, len} <- pax_record_length(block),
         {:ok, record, rest} <- pax_split_record(block, len),
         {:ok, key, value} <- pax_key_value(record) do
      acc = if key in @pax_applied_keys, do: pax_apply(acc, key, value), else: acc

      case acc do
        {:error, _code, _message} = refusal -> refusal
        acc -> pax_records(rest, acc, count + 1)
      end
    end
  end

  defp pax_record_length(block) do
    case :binary.split(block, " ") do
      [digits, _rest] ->
        case Integer.parse(digits) do
          {len, ""} when len > 0 -> {:ok, len}
          _ -> {:error, "E_MALFORMED", pax_malformed_record()}
        end

      _ ->
        {:error, "E_MALFORMED", pax_malformed_record()}
    end
  end

  defp pax_split_record(block, len) do
    cond do
      len > @max_extension_record_bytes ->
        {:error, "E_MALFORMED",
         "a pax extension record declares #{len} bytes, over the " <>
           "#{@max_extension_record_bytes} byte per-record cap"}

      len > byte_size(block) ->
        {:error, "E_MALFORMED",
         "a pax extension record declares #{len} bytes but only #{byte_size(block)} remain"}

      true ->
        <<record::binary-size(len), rest::binary>> = block
        {:ok, record, rest}
    end
  end

  # The record's own declared length said where it ends, so the only framing left
  # to check is that it ends in a newline and carries a non-empty `<key>=`.
  defp pax_key_value(record) do
    with [_digits, payload] <- :binary.split(record, " "),
         true <- String.ends_with?(payload, "\n"),
         [key, value] <- :binary.split(binary_part(payload, 0, byte_size(payload) - 1), "="),
         true <- key != "" do
      {:ok, key, value}
    else
      _ -> {:error, "E_MALFORMED", pax_malformed_record()}
    end
  end

  defp pax_apply(acc, "path", value), do: Map.put(acc, :path, value)

  defp pax_apply(acc, "size", value) do
    case Integer.parse(value) do
      {size, ""} when size >= 0 ->
        Map.put(acc, :size, size)

      _ ->
        {:error, "E_MALFORMED",
         "a pax extension header declares a size record that is not a number"}
    end
  end

  defp pax_malformed_record,
    do: "a pax extension header holds a malformed record (expected \"<len> <key>=<value>\\n\")"

  defp place_dir(path, state) do
    with {:ok, state} <- count_entry(state),
         :ok <- mkdir_entry(path) do
      {:ok, state}
    end
  end

  defp place_file(path, size, state) do
    with {:ok, state} <- count_entry(state),
         :ok <- mkdir_entry(Path.dirname(path)),
         {:ok, io} <- open_entry(path) do
      state = %{
        state
        | files: state.files + 1,
          root_index: state.root_index or root_index?(path, state)
      }

      {:ok, %{state | phase: :body, io: io, remaining: size, padding: padding_for(size)}}
    end
  end

  # The one file the static runtime serves for `/` and HEALTH reads its markers
  # out of. `path` is already the EXPANDED join, so `index.html` and
  # `./index.html` are the same answer here and a nested `blog/index.html` is not.
  defp root_index?(path, state), do: path == state.root_prefix <> "index.html"

  defp count_entry(state) do
    entries = state.entries + 1

    if entries > state.max_entries do
      {:error, "E_TOO_MANY_ENTRIES", "the archive holds more than #{state.max_entries} entries"}
    else
      {:ok, %{state | entries: entries}}
    end
  end

  defp padding_for(size) do
    case rem(size, @block) do
      0 -> 0
      r -> @block - r
    end
  end

  # Reachability: `path` is the EXPANDED join of the staging root with an entry
  # name `safe_path/2` already proved lands strictly under that root — an
  # absolute name, a `..` segment, or any path escaping the root was refused
  # before this line. `:enotdir` (a parent already written as a FILE) is the
  # write-through case, and it is refused rather than created.
  # sobelow_skip ["Traversal.FileModule"]
  defp mkdir_entry(path) do
    case File.mkdir_p(path) do
      :ok ->
        chmod_quiet(path, 0o755)

      {:error, reason} when reason in [:enotdir, :eexist] ->
        {:error, "E_UNSAFE_PARENT",
         "entry #{inspect(path)} would be written through a parent that is not a directory"}

      {:error, reason} ->
        {:error, "E_WRITE_FAILED", "could not create #{inspect(path)}: #{inspect(reason)}"}
    end
  end

  # Reachability: identical to `mkdir_entry/1` — a `safe_path/2`-proven path
  # under the staging root this module created. `:exclusive` so an archive that
  # names the same file twice cannot rewrite bytes already validated.
  # sobelow_skip ["Traversal.FileModule"]
  defp open_entry(path) do
    case File.open(path, [:write, :binary, :exclusive, :raw]) do
      {:ok, io} ->
        _ = chmod_quiet(path, 0o644)
        {:ok, io}

      # `O_CREAT|O_EXCL` answers `:eexist` for ANY existing path, file or
      # directory, so this one arm is what covers BOTH collisions — and the
      # message has to say which, because "names it more than once" is wrong and
      # unactionable for a file landing on a staged DIRECTORY. That collision is
      # the one a pax `path` record makes reachable: an `x` block can rewrite a
      # leaf onto a directory the archive already created.
      #
      # The remaining direction — a DIRECTORY header naming an already-staged
      # DIRECTORY — is covered by no rule ON PURPOSE: `File.mkdir_p/1` on an
      # existing directory is idempotent and writes no bytes, so a duplicate dir
      # header can neither overwrite nor shadow anything, and its children are each
      # validated on their own headers.
      {:error, :eexist} ->
        {:error, "E_UNSAFE_PARENT", eexist_message(path)}

      {:error, :enotdir} ->
        {:error, "E_UNSAFE_PARENT",
         "entry #{inspect(path)} would be written through a parent that is a file"}

      {:error, reason} ->
        {:error, "E_WRITE_FAILED", "could not open #{inspect(path)}: #{inspect(reason)}"}
    end
  end

  # Reachability: a `safe_path/2`-validated path under the staging root, read only
  # to name the collision that just happened.
  # sobelow_skip ["Traversal.FileModule"]
  defp eexist_message(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        "the archive names #{inspect(path)} as a file after already staging it as a directory"

      _ ->
        "the archive names #{inspect(path)} more than once"
    end
  end

  # Reachability: as above — a validated path under the staging root. A chmod
  # failure is never fatal: the bytes are already correct and the mode being set
  # is the SANITIZED one, never the archive's.
  # sobelow_skip ["Traversal.FileModule"]
  defp chmod_quiet(path, mode) do
    _ = File.chmod(path, mode)
    :ok
  end

  # A refusal taken mid-file still holds an open handle; close it before the
  # staging tree is removed so no descriptor outlives the refusal.
  defp close_io(%{io: io}, refusal) when not is_nil(io) do
    _ = File.close(io)
    refusal
  end

  defp close_io(_state, refusal), do: refusal

  # End of stream, in the order the questions have to be asked: was an entry cut
  # in half, was the archive itself cut before its marker, does it hold anything
  # at all, and is what it holds a SITE.
  defp finish(%{phase: :body, remaining: remaining} = state) when remaining > 0 do
    _ = File.close(state.io)
    {:error, "E_MALFORMED", "the archive ends mid-entry (#{remaining} bytes short)"}
  end

  # Cut INSIDE a pax record block: the override never arrived whole, so the entry
  # it describes could not be validated even if its header did arrive.
  defp finish(%{phase: :pax_body} = state) do
    if state.io, do: File.close(state.io)

    {:error, "E_MALFORMED",
     "the archive ends inside a pax extension header (#{state.pax_remaining} bytes short)"}
  end

  # A pending override with no entry to describe — the archive stopped between an
  # extension header and its file.
  defp finish(%{pax: pax} = state) when not is_nil(pax) do
    if state.io, do: File.close(state.io)
    {:error, "E_MALFORMED", pax_dangling_message()}
  end

  # No end-of-archive marker. A tar cut ON a 512-byte boundary yields entries
  # that all parse — the loss is whole FILES, and nothing else in the stream
  # says so.
  defp finish(%{halted: false} = state) do
    if state.io, do: File.close(state.io)

    {:error, "E_MALFORMED",
     "the archive has no end-of-archive marker (its two zero blocks) — " <>
       "it was truncated after #{state.entries} entries"}
  end

  defp finish(%{entries: 0} = state) do
    if state.io, do: File.close(state.io)
    {:error, "E_MALFORMED", "the archive holds no entries"}
  end

  # The SHAPE assert. Same contract the CLI states one hop earlier in
  # `validatePrebuiltDir` (internal/cli/sites_tarball.go): a build-output
  # directory has a root `index.html`, and a bundle without one deploys green
  # and 404s. Two flavours because the two mistakes are different mistakes — a
  # `dist` that packed hollow, versus a project directory packed instead of its
  # output.
  defp finish(%{files: 0} = state) do
    if state.io, do: File.close(state.io)

    {:error, "E_NO_INDEX",
     "the archive stages no files at all — the served tree would be empty " <>
       "(pass the build OUTPUT directory, e.g. ./dist)"}
  end

  defp finish(%{root_index: false} = state) do
    if state.io, do: File.close(state.io)

    {:error, "E_NO_INDEX",
     "the archive has no index.html at its root — the site would 404 at its own " <>
       "domain (pass the build OUTPUT directory, e.g. ./dist)"}
  end

  defp finish(state) do
    if state.io, do: File.close(state.io)
    {:ok, %{entries: state.entries, bytes: state.bytes}}
  end

  # ── header field primitives ───────────────────────────────────────────────

  defp trim_nul(field) do
    case :binary.split(field, <<0>>) do
      [head | _] -> head
      [] -> ""
    end
  end

  # A tar numeric field is NUL/space-padded octal. GNU's base-256 extension
  # (high bit set on the first byte) is NOT parsed: it exists to carry values
  # larger than the octal field can hold — i.e. exactly the sizes this module
  # refuses — so it is reported as malformed rather than decoded.
  defp octal(field) do
    digits =
      field
      |> trim_nul()
      |> String.trim()

    case digits do
      "" ->
        {:ok, 0}

      digits ->
        case Integer.parse(digits, 8) do
          {value, ""} when value >= 0 -> {:ok, value}
          _ -> :error
        end
    end
  end
end
