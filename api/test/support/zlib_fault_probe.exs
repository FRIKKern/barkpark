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

:persistent_term.put(:zlib_fault_probe_cfg, cfg)

# The stub. It does NOT inflate: it hands back a slice of the plaintext the
# caller already computed, so the bytes reaching the tar state machine are
# exactly the bytes a real inflate would have produced, and the ONE thing that
# differs from a real run is the injected raise.
stub = ~S"""
-module(zlib).
-export([open/0, inflateInit/2, safeInflate/2, inflateEnd/1, close/1]).

open() -> zlib_fault_probe_stream.

inflateInit(_Z, _WindowBits) ->
    persistent_term:put(zlib_fault_probe_calls, 0),
    persistent_term:put(zlib_fault_probe_delivered, 0),
    ok.

safeInflate(_Z, _Data) ->
    N = persistent_term:get(zlib_fault_probe_calls) + 1,
    persistent_term:put(zlib_fault_probe_calls, N),
    Cfg = persistent_term:get(zlib_fault_probe_cfg),
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
            persistent_term:put(zlib_fault_probe_delivered, Offset + Take),
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
    calls: :persistent_term.get(:zlib_fault_probe_calls, 0),
    delivered: :persistent_term.get(:zlib_fault_probe_delivered, 0)
  })
)
