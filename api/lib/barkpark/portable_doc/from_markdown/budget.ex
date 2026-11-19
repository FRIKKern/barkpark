defmodule Barkpark.PortableDoc.FromMarkdown.Budget do
  @moduledoc """
  The bounds on one Markdown import (`Barkpark.PortableDoc.FromMarkdown`).

    * **Input size.** At most `max_bytes/0` bytes of Markdown. Larger input is
      refused with `:markdown_too_large` before anything reads it. Every
      PortableDoc importer shares this number and this code: the golden pack
      states them in `limits/markdown-input.json`.
    * **Work, memory and result.** The import runs in a worker process that a
      watchdog holds to `max_reductions/0` reductions (a count that is the same
      on every machine) and `max_memory_bytes/0` of memory: its heap and the
      large binaries it holds. The worker measures its own result, which may be
      at most `max_output_bytes/0` (`@output_multiple` times the input size) in
      external term format, before it hands it over. An import past any of
      these is stopped and refused with `:markdown_too_costly` ("too costly to
      import"); it returns nothing, so no caller writes, encodes or renders
      half of it.
    * **Tied to the caller.** The watchdog monitors the caller and is linked to
      the worker: if the caller goes away the worker is killed at once, and if
      the watchdog dies the worker dies with it, so nothing parses without its
      budget held.

  Each number is at least eight times what an ordinary document of
  `max_bytes/0` needs (pinned by
  `test/barkpark/portable_doc/from_markdown_budget_test.exs`).
  """

  @max_bytes 500_000
  @max_reductions 1_000_000_000
  @max_memory_bytes 256_000_000
  @output_multiple 40
  @poll_ms 10

  @typedoc "Why an import was refused."
  @type refusal :: :markdown_too_large | :markdown_too_costly

  @doc "The largest Markdown input, in bytes, an importer takes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The most reductions one import may spend."
  @spec max_reductions() :: pos_integer()
  def max_reductions, do: @max_reductions

  @doc "The most memory, in bytes (heap and large binaries), one import may hold."
  @spec max_memory_bytes() :: pos_integer()
  def max_memory_bytes, do: @max_memory_bytes

  @doc "The largest result, in external-term bytes: `@output_multiple` times `max_bytes/0`."
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @output_multiple * @max_bytes

  @doc """
  `fun.(markdown)` within the bounds: `{:ok, result}`, `{:error, refusal}`, or
  `{:error, :crashed}` when `fun` raised or its process died. The size is
  checked before `fun` runs. `:max_bytes`, `:max_reductions`,
  `:max_memory_bytes` and `:max_output_bytes` override the bounds (tests and
  measuring).
  """
  @spec run(binary(), (binary() -> result), keyword()) ::
          {:ok, result} | {:error, refusal() | :crashed}
        when result: term()
  def run(markdown, fun, opts \\ []) when is_binary(markdown) and is_function(fun, 1) do
    if byte_size(markdown) > Keyword.get(opts, :max_bytes, @max_bytes) do
      {:error, :markdown_too_large}
    else
      limits = %{
        reductions: Keyword.get(opts, :max_reductions, @max_reductions),
        memory: Keyword.get(opts, :max_memory_bytes, @max_memory_bytes),
        output: Keyword.get(opts, :max_output_bytes, max_output_bytes())
      }

      supervise(fn -> fun.(markdown) end, limits)
    end
  end

  # The caller only waits; the watchdog holds the budget. One outcome comes
  # back, then the watchdog's DOWN, after which nothing more can arrive.
  defp supervise(fun, limits) do
    caller = self()
    tag = make_ref()
    {watchdog, ref} = spawn_monitor(fn -> watch(caller, tag, fun, limits) end)

    receive do
      {^tag, outcome} ->
        receive do
          {:DOWN, ^ref, :process, ^watchdog, _reason} -> :ok
        end

        flush(tag)
        outcome

      {:DOWN, ^ref, :process, ^watchdog, _reason} ->
        receive do
          {^tag, outcome} -> outcome
        after
          0 -> {:error, :crashed}
        end
    end
  end

  defp flush(tag) do
    receive do
      {^tag, _outcome} -> flush(tag)
    after
      0 -> :ok
    end
  end

  defp watch(caller, tag, fun, limits) do
    Process.flag(:trap_exit, true)
    watched = Process.monitor(caller)
    heap_words = div(limits.memory, :erlang.system_info(:wordsize))

    worker =
      :erlang.spawn_opt(fn -> deliver(caller, tag, fun, limits.output) end, [
        :link,
        {:max_heap_size, %{size: heap_words, kill: true, error_logger: false}}
      ])

    guard(caller, tag, worker, watched, limits)
  end

  # Kills (`:killed`) come only from here or the heap cap: both mean too costly.
  defp guard(caller, tag, worker, watched, limits) do
    receive do
      {:EXIT, ^worker, :normal} ->
        :ok

      {:EXIT, ^worker, :killed} ->
        send(caller, {tag, {:error, :markdown_too_costly}})

      {:EXIT, ^worker, _reason} ->
        send(caller, {tag, {:error, :crashed}})

      {:DOWN, ^watched, :process, ^caller, _reason} ->
        Process.exit(worker, :kill)
    after
      @poll_ms ->
        if over?(worker, limits), do: Process.exit(worker, :kill)
        guard(caller, tag, worker, watched, limits)
    end
  end

  defp over?(worker, limits) do
    case Process.info(worker, [:reductions, :memory, :binary]) do
      [reductions: spent, memory: heap, binary: binaries] ->
        spent > limits.reductions or heap + binary_bytes(binaries) > limits.memory

      nil ->
        false
    end
  end

  defp binary_bytes(binaries),
    do: Enum.reduce(binaries, 0, fn {_id, size, _refs}, total -> total + size end)

  # The worker measures its own result, so no caller ever holds an oversized one.
  defp deliver(caller, tag, fun, max_output) do
    result = fun.()

    outcome =
      if :erlang.external_size(result) > max_output,
        do: {:error, :markdown_too_costly},
        else: {:ok, result}

    send(caller, {tag, outcome})
  end
end
