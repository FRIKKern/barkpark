defmodule Barkpark.Content.Papers.EpicQuality do
  @moduledoc """
  The publish-time editorial floor for canonical Epic Cycle Papers.

  The contract is intentionally tag-scoped: only Papers carrying the exact
  `epic-cycle-wave-paper` tag are gated. Other Papers retain the general
  hollow-body and reader-shape laws.

  This gate measures editorial composition rather than ornamental block count.
  A canonical Epic Paper must have a real opening, one coherent outline, a
  bounded first-pass reading load, semantic tables and procedures, and no
  exact empty scaffolds. Long-form evidence remains welcome behind a collapsed
  `expandable`, following the canonical reference Paper's appendix treatment.
  When a producer declares a `reader_checks` suite, every required reader must
  pass; revision-pinned reader evidence is still sealed after publication.
  """

  @canonical_tag "epic-cycle-wave-paper"
  @opening_window 8
  @max_primary_words 5_000
  @max_top_level_blocks 80
  @max_top_level_headings 16
  @max_step_title_words 16
  @orientation_types ~w(byline stats toc list steps)
  @required_readers ~w(public studio tui80 email cli_api)
  @text_keys ~w(alt blocks caption children content description head items label lead rows steps subtitle summary text title value)
  @nested_keys ~w(blocks children columns content items panels rows sections steps tabs)
  @intrinsically_meaningful_types ~w(audio callout code divider embed figure gallery image quote sheet video)

  @type failure ::
          :blocks_not_array
          | :empty_paragraph_spacer
          | :empty_step_body
          | :hollow
          | :micro_only
          | :opening_missing_h1
          | :opening_missing_ingress
          | :opening_missing_orientation
          | :overloaded_step_title
          | :outline_heading_level_jump
          | :outline_requires_one_h1
          | :primary_reading_load_exceeded
          | :table_missing_header
          | :top_level_block_overload
          | :top_level_heading_overload
          | {:reader_check_failed, String.t()}

  @doc "The exact cohort tag guarded by this publish-time editorial floor."
  @spec canonical_tag() :: String.t()
  def canonical_tag, do: @canonical_tag

  @doc "The five reader names accepted by a declared publish-time check suite."
  @spec required_readers() :: [String.t()]
  def required_readers, do: @required_readers

  @doc """
  Validate a Paper content map.

  Untagged content is a byte-identical no-op. Tagged content returns the stable
  `{:invalid_epic_paper_quality, details}` error consumed by the shared publish
  wall and public error envelope.
  """
  @spec validate(term()) :: :ok | {:error, {:invalid_epic_paper_quality, map()}}
  def validate(content) when is_map(content) do
    if canonical?(content) do
      failures = failures(content)

      if failures == [] do
        :ok
      else
        {:error,
         {:invalid_epic_paper_quality,
          %{
            "tag" => @canonical_tag,
            "failures" => Enum.map(failures, &failure_name/1),
            "required_readers" => @required_readers
          }}}
      end
    else
      :ok
    end
  end

  def validate(_content), do: :ok

  @doc "Return the deterministic hard failures for a canonical candidate."
  @spec failures(map()) :: [failure()]
  def failures(content) when is_map(content) do
    raw_blocks = Map.get(content, "blocks")
    blocks = if is_list(raw_blocks), do: raw_blocks, else: []
    meaningful = Enum.reject(blocks, &(empty_paragraph?(&1) or not meaningful?(&1)))
    visible_words = word_count(blocks)

    []
    |> maybe_add(not is_list(raw_blocks), :blocks_not_array)
    |> maybe_add(meaningful == [] or visible_words == 0, :hollow)
    |> maybe_add(meaningful != [] and length(meaningful) < 3, :micro_only)
    |> maybe_add(Enum.any?(walk_maps(blocks), &empty_paragraph?/1), :empty_paragraph_spacer)
    |> add_opening_failures(meaningful)
    |> add_outline_failures(blocks)
    |> add_composition_failures(blocks)
    |> add_reader_failures(Map.get(content, "reader_checks"))
    |> Enum.uniq()
    |> Enum.sort_by(&failure_name/1)
  end

  defp canonical?(content) do
    content
    |> Map.get("tags", [])
    |> List.wrap()
    |> Enum.any?(fn
      @canonical_tag -> true
      %{"tag" => @canonical_tag} -> true
      _ -> false
    end)
  end

  defp add_opening_failures(failures, meaningful) do
    opening = Enum.take(meaningful, @opening_window)
    types = MapSet.new(Enum.map(opening, &Map.get(&1, "type")))

    failures
    |> maybe_add(
      not Enum.any?(opening, &(Map.get(&1, "type") == "heading" and Map.get(&1, "level") == 1)),
      :opening_missing_h1
    )
    |> maybe_add(not MapSet.member?(types, "ingress"), :opening_missing_ingress)
    |> maybe_add(
      not Enum.any?(@orientation_types, &MapSet.member?(types, &1)),
      :opening_missing_orientation
    )
  end

  defp add_outline_failures(failures, blocks) do
    levels =
      for %{"type" => "heading", "level" => level} <- blocks,
          is_integer(level),
          do: level

    failures
    |> maybe_add(Enum.count(levels, &(&1 == 1)) != 1, :outline_requires_one_h1)
    |> maybe_add(
      levels
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [previous, current] -> current > previous + 1 end),
      :outline_heading_level_jump
    )
  end

  defp add_composition_failures(failures, blocks) do
    nested = walk_maps(blocks)

    failures
    |> maybe_add(
      blocks |> first_pass_blocks() |> word_count() > @max_primary_words,
      :primary_reading_load_exceeded
    )
    |> maybe_add(length(blocks) > @max_top_level_blocks, :top_level_block_overload)
    |> maybe_add(
      Enum.count(blocks, &(is_map(&1) and Map.get(&1, "type") == "heading")) >
        @max_top_level_headings,
      :top_level_heading_overload
    )
    |> maybe_add(Enum.any?(nested, &empty_step_body?/1), :empty_step_body)
    |> maybe_add(Enum.any?(nested, &overloaded_step_title?/1), :overloaded_step_title)
    |> maybe_add(Enum.any?(nested, &headerless_table?/1), :table_missing_header)
  end

  defp add_reader_failures(failures, nil), do: failures

  defp add_reader_failures(failures, checks) when is_map(checks) do
    Enum.reduce(@required_readers, failures, fn reader, acc ->
      maybe_add(
        acc,
        Map.get(checks, reader) not in [true, "pass"],
        {:reader_check_failed, reader}
      )
    end)
  end

  defp add_reader_failures(failures, _invalid), do: [{:reader_check_failed, "suite"} | failures]

  defp maybe_add(failures, true, failure), do: [failure | failures]
  defp maybe_add(failures, false, _failure), do: failures

  defp failure_name({:reader_check_failed, reader}), do: "reader_#{reader}_failed"
  defp failure_name(failure), do: Atom.to_string(failure)

  defp meaningful?(block) when is_map(block) do
    plain_text(block) != "" or Map.get(block, "type") in @intrinsically_meaningful_types
  end

  defp meaningful?(_block), do: false

  defp empty_paragraph?(%{"type" => "paragraph"} = block) do
    content = Map.get(block, "content")
    text = Map.get(block, "text")
    content in [nil, []] and not (is_binary(text) and String.trim(text) != "")
  end

  defp empty_paragraph?(_block), do: false

  defp empty_step_body?(%{"type" => "steps", "steps" => steps}) when is_list(steps) do
    Enum.any?(steps, fn
      %{} = step ->
        title_words = word_count(Map.get(step, "title", ""))
        blocks = Map.get(step, "blocks")

        title_words == 0 or
          (title_words > @max_step_title_words and
             (not is_list(blocks) or not Enum.any?(blocks, &meaningful?/1)))

      _ ->
        false
    end)
  end

  defp empty_step_body?(_block), do: false

  defp overloaded_step_title?(%{"type" => "steps", "steps" => steps}) when is_list(steps) do
    Enum.any?(steps, fn
      %{} = step -> word_count(Map.get(step, "title", "")) > @max_step_title_words
      _ -> false
    end)
  end

  defp overloaded_step_title?(_block), do: false

  defp headerless_table?(%{"type" => "table", "rows" => rows} = block)
       when is_list(rows) and rows != [] do
    head = Map.get(block, "head")
    not (is_list(head) and head != [])
  end

  defp headerless_table?(_block), do: false

  defp first_pass_blocks(blocks) do
    Enum.reject(blocks, fn
      %{"type" => "expandable"} = block -> Map.get(block, "open") != true
      _ -> false
    end)
  end

  defp word_count(value), do: value |> plain_text() |> String.split() |> length()

  defp plain_text(value) when is_binary(value), do: String.trim(value)

  defp plain_text(value) when is_list(value) do
    value
    |> Enum.map(&plain_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp plain_text(value) when is_map(value) do
    @text_keys
    |> Enum.map(&Map.get(value, &1))
    |> Enum.map(&plain_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp plain_text(_value), do: ""

  defp walk_maps(value) when is_list(value), do: Enum.flat_map(value, &walk_maps/1)

  defp walk_maps(value) when is_map(value) do
    nested =
      @nested_keys
      |> Enum.map(&Map.get(value, &1))
      |> Enum.flat_map(&walk_maps/1)

    [value | nested]
  end

  defp walk_maps(_value), do: []
end
