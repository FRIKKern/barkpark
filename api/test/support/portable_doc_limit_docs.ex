defmodule Barkpark.PortableDoc.LimitDocs do
  import ExUnit.Assertions

  @heap_bytes 100 * 1024 * 1024

  def toc_item(level), do: %{"text" => "h#{level}", "level" => level, "anchor" => "a#{level}"}

  def limit_docs do
    [
      {"toc",
       %{
         "type" => "toc",
         "depth" => 10_000_000,
         "numbered" => true,
         "items" => [toc_item(1), toc_item(2)]
       }},
      {"sheet",
       %{
         "type" => "sheet",
         "snapshot" => %{
           "rows" => [["a", "b"]],
           "merges" => for(i <- 0..399, do: [i, 0, 100, 100])
         }
       }},
      {"table",
       %{
         "type" => "table",
         "rows" => [List.duplicate([], 1000) | List.duplicate([[]], 999)],
         "spans" =>
           List.duplicate(%{"row" => 0, "col" => 0, "rowspan" => 1000, "colspan" => 1000}, 5)
       }},
      {"heatmap",
       %{"type" => "heatmap", "cells" => [List.duplicate(1, 2000) | List.duplicate([1], 1999)]}},
      {"route", %{"type" => "route", "polyline" => String.duplicate("~", 60_000) <> "???"}},
      {"record table",
       %{
         "type" => "table",
         "columns" => List.duplicate(%{"key" => "k"}, 1000),
         "rows" => List.duplicate(%{}, 1000)
       }},
      {"tool diff",
       %{
         "type" => "chat-tool-diff",
         "input" => %{
           "file_path" => "f",
           "old_string" => String.duplicate("a\n", 2000),
           "new_string" => String.duplicate("b\n", 2000)
         }
       }},
      {"multi edit",
       %{
         "type" => "chat-tool-diff",
         "input" => %{
           "file_path" => "f",
           "edits" =>
             List.duplicate(
               %{
                 "old_string" => String.duplicate("a\n", 2000),
                 "new_string" => String.duplicate("b\n", 2000)
               },
               5
             )
         }
       }},
      {"nested columns", nest(&%{"type" => "columns", "columns" => [[&1]]})},
      {"nested section", nest(&%{"type" => "section", "blocks" => [&1]})},
      {"big number", %{"type" => "heatmap", "cells" => [[Integer.pow(10, 400), 1]]}},
      {"nested strong",
       %{
         "type" => "paragraph",
         "content" => [nest_inline("strong", 20_000)]
       }},
      {"many merges",
       %{
         "type" => "sheet",
         "snapshot" => %{
           "rows" => List.duplicate(List.duplicate("a", 100), 100),
           "merges" => List.duplicate([0, 0, 100, 100], 20_000)
         }
       }},
      {"many spans",
       %{
         "type" => "table",
         "rows" => List.duplicate(List.duplicate([], 100), 100),
         "spans" =>
           List.duplicate(%{"row" => 0, "col" => 0, "rowspan" => 100, "colspan" => 100}, 20_000)
       }},
      {"flat line", flat_line(1.0e16)},
      {"flat line high", flat_line(1.0e100)}
    ]
  end

  defp flat_line(value),
    do: %{"type" => "chart", "series" => [%{"label" => "s", "points" => [value, value]}]}

  def nest_inline(type, depth),
    do:
      Enum.reduce(1..depth, %{"type" => "text", "value" => "leaf"}, fn _, node ->
        %{"type" => type, "children" => [node]}
      end)

  def nest(wrap, depth \\ 4000),
    do: Enum.reduce(1..depth, %{"type" => "paragraph", "text" => "leaf"}, fn _, b -> wrap.(b) end)

  def bounded(fun) do
    parent = self()
    words = div(@heap_bytes, :erlang.system_info(:wordsize))

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          {us, result} = :timer.tc(fun)
          send(parent, {:bounded, self(), us, result})
        end,
        [
          :monitor,
          {:max_heap_size,
           %{size: words, kill: true, error_logger: false, include_shared_binaries: true}}
        ]
      )

    receive do
      {:bounded, ^pid, us, result} ->
        Process.demonitor(ref, [:flush])
        {us, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("passed #{@heap_bytes} bytes of heap: #{inspect(reason)}")
    after
      30_000 ->
        Process.exit(pid, :kill)
        flunk("still running after 30 s")
    end
  end
end
