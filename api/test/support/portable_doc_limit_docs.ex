defmodule Barkpark.PortableDoc.LimitDocs do
  import ExUnit.Assertions

  @heap_bytes 100 * 1024 * 1024

  def toc_item(level), do: %{"text" => "h#{level}", "level" => level, "anchor" => "a#{level}"}

  def limit_docs, do: Mix.Tasks.Barkpark.PortableDoc.GenPdParity.Limits.docs()

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
