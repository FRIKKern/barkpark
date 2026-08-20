defmodule Barkpark.Content.Papers.Hollow do
  @moduledoc """
  The paper hollow-body predicate — the authoring quality gate's ONE truth
  (epic p-quality-gate, charter D3).

  A paper is **hollow** when its body carries nothing beyond the enforced
  title/featured SKELETON — no real content block an author actually wrote.
  Hollow published papers are refused at every write seam; the seams share
  this predicate and the ratified copy below, so Studio, Bulldocs ingest,
  mutate/SDK/CLI/MCP writers all hit the SAME truth.

  ## The predicate (charter D3 — do not relitigate)

  **Skeleton** blocks (never content, whatever they carry):

    * `"locked" => true` blocks (the template's enforced structure);
    * blocks with `role` `"title"` or `"featured"` (locked or not);
    * block 0 when it is a heading — the de-facto title of the un-migrated
      role-less corpus (0/78 live papers carry locked/role blocks, so a
      purely locked-keyed skeleton would gate nothing that exists).

  **Content** is any non-skeleton block that is:

    * a TEXT-BEARING type (paragraph/heading/list/quote/…) whose recursively
      flattened text contains a Unicode letter, number, or symbol — whitespace
      and punctuation-only placeholders never count (`maybe_seed` gives every
      fresh paper an empty `tpl-body` paragraph, so block-COUNT predicates are
      wrong both ways); or
    * any other (inherently non-text) type with a REAL payload — an image
      with a `src`, a table with rows, code with source, a diagram, a sheet
      ref, a task-list query… An empty ghost (e.g. `{"type":"image"}` with a
      blank `src`) does not count. Unknown/fleet block types err on the side
      of NOT hollow: any substantive payload counts, so the gate can never
      brick a real save of a block type it has not met.

  `divider` never counts. Docs with no `blocks` list (body_html-only,
  pre-doctrine) are EXEMPT — `hollow?/1` returns `false` for any non-list.

  ## The ratified copy (shared by every seam)

    * `message/0` — the hard stop for a hollow published-surface write.
    * `ratchet_message/0` — the canvas ratchet: an edit may not hollow OUT a
      paper that had content (fresh hollow papers stay freely editable).
  """

  @message "This paper has a title but no content yet — add at least one body block."
  @ratchet_message "This edit would remove the last content block — a published paper cannot be hollowed out to title-only."

  # Block types whose contribution is their TEXT: they count as content only
  # when the recursively-flattened trimmed text is non-blank.
  @text_types ~w(paragraph heading list quote pullquote callout note ingress eyebrow byline)

  # Keys that are STRUCTURE, never payload, on a non-text block (at every
  # nesting level). Everything else non-blank counts as real payload.
  @structural_keys ~w(id type role locked style level lang language)

  # The string keys that carry visible text, and the containers to recurse
  # through when flattening a text-bearing block.
  @text_keys ~w(text value title caption)
  @container_keys ~w(content items blocks children)

  @doc "The ratified hard-stop copy for a hollow published-surface write."
  @spec message() :: String.t()
  def message, do: @message

  @doc "The ratified ratchet copy — an edit may not hollow out a real paper."
  @spec ratchet_message() :: String.t()
  def ratchet_message, do: @ratchet_message

  @doc """
  Whether a block list is skeleton-only. Non-lists (an HTML-only/pre-doctrine
  doc with no `blocks`) are exempt and return `false`.
  """
  @spec hollow?(term()) :: boolean()
  def hollow?(blocks) when is_list(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.all?(fn {block, index} -> not content_block?(block, index) end)
  end

  def hollow?(_no_blocks_list), do: false

  @doc "Whether visible prose contains a letter, number, or semantic symbol."
  @spec semantic_text?(term()) :: boolean()
  def semantic_text?(text) when is_binary(text),
    do: Regex.match?(~r/[\p{L}\p{N}\p{S}]/u, text)

  def semantic_text?(_), do: false

  # ── internals ──────────────────────────────────────────────────────────

  defp content_block?(block, index) when is_map(block) do
    not skeleton?(block, index) and substantive?(block)
  end

  defp content_block?(_block, _index), do: false

  defp skeleton?(block, index) do
    Map.get(block, "locked") == true or
      role_of(block) in ["title", "featured"] or
      (index == 0 and Map.get(block, "type") == "heading")
  end

  defp role_of(%{"role" => role}) when is_binary(role), do: role
  defp role_of(_), do: nil

  # divider never counts; text-bearing types count on semantic flattened text;
  # every other type counts on any substantive (non-structural) payload.
  defp substantive?(%{"type" => "divider"}), do: false

  # Image dimensions and editor metadata are not reader content. The renderer
  # deliberately emits nothing for an image without an asset, so the quality
  # gate must require the same real `src` payload instead of accepting width,
  # height, or booleans that never reach a reader.
  defp substantive?(%{"type" => "image"} = block) do
    case Map.get(block, "src") do
      src when is_binary(src) -> String.trim(src) != ""
      _ -> false
    end
  end

  defp substantive?(%{"type" => type} = block) when type in @text_types,
    do: any_text?(block)

  defp substantive?(block), do: payload?(block)

  # Recursively flatten a text-bearing block: a bare binary item (legacy flat
  # list items), the @text_keys of any map, and the @container_keys recursed.
  defp any_text?(text) when is_binary(text), do: semantic_text?(text)
  defp any_text?(list) when is_list(list), do: Enum.any?(list, &any_text?/1)

  defp any_text?(%{} = node) do
    Enum.any?(@text_keys, fn key ->
      case Map.get(node, key) do
        text when is_binary(text) -> semantic_text?(text)
        _ -> false
      end
    end) or
      Enum.any?(@container_keys, fn key ->
        case Map.get(node, key) do
          children when is_list(children) -> any_text?(children)
          _ -> false
        end
      end)
  end

  defp any_text?(_), do: false

  # A non-text block has real payload when anything OUTSIDE the structural
  # keys is substantive: a non-blank string, any number/boolean (chart data,
  # sheet tabs), or a list/map holding one. Structural keys are stripped at
  # every nesting level so `{"type":"text","value":"  "}` inline nodes and
  # nested skeleton-ish maps never count by their type strings.
  defp payload?(block) do
    block
    |> Map.drop(@structural_keys)
    |> Map.values()
    |> Enum.any?(&substantive_value?/1)
  end

  defp substantive_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp substantive_value?(value) when is_number(value), do: true
  defp substantive_value?(value) when is_boolean(value), do: true
  defp substantive_value?(list) when is_list(list), do: Enum.any?(list, &substantive_value?/1)

  defp substantive_value?(%{} = map) do
    map
    |> Map.drop(@structural_keys)
    |> Map.values()
    |> Enum.any?(&substantive_value?/1)
  end

  defp substantive_value?(_), do: false
end
