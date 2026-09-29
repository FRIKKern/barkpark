defmodule Barkpark.Content.Papers.PreGateRegister do
  @moduledoc """
  The READ side of the 2026-09-02 grandfather ruling (task-597ea451072da061):
  the 38 Papers that published before the block gate existed and whose stored
  blocks the gate would refuse today keep serving, must pass the gate on their
  next edit, and wear one quiet badge until then.

  ## One register, no second list

  Membership is read from `tooling/pds/pre-gate-papers.json` — the register PR
  #15234 introduces and the ratchet (`scripts/pds-pre-gate-papers-check.sh`)
  guards. This module never carries an id of its own: the JSON is the only
  source, and `pre_gate_register_test.exs` scans `lib/` to prove no `.ex`
  file names a register id.

  ## Loaded at compile time, on purpose

  The JSON is embedded with `@external_resource` + `File.read!/1` at compile,
  not read per request and not cached at runtime:

    * the release the server runs is built from `api/` and ships no `tooling/`
      directory, so a runtime read would ALWAYS miss in a release while passing
      every `mix test` — the release-only failure shape. Embedding at compile
      is the only loader that works where the reader actually runs;
    * the register changes only through a PR (the ratchet forbids growth; a
      heal is a register EDIT); `@external_resource` recompiles this module
      when the file changes, which is exactly that cadence;
    * the reader never stats the file.

  Before #15234 lands the file is absent on `main`: the module compiles to an
  EMPTY register with a compile-time warning, so the reader keeps serving and
  the focused test (which requires the file) is the tripwire, not the build.

  ## The badge reads state, it never stores it

  `badge/2` requires BOTH register membership AND a still-refused recheck
  through the real gate predicate (`BlockOps.normalize_render_shapes/1` then
  `BlockOps.validate_render_shapes/1`, the same pair
  `Lifecycle.prepare_paper_render_shapes/2` runs on the blocks
  `Projection.read_blocks/1` locates). A Paper healed by a passing edit drops
  the badge with no register edit; a register id whose blocks already pass
  never shows it. The badge rides the render path as ONE synthesised block
  (`"type" => "pre-gate-badge"`, never stored) inserted by `annotate/3` below
  the masthead byline — the public reader and the Studio paper view both feed
  their block streams through it, so there is one emitter and no parallel
  producer.
  """

  alias Barkpark.Content
  alias Barkpark.Content.Papers.BlockOps

  @register_path Path.expand("../../../../../tooling/pds/pre-gate-papers.json", __DIR__)
  @external_resource @register_path

  @register (if File.exists?(@register_path) do
               Jason.decode!(File.read!(@register_path))
             else
               IO.warn(
                 "pre-gate register absent at #{@register_path} — the pre-gate badge is " <>
                   "disabled until tooling/pds/pre-gate-papers.json (PR #15234) is present"
               )

               %{"papers" => [], "classes" => []}
             end)

  @classes Map.new(Map.get(@register, "classes", []), &{Map.get(&1, "class"), &1})

  @entries Map.new(Map.get(@register, "papers", []), fn paper ->
             class = Map.get(@classes, Map.get(paper, "class"), %{})

             {Map.get(paper, "id"),
              %{
                id: Map.get(paper, "id"),
                class: Map.get(paper, "class"),
                reader_impact: Map.get(paper, "reader_impact") || Map.get(class, "reader_impact"),
                reader_behaviour: Map.get(class, "reader_behaviour"),
                error_count: Map.get(paper, "error_count"),
                first_error: Map.get(paper, "first_error")
              }}
           end)

  @ruling_date get_in(@register, ["ruling", "date"])

  @badge_type "pre-gate-badge"
  @badge_block_id "pre-gate-badge"

  # Plain sentence case, one line. The register's own measurement says 37 of
  # the 38 render CORRECTLY today (reader_impact "none"), so the copy must not
  # promise missing content it cannot point at; the one Paper that does lose a
  # header (reader_impact "blank_header_cell") says so, and takes the warn tone.
  @label_none "Published before the block gate"
  @label_blank_header "Published before the block gate · one table header renders empty"

  @doc "The synthesised block type the badge rides as. Never stored."
  def badge_type, do: @badge_type

  @doc "Absolute path of the register this module was compiled from."
  def register_path, do: @register_path

  @doc "True when the register file was present at compile time."
  def loaded?, do: map_size(@entries) > 0

  @doc "The ruling date recorded in the register, or nil before #15234."
  def ruling_date, do: @ruling_date

  @doc "Every grandfathered Paper id, as a MapSet."
  def ids, do: @entries |> Map.keys() |> MapSet.new()

  @doc """
  The register entry for a Paper id (draft ids resolve to their published id),
  with its class's `reader_impact` / `reader_behaviour` joined in. `nil` when the
  id is not grandfathered.
  """
  @spec entry(String.t() | nil) :: map() | nil
  def entry(paper_id) when is_binary(paper_id),
    do: Map.get(@entries, Content.published_id(paper_id))

  def entry(_), do: nil

  @doc "Register membership alone — NOT the badge rule (see `badge/2`)."
  def grandfathered?(paper_id), do: entry(paper_id) != nil

  @doc """
  The badge a Paper should wear, or `nil`.

  `gate_blocks` is the STORED block list (`Projection.read_blocks/1` of the
  content the gate would read), never a resolved/expanded one — the recheck must
  answer the same question the publish gate answers. Both conditions must hold:
  the id is in the register AND the gate still refuses these blocks.
  """
  @spec badge(String.t() | nil, list() | nil) :: map() | nil
  def badge(paper_id, gate_blocks) do
    with %{} = entry <- entry(paper_id),
         true <- still_refused?(gate_blocks) do
      %{
        label: label(entry.reader_impact),
        title: entry.reader_behaviour || @label_none,
        tone: tone(entry.reader_impact),
        reader_impact: entry.reader_impact
      }
    else
      _ -> nil
    end
  end

  @doc """
  Insert the badge block into `blocks` (the list about to be rendered) when
  `badge/2` says the Paper wears one; otherwise return `blocks` unchanged.

  Anchor: directly after the masthead `byline` block (the first byline that
  precedes any level-2+ heading); a Paper with no byline anchors after its first
  level-1 heading; a Paper with neither gets it first. Only the byline anchor
  tucks the badge up under the byline's rule (`"anchor" => "byline"`), so the
  CSS pull-up never fights a heading's margin.
  """
  @spec annotate(list(), String.t() | nil, list() | nil) :: list()
  def annotate(blocks, paper_id, gate_blocks \\ nil)

  def annotate(blocks, paper_id, gate_blocks) when is_list(blocks) do
    case badge(paper_id, gate_blocks || blocks) do
      nil -> blocks
      badge -> insert_badge(blocks, badge)
    end
  end

  def annotate(blocks, _paper_id, _gate_blocks), do: blocks

  @doc "The synthesised block for a badge map (public so the rig can render one)."
  def badge_block(%{label: label, title: title, tone: tone} = badge) do
    %{
      "type" => @badge_type,
      "id" => @badge_block_id,
      "label" => label,
      "title" => title,
      "tone" => tone,
      "anchor" => Map.get(badge, :anchor, "byline")
    }
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp still_refused?(blocks) when is_list(blocks) do
    blocks
    |> BlockOps.normalize_render_shapes()
    |> BlockOps.validate_render_shapes()
    |> case do
      :ok -> false
      {:error, _} -> true
    end
  end

  # No readable block list: nothing for the gate to refuse, nothing to badge.
  defp still_refused?(_), do: false

  defp label("blank_header_cell"), do: @label_blank_header
  defp label(_), do: @label_none

  defp tone("blank_header_cell"), do: "warning"
  defp tone(_), do: "neutral"

  defp insert_badge(blocks, badge) do
    {anchor, index} = anchor(blocks)
    block = badge_block(Map.put(badge, :anchor, anchor))
    List.insert_at(blocks, index, block)
  end

  # `{anchor_kind, insert_index}` — see `annotate/3`.
  defp anchor(blocks) do
    indexed = Enum.with_index(blocks)

    byline_idx = find_index(indexed, &(type(&1) == "byline"))
    section_idx = find_index(indexed, &(type(&1) == "heading" and level(&1) >= 2))
    title_idx = find_index(indexed, &(type(&1) == "heading" and level(&1) == 1))

    cond do
      byline_idx != nil and (section_idx == nil or byline_idx < section_idx) ->
        {"byline", byline_idx + 1}

      title_idx != nil ->
        {"heading", title_idx + 1}

      true ->
        {"top", 0}
    end
  end

  defp find_index(indexed, pred) do
    Enum.find_value(indexed, fn {block, index} -> if pred.(block), do: index end)
  end

  defp type(%{"type" => type}) when is_binary(type), do: type
  defp type(_), do: nil

  defp level(%{"level" => level}) when level in [1, 2, 3], do: level

  defp level(%{"level" => level}) when is_binary(level) do
    case Integer.parse(level) do
      {n, ""} -> n
      _ -> 2
    end
  end

  defp level(_), do: 2
end
