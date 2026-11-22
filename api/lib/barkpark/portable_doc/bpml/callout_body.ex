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
      `Bpml.ListItems`). What the push would lose decides it. Each block
      holding content of such a form (`PrintMark.homes/2`: a callout whose
      body holds something) comes home once under its own id, at any depth
      and whatever happened to the blocks around it, and is kept as stored
      there when it spells as the old printer spelled it
      (`PrintMark.before/2`); otherwise (missing, found twice, or spelled
      otherwise) the push is refused with `bpml_stale_copy`, naming the
      block, with the stored paths of what the copy lacks in `paths`. A body
      that holds nothing (`"body" => []`, or `slots` with no key) has nothing
      to keep and never causes this refusal.
    * **A form past the believed mark** (`PrintMark.believed/1`: a push
      without its pull's fingerprint). A block holding one is kept as stored
      when it spells as this pull printed it or as the print before the form;
      any other is left to `Bpml.WriteWall`, which reads the push against the
      print before the form, so the block comes home byte-equal under its id
      or the push is refused.
    * **The inline form never deletes a body**, in a marked copy too. An
      inline callout whose stored callout has `slots` keeps the stored body
      when its text is unchanged, and the answer says so in one note; when
      the body holds nothing, the words change and the slots stay; otherwise
      `bpml_inline_body`. A body is deleted only in the structured
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
  # The blocks in `value` an old copy must bring home: each outermost callout
  # whose body holds something.
  def homes(%{"type" => "callout", "slots" => slots} = c),
    do: if(holds?(slots), do: [c], else: homes(Map.delete(c, "slots")))

  def homes(%{} = map), do: map |> Enum.sort() |> Enum.flat_map(fn {_k, v} -> homes(v) end)
  def homes(list) when is_list(list), do: Enum.flat_map(list, &homes/1)
  def homes(_other), do: []

  # Each callout in `value` with a `slots` key that holds nothing, outside
  # the bodies of the others.
  defp empties(%{"type" => "callout", "slots" => slots} = c) do
    if holds?(slots), do: [], else: [c | empties(Map.delete(c, "slots"))]
  end

  defp empties(%{} = map), do: map |> Map.values() |> Enum.flat_map(&empties/1)
  defp empties(list) when is_list(list), do: Enum.flat_map(list, &empties/1)
  defp empties(_other), do: []

  defp holds?(%{} = slots), do: Enum.any?(Map.values(slots), &(&1 not in [nil, [], ""]))
  defp holds?(other), do: other not in [nil, [], ""]

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
         {:ok, pushed, notes} <- old_copy(pushed, done, {view, stored, pulled}, copy),
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
         {:ok, old} <- every_kept_back(printed, pushed, stored, read) do
      {:ok, Enum.reverse(rev), MapSet.new(Map.keys(printed) -- old)}
    end
  end

  # A copy older than a form the kept block holds was pulled before that
  # block printed as <kept>, so it never had the line: the block is read as
  # the old copy's (`old_copy/5`), not as an edit of the line.
  defp every_kept_back(printed, pushed, stored, {n, believed}) do
    kept_ids = for %{"type" => @kept, "id" => id} <- pushed, into: MapSet.new(), do: id
    stored_by_id = by_id(stored)

    Enum.reduce_while(printed, {:ok, []}, fn {id, of}, {:ok, old} ->
      {forms, _unproven} = split(PrintMark.newer(stored_by_id[id], n), believed)

      cond do
        MapSet.member?(kept_ids, id) ->
          {:cont, {:ok, old}}

        forms != [] ->
          {:cont, {:ok, [id | old]}}

        true ->
          {:halt,
           refuse(
             "bpml_kept",
             "#{of} #{id} was pulled as <kept> and your copy removed or replaced it",
             "BPML cannot change this block: keep its <kept> line as pulled and edit it in Studio"
           )}
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

  # What a push from a copy older than a believed form would lose decides it.
  # Each block holding content of that form (`PrintMark.homes/2`: a callout
  # whose body holds something, at any depth) comes home once under its own
  # id, wherever it stands and whatever happened to the blocks around it,
  # spelled as the print before the form, and is kept as stored there; any
  # other answer is refused by name. A callout whose body holds nothing has
  # nothing to keep: pulled as it was, it comes home as stored, and otherwise
  # stands as pushed. A form newer than the mark is believed for
  # (`PrintMark.believed/1`) is read as unshown: a block holding one that
  # spells as this pull or as the print before the form comes home as stored,
  # and any other is left to the write wall, which reads the push against the
  # print before the form. A block comes home as stored only when the pushed
  # block, as typed, spells exactly as that print: anything typed into it that
  # the print had no place for is refused by the block's name. A home holding
  # an id the stored Paper holds more than once is refused by that id, never
  # matched by a guess.
  defp old_copy(pushed, done, {view, stored, pulled}, copy) do
    n = PrintMark.read_number(copy)
    believed = PrintMark.believed(copy)

    if PrintMark.newer(view, n) != [] do
      # Blocks this pull printed as <kept> that the copy shows inline.
      inline_kept =
        for %{"type" => @kept, "id" => id} <- pulled, not MapSet.member?(done, id), do: id

      twice = twice(stored)

      with {:ok, pushed, notes} <- come_home(pushed, done, {view, stored, twice}, {n, believed}),
           {:ok, pushed} <- kept_old(pushed, inline_kept, {by_id(view), stored, twice}, n) do
        done = MapSet.union(done, MapSet.new(inline_kept))
        {:ok, each_old(pushed, done, by_id(view), by_id(stored), {n, believed}), notes}
      end
    else
      {:ok, pushed, []}
    end
  end

  # A block this pull printed as <kept> is one no copy can change. An old
  # copy shows it inline: it comes home once, at the top level, spelled as
  # typed exactly as the old print, and is kept as stored; any other answer,
  # a body or a nested list typed into it among them, is refused by the
  # block's name.
  defp kept_old(pushed, ids, {view_by_id, stored, twice}, n) do
    Enum.reduce_while(ids, {:ok, pushed}, fn id, {:ok, acc} ->
      i = Enum.find_index(acc, &(&1["id"] == id))
      v = view_by_id[id]

      cond do
        held = v && twice_in(v, twice) ->
          {:halt, twice_refused(held)}

        i != nil and v != nil and Enum.count(found(acc, []), &(&1["id"] == id)) == 1 and
            spells_as?(Enum.at(acc, i), PrintMark.before(v, n)) ->
          {:cont, {:ok, List.replace_at(acc, i, by_id(stored)[id])}}

        true ->
          {:halt, unwritable(id, stored)}
      end
    end)
  end

  # Every id the stored blocks hold more than once, at any depth.
  defp twice(stored) do
    found(stored, [])
    |> Enum.frequencies_by(& &1["id"])
    |> Enum.flat_map(fn {id, count} -> if count > 1, do: [id], else: [] end)
    |> MapSet.new()
  end

  # The first id in `block`, itself included, that `twice` holds.
  defp twice_in(block, twice) do
    Enum.find_value(found([block], []), fn %{"id" => id} -> MapSet.member?(twice, id) && id end)
  end

  defp twice_refused(id),
    do:
      refuse(
        "bpml_stale_copy",
        ~s(block "#{id}" is stored more than once, so an old copy cannot be matched ) <>
          "to it; nothing was written",
        "bp paper pull, then make your edit again"
      )

  defp unwritable(id, stored) do
    i = Enum.find_index(stored, &(is_map(&1) and &1["id"] == id))

    {:refused,
     %{
       code: "bpml_unshown",
       message:
         ~s(block "#{id}" is one BPML cannot write \(it prints as <kept>\), ) <>
           "so a text copy cannot change it; nothing was written",
       hint: "BPML cannot change this block: keep it as pulled and edit it in Studio",
       paths: if(i, do: ["blocks[#{i}]"], else: [])
     }}
  end

  defp come_home(pushed, done, {view, stored, twice}, {n, believed}) do
    found = found(pushed, [])
    stored_at = deep_by_id(stored, %{})
    view = Enum.reject(view, &MapSet.member?(done, &1["id"]))

    {homes, empties} =
      view
      |> Enum.map(fn v ->
        {forms, _} = split(PrintMark.newer(v, n), believed)
        if forms == [], do: {[], []}, else: {PrintMark.homes(v, forms), empties(v)}
      end)
      |> Enum.unzip()

    homes
    |> List.flatten()
    |> Enum.reduce_while({:ok, pushed, []}, fn {h, forms}, {:ok, acc, notes} ->
      cond do
        held = twice_in(h, twice) ->
          {:halt, twice_refused(held)}

        home?(found, h, n) ->
          {:cont,
           {:ok, put_nested(acc, h["id"], stored_at[h["id"]] || h), notes ++ kept_notes(h)}}

        true ->
          {:halt, PrintMark.stale(h, stored, forms, &canonical/1)}
      end
    end)
    |> case do
      {:ok, acc, notes} ->
        acc =
          empties
          |> List.flatten()
          |> Enum.reduce(acc, fn e, acc ->
            if home?(found, e, n),
              do: put_nested(acc, e["id"], stored_at[e["id"]] || e),
              else: acc
          end)

        {:ok, acc, notes}

      refused ->
        refused
    end
  end

  # `block` is pushed once under its id, at any depth, spelled as the print
  # before the form.
  defp home?(found, block, n) do
    case Enum.filter(found, &(&1["id"] == block["id"])) do
      [pushed] -> spells_as?(pushed, PrintMark.before(block, n))
      _none_or_twice -> false
    end
  end

  # Every map with an id and a type in `term`, at any depth.
  defp found(list, acc) when is_list(list), do: Enum.reduce(list, acc, &found/2)

  defp found(%{} = map, acc) do
    acc = if is_binary(map["id"]) and is_binary(map["type"]), do: [map | acc], else: acc
    map |> Map.values() |> Enum.reduce(acc, &found/2)
  end

  defp found(_other, acc), do: acc

  # Every block with an id and a type in `term`, at any depth, the outermost
  # first.
  defp deep_by_id(list, acc) when is_list(list), do: Enum.reduce(list, acc, &deep_by_id/2)

  defp deep_by_id(%{} = map, acc) do
    acc =
      if is_binary(map["id"]) and is_binary(map["type"]),
        do: Map.put_new(acc, map["id"], map),
        else: acc

    map |> Map.values() |> Enum.reduce(acc, &deep_by_id/2)
  end

  defp deep_by_id(_other, acc), do: acc

  # `term` with the nested block `id` replaced by `stored`.
  defp put_nested(list, id, stored) when is_list(list),
    do: Enum.map(list, &put_nested(&1, id, stored))

  defp put_nested(%{"id" => id, "type" => _}, id, stored), do: stored

  defp put_nested(%{} = map, id, stored),
    do: Map.new(map, fn {k, v} -> {k, put_nested(v, id, stored)} end)

  defp put_nested(other, _id, _stored), do: other

  # A top-level block holding a newer form that spells as this pull printed it
  # (its homes back as stored) or as the print before the forms past the
  # believed mark is kept as stored; any other stands as pushed, for the
  # write wall to read.
  defp each_old(pushed, done, view_by_id, stored_by_id, {n, believed}) do
    Enum.map(pushed, fn block ->
      id = block["id"]
      v = Map.get(view_by_id, id)

      if v != nil and not MapSet.member?(done, id) and PrintMark.newer(v, n) != [] and
           (spells_as?(block, v) or spells_as?(block, PrintMark.before(v, believed))),
         do: stored_by_id[id],
         else: block
    end)
  end

  # The forms the mark is believed for, and the newer ones.
  defp split(forms, believed),
    do: Enum.split_with(forms, fn {since, _mod} -> since <= believed end)

  # `paths` names each outermost body in the stored block's canonical
  # spelling, in the write wall's shape.
  defp slot_paths(%{"type" => "callout", "slots" => slots} = c, path) do
    if holds?(slots),
      do: ["#{path}.slots"],
      else: slot_paths(Map.delete(c, "slots"), path)
  end

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
        s = Map.get(kept, c["id"], v)

        cond do
          spells_as?(content_only(c), content_only(v)) ->
            # The stored callout's own content: no content key stays no key.
            block =
              c
              |> Map.delete("content")
              |> Map.merge(Map.take(s, ["content"]))
              |> Map.put("slots", s["slots"])

            {:ok, block, if(holds?(s["slots"]), do: notes ++ [kept_note(c["id"])], else: notes)}

          # A body that holds nothing has nothing to keep: the words change.
          not holds?(s["slots"]) ->
            {:ok, Map.put(c, "slots", s["slots"]), notes}

          true ->
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
    do: v |> homes() |> Enum.map(& &1["id"]) |> Enum.sort() |> Enum.map(&kept_note/1)

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

  # Every callout in `v` whose body holds something, inside a body too.
  defp holding_ids(v),
    do:
      for(
        {id, c} <- callouts_with_slots(v),
        holds?(c["slots"]),
        do: to_string(id)
      )
      |> Enum.sort()

  defp callout_names(v), do: Enum.map_join(holding_ids(v), ", ", &"callout #{&1}")

  defp has_have(v), do: if(length(holding_ids(v)) == 1, do: "has", else: "have")

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
