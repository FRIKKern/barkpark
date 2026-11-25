defmodule BarkparkWeb.Studio.ObjectRichTextSeenFuzzTest do
  @moduledoc """
  task-2833650e2e72d380: seeded runs of B's saves and A's posts on a rich
  text inside an object, A's page modelled as bp-rt-remote.js keeps its
  number (`page/0`, `got/3`: one less than the first value waiting, or the
  merge of A's own post). B never loses its last change to a block with no
  word: a post without the banner keeps every block B wrote that was
  stored, and brings back none B took out. B edits only past A's block; A
  types only in it, so a block B lost is never A's own edit. A banner ends
  the run.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag timeout: 300_000

  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content.PortableText

  @banner "Someone else rewrote"
  @steps 12
  @pool ~w(alpha beta gamma delta zeta theta kappa sigma omega lambda)

  # 24 seeds in 4 tests, so no one test holds its sandbox for long. Each
  # chunk reaches a merge over B's saves; the four together, a hold.
  for seeds <- Enum.chunk_every(1..24, 6) do
    test "seeds #{List.first(seeds)}..#{List.last(seeds)}: B's last change is stored or shown with the banner",
         %{conn: conn} do
      tally =
        Enum.reduce(unquote(seeds), %{posts: 0, quiet: 0, merged: 0, banners: 0}, fn seed, t ->
          :rand.seed(:exsss, {seed, 7, 11})
          run(setup_doc(conn), seed, t)
        end)

      assert tally.merged >= 3, inspect(tally)
    end
  end

  defp run(c, seed, tally) do
    {a, b} = {open(c), open(c)}
    state = %{page: page(), editor: ["one two"], live: MapSet.new(), dead: MapSet.new()}

    Enum.reduce_while(1..@steps, {state, tally}, fn i, {state, t} ->
      if :rand.uniform(3) > 1,
        do: {:cont, {b_step(b, c, a, state, "s#{seed}n#{i}"), t}},
        else: a_step(a, c, state, "a#{seed}n#{i}", t, seed)
    end)
    |> elem(1)
  end

  defp b_step(b, c, a, state, tag) do
    old = rt(c)
    new = with ^old <- edit(old, tag), do: edit(old, tag, 1)
    b_saves_rt(b, c, html(new), new)
    {gone, added} = {MapSet.new(old -- new), MapSet.new(new -- old)}
    live = state.live |> MapSet.difference(gone) |> MapSet.union(added)
    dead = state.dead |> MapSet.difference(added) |> MapSet.union(gone)
    arrive(%{state | live: live, dead: dead}, next_push(a))
  end

  # Past A's block: add one, change one (a word more), take one out, or take
  # a block's last word off again.
  defp edit([first | rest], tag, pick \\ :rand.uniform(4)) do
    n = length(rest)
    new = Enum.join(Enum.take_random(@pool, 3) ++ [tag], " ")

    case {pick, n} do
      {k, n} when k == 1 or n == 0 -> List.insert_at([first | rest], :rand.uniform(n + 1), new)
      {2, _} -> [first | List.update_at(rest, :rand.uniform(n) - 1, &(&1 <> " " <> tag))]
      {3, _} -> [first | List.delete_at(rest, :rand.uniform(n) - 1)]
      {4, _} -> [first | List.update_at(rest, :rand.uniform(n) - 1, &undo/1)]
    end
  end

  defp undo(text) do
    words = String.split(text, " ")
    if length(words) > 4, do: Enum.join(Enum.drop(words, -1), " "), else: text
  end

  defp a_step(a, c, state, tag, t, seed) do
    [mine | rest] = state.editor
    editor = [mine <> " " <> tag | rest]
    before = rt(c)
    shown = post_rt(a, html(editor), seen(state.page))
    after_ = rt(c)
    t = %{t | posts: t.posts + 1}

    if shown =~ @banner do
      assert after_ == before, "seed #{seed}: a hold wrote over theirs"
      {:halt, {state, %{t | banners: t.banners + 1}}}
    else
      lost = for x <- before, MapSet.member?(state.live, x), x not in after_, do: x
      back = for x <- after_, MapSet.member?(state.dead, x), x not in before, do: x
      assert {lost, back} == {[], []}, "seed #{seed}: #{inspect({before, editor, after_})}"
      merged? = after_ != editor
      t = %{t | quiet: t.quiet + 1, merged: t.merged + if(merged?, do: 1, else: 0)}
      state = %{state | editor: editor}

      # A merge is sent back (`own`); a post saved as typed is not.
      {:cont, {if(merged?, do: arrive(state, next_push(a)), else: state), t}}
    end
  end

  # A's page draws a pushed value at once, or, A typing, it waits; a value
  # that waits is drawn at once when the next one comes, sometimes.
  defp arrive(state, v) do
    state =
      if state.page.first && :rand.uniform(3) == 1, do: draw(state, state.waiting), else: state

    if :rand.uniform(2) == 1,
      do: draw(%{state | page: got(state.page, v, true)}, v),
      else: Map.put(%{state | page: got(state.page, v, false)}, :waiting, v)
  end

  defp draw(state, v),
    do: %{state | page: drew(state.page), editor: words(PortableText.from_html(v.html))}

  defp html(words), do: Enum.map_join(words, &"<p>#{&1}</p>")
  defp rt(c), do: words(stored(c)["meta"]["rt"])
end
