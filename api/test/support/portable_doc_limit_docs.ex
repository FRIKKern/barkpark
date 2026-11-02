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
      {"route", %{"type" => "route", "polyline" => String.duplicate("~", 60_000) <> "???"}}
    ]
  end

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
