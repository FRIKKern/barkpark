defmodule Barkpark.Content.EnvelopeInternalSentinelTest do
  @moduledoc """
  Static-analysis tripwire on the `:internal` no-redaction sentinel
  (`Barkpark.Content.Envelope`).

  WHAT THIS TEST'S RED ACTUALLY MEANS, said plainly: a NEW call site now hands
  `:internal` to `Envelope.render/3`, `Envelope.redact/3,4` or
  `Envelope.field_readable?/3`, and either it is not one of the three known
  `Content.Broadcast` sites, or it lives under `lib/barkpark_web/` — the web
  layer, where the requester's own context is in scope and the sentinel would
  silently turn a per-caller read into an unredacted one.

  WHY IT IS WORTH PINNING. The sentinel's real security property is that it is
  UNFORGEABLE INPUT: no header, token, query param or share link can produce it,
  because `CallerContext.from_conn/1` returns a `%CallerContext{}` or
  `CallerContext.anonymous()` — never the bare atom. That property held only by
  construction; nothing but a `@spec` stood behind it. This test is that
  something.

  ITS LIMIT, stated so no later reader over-reads it: it pins that no web-layer
  source in `lib/` PASSES the sentinel. It does NOT prove the sentinel is
  unforgeable at runtime, does NOT prove the bytes an `:internal` render
  produces stay inside the node (they do not — see the two egress seams named in
  `envelope.ex`'s moduledoc), and it cannot see a call assembled dynamically
  (e.g. `apply/3`, or the atom threaded through a variable).

  MUTATION PROOF (this guard can actually fail; run 2026-08-19 in the builder's
  worktree off origin/main). A probe module `BarkparkWeb.ProbeInternalSentinel`
  was added at `lib/barkpark_web/probe_internal_sentinel.ex` with the single
  line `def leak(doc), do: Envelope.render(doc, nil, :internal)`. Both tests
  went RED — `2 tests, 2 failures` — the web-layer test printing
  `[{"barkpark_web/probe_internal_sentinel.ex", 6}]` and the sanctioned-set test
  printing the full list `broadcast.ex 69 / 133 / 319` plus the probe. The probe
  was then deleted and both tests returned to `2 tests, 0 failures`.

  It parses each `.ex` file under `lib/` to an AST and walks for real call
  expressions, so prose in a `@moduledoc` or a `#` comment that merely QUOTES
  `Envelope.render(doc, nil, :internal)` — `listen_controller.ex` does exactly
  that where it explains the admin forward — does not trip it. `envelope.ex`
  itself is excluded: it is the module that DEFINES the clauses, so its own
  function heads match by construction.
  """
  use ExUnit.Case, async: true

  @lib_dir Path.expand("../../../lib", __DIR__)
  @definition_site "barkpark/content/envelope.ex"
  @sentinel_funs [:render, :redact, :field_readable?]

  # The only sanctioned `:internal` call sites on origin/main: the immediate
  # broadcast, the deferred flush, and the stored `mutation_events` snapshot
  # (re-redacted per subscriber downstream).
  @expected %{"barkpark/content/broadcast.ex" => 3}

  test "`:internal` reaches the Envelope redaction API only from the sanctioned Broadcast sites" do
    sites = sentinel_sites()

    assert Enum.frequencies_by(sites, &elem(&1, 0)) == @expected, """
    The set of `:internal` call sites in lib/ changed.

    `:internal` is the no-redaction sentinel — it disables per-field visibility
    entirely. A new site is only safe if its output is re-redacted per recipient
    downstream (which is what the Broadcast sites rely on). Found:

    #{inspect(sites, pretty: true)}

    If the new site is legitimate, extend @expected AND say in the call site's
    own comment who re-redacts its output.
    """
  end

  test "no source under lib/barkpark_web/ passes `:internal` to the Envelope redaction API" do
    web_sites = Enum.filter(sentinel_sites(), fn {file, _line} -> file =~ ~r{^barkpark_web/} end)

    assert web_sites == [], """
    A web-layer source now passes the `:internal` no-redaction sentinel:

    #{inspect(web_sites, pretty: true)}

    The web layer always has the REQUESTER's own `%CallerContext{}` in scope
    (`CallerContext.from_conn/1`), so passing `:internal` there substitutes the
    full-content sentinel for a caller who did not earn it — every `private` /
    `owner_only` / `readable_by` / encrypted field would ride out on that
    response. Thread the caller's context instead.
    """
  end

  defp sentinel_sites do
    for file <- Path.wildcard(Path.join(@lib_dir, "**/*.ex")),
        (rel = Path.relative_to(file, @lib_dir)) != @definition_site,
        {:ok, ast} <- [Code.string_to_quoted(File.read!(file))],
        line <- internal_call_lines(ast) do
      {rel, line}
    end
    |> Enum.sort()
  end

  defp internal_call_lines(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn node, acc ->
        case call_node(node) do
          {fun, meta, args} when is_list(args) ->
            if fun in @sentinel_funs and Enum.any?(args, &mentions_internal?/1),
              do: {node, [Keyword.get(meta, :line, 0) | acc]},
              else: {node, acc}

          _ ->
            {node, acc}
        end
      end)

    Enum.reverse(lines)
  end

  # Both the qualified (`Envelope.render(…)`) and bare (`render(…)`) call shapes.
  defp call_node({{:., _, [_mod, fun]}, meta, args}), do: {fun, meta, args}
  defp call_node({fun, meta, args}) when is_atom(fun), do: {fun, meta, args}
  defp call_node(_), do: nil

  defp mentions_internal?(arg) do
    {_ast, found?} =
      Macro.prewalk(arg, false, fn
        :internal, _acc -> {:internal, true}
        node, acc -> {node, acc}
      end)

    found?
  end
end
