defmodule Barkpark.Plugins.ReleasePrivPathTest do
  @moduledoc """
  Release-safety invariant for plugin `priv` reads.

  A module attribute assigned from `Path.expand(..., __DIR__)` freezes the
  BUILD machine's absolute path into the `.beam`. That is fine for a value
  consumed at COMPILE time (`@external_resource`, or a `File.read!/1` in the
  module body, which bakes the CONTENT). It is a latent production bug the
  moment such an attribute is read from inside a function: in an OTP release
  `priv` lives at `lib/barkpark-<vsn>/priv`, the build tree is gone, and the
  read raises `File.Error` enoent.

  That is exactly how six plugins silently failed to register their document
  types on every released build (docker image / compose install) while working
  perfectly from the source tree — and why no dev-tree test caught it.

  The correct idiom, already used by the plugin loader itself
  (`registry/discovery.ex` `default_paths/0`) and by
  `onixedit/export/validator.ex` `default_xsd_path/0`, is to resolve at
  RUNTIME via `Application.app_dir(:barkpark, "priv/...")`, which is right
  under both the release and the source-tree deploy model.
  """
  use ExUnit.Case, async: true

  @plugins_root Path.expand("../../../lib/barkpark/plugins", __DIR__)

  test "no plugin module reads a __DIR__-baked priv path at runtime" do
    offenders =
      @plugins_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&offenders_in_file/1)

    assert offenders == [], """
    These plugin modules bake a build-time `priv` path into a module attribute
    and then READ it inside a function. That raises File.Error in an OTP
    release, where the build tree no longer exists:

    #{Enum.map_join(offenders, "\n", fn {file, attr} -> "  * #{Path.relative_to(file, @plugins_root)} — @#{attr}" end)}

    Resolve it at runtime instead:

        @some_subpath "priv/plugins/<name>/schemas"
        defp some_dir, do: Application.app_dir(:barkpark, @some_subpath)

    Keeping a separate `@external_resource Path.expand(..., __DIR__)` for
    recompilation tracking is fine — it is never read at runtime.
    """
  end

  # {file, attr_name} for every attribute that holds a __DIR__-derived priv
  # path AND is referenced from inside a def/defp body.
  defp offenders_in_file(file) do
    ast = file |> File.read!() |> Code.string_to_quoted!()

    baked = baked_priv_attrs(ast)
    read_at_runtime = attrs_read_in_functions(ast)

    baked
    |> MapSet.intersection(read_at_runtime)
    |> Enum.sort()
    |> Enum.map(&{file, &1})
  end

  defp baked_priv_attrs(ast) do
    {_, attrs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, [{name, _, [rhs]}]} = node, acc when is_atom(name) ->
          if dir_relative_priv_path?(rhs), do: {node, MapSet.put(acc, name)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    attrs
  end

  # True when the expression mentions __DIR__ and a string literal containing
  # "priv" — i.e. a path resolved against this source file's location.
  defp dir_relative_priv_path?(rhs) do
    {_, dir?} =
      Macro.prewalk(rhs, false, fn
        {:__DIR__, _, _} = n, _ -> {n, true}
        n, acc -> {n, acc}
      end)

    {_, priv?} =
      Macro.prewalk(rhs, false, fn
        s, acc when is_binary(s) -> {s, acc or String.contains?(s, "priv")}
        n, acc -> {n, acc}
      end)

    dir? and priv?
  end

  defp attrs_read_in_functions(ast) do
    {_, attrs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {def_kind, _, [_head, body]} = node, acc when def_kind in [:def, :defp] ->
          {node, MapSet.union(acc, attr_reads(body))}

        node, acc ->
          {node, acc}
      end)

    attrs
  end

  defp attr_reads(body) do
    {_, acc} =
      Macro.prewalk(body, MapSet.new(), fn
        {:@, _, [{name, _, ctx}]} = node, acc when is_atom(name) and not is_list(ctx) ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    acc
  end
end
