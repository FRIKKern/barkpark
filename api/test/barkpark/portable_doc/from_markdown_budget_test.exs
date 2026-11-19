defmodule Barkpark.PortableDoc.FromMarkdownBudgetTest do
  @moduledoc """
  The bounds on one Markdown import (`FromMarkdown.Budget`): the input size the
  golden pack states in `limits/markdown-input.json`, refused before parsing,
  and the work budget, past which an import is refused as too costly.

  Not async: CPU is read for the whole VM, so nothing else may run beside it.
  """
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.PortableDoc.FromMarkdown.Budget
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity.{Limits, Pack}

  @fixture Path.join(Pack.dir(), "limits/markdown-input.json")

  # CPU, in ms, within which a refused import must stop.
  @cpu_bound_ms 10_000

  # One section of an ordinary document: headings, prose with links and code,
  # lists, a table, a fence and a quote.
  @section """
  ## A section heading

  A paragraph of ordinary prose with a [link](https://example.com/page) and some `inline code`,
  plus **bold** and _emphasis_. It runs for a few sentences, the way a design doc does, and
  mentions a path like api/lib/barkpark/content.ex and a number like 1,234.

  - First item with a [reference](https://example.com/ref)
  - Second item, a little longer than the first one
    - A nested item

  1. Step one
  2. Step two

  | Name | Value | Note |
  |---|---|---|
  | alpha | 1 | first |
  | beta | 2 | second |

  ```elixir
  def hello, do: :world
  ```

  > A short quote from somewhere.

  """

  defp ordinary(bytes) do
    whole = String.duplicate(@section, div(bytes, byte_size(@section)))
    whole <> String.duplicate(" ", bytes - byte_size(whole))
  end

  defp repeat(unit, bytes),
    do: unit |> String.duplicate(div(bytes, byte_size(unit)) + 1) |> binary_part(0, bytes)

  defp cpu_ms(fun) do
    {before, _} = :erlang.statistics(:runtime)
    result = fun.()
    {later, _} = :erlang.statistics(:runtime)
    {later - before, result}
  end

  test "the pack states the input size and its error code" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert fixture["maxMarkdownBytes"] == 500_000
    assert fixture["errorCode"] == "markdown_too_large"
    assert Budget.max_bytes() == fixture["maxMarkdownBytes"]
  end

  test "each limits/markdown-input.json case imports or is refused as it says" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert length(fixture["cases"]) == 2

    for %{"name" => name, "markdown" => markdown, "expect" => expect} <- fixture["cases"] do
      markdown = Limits.expand(markdown)

      case expect do
        "imports" ->
          assert match?({:ok, [%{"type" => "paragraph"}], []}, FromMarkdown.read(markdown)), name

        %{"error" => code} ->
          assert FromMarkdown.read(markdown) == {:error, String.to_existing_atom(code)}, name
      end
    end
  end

  test "input over the size is refused before any parsing" do
    markdown = repeat("[", Budget.max_bytes() + 1)

    {:reductions, before} = Process.info(self(), :reductions)
    assert FromMarkdown.read(markdown) == {:error, :markdown_too_large}
    {:reductions, later} = Process.info(self(), :reductions)
    assert later - before < 10_000

    # A display caller shows the refused text unparsed, as one code block.
    assert FromMarkdown.blocks(markdown) == [%{"type" => "code", "value" => markdown}]
  end

  test "each worst input of 100 KB is stopped as too costly, inside the CPU bound" do
    for unit <- ["[", "<a b ", "word **bold** [l](https://example.com) `c`\n"] do
      markdown = repeat(unit, 100_000)
      {cpu, result} = cpu_ms(fn -> FromMarkdown.read(markdown) end)

      assert result == {:error, :markdown_too_costly}, inspect(unit)
      assert cpu < @cpu_bound_ms, "#{inspect(unit)}: #{cpu} ms"
    end
  end

  test "an import whose heap passes the cap is refused as too costly, not crashed" do
    markdown = ordinary(div(Budget.max_bytes(), 10))
    assert {:ok, _blocks, []} = FromMarkdown.read(markdown)

    assert FromMarkdown.read(markdown, max_heap_words: 100_000) ==
             {:error, :markdown_too_costly}
  end

  test "an ordinary document of the full input size imports in a ninth of the budget" do
    markdown = ordinary(Budget.max_bytes())
    assert byte_size(markdown) == Budget.max_bytes()

    assert {:ok, blocks, []} = FromMarkdown.read(markdown)
    assert length(blocks) > 5_000

    work = FromMarkdown.read(markdown, max_reductions: div(Budget.max_reductions(), 9))
    assert work == {:ok, blocks, []}, "needs more than a ninth of the reductions"

    heap = FromMarkdown.read(markdown, max_heap_words: div(Budget.max_heap_words(), 9))
    assert heap == {:ok, blocks, []}, "needs more than a ninth of the heap"
  end
end
