defmodule Barkpark.OnExitRefScan do
  @moduledoc """
  Static scanner for `ExUnit.Callbacks.on_exit/2` REF COLLISIONS in `api/test`.

  ## The defect

  `on_exit/2`'s first argument is a KEY, not a label. Registering a second
  callback under a ref that is already registered SILENTLY REPLACES the first —
  no error, no warning, no red. The replaced cleanup simply never runs, and the
  suite stays green while the fixture leaks.

  The shape that produces it is mundane: two helpers that each take the test
  context and hand it straight to `on_exit/2`.

      setup ctx do
        prior = Application.get_env(:barkpark, :shares)
        Application.delete_env(:barkpark, :shares)
        ExUnit.Callbacks.on_exit(ctx, fn -> restore(prior) end)   # (1)
      end

      test "…", ctx do
        with_shares("gyldendal:papers:read", ctx)                 # registers on_exit(ctx, …) — REPLACES (1)
      end

  ExUnit hands `setup` and the test body the SAME context map when the setup
  returns `:ok`, so the two refs compare equal and (1) is unregistered. The
  measured consequence on `Barkpark.SharingTest` was that the baseline
  `:barkpark, :shares` value the `describe "active?/0"` setup snapshotted was
  never put back — the module ended its run having DELETED an app env value
  another module had configured.

  ## The rule this module enforces (a predicate, not a list)

  > Every `on_exit/2` ref must be MODULE-SCOPED: a tuple whose first element is
  > `__MODULE__` or a module alias.

  A module-scoped ref cannot collide with a helper in another module, and two
  helpers inside one module collide only if they deliberately pick the same
  discriminator. A BARE ref (`ctx`, `context`, `conn`, a plain variable, an
  atom) is one key shared by every helper reachable in the test process, so any
  two of them collide.

  The rule is deliberately stronger than "two registrations exist today":
  whether a bare-ref site collides depends on which OTHER helper some future
  test happens to call, which is not a property the site can be read for. The
  1-site tree and the 2-site tree differ by one line nobody reviews.

  ## The single exemption, and why it is a rule too

  `api/test/barkpark/plugins/plugin_env_test.exs` pins the collision: it
  REGISTERS a bare-`ctx` sibling on purpose and asserts the earlier restore
  survives. Rewriting that site to a module-scoped ref would delete the
  regression test. A site may therefore opt out with an explicit marker on the
  preceding line:

      # on-exit-ref-gate: allow-bare-ref — <reason>

  The marker is a PREDICATE (any site may carry it, and it must state a reason),
  not an enumeration of paths that goes stale the moment a file is renamed.
  """

  @marker ~r/^\s*#.*on-exit-ref-gate:\s*allow-bare-ref\b/

  defmodule Site do
    @moduledoc false
    defstruct [:file, :line, :ref_source, :module_scoped?, :exempt?]
  end

  @doc "Every `*.ex`/`*.exs` file under the given roots, sorted."
  def files(roots) do
    roots
    |> List.wrap()
    |> Enum.flat_map(fn root ->
      Path.wildcard(Path.join(root, "**/*.ex")) ++ Path.wildcard(Path.join(root, "**/*.exs"))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Scan the given roots. Returns `{files_scanned, [%Site{}]}`."
  def scan(roots) do
    fs = files(roots)
    {length(fs), Enum.flat_map(fs, fn f -> scan_source(f, File.read!(f)) end)}
  end

  @doc """
  Scan one source string. Exposed so the gate's own arms can run on FIXTURES —
  a scanner proven only against the tree it already passes measures nothing.
  """
  def scan_source(path, source) do
    lines = String.split(source, "\n")

    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        {_, acc} = Macro.prewalk(ast, [], &collect(&1, &2, path, lines))
        Enum.reverse(acc)

      {:error, reason} ->
        raise "on-exit-ref scan could not parse #{path}: #{inspect(reason)}"
    end
  end

  # Bare `on_exit(ref, fun)` — the imported form.
  defp collect({:on_exit, meta, [ref, _fun]} = node, acc, path, lines) do
    {node, [site(path, meta, ref, lines) | acc]}
  end

  # Qualified `ExUnit.Callbacks.on_exit(ref, fun)` (or an alias of it).
  defp collect(
         {{:., _, [{:__aliases__, _, mods}, :on_exit]}, meta, [ref, _fun]} = node,
         acc,
         path,
         lines
       ) do
    if List.last(mods) in [:Callbacks, :ExUnit] do
      {node, [site(path, meta, ref, lines) | acc]}
    else
      {node, acc}
    end
  end

  defp collect(node, acc, _path, _lines), do: {node, acc}

  defp site(path, meta, ref, lines) do
    line = meta[:line]

    %Site{
      file: path,
      line: line,
      ref_source: Macro.to_string(ref),
      module_scoped?: module_scoped?(ref),
      exempt?: exempt?(lines, line)
    }
  end

  @doc """
  A ref is module-scoped when it is a tuple whose FIRST element is `__MODULE__`
  or a module alias. `{__MODULE__, ctx}`, `{__MODULE__, :baseline, ctx}` and
  `{Barkpark.PluginEnv, ctx}` qualify; `ctx`, `context`, `conn`, `:restore` and
  `{ctx, :restore}` do not.
  """
  # 2-tuples are their own AST literal, longer tuples arrive as {:{}, _, elems}.
  def module_scoped?({first, _second}), do: module_head?(first)
  def module_scoped?({:{}, _, [first | _]}), do: module_head?(first)
  def module_scoped?(_), do: false

  defp module_head?({:__MODULE__, _, _}), do: true
  defp module_head?({:__aliases__, _, _}), do: true
  defp module_head?(_), do: false

  # The marker may sit anywhere in the CONTIGUOUS COMMENT BLOCK immediately
  # above the call. Requiring it on the single nearest non-blank line was a real
  # defect: a two-line marker comment (the reason does not fit on one line) put
  # the marker on the FIRST of the two and the scanner read only the second, so
  # a correctly-marked site still reported as a violation. Blank lines above the
  # call are skipped; the first non-comment line ends the block.
  defp exempt?(lines, line) when is_integer(line) do
    lines
    |> Enum.take(line - 1)
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.take_while(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.any?(&Regex.match?(@marker, &1))
  end

  defp exempt?(_lines, _line), do: false

  @doc "Sites that break the rule: a non-module-scoped ref with no marker."
  def violations(sites), do: Enum.filter(sites, &(not &1.module_scoped? and not &1.exempt?))

  @doc "One line per site, the form the gate's failure message quotes."
  def format(%Site{} = s), do: "#{s.file}:#{s.line}  on_exit(#{s.ref_source}, …)"
end
