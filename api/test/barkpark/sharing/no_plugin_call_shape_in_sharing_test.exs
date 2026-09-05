defmodule Barkpark.Sharing.NoPluginCallShapeTest do
  @moduledoc """
  THE `sharing>plugin` SIDEWAYS EDGE, PINNED AT ITS SOURCE (task-2a47502792773c6c).

  cqv8's boundary gate reported a NEW feature→feature sideways edge
  `sharing>plugin` against `tooling/concept-map/boundary-baseline.json`, and
  #16124 made that gate BLOCKING. Dumped on a warmed tree, the edge resolved to
  EXACTLY ONE raw edge, and its source line is PROSE — a `@doc` bullet in
  `Barkpark.Sharing.Links` that wrote the socket-side gate as
  `PluginScopeSession.on_mount(:scope, …)`.

  `tooling/symbol-graph/build-symbols.mjs` mints its Elixir call edges by
  matching `Module.fun(` over the RAW FILE TEXT. It does not parse, so it
  cannot tell a call from a docstring: a module reference written in CALL shape
  inside documentation is indistinguishable from a real dependency. There is no
  real one — `api/lib/barkpark/sharing` aliases Auth, Content.DraftId, Repo and
  Tenancy, and nothing under the plugin concept.

  So this asserts a DOC CONVENTION, not an architectural rule about the plugin
  behaviour: a plugin-concept module referenced from `api/lib/barkpark/sharing`
  documentation is written in ExDoc arity form (`Mod.fun/4`) — the form the
  sibling bullet on the line above it already used, and the only form ExDoc
  actually turns into a link.

  DELIBERATELY NARROW. It does not police every call-shape reference in these
  docstrings: `Repo.uuid_or_nil(workspace_id)` and `Share.t()` are written that
  way today and mint `sharing>repo`-shaped edges the baseline already knows.
  Widening this to all of them would be a different decision, owned by a
  different row — this one owns `sharing>plugin`.
  """
  use ExUnit.Case, async: true

  @sharing_dir Path.expand("../../../lib/barkpark/sharing", __DIR__)

  # A plugin-concept module in the edge-minting shape from build-symbols.mjs:
  # a module path whose last segment starts with `Plugin`, a dot, a lowercase
  # function name, then an open paren.
  @plugin_call_shape ~r/\b(?:[A-Z][\w.]*\.)?Plugin\w*\.[a-z_][\w?!]*\s*\(/

  test "no plugin-concept module is referenced in call shape under api/lib/barkpark/sharing" do
    files = Path.wildcard(Path.join(@sharing_dir, "**/*.ex"))
    assert files != [], "no sharing sources found under #{@sharing_dir}"

    offenders =
      for path <- files,
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          match = Regex.run(@plugin_call_shape, line),
          do: "#{Path.relative_to(path, @sharing_dir)}:#{n}: #{hd(match)}"

    assert offenders == [],
           """
           A plugin-concept module is referenced in CALL shape under
           api/lib/barkpark/sharing. build-symbols.mjs cannot tell that from a real
           dependency even when it sits in a docstring, so it mints a sharing>plugin
           concept edge and the (blocking, #16124) cqv8 boundary gate reds on
           architectural debt the code does not have.

           If this is documentation, write the reference in ExDoc arity form —
           `BarkparkWeb.PluginScopeSession.on_mount/4`.
           If this is real code, the sideways edge is real and owes a port inversion,
           not a doc edit.

           #{Enum.join(offenders, "\n")}
           """
  end
end
