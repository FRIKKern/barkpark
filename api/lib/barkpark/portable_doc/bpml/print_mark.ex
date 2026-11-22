defmodule Barkpark.PortableDoc.Bpml.PrintMark do
  @moduledoc """
  The print mark: which forms a BPML copy was printed able to show.

  Each row of `@forms` is a form the printer began to show at one print
  number. A pull of a Paper holding any of them carries `<paper print="N">`,
  N the highest number among the forms it holds; no `print` reads as 1.

  A push reads the mark as far as it is believed (`believed/1`). A push that
  brings back the fingerprint its pull served (`bpmlView`, checked first by
  `Bpml.WriteWall.same_view/2`) comes from the current view, so its mark is
  believed in full. A push without one is believed up to print 2.

  For a form newer than a believed mark (`Bpml.CalloutBody.resolve/4`), what
  the push would lose decides it. Each block holding content of the form
  (`homes/2`) comes home once under its own id, at any depth and whatever
  happened to the blocks around it, spelled as the printer before the form
  spelled it, and is kept as stored there. Any other push is refused with
  `bpml_stale_copy`, naming the block, with the stored paths of what the copy
  lacks, writing nothing. A form that holds nothing has nothing to keep.

  For a form newer than the mark is believed for, `Bpml.WriteWall` reads the
  push against the print before that form: a block holding the form comes
  home byte-equal under its id, or the push is refused (`bpml_unshown`) with
  a hint to update bp.

  A form is one row: its print number and the module that answers for it
  (`marked?/1`: the form is in a value at any depth; `before_print/1`: the
  value as the printer before the form spelled it; `homes/1`: the blocks in a
  value holding content of the form; `stale_words/1`: what the refusal says
  a block holds; `stale_paths/2`: the stored paths of the form in a block).
  """

  alias Barkpark.PortableDoc.Bpml.{CalloutBody, ListItems}

  @forms [
    # A callout's body, printed in the structured form (task-4c27c15194ae9369).
    {2, CalloutBody},
    # A list item's child lists and its id (task-0b448ea0847a6b4f).
    {3, ListItems}
  ]

  @doc "The rows: `[{print number, module}]`, oldest first."
  @spec forms() :: [{pos_integer(), module()}]
  def forms, do: @forms

  @doc "The `<paper>` attribute for `blocks`: `print=\"N\"`, or nothing when they hold no form."
  @spec attr([map()]) :: String.t()
  def attr(blocks) do
    case number(blocks) do
      1 -> ""
      n -> ~s( print="#{n}")
    end
  end

  @doc "The highest print number among the forms `value` holds; 1 when it holds none."
  @spec number(term()) :: pos_integer()
  def number(value) do
    Enum.reduce(@forms, 1, fn {n, mod}, acc ->
      if mod.marked?(value), do: max(n, acc), else: acc
    end)
  end

  @doc "The print number a pushed copy (`Bpml.parse_copy/1`) carries; 1 without one."
  @spec copy_number(map()) :: pos_integer()
  def copy_number(copy) do
    case Integer.parse(to_string(Map.get(copy, "print") || "")) do
      {n, ""} when n > 1 -> n
      _ -> 1
    end
  end

  # The newest print number a mark is believed for without a fingerprint.
  @unproven 2

  @doc """
  The newest print number `copy`'s mark is believed for: every one when the
  push brings its pull's fingerprint, else 2.
  """
  @spec believed(map()) :: pos_integer()
  def believed(copy) do
    case Map.get(copy, "bpmlView") do
      view when is_binary(view) and view != "" -> @forms |> Enum.map(&elem(&1, 0)) |> Enum.max()
      _ -> @unproven
    end
  end

  @doc "The print number a push reads `copy` at: its mark, no newer than `believed/1`."
  @spec read_number(map()) :: pos_integer()
  def read_number(copy), do: min(copy_number(copy), believed(copy))

  @doc "The forms in `value` newer than print number `n`: `[{print number, module}]`."
  @spec newer(term(), pos_integer()) :: [{pos_integer(), module()}]
  def newer(value, n),
    do: Enum.filter(@forms, fn {since, mod} -> since > n and mod.marked?(value) end)

  @doc "`value` as a printer at print number `n` spelled it: every newer form taken out."
  @spec before(term(), pos_integer()) :: term()
  def before(value, n) do
    @forms
    |> Enum.filter(fn {since, _mod} -> since > n end)
    |> Enum.reduce(value, fn {_since, mod}, acc -> mod.before_print(acc) end)
  end

  @doc """
  What a copy read at print number `n` must bring home from the view's
  top-level block `v`, for its `forms` (from `newer/2`): `[{home, forms}]`.
  Each home is a block holding content of a form (each form's `homes/1`):
  `v` itself for a nested list, each outermost callout whose body holds
  something for a callout body. A form that holds nothing gives no home.
  """
  @spec homes(map(), [{pos_integer(), module()}]) :: [{map(), [{pos_integer(), module()}]}]
  def homes(v, forms) do
    pairs =
      for {_n, mod} = form <- forms, home <- mod.homes(v), is_binary(home["id"]), do: {home, form}

    if Enum.any?(pairs, fn {home, _form} -> home["id"] == v["id"] end),
      do: [{v, pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}],
      else:
        pairs
        |> Enum.uniq_by(&elem(&1, 0)["id"])
        |> Enum.map(fn {home, form} -> {home, [form]} end)
  end

  @doc """
  The refusal for an old copy that did not bring `home` (from `homes/2`)
  home: its words name what the block holds, and `paths` are the stored
  paths of each form in it, at any depth, in the stored block's canonical
  spelling.
  """
  @spec stale(map(), [map()], [{pos_integer(), module()}], (map() -> map())) :: {:refused, map()}
  def stale(home, stored, forms, canonical) do
    id = home["id"]
    i = Enum.find_index(stored, &(locate(&1, id, "") != nil))
    located = if i, do: locate(canonical.(Enum.at(stored, i)), id, "blocks[#{i}]")

    {:refused,
     %{
       code: "bpml_stale_copy",
       message:
         Enum.map_join(forms, "; ", fn {_n, mod} ->
           mod.stale_words(home) <> " your copy was pulled without"
         end) <> "; nothing was written",
       hint: "bp paper pull, then make your edit again",
       paths:
         case located do
           {block, path} -> Enum.flat_map(forms, fn {_n, mod} -> mod.stale_paths(block, path) end)
           nil -> []
         end
     }}
  end

  # The block with `id` in `term` and its path, the outermost first.
  defp locate(%{"id" => id} = block, id, path), do: {block, path}

  defp locate(%{} = map, id, path),
    do: map |> Enum.sort() |> Enum.find_value(fn {k, v} -> locate(v, id, "#{path}.#{k}") end)

  defp locate(list, id, path) when is_list(list),
    do:
      list
      |> Enum.with_index()
      |> Enum.find_value(fn {v, j} -> locate(v, id, "#{path}[#{j}]") end)

  defp locate(_other, _id, _path), do: nil
end
