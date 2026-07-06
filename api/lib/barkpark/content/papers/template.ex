defmodule Barkpark.Content.Papers.Template do
  @moduledoc """
  The PortableDoc body template — the content-first doctrine's enforcement core
  (paper `portabledoc-doctrine`, tasks pdd-t1/t3/t4).

  Structure is guaranteed by ENFORCED BLOCKS, not fields: a new paper opens as a
  document — a locked `role: "title"` heading at block 0 and a locked
  `role: "featured"` image at block 1 — never a blank form. This module owns the
  three server truths:

    * `maybe_seed/2` — seed the forced initial block set on a BRAND-NEW paper
      whose caller provided no blocks (the Beta canvas' new-doc path), or when
      the caller opts in with `"template" => true`. Existing papers and callers
      with explicit blocks are byte-untouched — corpus migration is its own
      task (pdd-t5), never a side effect.
    * `derive_title/2` — `doc.title` IS the locked title block's text (one
      truth, no second field to drift). Fires only when a `role: "title"` block
      exists, so legacy papers keep their row title.
    * `validate/1` — the `before_save` gate half (wired by the Bulldocs
      plugin): a doc that carries locked blocks must keep the template shape —
      exactly one `role: "title"` heading and it sits at block 0; a
      `role: "featured"` block sits at block 1. Papers with no locked blocks
      pass untouched (additive enforcement).

  The op-level backstop lives in `Barkpark.PortableDoc.Patch`: a `remove-block`
  or `move-block` targeting a `"locked" => true` block is rejected, and
  `patch-block` cannot strip `locked` — so no client, canvas or raw API, can
  unmake the guarantee.
  """

  @title_role "title"
  @featured_role "featured"

  @doc """
  The template re-expressed as the CONSTRAINT VOCABULARY (pdd-t20) — the SAME shape
  the editor consumes as ghost slots + a calm client veto (canvas/constraints.js),
  JSON-encoded onto the canvas host as `data-constraints`.

  Each DECLARATION is `{kind, role, presence, count, position, locked}`:

    * `presence` — `"required"` | `"optional"`.
    * `count` — `%{"exactly" => n}` | `%{"min" => n}` | `%{"max" => n}`.
    * `position` — `"top"` (block 0) | `%{"after" => kind, "before" => kind}`
      (a relative order rule; either key optional).
    * `locked` — whether a materialized instance is a template-locked block.

  The current template, byte-compatibly: the title is required, exactly one, at the
  top, locked; the ingress is optional, at most one, after the title and before the
  featured; the featured image is optional, at most one, after the title, locked.
  Only the REQUIRED minimum is seeded at birth (`maybe_seed/2` seeds the title);
  the optionals are offered as ghost affordances in their enforced place and
  MATERIALIZE on use — absent, never an empty husk. Additive (D3): declarations are
  read only for docs that already carry locked blocks.
  """
  @spec paper_declarations() :: [map()]
  def paper_declarations do
    [
      %{
        "kind" => @title_role,
        "role" => @title_role,
        "presence" => "required",
        "count" => %{"exactly" => 1},
        "position" => "top",
        "locked" => true
      },
      %{
        "kind" => "ingress",
        "role" => "ingress",
        "presence" => "optional",
        "count" => %{"max" => 1},
        "position" => %{"after" => @title_role, "before" => @featured_role},
        "locked" => false
      },
      %{
        "kind" => @featured_role,
        "role" => @featured_role,
        "presence" => "optional",
        "count" => %{"max" => 1},
        "position" => %{"after" => @title_role},
        "locked" => true
      }
    ]
  end

  @doc "The forced initial block set: locked title heading + locked featured image."
  @spec template_blocks(String.t() | nil) :: [map()]
  def template_blocks(title) do
    [
      %{
        "id" => "tpl-title",
        "type" => "heading",
        "level" => 1,
        "role" => @title_role,
        "locked" => true,
        "text" => to_string(title || "")
      },
      %{
        "id" => "tpl-featured",
        "type" => "image",
        "role" => @featured_role,
        "locked" => true
      }
    ]
  end

  @doc """
  Seed the template on a brand-new paper. Fires when the doc is NEW and either
  (a) the caller provided no/empty blocks, or (b) attrs opt in with
  `"template" => true` and no title block exists yet. Never touches an existing
  doc or a caller's explicit block list.
  """
  @spec maybe_seed(term(), term(), map()) :: term()
  def maybe_seed(blocks, existing, attrs)

  def maybe_seed(blocks, nil, attrs) do
    cond do
      # An explicit empty block list = "a new blank document" (the canvas'
      # new-doc path). A nil `blocks` is the HTML-only ingest path — untouched.
      blocks == [] ->
        template_blocks(attrs["title"]) ++ [empty_paragraph()]

      is_list(blocks) and attrs["template"] == true and not has_role?(blocks, @title_role) ->
        template_blocks(attrs["title"]) ++ blocks

      true ->
        blocks
    end
  end

  def maybe_seed(blocks, _existing, _attrs), do: blocks

  @doc """
  Derive the row title from the locked title block's text — additive: returns
  `attrs` untouched when the blocks carry no `role: "title"` block.
  """
  @spec derive_title(map(), term()) :: map()
  def derive_title(attrs, blocks) when is_list(blocks) do
    case Enum.find(blocks, &(role_of(&1) == @title_role)) do
      %{"text" => text} when is_binary(text) and text != "" ->
        Map.put(attrs, "title", text)

      _ ->
        attrs
    end
  end

  def derive_title(attrs, _blocks), do: attrs

  @doc """
  Template papers are ARTICLE papers (doctrine rule 3 — 100% parity): the
  canvas paints every block through the `:article` producer, so a paper whose
  body carries the locked title must ALSO read as `:article` publicly, or the
  reader's legacy bold-span heading diverges from the canvas' real `<h1>`
  (found live, pdd-t15). Additive: an explicit caller style always wins, and
  papers with no title block (the legacy corpus) keep their bytes (D3/D6).
  """
  @spec stamp_article_style(map(), term()) :: map()
  def stamp_article_style(attrs, blocks) when is_list(blocks) do
    if is_binary(attrs["style"]) or not has_role?(blocks, @title_role) do
      attrs
    else
      Map.put(attrs, "style", "article")
    end
  end

  def stamp_article_style(attrs, _blocks), do: attrs

  @doc """
  The gate half: template-shape errors for a locked-carrying block list.
  Returns `[]` for a valid doc AND for any doc with no locked blocks.
  """
  @spec validate(term()) :: [String.t()]
  def validate(blocks) when is_list(blocks) do
    if Enum.any?(blocks, &locked?/1) do
      title_errors(blocks) ++ featured_errors(blocks)
    else
      []
    end
  end

  def validate(_), do: []

  defp title_errors(blocks) do
    case Enum.with_index(blocks) |> Enum.filter(fn {b, _} -> role_of(b) == @title_role end) do
      [{%{"type" => "heading"}, 0}] ->
        []

      [] ->
        ["template: the locked title block is missing (a paper opens with its title at block 0)"]

      [{%{"type" => "heading"}, idx}] ->
        ["template: the title block must be block 0, found at #{idx}"]

      [{_other, _}] ->
        ["template: the role \"title\" block must be a heading"]

      many ->
        ["template: exactly one title block allowed, found #{length(many)}"]
    end
  end

  defp featured_errors(blocks) do
    case Enum.with_index(blocks) |> Enum.find(fn {b, _} -> role_of(b) == @featured_role end) do
      nil -> []
      {_b, 1} -> []
      {_b, idx} -> ["template: the featured block must be block 1, found at #{idx}"]
    end
  end

  defp empty_paragraph do
    %{"id" => "tpl-body", "type" => "paragraph", "content" => []}
  end

  defp has_role?(blocks, role), do: Enum.any?(blocks, &(role_of(&1) == role))

  defp role_of(%{"role" => role}) when is_binary(role), do: role
  defp role_of(_), do: nil

  @doc "Whether a block is template-locked."
  @spec locked?(term()) :: boolean()
  def locked?(%{"locked" => true}), do: true
  def locked?(_), do: false
end
