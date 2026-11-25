defmodule Barkpark.Content.PortableTextPairingScaleTest do
  @moduledoc """
  task-dd2886673f171e40, #28724 review B1 and B2: a save of a long value.
  A find and replace across it keeps every key, and a post unlike the
  stored value costs no more than a linear walk.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableText

  defp block(k, text) do
    %{
      "_type" => "block",
      "_key" => k,
      "style" => "normal",
      "markDefs" => [],
      "children" => [%{"_type" => "span", "_key" => k <> "s", "text" => text, "marks" => []}]
    }
  end

  defp save(stored, edit), do: PortableText.from_html(PortableText.to_html(edit), stored)

  # Every block but the first and last gets one more word, as a find and
  # replace or a "fix the quotes" pass does. 148 x 148 is past the budget of
  # the pairing by words, which then paired nothing (B1).
  for n <- [150, 2_000] do
    test "a find and replace across #{n} blocks keeps every key" do
      n = unquote(n)
      stored = for i <- 1..n, do: block("k#{i}", "paragraph #{i} says something here")

      edit =
        for {b, i} <- Enum.with_index(stored, 1) do
          if i in [1, n], do: b, else: block("x", "paragraph #{i} says something else here")
        end

      assert Enum.map(save(stored, edit), & &1["_key"]) == for(i <- 1..n, do: "k#{i}")
    end
  end

  # Runs `fun` in a process whose heap is capped at 100 MB: its result and
  # the reductions it took. A run past the cap is killed and the test fails.
  defp bounded(fun) do
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          {:reductions, r0} = Process.info(self(), :reductions)
          out = fun.()
          {:reductions, r1} = Process.info(self(), :reductions)
          send(parent, {:done, out, r1 - r0})
        end,
        [
          :monitor,
          {:max_heap_size, %{size: div(100_000_000, 8), kill: true, error_logger: false}}
        ]
      )

    assert_receive {:done, out, reductions}, 60_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    {out, reductions}
  end

  # #28724 r2 review S1: identical blocks between two ends that differ are
  # past the line-up's cap, and the in-order walk looked each one up past
  # every block it had taken: stored Y, A x 10k, Y' against posted Z,
  # A x 20k, Z' took 5.9 s (main 0.36 s), 20k empty paragraphs 5.7 s.
  for {name, text} <- [{"identical", "the same words"}, {"empty", ""}] do
    test "#{name} blocks past the line-up's cap cost a linear walk" do
      text = unquote(text)
      many = fn n, k -> for i <- 1..n, do: block("#{k}#{i}", text) end
      stored = [block("y", "stored start")] ++ many.(10_000, "a") ++ [block("y2", "stored end")]
      posted = [block("z", "posted start")] ++ many.(20_000, "x") ++ [block("z2", "posted end")]
      html = PortableText.to_html(posted)

      {_out, reductions} = bounded(fn -> length(PortableText.from_html(html, stored)) end)
      # Measured on the fix: about 0.2G at most.
      assert reductions < 1_000_000_000, "took #{reductions} reductions"
    end
  end

  # 10,000 stored blocks and a post of 10,000 others: the line-up's table
  # held 10,000 x 10,000 cells, about 1 GB (B2). In a process whose heap is
  # capped at 100 MB, a save past the cap is killed and the test fails.
  test "a post unlike a long stored value stays within 100 MB and a bound on reductions" do
    stored = for i <- 1..10_000, do: block("k#{i}", "s#{i}")
    html = PortableText.to_html(for i <- 1..10_000, do: block("x", "p#{i}"))
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          {:reductions, r0} = Process.info(self(), :reductions)
          out = PortableText.from_html(html, stored)
          {:reductions, r1} = Process.info(self(), :reductions)
          send(parent, {:done, length(out), r1 - r0})
        end,
        [
          :monitor,
          {:max_heap_size, %{size: div(100_000_000, 8), kill: true, error_logger: false}}
        ]
      )

    assert_receive {:done, 10_000, reductions}, 60_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    # Measured: about 70M.
    assert reductions < 200_000_000, "took #{reductions} reductions"
  end
end
