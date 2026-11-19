defmodule Barkpark.PortableDoc.FromMarkdown.Budget do
  @moduledoc """
  The bounds on one Markdown import (`Barkpark.PortableDoc.FromMarkdown`).

    * **Input size.** At most `max_bytes/0` bytes of Markdown. Larger input is
      refused with `:markdown_too_large` before anything reads it. Every
      PortableDoc importer shares this number and this code: the golden pack
      states them in `limits/markdown-input.json`.
    * **Work.** The import runs in its own process, which may spend at most
      `max_reductions/0` reductions, a count that is the same on every machine.
      Its heap may grow to at most `max_heap_words/0` words. An import that
      needs more of either is stopped and refused with `:markdown_too_costly`
      ("too costly to import"); it returns nothing, so no caller writes half
      of it. Both numbers are at least nine times what an ordinary document
      of `max_bytes/0` needs (pinned by
      `test/barkpark/portable_doc/from_markdown_budget_test.exs`).
  """

  @max_bytes 500_000
  @max_reductions 1_000_000_000
  @max_heap_words 30_000_000
  @poll_ms 10

  @typedoc "Why an import was refused."
  @type refusal :: :markdown_too_large | :markdown_too_costly

  @doc "The largest Markdown input, in bytes, an importer takes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The most reductions one import may spend."
  @spec max_reductions() :: pos_integer()
  def max_reductions, do: @max_reductions

  @doc "The largest heap, in words, one import may grow."
  @spec max_heap_words() :: pos_integer()
  def max_heap_words, do: @max_heap_words

  @doc """
  `fun.(markdown)` within the bounds: `{:ok, result}`, `{:error, refusal}`, or
  `{:error, :crashed}` when `fun` raised or its process died. The size is
  checked before `fun` runs. `:max_bytes`, `:max_reductions` and
  `:max_heap_words` override the bounds (tests and measuring).
  """
  @spec run(binary(), (binary() -> result), keyword()) ::
          {:ok, result} | {:error, refusal() | :crashed}
        when result: term()
  def run(markdown, fun, opts \\ []) when is_binary(markdown) and is_function(fun, 1) do
    if byte_size(markdown) > Keyword.get(opts, :max_bytes, @max_bytes),
      do: {:error, :markdown_too_large},
      else:
        work(
          fn -> fun.(markdown) end,
          Keyword.get(opts, :max_reductions, @max_reductions),
          Keyword.get(opts, :max_heap_words, @max_heap_words)
        )
  end

  defp work(fun, budget, heap) do
    caller = self()
    tag = make_ref()

    {pid, ref} =
      :erlang.spawn_opt(fn -> send(caller, {tag, fun.()}) end, [
        :monitor,
        {:max_heap_size, %{size: heap, kill: true, error_logger: false}}
      ])

    await(pid, ref, tag, budget)
  end

  defp await(pid, ref, tag, budget) do
    receive do
      {^tag, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      # The heap cap kills it with `:killed`; nothing else here does.
      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {:error, :markdown_too_costly}

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {:error, :crashed}
    after
      @poll_ms ->
        case Process.info(pid, :reductions) do
          {:reductions, spent} when spent > budget -> stop(pid, ref, tag)
          _ -> await(pid, ref, tag, budget)
        end
    end
  end

  # Kill the import and drop anything it sent before it died.
  defp stop(pid, ref, tag) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end

    receive do
      {^tag, _result} -> :ok
    after
      0 -> :ok
    end

    {:error, :markdown_too_costly}
  end
end
