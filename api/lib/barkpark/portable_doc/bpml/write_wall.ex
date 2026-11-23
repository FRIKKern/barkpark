defmodule Barkpark.PortableDoc.Bpml.WriteWall do
  @moduledoc """
  A BPML push may not change what its pull did not show.

  The pull prints a VIEW of the stored row S (`Papers.BpmlView`: anonymous
  redaction, task blocks resolved, label fields redacted), and the printer
  spells only part of each block. Whatever S holds that the view's print does
  not carry is UNSHOWN: the author never saw it, so a push may not remove or
  rewrite it.

  ## What is unshown

  Per stored top-level block: the content of `Canonical.normalize(s)` missing
  from `parse(print(v))`, where `v` is the view block with the same id (by
  position when S has no ids or repeats one). One direction only: what the
  view adds (resolved task rows) is ignored. Every key counts, at every depth,
  by full equality, so a key nobody listed is content; a list the view prints
  shorter is missing its tail. No key is exempt. A stored block with no view
  block, or whose view does not print and parse back to one block, is unshown
  whole.

  `normalize` is the spelling equivalence: a stored spelling the print merely
  re-spells (an alias key, a string heading level) is shown. Each of its rules
  fires on an exact key set and drops no content: a key it removes holds
  nothing (nil, false or empty), or its body moves whole to another key or
  node; its sweep over the stored-document fixtures (`BpmlStoredDocuments`)
  holds that it loses nothing, so a spelling it misses refuses an edit and
  never loses content.

  ## The rule

  A stored block that holds unshown content must come out of the push
  byte-equal to S: exactly one top-level block with its id, equal to the stored
  block. So editing it, deleting it, moving it into a container or re-adding
  it without its id is refused with 422 `bpml_unshown`, naming the block and
  the first unshown path; pushing any id twice is refused first, with 422
  `bpml`. A stored block with no id, or
  one whose id S already repeats, cannot be matched, so any push that changes
  the document is refused when it holds unshown content. Blocks that hold
  none are written from the push as before.

  The rule reads per list item too (`WriteWall.Items`): unshown content inside
  a stored list item with an id is kept when the block with the same id holds
  that item once, with its id, and the content byte-equal in canonical
  spelling. `Bpml.ListItems.carry/2` brings it back on push, so the item may
  be edited where the pull showed it.

  The check runs inside `Papers.BpmlView.push/3`, after
  `Bpml.CalloutBody.resolve/4` and before any op derives, on the blocks the
  push would write (`Diff.target/3`). It compares against the blocks the
  pull's own bytes read back as, so a `<kept>` line or a callout body counts
  as shown exactly as the pull printed it. The sync write then asks the
  chokepoint to keep every top-level block the ops did not touch as stored
  (`Papers.KeepUntouched`), so a protected block in an older shape (bare-string
  list items, `{"text"}` items) keeps its bytes too; the corpus test asserts
  that on the row the write left.

  ## Paper fields

      field        shown in the pull                 written by a push   rule
      slug         yes                               no (path identity)  must match the path
      title        `<paper title>`, from the heading no (derived)        the attribute is ignored
      description  unless the schema hides it        no                  hidden + changed: refused
      tags         unless the schema hides it        no                  hidden + changed: refused

  A push that sets a description or tags the view hid is refused rather than
  ignored, so bp never reports a hidden-field edit as landed.

  ## A view that changed at the same rev

  The rev counts content writes only, so the view can change while it stays:
  a schema makes a hidden field public, or a printer change shows more of a
  block. A copy pulled before would push over a part it never saw. The pull
  answers the fingerprint of its bytes (`x-bpml-view`); bp keeps it with the
  anchor and sends it back as `bpmlView`; a push whose fingerprint is not the
  row's current one is refused with 412, and an applied push answers the new
  one. A form the printer began to show at a print number (`Bpml.PrintMark`)
  is read from the copy's print mark too, as far as the mark is believed: a
  block that holds content the copy did not show comes home unchanged or the
  push is refused. A pull
  through another perspective or tenant scope than `bp paper pull`'s can print
  another view; when it does, its push answers 412.

  The pull golden test fails when the print of any corpus shape or block
  golden changes, and names this rule.
  """

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.{Canonical, Diff}
  alias Barkpark.PortableDoc.Bpml.WriteWall.Items

  @code "bpml_unshown"

  @doc "The error code a refused push answers."
  @spec code() :: String.t()
  def code, do: @code

  @doc """
  `:ok` when the copy was pulled from the view the row prints now: `current`
  is the fingerprint of that print, `pulled` the one the copy carries back
  (`bpmlView`). A copy without it (a bp from before it) falls back to the
  block rules alone, which cannot see a view that changed at the same rev.
  """
  @spec same_view(String.t(), String.t() | nil) :: :ok | {:refused, map()}
  def same_view(_current, nil), do: :ok
  def same_view(current, current), do: :ok

  def same_view(_current, _pulled) do
    {:refused,
     %{
       code: "precondition_failed",
       message: "the readable view of this paper changed since your pull",
       hint: "bp paper pull to get the current text, re-apply your edit, push again"
     }}
  end

  @doc """
  The blocks a push of `pushed` writes over `stored` (`Diff.target/3`, against
  `pulled`, the blocks the pull's bytes read back as), or the refusal when
  they change what the pull did not show, or repeat a top-level id.
  """
  @spec target([map()], [map()], [map()]) :: {:ok, [map()]} | {:refused, map()}
  def target(stored, pulled, pushed) do
    with :ok <- unique_ids(pushed, stored),
         result = Diff.target(stored, pushed, pulled),
         :ok <- check(stored, pulled, result),
         do: {:ok, result}
  end

  # Two top-level blocks under one id cannot both be the block the id names.
  defp unique_ids(pushed, stored) do
    case repeated(pushed) do
      [] ->
        :ok

      [id | _] ->
        if id in repeated(stored),
          do:
            bpml_error(
              ~s(block id "#{id}" appears twice in the stored paper, so a push cannot tell those blocks apart),
              "give one of them a new id in the editor, then pull again"
            ),
          else:
            bpml_error(
              ~s(block id "#{id}" appears twice in the pushed document),
              "give each block its own id, or leave the id off a new block"
            )
    end
  end

  defp repeated(blocks) do
    ids = for %{"id" => id} when is_binary(id) <- blocks, do: id
    ids -- Enum.uniq(ids)
  end

  defp bpml_error(message, hint), do: {:refused, %{code: "bpml", message: message, hint: hint}}

  @doc """
  `:ok`, or the 422 refusal for a push whose `result` blocks change content of
  `stored` that `pulled` (the blocks the pull's bytes read back as) does not
  carry.
  """
  @spec check([map()], [map()], [map()]) :: :ok | {:refused, map()}
  def check(stored, pulled, result)
      when is_list(stored) and is_list(pulled) and is_list(result) do
    if stored == result do
      :ok
    else
      stored
      |> Enum.with_index()
      |> Enum.find_value(:ok, fn {s, i} -> refusal(s, i, stored, pulled, result) end)
    end
  end

  @doc """
  The paths in a stored block that the view block's print does not carry; `[]`
  when it shows everything. `shown` nil means the view has no such block.
  """
  @spec unshown(term(), term()) :: [String.t()]
  def unshown(_stored, nil), do: [""]

  def unshown(stored, shown) do
    case reprint(shown) do
      {:ok, back} -> missing_from(stored, back)
      :error -> [""]
    end
  end

  # What the stored block holds that `back` (a block as a print reads back)
  # lacks, in the stored block's canonical spelling.
  defp missing_from(_stored, nil), do: [""]

  defp missing_from(stored, back),
    do: stored |> List.wrap() |> Canonical.normalize() |> hd() |> missing(back, "")

  @doc """
  `:ok`, or the 422 refusal for a push that sets a label field (`description`,
  `tags`) the view hid. `stored` is the row's content, `view_fields` the
  redacted fields the pull printed, `parsed` the pushed document.
  """
  @spec check_fields(map(), map(), map()) :: :ok | {:refused, map()}
  def check_fields(stored, view_fields, parsed) do
    hidden =
      for key <- ~w(description tags),
          Map.has_key?(stored, key) and not Map.has_key?(view_fields, key),
          parsed[key] not in [nil, "", []],
          do: key

    case hidden do
      [] ->
        :ok

      [key | _] ->
        {:refused,
         %{
           code: @code,
           message: "this text cannot show the paper's #{key}, so a push cannot change it",
           hint: "pull again and leave <#{key}> out, or change it in the editor",
           paths: Enum.map(hidden, &"paper.#{&1}")
         }}
    end
  end

  # ── the per-block rule ──────────────────────────────────────────────────────

  defp refusal(s, i, stored, pulled, result) do
    id = if is_map(s), do: s["id"]
    matched? = is_binary(id) and Enum.count(stored, &(is_map(&1) and &1["id"] == id)) == 1

    kept? =
      if matched?,
        do: Enum.filter(result, &(is_map(&1) and &1["id"] == id)) == [s],
        else: false

    if kept? do
      nil
    else
      paths = missing_from(s, pulled_block(s, i, matched?, stored, pulled))
      paths = if matched?, do: Items.uncovered(paths, s, result), else: paths

      case paths do
        [] -> nil
        [first | _] = paths -> refuse(i, id, first, paths)
      end
    end
  end

  defp pulled_block(s, _i, true, _stored, pulled),
    do: Enum.find(pulled, &(is_map(&1) and &1["id"] == s["id"]))

  defp pulled_block(_s, i, false, stored, pulled) do
    if length(pulled) == length(stored), do: Enum.at(pulled, i)
  end

  defp refuse(i, id, first, paths) do
    where = "blocks[#{i}]" <> first
    block = if is_binary(id), do: ~s(block "#{id}"), else: "block #{i + 1} (it has no id)"

    {:refused,
     %{
       code: @code,
       message:
         "this text cannot show #{where}, so a push may not change #{block}: it would lose what the pull left out",
       hint: "pull again and leave that block as it is, or change it in the editor",
       paths: Enum.map(paths, &("blocks[#{i}]" <> &1))
     }}
  end

  defp reprint(shown) do
    case Bpml.parse_blocks(Bpml.print_blocks([shown])) do
      {:ok, [back]} -> {:ok, back}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # What `s` holds that `v` lacks, by path. One direction: keys only `v` has
  # are ignored; a shorter list misses its tail.
  defp missing(%{} = s, %{} = v, path) do
    Enum.flat_map(Enum.sort(s), fn {k, sv} ->
      case Map.fetch(v, k) do
        {:ok, vv} -> missing(sv, vv, "#{path}.#{k}")
        :error -> ["#{path}.#{k}"]
      end
    end)
  end

  defp missing(s, v, path) when is_list(s) and is_list(v) do
    s
    |> Enum.with_index()
    |> Enum.flat_map(fn {x, i} ->
      case Enum.fetch(v, i) do
        {:ok, y} -> missing(x, y, "#{path}[#{i}]")
        :error -> ["#{path}[#{i}]"]
      end
    end)
  end

  defp missing(s, s, _path), do: []
  defp missing(_s, _v, path), do: [path]
end
