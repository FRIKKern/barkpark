# A FAULT INJECTOR for `Barkpark.Sites.PrebuiltArtifact.run_stream/3`, run in a
# SEPARATE OS PROCESS on purpose.
#
# The hole under test is that `run_stream/3` catches exactly three zlib errors.
# To prove what any OTHER error inside the stream does, something has to MAKE
# zlib raise one — and the only seam is `:zlib` itself. Replacing a stdlib
# module is a whole-VM act: it would be visible to every other process on the
# node, so it happens in a VM of its own that exits when the probe does. Nothing
# in the test node is swapped, stubbed or restored.
#
# Usage (see `PrebuiltArtifactStreamFaultTest`, which is the only caller):
#
#     elixir -pa <build>/lib/barkpark/ebin zlib_fault_probe.exs <request> <reply>
#
# `<request>` is `:erlang.term_to_binary/1` of a map:
#
#     %{plain: <the UNCOMPRESSED tar bytes the stub hands back>,
#       chunk: <bytes of `plain` per safeInflate call>,
#       fire_at: <1-based safeInflate call index that raises>,
#       error: <the atom to raise>,
#       artifact_b64: ..., sha256: ..., dest: ..., opts: ...}
#
# `<reply>` is written as `:erlang.term_to_binary/1` of:
#
#     %{outcome: {:returned, term} | {:raised, kind, reason, stacktrace},
#       calls: <how many safeInflate calls happened>,
#       delivered: <bytes of `plain` handed over BEFORE the fault>}
#
# `calls` and `delivered` are what make the assertion "the injection fired on
# the call inside `drain/3`, after the parser had already consumed real tar"
# checkable — an injector armed on the wrong call site goes green while the hole
# under test never runs.

[request_path, reply_path] = System.argv()

cfg = request_path |> File.read!() |> :erlang.binary_to_term()

# THE PROCESS DICTIONARY, NOT `:persistent_term`. The stub below needs its
# config and its call counter somewhere Erlang code can reach without an
# argument, and the first draft of this file reached for `:persistent_term` —
# which is VM-GLOBAL, so the value outlives the test, the module and the file,
# and the next module the scheduler happens to run inherits it. That is the
# ghost-failure-in-a-file-nobody-touched class, which is the very disease this
# probe exists to diagnose; `scripts/test-env-leak-gate.sh` was right to red it.
#
# It is NOT allowlisted on the grounds that this runs in its own VM. That
# argument is true today and silently false the day anyone calls this file from
# inside the test node, and a waiver is permanent while the reasoning that
# justified it is not. The process dictionary needs no such argument: it is
# scoped to ONE process by construction, and this whole script — the `put`
# below, `stage/4`, and every `:zlib` callback `stage/4` makes — runs in that
# single process, asserted after the run rather than assumed.
Process.put(:zlib_fault_probe_cfg, cfg)
Process.put(:zlib_fault_probe_owner, self())

# The stub. It does NOT inflate: it hands back a slice of the plaintext the
# caller already computed, so the bytes reaching the tar state machine are
# exactly the bytes a real inflate would have produced, and the ONE thing that
# differs from a real run is the injected raise.
stub = ~S"""
-module(zlib).
-export([open/0, inflateInit/2, inflateInit/3, safeInflate/2, inflateEnd/1, close/1]).

open() -> zlib_fault_probe_stream.

inflateInit(_Z, _WindowBits) ->
    put(zlib_fault_probe_calls, 0),
    put(zlib_fault_probe_delivered, 0),
    ok.

%% `stage/4` inits with an end-of-stream behaviour (`:error`, and `:cut` for its
%% data_error classifier); the stub has no stream to end, so it is ignored.
inflateInit(Z, WindowBits, _EoSBehavior) ->
    inflateInit(Z, WindowBits).

safeInflate(_Z, _Data) ->
    %% `get/1` answering `undefined` here would mean the caller is NOT the
    %% process that wrote the config — the one assumption behind using the
    %% process dictionary. Fail by name rather than by badmatch three lines on.
    Cfg = case get(zlib_fault_probe_cfg) of
              undefined -> erlang:error(zlib_fault_probe_config_not_in_this_process);
              C -> C
          end,
    N = get(zlib_fault_probe_calls) + 1,
    put(zlib_fault_probe_calls, N),
    #{plain := Plain, chunk := Chunk, fire_at := FireAt, error := Error} = Cfg,
    case N =:= FireAt of
        true -> erlang:error(Error);
        false -> ok
    end,
    Offset = (N - 1) * Chunk,
    Size = byte_size(Plain),
    case Offset >= Size of
        true ->
            {finished, []};
        false ->
            Take = min(Chunk, Size - Offset),
            Out = binary:part(Plain, Offset, Take),
            put(zlib_fault_probe_delivered, Offset + Take),
            case Offset + Take >= Size of
                true -> {finished, [Out]};
                false -> {continue, [Out]}
            end
    end.

inflateEnd(_Z) -> ok.

close(_Z) -> ok.
"""

erl = Path.join(System.tmp_dir!(), "zlib_fault_probe_#{System.unique_integer([:positive])}.erl")
File.write!(erl, stub)
{:ok, :zlib, beam} = :compile.file(String.to_charlist(erl), [:binary, :return_errors])
File.rm(erl)

# stdlib's ebin is sticky; a stdlib module cannot be replaced until it is not.
true = :code.unstick_mod(:zlib)
{:module, :zlib} = :code.load_binary(:zlib, ~c"zlib_fault_probe.erl", beam)

outcome =
  try do
    {:returned,
     Barkpark.Sites.PrebuiltArtifact.stage(
       cfg.artifact_b64,
       cfg.sha256,
       cfg.dest,
       cfg.opts
     )}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

File.write!(
  reply_path,
  :erlang.term_to_binary(%{
    outcome: outcome,
    calls: Process.get(:zlib_fault_probe_calls, 0),
    delivered: Process.get(:zlib_fault_probe_delivered, 0)
  })
)

# The assumption, ASSERTED rather than assumed: the counters the reply just
# reported were written into THIS process's dictionary by the stub. If the
# `:zlib` callbacks had run anywhere else these would both read 0, and a
# fault-injection probe that reports zeros must refuse, not answer.
owner = Process.get(:zlib_fault_probe_owner)

unless owner == self() and Process.get(:zlib_fault_probe_calls, 0) > 0 do
  raise "zlib_fault_probe: the stub's counters are not in the writing process " <>
          "(owner #{inspect(owner)}, self #{inspect(self())}, " <>
          "calls #{inspect(Process.get(:zlib_fault_probe_calls))}) — the " <>
          "process-dictionary assumption this file rests on no longer holds"
end
