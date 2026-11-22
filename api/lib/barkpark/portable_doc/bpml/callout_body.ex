defmodule Barkpark.PortableDoc.Bpml.CalloutBody do
  @moduledoc """
  A callout's body in BPML (task-4c27c15194ae9369): what a push may do to it.

  A callout with a `slots` key prints in the structured form, and the Paper's
  `<paper>` carries the print mark (`Bpml.PrintMark`, this form's row is 2):

      <callout id="c1" tone="info">
        <content>inline</content>
        <slot name="body">
          <p id="c1-a">blocks</p>
        </slot>
      </callout>

  A copy pulled before this form existed shows the same callout inline, with
  no body. The mark is how a push tells the two apart, so a body is never lost
  to an old copy. `resolve/4` applies these rules before the diff:

    * **Old copy** (the view holds a form of `Bpml.PrintMark` newer than the
      copy's believed mark: a callout body here, a nested list item in
      `Bpml.ListItems`). Each top-level block holding such a form comes home
      as one top-level block with its id, and is kept as stored when it
      spells as the old printer spelled it (`PrintMark.before/2`); otherwise
      the push is refused with `bpml_stale_copy`, naming what the block
      holds, with the stored paths of what the copy lacks in `paths`.
    * **A form past the believed mark** (`PrintMark.believed/1`: a push
      without its pull's fingerprint). A block holding one is kept as stored
      when it spells as this pull printed it or as the print before the form;
      any other is left to `Bpml.WriteWall`, which reads the push against the
      print before the form, so the block comes home byte-equal under its id
      or the push is refused.
    * **The inline form never deletes a body**, in a marked copy too. An
      inline callout whose stored callout has `slots` keeps the stored body
      when its text is unchanged, and the answer says so in one note;
      otherwise `bpml_inline_body`. A body is deleted only in the structured
      form: the slot left out stores no body, `<content>` left out stores no
      content.
    * **`<kept>`.** A top-level block holding a block BPML cannot write (a
      callout here, a list item in `Bpml.ListItems`) prints as
      `<kept id type why/>` (`Bpml.Unwritable`). It resolves
      to the stored block only at top level, when its id and type match a
      block the pull printed as `<kept>` and that id appears once. Anything
      else, including a `<kept>` removed, replaced or moved inside another
      block, is refused with `bpml_kept`. Nothing is ever stored as `<kept>`.

  The parser marks an inline callout with `"$form" => "inline"` and reads
  `<kept>` as a `"$kept"` block. `clean/1` strips the first and refuses the
  second, so only the push path (`Bpml.parse_copy/1`) ever sees them.
  """

  alias Barkpark.PortableDoc.Bpml.{Canonical, PrintMark, Printer}

  @form "$form"
  @kept "$kept"

  @doc "True when `blocks` hold a callout with a `slots` key at any depth."
  @spec marked?(term()) :: boolean()
  def marked?(%{"type" => "callout"} = b) when is_map_key(b, "slots"), do: true
  def marked?(%{} = map), do: Enum.any?(Map.values(map), &marked?/1)
  def marked?(list) when is_list(list), do: Enum.any?(list, &marked?/1)
  def marked?(_other), do: false

  @doc "The block as the printer before the structured form saw it: no callout `slots`."
  @spec strip_slots(term()) :: term()
  def strip_slots(%{"type" => "callout"} = b),
    do: b |> Map.delete("slots") |> Map.new(fn {k, v} -> {k, strip_slots(v)} end)

  def strip_slots(%{} = map), do: Map.new(map, fn {k, v} -> {k, strip_slots(v)} end)
  def strip_slots(list) when is_list(list), do: Enum.map(list, &strip_slots/1)
  def strip_slots(other), do: other

  # ── the print mark's row (`Bpml.PrintMark`) ─────────────────────────────────

  @doc false
  def before_print(value), do: strip_slots(value)

  @doc false
  def stale_words(v), do: "#{callout_names(v)} #{has_have(v)} a body"

  @doc false
  # The path of every callout's `slots` key; a callout inside a body is under
  # its outer `.slots` path already.
  def stale_paths(block, path), do: slot_paths(block, path)

  @doc """
  Parsed blocks as every caller but the push sees them: the inline marks
  stripped, and `{:error, errors}` when the text holds a `<kept>`.
  """
  @spec clean([map()]) :: {:ok, [map()]} | {:error, [map()]}
  def clean(blocks) do
    case find_kept(blocks) do
      nil ->
        {:ok, strip_forms(blocks)}

      kept ->
        {:error,
         [
           %{
             code: "kept",
             message: "<kept id=\"#{kept["id"]}\"> stands for a block this text cannot show",
             line: 1,
             hint: "push it unchanged to the Paper it was pulled from; edit that block in Studio"
           }
         ]}
    end
  end

  @doc false
  def strip_forms(%{} = map),
    do: map |> Map.delete(@form) |> Map.new(fn {k, v} -> {k, strip_forms(v)} end)

  def strip_forms(list) when is_list(list), do: Enum.map(list, &strip_forms/1)
  def strip_forms(other), do: other

  @doc """
  The pushed blocks with the rules above applied: `{:ok, blocks, notes}`, or
  `{:refused, body}` writing nothing. `stored` is the row's blocks, `view` the
  blocks the pull printed, `pulled` that print read back (`parse_copy/1`, ids
  ensured) and `copy` the pushed paper as `parse_copy/1` read it.
  """
  @spec resolve([map()], [map()], [map()], map()) ::
          {:ok, [map()], [String.t()]} | {:refused, map()}
  def resolve(stored, view, pulled, copy) do
    pushed = Map.get(copy, "blocks") || []

    with :ok <- no_nested_kept(pushed),
         n = PrintMark.read_number(copy),
         {:ok, pushed, done} <-
           resolve_kept(pushed, pulled, stored, {n, PrintMark.believed(copy)}),
         {:ok, pushed, notes} <- old_copy(pushed, done, view, stored, copy),
         {:ok, pushed, more} <- inline_form(pushed, done, view, stored) do
      {:ok, strip_forms(pushed), notes ++ more}
    end
  end

  # ── <kept> ──────────────────────────────────────────────────────────────────

  defp no_nested_kept(pushed) do
    Enum.find_value(pushed, :ok, fn block ->
      case find_kept(Map.delete(block, "type")) do
        nil ->
          false

        kept ->
          refuse(
            "bpml_kept",
            "<kept id=\"#{kept["id"]}\"> was found inside #{name(block)}; " <>
              "a <kept> line stands for a whole top-level block",
            "put the <kept> line back at the top level, as the pull printed it"
          )
      end
    end)
  end

  defp resolve_kept(pushed, pulled, stored, read) do
    stored_by_id = by_id(stored)
    printed = for %{"type" => @kept, "id" => id, "of" => of} <- pulled, into: %{}, do: {id, of}
    counts = Enum.frequencies_by(pushed, & &1["id"])

    resolved =
      Enum.reduce_while(pushed, {:ok, []}, fn
        %{"type" => @kept, "id" => id} = k, {:ok, acc} ->
          if Map.get(printed, id) == k["of"] and counts[id] == 1 and
               Map.has_key?(stored_by_id, id),
             do: {:cont, {:ok, [stored_by_id[id] | acc]}},
             else: {:halt, kept_changed(k)}

        block, {:ok, acc} ->
          {:cont, {:ok, [block | acc]}}
      end)

    with {:ok, rev} <- resolved,
         :ok <- every_kept_back(printed, pushed, stored, read) do
      {:ok, Enum.reverse(rev), MapSet.new(Map.keys(printed))}
    end
  end

  # A copy older than a form the kept block holds was pulled before that
  # block printed as <kept>, so it never had the line: it is stale, not an
  # edit of the line.
  defp every_kept_back(printed, pushed, stored, {n, believed}) do
    kept_ids = for %{"type" => @kept, "id" => id} <- pushed, into: MapSet.new(), do: id
    stored_by_id = by_id(stored)

    Enum.find_value(printed, :ok, fn {id, of} ->
      {forms, _unproven} = split(PrintMark.newer(stored_by_id[id], n), believed)

      cond do
        MapSet.member?(kept_ids, id) ->
          false

        forms != [] ->
          PrintMark.stale(stored_by_id[id], stored, id, forms, &canonical/1)

        true ->
          refuse(
            "bpml_kept",
            "#{of} #{id} was pulled as <kept> and your copy removed or replaced it",
            "BPML cannot change this block: keep its <kept> line as pulled and edit it in Studio"
          )
      end
    end)
  end

  defp kept_changed(k),
    do:
      refuse(
        "bpml_kept",
        "<kept id=\"#{k["id"]}\" type=\"#{k["of"]}\"> does not match a block this Paper's " <>
          "pull printed as <kept>",
        "a <kept> line resolves only with the id and type the pull printed, once"
      )

  # ── old copy ────────────────────────────────────────────────────────────────

  # A top-level block holding a form newer than the copy's mark comes home as
  # one top-level block with its id, spelled as the print before the form, and
  # is kept as stored; any other answer is refused by name. A form newer than
  # the mark is believed for (`PrintMark.believed/1`) is read as unshown: a
  # block holding one that spells as this pull or as the print before the form
  # comes home as stored, and any other is left to the write wall, which reads
  # the push against the print before the form.
  defp old_copy(pushed, done, view, stored, copy) do
    n = PrintMark.read_number(copy)
    believed = PrintMark.believed(copy)

    if PrintMark.newer(view, n) != [] do
      view_by_id = by_id(view)
      stored_by_id = by_id(stored)

      case not_home(pushed, done, view, n, believed) do
        {v, forms} -> PrintMark.stale(v, stored, v["id"], forms, &canonical/1)
        nil -> each_old(pushed, done, {view_by_id, stored_by_id, stored}, {n, believed})
      end
    else
      {:ok, pushed, []}
    end
  end

  # The first view block holding a believed form newer than `n` whose id is
  # not among the pushed top-level blocks, with those forms.
  defp not_home(pushed, done, view, n, believed) do
    ids = MapSet.new(pushed, & &1["id"])

    Enum.find_value(view, fn v ->
      id = v["id"]
      {forms, _} = split(PrintMark.newer(v, n), believed)

      if id != nil and forms != [] and not MapSet.member?(done, id) and
           not MapSet.member?(ids, id),
         do: {v, forms}
    end)
  end

  defp each_old(pushed, done, {view_by_id, stored_by_id, stored}, {n, believed}) do
    Enum.reduce_while(pushed, {:ok, [], []}, fn block, {:ok, acc, notes} ->
      id = block["id"]
      v = Map.get(view_by_id, id)
      {forms, unproven} = if v == nil, do: {[], []}, else: split(PrintMark.newer(v, n), believed)

      cond do
        MapSet.member?(done, id) or (forms == [] and unproven == []) ->
          {:cont, {:ok, [block | acc], notes}}

        forms != [] and spells_as?(block, PrintMark.before(v, n)) ->
          {:cont, {:ok, [stored_by_id[id] | acc], notes ++ kept_notes(v)}}

        forms != [] ->
          {:halt, PrintMark.stale(v, stored, id, forms, &canonical/1)}

        spells_as?(block, v) or spells_as?(block, PrintMark.before(v, believed)) ->
          {:cont, {:ok, [stored_by_id[id] | acc], notes}}

        true ->
          {:cont, {:ok, [block | acc], notes}}
      end
    end)
    |> reversed()
  end

  # The forms the mark is believed for, and the newer ones.
  defp split(forms, believed),
    do: Enum.split_with(forms, fn {since, _mod} -> since <= believed end)

  # `paths` names each outermost body in the stored block's canonical
  # spelling, in the write wall's shape.
  defp slot_paths(%{"type" => "callout"} = c, path) when is_map_key(c, "slots"),
    do: ["#{path}.slots" | slot_paths(Map.delete(c, "slots"), path)]

  defp slot_paths(%{} = map, path),
    do: map |> Enum.sort() |> Enum.flat_map(fn {k, v} -> slot_paths(v, "#{path}.#{k}") end)

  defp slot_paths(list, path) when is_list(list),
    do:
      list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> slot_paths(v, "#{path}[#{i}]") end)

  defp slot_paths(_other, _path), do: []

  defp canonical(block), do: block |> List.wrap() |> Canonical.normalize() |> hd()

  # ── the inline form ─────────────────────────────────────────────────────────

  defp inline_form(pushed, done, view, stored) do
    shown = callouts_with_slots(view)
    kept = callouts_with_slots(stored)

    Enum.reduce_while(pushed, {:ok, [], []}, fn block, {:ok, acc, notes} ->
      if MapSet.member?(done, block["id"]) do
        {:cont, {:ok, [block | acc], notes}}
      else
        case inline_walk(block, shown, kept, []) do
          {:ok, block, more} -> {:cont, {:ok, [block | acc], notes ++ more}}
          refused -> {:halt, refused}
        end
      end
    end)
    |> reversed()
  end

  defp inline_walk(%{"type" => "callout", @form => "inline"} = c, shown, kept, notes)
       when not is_map_key(c, "slots") do
    case Map.fetch(shown, c["id"]) do
      {:ok, v} ->
        if spells_as?(content_only(c), content_only(v)) do
          s = Map.get(kept, c["id"], v)

          # The stored callout's own content: no content key stays no key.
          block =
            c
            |> Map.delete("content")
            |> Map.merge(Map.take(s, ["content"]))
            |> Map.put("slots", s["slots"])

          {:ok, block, notes ++ [kept_note(c["id"])]}
        else
          refuse(
            "bpml_inline_body",
            "callout #{c["id"]} has a body, and the inline form cannot change it",
            "write it as <callout><content>…</content><slot name=\"body\">…</slot></callout>; " <>
              "leave the slot out to delete the body"
          )
        end

      :error ->
        {:ok, c, notes}
    end
  end

  defp inline_walk(%{} = map, shown, kept, notes) do
    Enum.reduce_while(map, {:ok, %{}, notes}, fn {k, v}, {:ok, acc, notes} ->
      case inline_walk(v, shown, kept, notes) do
        {:ok, v, notes} -> {:cont, {:ok, Map.put(acc, k, v), notes}}
        refused -> {:halt, refused}
      end
    end)
  end

  defp inline_walk(list, shown, kept, notes) when is_list(list) do
    Enum.reduce_while(list, {:ok, [], notes}, fn v, {:ok, acc, notes} ->
      case inline_walk(v, shown, kept, notes) do
        {:ok, v, notes} -> {:cont, {:ok, [v | acc], notes}}
        refused -> {:halt, refused}
      end
    end)
    |> case do
      {:ok, rev, notes} -> {:ok, Enum.reverse(rev), notes}
      refused -> refused
    end
  end

  defp inline_walk(other, _shown, _kept, notes), do: {:ok, other, notes}

  defp content_only(c), do: %{"type" => "callout", "content" => Map.get(c, "content") || []}

  # ── notes and helpers ───────────────────────────────────────────────────────

  defp kept_notes(v),
    do: v |> callouts_with_slots() |> Map.keys() |> Enum.sort() |> Enum.map(&kept_note/1)

  defp kept_note(id),
    do:
      "callout #{id} kept its stored body: the inline form never changes a body; " <>
        "to delete it, take <slot name=\"body\"> out of the structured form"

  defp callouts_with_slots(value), do: callouts_with_slots(value, %{})

  defp callouts_with_slots(%{"type" => "callout"} = c, acc) when is_map_key(c, "slots"),
    do: Enum.reduce(Map.values(c), Map.put(acc, c["id"], c), &callouts_with_slots/2)

  defp callouts_with_slots(%{} = map, acc),
    do: Enum.reduce(Map.values(map), acc, &callouts_with_slots/2)

  defp callouts_with_slots(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &callouts_with_slots/2)

  defp callouts_with_slots(_other, acc), do: acc

  defp callout_names(v) do
    ids = v |> callouts_with_slots() |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    Enum.map_join(ids, ", ", &"callout #{&1}")
  end

  defp has_have(v), do: if(map_size(callouts_with_slots(v)) == 1, do: "has", else: "have")

  defp find_kept(%{"type" => @kept} = k), do: k
  defp find_kept(%{} = map), do: Enum.find_value(Map.values(map), &find_kept/1)
  defp find_kept(list) when is_list(list), do: Enum.find_value(list, &find_kept/1)
  defp find_kept(_other), do: nil

  defp spells_as?(a, b) do
    Printer.print_blocks([a]) == Printer.print_blocks([b])
  rescue
    _ -> false
  end

  defp by_id(blocks), do: for(%{"id" => id} = b <- blocks, into: %{}, do: {id, b})
  defp name(%{"type" => type, "id" => id}), do: "#{type} #{id}"
  defp name(%{"type" => type}), do: type

  defp reversed({:ok, rev, notes}), do: {:ok, Enum.reverse(rev), notes}
  defp reversed(refused), do: refused

  defp refuse(code, message, hint), do: {:refused, %{code: code, message: message, hint: hint}}
end
