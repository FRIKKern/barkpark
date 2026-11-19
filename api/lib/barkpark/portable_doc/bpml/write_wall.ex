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
  fires on an exact key set and drops no key, and its property test holds that
  it loses nothing, so a spelling it misses refuses an edit and never loses
  content.

  ## The rule

  A stored block that holds unshown content must come out of the push
  byte-equal to S: exactly one top-level block with its id, equal to the stored
  block. So editing it, deleting it, moving it into a container, re-adding it
  without its id, or pushing its id twice is refused with 422 `bpml_unshown`,
  naming the block and the first unshown path. A stored block with no id, or
  one whose id S already repeats, cannot be matched, so any push that changes
  the document is refused when it holds unshown content. Blocks that hold
  none are written from the push as before.

  The check runs on the blocks the push would write (`Diff.target/3`), before
  any op derives. The write then puts EVERY block of the Paper, touched or not,
  through the chokepoint every block write runs, whose
  `BlockOps.normalize_render_shapes/1` rewrites older shapes (list items, notes
  and cards items, text-keyed leaves). A block that must stay byte-equal and
  is stored in such a shape would be rewritten, so the push is refused; an
  edit in the editor brings it to the current shape. The corpus test asserts
  that every other block leaves the write as `normalize_render_shapes([s])`.

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
  one. A push without a fingerprint (a bp from before it) gets the block rules
  alone, which cannot see such a change: that gap is pinned by a test. A pull
  through another perspective or tenant scope than `bp paper pull`'s prints
  another view, so its push answers 412.

  The pull golden test fails on any printer output change and names the same
  rule.
  """

  alias Barkpark.Content.Document
  alias Barkpark.Content.Papers.{BlockOps, BpmlView}
  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.{Canonical, Diff}

  @code "bpml_unshown"

  @doc "The error code a refused push answers."
  @spec code() :: String.t()
  def code, do: @code

  @doc """
  The push of `parsed` onto `paper`: the field and block rules on the blocks
  `Diff.target/3` would write (against the view the pull printed), then the
  op batch. The view is computed from `paper`,
  the row being written (published task rows, the Paper's own schema), never
  re-fetched. Answers what `Diff.derive/3` answers, or `{:error, fields}` for a
  refusal.
  """
  @spec derive(Document.t(), map(), String.t()) ::
          {:ok, [map()], [map()]} | {:error, :diff_verification_failed} | {:error, map()}
  def derive(%Document{} = paper, parsed, dataset) do
    content = paper.content || %{}
    stored = content["blocks"] || []

    {shown, fields} =
      case BpmlView.of(paper, dataset, [], :published) do
        {:blocks, blocks, fields} -> {blocks, fields}
        _nothing_shown -> {[], %{}}
      end

    pushed = parsed["blocks"] || []

    with :ok <- same_view(paper, dataset, parsed["bpmlView"]),
         :ok <- unique_ids(pushed, stored),
         :ok <- check_fields(content, fields, parsed),
         result = Diff.target(stored, pushed, shown),
         :ok <- check(stored, shown, result) do
      Diff.derive_target(stored, result)
    end
  end

  @doc "The HTTP status a refusal answers."
  @spec status(map()) :: atom()
  def status(%{code: "precondition_failed"}), do: :precondition_failed
  def status(_refusal), do: :unprocessable_entity

  # The view the copy was pulled from must be the view the row prints now. A
  # copy without the fingerprint (a bp from before it) falls back to the rules
  # above alone, which cannot see a view that changed at the same rev.
  defp same_view(_paper, _dataset, nil), do: :ok

  defp same_view(paper, dataset, pulled) do
    if pulled == BpmlView.hash_of(paper, dataset) do
      :ok
    else
      {:error,
       %{
         code: "precondition_failed",
         message: "the readable view of this paper changed since your pull",
         hint: "bp paper pull to get the current text, re-apply your edit, push again"
       }}
    end
  end

  # Two top-level blocks under one id cannot both be the block the id names.
  defp unique_ids(pushed, stored) do
    case repeated(pushed) do
      [] ->
        :ok

      [id | _] ->
        if id in repeated(stored) do
          {:error,
           %{
             code: "bpml",
             message:
               ~s(block id "#{id}" appears twice in the stored paper, so a push cannot tell those blocks apart),
             hint: "give one of them a new id in the editor, then pull again"
           }}
        else
          {:error,
           %{
             code: "bpml",
             message: ~s(block id "#{id}" appears twice in the pushed document),
             hint: "give each block its own id, or leave the id off a new block"
           }}
        end
    end
  end

  defp repeated(blocks) do
    ids = for %{"id" => id} when is_binary(id) <- blocks, do: id
    ids -- Enum.uniq(ids)
  end

  @doc """
  `:ok`, or the 422 fields for a push whose `result` blocks change content of
  `stored` that `shown` (the view's blocks) did not print.
  """
  @spec check([map()], [map()], [map()]) :: :ok | {:error, map()}
  def check(stored, shown, result) when is_list(stored) and is_list(shown) and is_list(result) do
    if stored == result do
      :ok
    else
      stored
      |> Enum.with_index()
      |> Enum.find_value(:ok, fn {s, i} -> refusal(s, i, stored, shown, result) end)
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
      {:ok, back} -> stored |> List.wrap() |> Canonical.normalize() |> hd() |> missing(back, "")
      :error -> [""]
    end
  end

  @doc """
  `:ok`, or the 422 fields for a push that sets a label field (`description`,
  `tags`) the view hid. `stored` is the row's content, `view_fields` the
  redacted fields the pull printed, `parsed` the pushed document.
  """
  @spec check_fields(map(), map(), map()) :: :ok | {:error, map()}
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
        {:error,
         %{
           code: @code,
           message: "this text cannot show the paper's #{key}, so a push cannot change it",
           hint: "pull again and leave <#{key}> out, or change it in the editor",
           paths: Enum.map(hidden, &"paper.#{&1}")
         }}
    end
  end

  # ── the per-block rule ──────────────────────────────────────────────────────

  defp refusal(s, i, stored, shown, result) do
    id = if is_map(s), do: s["id"]
    matched? = is_binary(id) and Enum.count(stored, &(is_map(&1) and &1["id"] == id)) == 1

    kept? =
      if matched?,
        do: Enum.filter(result, &(is_map(&1) and &1["id"] == id)) == [s],
        else: false

    cond do
      kept? and BlockOps.normalize_render_shapes([s]) == [s] ->
        nil

      true ->
        case unshown(s, view_block(s, i, matched?, stored, shown)) do
          [] -> nil
          [first | _] = paths when kept? -> refuse_reshape(i, id, first, paths)
          [first | _] = paths -> refuse(i, id, first, paths)
        end
    end
  end

  defp view_block(s, _i, true, _stored, shown),
    do: Enum.find(shown, &(is_map(&1) and &1["id"] == s["id"]))

  defp view_block(_s, i, false, stored, shown) do
    if length(shown) == length(stored), do: Enum.at(shown, i)
  end

  defp refuse(i, id, first, paths) do
    where = "blocks[#{i}]" <> first
    block = if is_binary(id), do: ~s(block "#{id}"), else: "block #{i + 1} (it has no id)"

    {:error,
     %{
       code: @code,
       message:
         "this text cannot show #{where}, so a push may not change #{block}: it would lose what the pull left out",
       hint: "pull again and leave that block as it is, or change it in the editor",
       paths: Enum.map(paths, &("blocks[#{i}]" <> &1))
     }}
  end

  # Kept byte-equal by the push, but stored in an older shape the write's
  # chokepoint (`BlockOps.normalize_render_shapes/1`) would rewrite.
  defp refuse_reshape(i, id, first, paths) do
    {:error,
     %{
       code: @code,
       message:
         ~s(block "#{id}" is stored in an older shape this write would rewrite, and this text cannot show blocks[#{i}]#{first}),
       hint:
         "change the paper once in the editor (any edit there updates the shape), then pull again",
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
