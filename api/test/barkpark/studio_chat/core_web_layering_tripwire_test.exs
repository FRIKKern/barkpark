defmodule Barkpark.StudioChat.CoreWebLayeringTripwireTest do
  @moduledoc """
  One rule, two instruments: **nothing under `Barkpark.StudioChat.*` may depend
  on `BarkparkWeb.*`.**

  ## Why (task-ad931ba2e0d0bdf4)

  Core drove provider sessions through the web wrapper. On `origin/main` the
  live references were:

      lib/barkpark/studio_chat/runtime/claude.ex:8
        alias BarkparkWeb.Studio.ClaudeChat
      lib/barkpark/studio_chat/runtime.ex:637
        Keyword.get(studio_config, :remote_mcp_api_url) || BarkparkWeb.Endpoint.url()
      lib/barkpark/studio_chat/runtime/codex/session.ex:597
        api_url = BarkparkWeb.Studio.ClaudeChat.mcp_api_url()

  plus a doc-only pair in `capabilities.ex` and a hand-kept `@modes` MIRROR in
  `session.ex` whose comment asked two lists to "move TOGETHER". That inversion
  meant a detached / API / background transport could not run a chat session
  without the whole presentation layer compiled, and it spread with every new
  transport. The engine now lives in `Barkpark.StudioChat.Provider.Claude`;
  `BarkparkWeb.Studio.ClaudeChat` is a `defdelegate` shell.

  ## Two instruments, because each is blind where the other sees

  * **`imports` (the BEAM ImpT chunk)** lists every remote `{mod, fun, arity}`
    the COMPILED code can call. It is the authority on a real dependency: it
    survives aliases, `Module.concat/1`-free indirection and formatting, and it
    cannot be fooled by a string. It is blind to a dependency that never
    becomes a call — an `alias` alone, an `@spec`, a struct name in a typespec.
  * **A SOURCE SCAN** of `lib/barkpark/studio_chat/**/*.ex` with `#` comment
    lines and `@moduledoc`/`@doc` heredocs stripped catches exactly that
    residue. It is blind to dynamic dispatch, which the ImpT arm also cannot
    see (`apply(BarkparkWeb.Endpoint, :url, [])` leaves neither a token nor an
    ImpT entry) — see WHAT THIS CANNOT SEE below.

  Prose is deliberately NOT policed. `recorder.ex` and `stream_tail.ex` each
  name a web module in a comment precisely to say core must NOT call it; a scan
  that red on those would train people to delete the warning.

  ## WHAT THIS CANNOT SEE — read before trusting it as coverage

    1. **Dynamic dispatch.** `apply/3` or `Module.concat(["BarkparkWeb", …])`
       resolves at runtime: no ImpT entry, no source token. Nothing in the tree
       does this today.
    2. **Transitive reach.** A core module may call another core module that
       calls the web layer. This checks the `StudioChat` subtree's own edges,
       which is where the inversion lived.
    3. **Config VALUES.** `config :barkpark, :studio_chat, endpoint:
       BarkparkWeb.Endpoint` is the deliberate seam: the module crosses as
       DATA, in `config/config.exs`, which is not scanned. That is the point —
       core reads it with `Application.get_env/3` and names nothing.
  """
  use ExUnit.Case, async: true

  @core_dir "lib/barkpark/studio_chat"
  @web_prefix "Elixir.BarkparkWeb"
  # A floor, not a count: the subtree had 28 modules / 28 source files when this
  # was written. Well under that means the scan has degenerated and any PASS
  # below is vacuous.
  @min_files 20
  @min_modules 20

  # ── arm 1: the compiled import table ──────────────────────────────────────

  test "the ImpT scan actually reaches the StudioChat subtree" do
    mods = core_modules() |> Enum.map(&elem(&1, 0))

    assert length(mods) >= @min_modules,
           "only #{length(mods)} StudioChat module(s) reached — the scan has " <>
             "degenerated (cover-compiled? app not loaded?) and any PASS is vacuous"

    # The three modules that carried the filed references must be in range.
    for mod <- [
          Barkpark.StudioChat.Runtime,
          Barkpark.StudioChat.Runtime.Claude,
          Barkpark.StudioChat.Runtime.Codex.Session
        ] do
      assert mod in mods, "#{inspect(mod)} is not in the scanned set"
    end
  end

  test "no compiled Barkpark.StudioChat module calls into BarkparkWeb" do
    offenders =
      core_modules()
      |> Enum.map(fn {mod, beam} -> {mod, web_imports(beam)} end)
      |> Enum.reject(fn {_mod, imports} -> imports == [] end)

    assert offenders == [], """
    #{length(offenders)} StudioChat module(s) make a RUNTIME call into BarkparkWeb:

    #{Enum.map_join(offenders, "\n", fn {mod, imports} -> "  #{inspect(mod)} → #{Enum.map_join(imports, ", ", &format_mfa/1)}" end)}

    Core must not depend on the web layer (task-ad931ba2e0d0bdf4). Fix it by
    moving the owning code into `Barkpark.StudioChat.*` and leaving a
    `defdelegate` behind, or by handing the web value across as CONFIG DATA the
    way `Barkpark.StudioChat.Endpoints` reads `:studio_chat[:endpoint]`.
    """
  end

  # ── arm 2: the source scan (catches alias-only / typespec residue) ─────────

  test "the source scan actually reaches the StudioChat subtree" do
    files = core_files()

    assert length(files) >= @min_files,
           "only #{length(files)} file(s) found under #{@core_dir} — the scan has " <>
             "degenerated and any PASS is vacuous"

    assert Enum.any?(files, &String.ends_with?(&1, "/runtime/claude.ex"))
  end

  test "no source file under lib/barkpark/studio_chat names BarkparkWeb outside prose" do
    offenders =
      for path <- core_files(),
          {line, n} <- offending_lines(File.read!(path)),
          do: {path, n, line}

    assert offenders == [], """
    #{length(offenders)} line(s) under #{@core_dir} name BarkparkWeb in CODE:

    #{Enum.map_join(offenders, "\n", fn {p, n, l} -> "  #{p}:#{n}  #{String.trim(l)}" end)}
    """
  end

  test "POSITIVE CONTROL: the source scan catches a planted reference" do
    real = Path.join(@core_dir, "runtime/claude.ex")
    body = File.read!(real)

    # Sanity: the real file is clean, so a hit below can only be the plant.
    assert offending_lines(body) == []

    planted =
      String.replace(body, "  @behaviour", "  alias BarkparkWeb.Studio.ClaudeChat\n  @behaviour",
        global: false
      )

    assert planted != body, "the plant anchor moved — this control is inert"

    assert [{line, _n}] = offending_lines(planted)
    assert String.contains?(line, "alias BarkparkWeb.Studio.ClaudeChat")
  end

  test "POSITIVE CONTROL: prose is not policed, code on the same shape is" do
    # A comment and a docstring naming a web module must NOT red...
    assert offending_lines(~s|  # mirrors BarkparkWeb.Studio.ChatToolRenderer.classify/1\n|) == []

    assert offending_lines("""
             @moduledoc \"\"\"
             Extracted out of `BarkparkWeb.Studio.ChatLive`.
             \"\"\"
           """) == []

    # ...but the same token in a code position must.
    assert [{_line, 1}] = offending_lines(~s|  def url, do: BarkparkWeb.Endpoint.url()\n|)
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp core_modules do
    Application.spec(:barkpark, :modules)
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.Barkpark.StudioChat"))
    |> Enum.flat_map(fn mod ->
      case :code.which(mod) do
        beam when is_list(beam) -> [{mod, beam}]
        _other -> []
      end
    end)
  end

  defp web_imports(beam) do
    case :beam_lib.chunks(beam, [:imports]) do
      {:ok, {_mod, [imports: imports]}} ->
        Enum.filter(imports, fn {mod, _f, _a} ->
          String.starts_with?(Atom.to_string(mod), @web_prefix)
        end)

      _ ->
        []
    end
  end

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"

  defp core_files do
    Path.wildcard(Path.join(@core_dir, "**/*.ex")) |> Enum.sort()
  end

  # Strips `#` comment LINES and @moduledoc/@doc heredocs, then returns every
  # remaining line that still names BarkparkWeb, as {line, 1-based line number}.
  defp offending_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], false}, fn {line, n}, {acc, in_doc?} ->
      cond do
        in_doc? ->
          {acc, not String.contains?(line, ~s("""))}

        Regex.match?(~r/^\s*@(module)?doc\s+(~[A-Za-z])?"""/, line) ->
          {acc, true}

        Regex.match?(~r/^\s*#/, line) ->
          {acc, false}

        String.contains?(line, "BarkparkWeb") ->
          {[{line, n} | acc], false}

        true ->
          {acc, false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
