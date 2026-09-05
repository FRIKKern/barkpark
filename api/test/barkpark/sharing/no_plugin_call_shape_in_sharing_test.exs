defmodule Barkpark.Sharing.NoPluginCallShapeTest do
  @moduledoc """
  THE `sharing>plugin` SIDEWAYS EDGE, PINNED AT ITS SOURCE (task-2a47502792773c6c).

  cqv8's boundary gate reported a NEW feature→feature sideways edge
  `sharing>plugin` against `tooling/concept-map/boundary-baseline.json`. The
  concrete reference behind it was ONE line of PROSE — a `@doc` bullet in
  `Barkpark.Sharing.Links` written as `PluginScopeSession.on_mount(:scope, …)`.

  `tooling/symbol-graph/build-symbols.mjs` mints its call edges by matching
  `\\b([A-Z][\\w.]*)\\.([a-z_][\\w?!]*)\\s*\\(` over the RAW FILE TEXT — it does
  not parse, so it cannot tell a call from a `@doc` string. A module reference
  written in CALL shape inside documentation is therefore indistinguishable
  from a real dependency, and `api/lib/barkpark/sharing` has no real one: it
  aliases Auth, Content.DraftId, Repo and Tenancy, and nothing under the plugin
  concept.

  So this test does NOT assert an architectural rule about the plugin
  behaviour. It asserts the DOC CONVENTION that keeps the instrument honest
  for this directory: a module reference in `api/lib/barkpark/sharing/**` is
  written in ExDoc arity form (`Mod.fun/4`), the same form the sibling bullet
  two lines above it already used. Arity form is the reference ExDoc actually
  links, so the convention pays for itself independently of the gate.
  """
  use ExUnit.Case, async: true

  @sharing_dir Path.expand("../../../lib/barkpark/sharing", __DIR__)

  # The edge-minting shape from build-symbols.mjs, transcribed: an uppercase
  # module path, a dot, a lowercase function name, then an open paren.
  @call_shape ~r/\b[A-Z][\w.]*\.[a-z_][\w?!]*\s*\(/

  test "no module reference in a sharing @doc is written in call shape" do
    files = Path.wildcard(Path.join(@sharing_dir, "**/*.ex"))
    assert files != [], "no sharing sources found under #{@sharing_dir}"

    offenders =
      for path <- files,
          {line, n} <- Enum.with_index(File.read!(path) |> String.split("\n"), 1),
          # Only DOC prose: the bullet/backtick lines. A real call in code is
          # exactly what this test must not flag.
          String.contains?(line, "`"),
          match = Regex.run(@call_shape, line),
          do: "#{Path.relative_to(path, @sharing_dir)}:#{n}: #{hd(match)}"

    assert offenders == [],
           """
           A documented module reference under api/lib/barkpark/sharing is written in
           CALL shape inside backticks. build-symbols.mjs cannot tell that from a real
           dependency, so it mints a sharing>plugin-style concept edge and the cqv8
           boundary gate reds on architectural debt that does not exist in the code.

           Write the reference in ExDoc arity form instead — `Mod.fun/4`.

           #{Enum.join(offenders, "\n")}
           """
  end
end
