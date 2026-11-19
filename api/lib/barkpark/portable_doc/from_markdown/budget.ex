defmodule Barkpark.PortableDoc.FromMarkdown.Budget do
  @moduledoc """
  The two bounds on one Markdown import (`Barkpark.PortableDoc.FromMarkdown`).

    * **Input size.** At most `max_bytes/0` bytes of Markdown. Larger input is
      refused with `:markdown_too_large` before anything reads it. Every
      PortableDoc importer shares this number and this code: the golden pack
      states them in `limits/markdown-input.json`.
    * **Work.** The import runs in its own process, which may spend at most
      `max_reductions/0` reductions, a count that is the same on every machine.
      An import that needs more is stopped and refused with
      `:markdown_too_costly` ("too costly to import"); it returns nothing, so no
      caller writes half of it. The number is a stated multiple of what the
      largest ordinary document of `max_bytes/0` needs (see
      `test/barkpark/portable_doc/from_markdown_budget_test.exs`).
  """

  @max_bytes 2_000_000
  @max_reductions 2_000_000_000
  @poll_ms 10

  @typedoc "Why an import was refused."
  @type refusal :: :markdown_too_large | :markdown_too_costly

  @doc "The largest Markdown input, in bytes, an importer takes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The most reductions one import may spend."
  @spec max_reductions() :: pos_integer()
  def max_reductions, do: @max_reductions

  @doc """
  `fun.(markdown)` within both bounds: `{:ok, result}`, `{:error, refusal}`, or
  `{:error, :crashed}` when `fun` raised or its process died. The size is
  checked before `fun` runs. `:max_bytes` and `:max_reductions` override the
  bounds (tests and measuring).
  """
  @spec run(binary(), (binary() -> result), keyword()) ::
          {:ok, result} | {:error, refusal() | :crashed}
        when result: term()
  def run(markdown, fun, opts \\ []) when is_binary(markdown) and is_function(fun, 1) do
    if byte_size(markdown) > Keyword.get(opts, :max_bytes, @max_bytes),
      do: {:error, :markdown_too_large},
      else: work(fn -> fun.(markdown) end, Keyword.get(opts, :max_reductions, @max_reductions))
  end

  defp work(fun, budget) do
    caller = self()
    tag = make_ref()
    {pid, ref} = spawn_monitor(fn -> send(caller, {tag, fun.()}) end)
    await(pid, ref, tag, budget)
  end

  defp await(pid, ref, tag, budget) do
    receive do
      {^tag, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

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
