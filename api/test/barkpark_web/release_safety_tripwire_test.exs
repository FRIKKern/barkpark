defmodule BarkparkWeb.ReleaseSafetyTripwireTest do
  @moduledoc """
  Turns every module compiled from `lib/` into one assertion: none of them may
  make a RUNTIME call into `Mix`.

  Why this exists (gh-8461). `LiveAuth.dev_browser_token_fallback/0` read
  `Mix.env() == :dev` inside a function body. `mix release` does not ship Mix —
  it is a build-time tool — so in the Docker image (`api/Dockerfile` →
  `mix release` → bare alpine → `bin/barkpark start`) that line raised:

      ** (UndefinedFunctionError) function Mix.env/0 is undefined
         (module Mix is not available)
          lib/barkpark_web/live_auth.ex:163: LiveAuth.dev_browser_token_fallback/0
          lib/barkpark_web/live_auth.ex:174: LiveAuth.authorize/4

  `authorize/4` calls it unconditionally, so EVERY `:admin`/`:ops` Studio mount
  500'd — the settings panes rendered and then went click-dead. It survived
  because neither environment anyone runs by hand is a release: local dev is
  `mix phx.server`, and so is the Hetzner systemd prod box (`api/start.sh`).
  Only the container path is a release, and only the container path broke.

  ## Why the IMPORT TABLE is the right instrument

  A grep for `Mix.` cannot tell a runtime call from a compile-time one, and the
  compile-time one is CORRECT and used deliberately in this tree
  (`Icons.@unknown_icon_policy`, `MetaController.@production`). A module
  attribute is evaluated by the compiler, so the BEAM holds the resulting
  literal and nothing about Mix survives into the artifact.

  So this test reads the BEAM's own import table (the `ImpT` chunk), which
  lists every remote `{module, function, arity}` the compiled code can call.
  A compile-time `Mix.env()` leaves NO entry. A runtime one leaves
  `{Mix, :env, 0}`. The instrument draws exactly the line that matters, on the
  exact artifact a release ships, with no maintenance as the tree grows.

  ## WHAT THIS TEST CANNOT SEE — read before trusting it as coverage

    1. **Dynamic dispatch is invisible.** `apply(Mix, :env, [])` and
       `Module.concat(["Mix"]).env()` resolve the module at runtime, so they
       leave no ImpT entry. This test would stay green while the release still
       crashed. Nothing in the tree does this today; if a future one does, this
       test is not the thing that catches it.
    2. **It does not boot a release.** It proves the absence of a Mix call in
       the compiled code, NOT that `bin/barkpark start` succeeds. A separate
       release smoke test is the thing that would prove that; gh-8461 asks for
       one and it does not exist yet.
    3. **Modules are compiled here under `MIX_ENV=test`.** A compile-time
       branch that emits a Mix call in `:prod` but not in `:test` would slip
       through. That shape does not occur in the tree — and it is self-defeating
       anyway, since the whole point of a compile-time read is to leave no call
       behind.
    4. **It covers this app only.** A dependency calling Mix at runtime is out
       of scope.
  """
  use ExUnit.Case, async: true

  # The ONE legitimate runtime Mix reference in `lib/`. `default_paths/0` adds
  # `Mix.Project.deps_path()` so a DEV/TEST checkout discovers plugins that live
  # in `deps/`, and it is fenced behind
  # `Code.ensure_loaded?(Mix.Project) and function_exported?(Mix.Project, :deps_path, 0)`
  # plus a `rescue` — the guarded idiom that is safe precisely BECAUSE Mix is
  # absent in a release, where it correctly degrades to the bundled path only.
  # Its moduledoc states this. Any NEW entry here needs the same fencing and the
  # same justification written down.
  @guarded_runtime_mix_callers %{
    Barkpark.Plugins.Registry.Discovery =>
      "fenced by Code.ensure_loaded?/1 + function_exported?/3 + rescue; degrades to the bundled plugin path in a release"
  }

  test "no module compiled from lib/ makes a runtime call into Mix" do
    offenders =
      lib_modules()
      |> Enum.map(fn {mod, beam} -> {mod, mix_imports(beam)} end)
      |> Enum.reject(fn {_mod, imports} -> imports == [] end)
      |> Enum.reject(fn {mod, _imports} -> Map.has_key?(@guarded_runtime_mix_callers, mod) end)

    assert offenders == [], """
    #{length(offenders)} module(s) compiled from lib/ call Mix at RUNTIME.
    Mix is not shipped in an OTP release (`mix release` → `bin/barkpark start`),
    so each of these raises UndefinedFunctionError in the Docker image:

    #{Enum.map_join(offenders, "\n", fn {mod, imports} -> "  #{inspect(mod)} → #{Enum.map_join(imports, ", ", &format_mfa/1)}" end)}

    Fix it one of three ways, in order of preference:

      1. Read the value from config instead. A key set only in `config/dev.exs`
         is absent everywhere else on its own — no env check needed. This is
         what `LiveAuth.dev_browser_token_fallback/0` and
         `Plugs.OptionalSessionToken.token_from_dev_config/0` both do.
      2. Hoist it to COMPILE time as a module attribute
         (`@production Mix.env() == :prod`). The compiler folds it to a literal
         and no Mix call survives into the BEAM. See `Icons` / `MetaController`.
      3. Fence it behind `Code.ensure_loaded?/1` + `function_exported?/3` and
         add it to @guarded_runtime_mix_callers with a written justification —
         only when the feature genuinely must degrade rather than be decided.
    """
  end

  # Every module in the :barkpark app whose compiled source is under `lib/`.
  # `elixirc_paths(:test)` also compiles `test/support`, which a release never
  # ships — the compile_info source path is what separates them.
  defp lib_modules do
    Application.spec(:barkpark, :modules)
    |> Enum.reject(&mix_task?/1)
    |> Enum.flat_map(fn mod ->
      case :code.which(mod) do
        beam when is_list(beam) -> if from_lib?(beam), do: [{mod, beam}], else: []
        _other -> []
      end
    end)
  end

  # `lib/mix/tasks/**` compiles into the release like everything else under
  # `lib/`, but a `Mix.Task` can only ever be entered through `mix <task>`,
  # which cannot happen in a release — nothing there is runtime-reachable. Their
  # Mix calls are the point of them.
  defp mix_task?(mod), do: String.starts_with?(Atom.to_string(mod), "Elixir.Mix.Tasks.")

  defp from_lib?(beam) do
    case :beam_lib.chunks(beam, [:compile_info]) do
      {:ok, {_mod, [compile_info: info]}} ->
        case Keyword.get(info, :source) do
          src when is_list(src) -> String.contains?(List.to_string(src), "/api/lib/")
          _ -> false
        end

      _ ->
        false
    end
  end

  defp mix_imports(beam) do
    case :beam_lib.chunks(beam, [:imports]) do
      {:ok, {_mod, [imports: imports]}} -> Enum.filter(imports, &mix_mfa?/1)
      _ -> []
    end
  end

  defp mix_mfa?({mod, _f, _a}) do
    mod == Mix or String.starts_with?(Atom.to_string(mod), "Elixir.Mix.")
  end

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
end
