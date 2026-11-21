defmodule Barkpark.PortableDoc.Bpml.CalloutBody do
  @moduledoc """
  A callout's body in BPML (task-4c27c15194ae9369): what a push may do to it.

  A callout with a `slots` key prints in the structured form, and the Paper's
  `<paper>` carries `print="2"` (`marked?/1`):

      <callout id="c1" tone="info">
        <content>inline</content>
        <slot name="body">
          <p id="c1-a">blocks</p>
        </slot>
      </callout>

  A copy pulled before this form existed shows the same callout inline, with
  no body. The mark is how a push tells the two apart, so a body is never lost
  to an old copy. `resolve/4` applies these rules before the diff:

    * **Old copy** (the stored view is marked, the copy is not). A top-level
      block holding a callout with `slots` is kept as stored when it spells as
      the old printer spelled it (`strip_slots/1`); otherwise the push is
      refused with `bpml_stale_copy`, naming the callouts.
    * **The inline form never deletes a body**, in a marked copy too. An
      inline callout whose stored callout has `slots` keeps the stored body
      when its text is unchanged, and the answer says so in one note;
      otherwise `bpml_inline_body`. A body is deleted only in the structured
      form: the slot left out stores no body, `<content>` left out stores no
      content.
    * **`<kept>`.** A top-level block holding a callout BPML cannot write
      prints as `<kept id type why/>` (the printer's `Unwritable`). It resolves
      to the stored block only at top level, when its id and type match a
      block the pull printed as `<kept>` and that id appears once. Anything
      else, including a `<kept>` removed, replaced or moved inside another
      block, is refused with `bpml_kept`. Nothing is ever stored as `<kept>`.

  The parser marks an inline callout with `"$form" => "inline"` and reads
  `<kept>` as a `"$kept"` block. `clean/1` strips the first and refuses the
  second, so only the push path (`Bpml.parse_copy/1`) ever sees them.
  """

  alias Barkpark.PortableDoc.Bpml.Printer

  defmodule Unwritable do
    @moduledoc """
    Raised by the printer for a callout it cannot spell. Only the top-level
    print catches it, turning the whole top-level block into `<kept>`.
    """
    defexception [:callout, :reason]

    @impl true
    def message(%{callout: nil, reason: reason}), do: "a callout: #{reason}"
    def message(%{callout: id, reason: reason}), do: "callout #{id}: #{reason}"
  end

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
    stored_by_id = by_id(stored)

    with :ok <- no_nested_kept(pushed),
         {:ok, pushed, done} <- resolve_kept(pushed, pulled, stored_by_id),
         {:ok, pushed, notes} <- old_copy(pushed, done, view, stored_by_id, copy),
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

  defp resolve_kept(pushed, pulled, stored_by_id) do
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
         :ok <- every_kept_back(printed, pushed) do
      {:ok, Enum.reverse(rev), MapSet.new(Map.keys(printed))}
    end
  end

  defp every_kept_back(printed, pushed) do
    kept_ids = for %{"type" => @kept, "id" => id} <- pushed, into: MapSet.new(), do: id

    Enum.find_value(printed, :ok, fn {id, of} ->
      if MapSet.member?(kept_ids, id),
        do: false,
        else:
          refuse(
            "bpml_kept",
            "#{of} #{id} was pulled as <kept> and your copy removed or replaced it",
            "BPML cannot change this block: keep its <kept> line as pulled and edit it in Studio"
          )
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

  defp old_copy(pushed, done, view, stored_by_id, copy) do
    if marked?(view) and Map.get(copy, "print") != "2" do
      view_by_id = by_id(view)

      Enum.reduce_while(pushed, {:ok, [], []}, fn block, {:ok, acc, notes} ->
        id = block["id"]
        v = Map.get(view_by_id, id)

        cond do
          MapSet.member?(done, id) or v == nil or not marked?(v) ->
            {:cont, {:ok, [block | acc], notes}}

          spells_as?(block, strip_slots(v)) ->
            {:cont, {:ok, [stored_by_id[id] | acc], notes ++ kept_notes(v)}}

          true ->
            {:halt, stale(v)}
        end
      end)
      |> reversed()
    else
      {:ok, pushed, []}
    end
  end

  defp stale(v),
    do:
      refuse(
        "bpml_stale_copy",
        "#{callout_names(v)} #{has_have(v)} a body your copy was pulled without; " <>
          "nothing was written",
        "bp paper pull, then make your edit again"
      )

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

          block =
            c |> Map.put("content", Map.get(s, "content", [])) |> Map.put("slots", s["slots"])

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
