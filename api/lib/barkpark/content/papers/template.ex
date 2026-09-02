defmodule Barkpark.Content.Papers.Template do
  @moduledoc """
  The PortableDoc paper template — the content-first doctrine's enforcement core
  (paper `portabledoc-doctrine`, tasks pdd-t1/t3/t4/t20).

  Structure is guaranteed by DECLARATIONS, not fields. The paper's declaration set
  (`paper_declarations/0`) is expressed in the generic constraint vocabulary
  (`Barkpark.PortableDoc.Constraints`, pdd-t20):

    * a **required** `role: "title"` heading, exactly one, pinned to block 0,
      locked;
    * an **optional** `role: "featured"` image, at most one, positioned *after* the
      title, locked;
    * an **optional** `role: "ingress"` block, at most one, positioned *after* the
      title and *before* the featured, unlocked.

  A new paper opens as a document — the locked title heading — never a blank form.
  The optional slots (featured, ingress) are ghost affordances the editor offers
  in their enforced place; only the required minimum is seeded at birth (D11). This
  module owns the paper's server truths:

    * `template_blocks/1` — the forced initial block set: just the locked
      `role: "title"` heading (id `tpl-title`). Optional blocks are NOT seeded.
    * `maybe_seed/3` — seed the forced initial set on a BRAND-NEW paper whose
      caller provided no blocks (the Beta canvas' new-doc path), or when the caller
      opts in with `"template" => true`. Existing papers and callers with explicit
      blocks are byte-untouched — corpus migration is its own task (pdd-t5), never
      a side effect.
    * `derive_title/2` — `doc.title` IS the locked title block's text (one truth,
      no second field to drift). Fires only when a `role: "title"` block exists, so
      legacy papers keep their row title.
    * `validate/1` — the `before_save` gate half (wired by the Bulldocs plugin): a
      doc that carries locked blocks must satisfy `paper_declarations/0`. Papers
      with no locked blocks pass untouched (additive enforcement, D3).

  The op-level backstop lives in `Barkpark.PortableDoc.Patch`: a `remove-block` or
  `move-block` targeting a `"locked" => true` block (or an op that would DISPLACE
  one) is rejected, and `patch-block` cannot strip `locked`/`role` — so no client,
  canvas or raw API, can unmake the guarantee.
  """

  alias Barkpark.PortableDoc.Constraints

  @title_role "title"

  @doc """
  The paper's structural declarations, in the generic constraint vocabulary. The
  current template re-expressed byte-compatibly: title required-exactly-1 at block
  0 (locked), featured optional-max-1 after the title (locked), ingress
  optional-max-1 after the title and before the featured (unlocked).
  """
  @spec paper_declarations() :: [Constraints.declaration()]
  def paper_declarations do
    [
      %{
        kind: "title",
        presence: :required,
        count: {:exactly, 1},
        position: [{:index, 0}],
        locked: true
      },
      %{
        kind: "ingress",
        presence: :optional,
        count: {:max, 1},
        position: [{:after, "title"}, {:before, "featured"}],
        locked: false
      },
      %{
        kind: "featured",
        presence: :optional,
        count: {:max, 1},
        position: [{:after, "title"}],
        locked: true
      }
    ]
  end

  @doc """
  The declarations in the JSON WIRE form the editor consumes (pdd-t20c): the SAME
  rules as `paper_declarations/0`, string-keyed and tuple-free so `Jason.encode!`
  can stamp them onto the canvas host as `data-constraints`. `canvas/constraints.js`
  reads `count: {exactly|min|max: N}` and `position: "top" | {after, before}` to
  render ghost slots + a calm client veto. DERIVED from the server declarations so
  the client affordances can never drift from the checker (single source).
  """
  @spec client_declarations() :: [map()]
  def client_declarations do
    Enum.map(paper_declarations(), fn decl ->
      %{
        "kind" => decl.kind,
        "role" => decl.kind,
        "presence" => Atom.to_string(decl.presence),
        "count" => wire_count(decl.count),
        "position" => wire_position(decl.position),
        "locked" => Map.get(decl, :locked, false)
      }
    end)
  end

  defp wire_count({kind, n}) when kind in [:exactly, :min, :max], do: %{Atom.to_string(kind) => n}

  # `[{:index, 0}]` (or a leading top_group) → "top"; before/after relations fold
  # into a single {after, before} object; anything else the client can't express
  # collapses to "top" (the server backstop, t20b, is the real enforcer).
  defp wire_position(position) when is_list(position) do
    rels =
      Enum.reduce(position, %{}, fn
        {:after, kind}, acc -> Map.put(acc, "after", kind)
        {:before, kind}, acc -> Map.put(acc, "before", kind)
        _other, acc -> acc
      end)

    if map_size(rels) > 0, do: rels, else: "top"
  end

  defp wire_position(_), do: "top"

  @doc """
  The forced initial block set: the locked `role: "title"` level-1 heading. The
  optional featured/ingress slots are NOT seeded — they are ghost affordances the
  editor offers in their enforced place (D11).

  THE TITLE ARGUMENT IS CONTENT, NOT CHROME. Whatever the caller passes is
  copied VERBATIM into the heading's `"text"` — it becomes real stored text the
  author must select and delete before typing their own, and `derive_title/2`
  reads it straight back out as `doc.title`. So `nil` (or `""`) is the correct
  argument for a paper born WITHOUT a title: the block starts empty, the editor
  paints its own heading placeholder over it, and every display surface falls
  back with `doc.title || "Untitled"` until the author types.

  A caller must therefore never pass a DISPLAY DEFAULT here. The Studio's
  new-document handler used to pass the literal `"Untitled"`, which seeded that
  word as the title block's text and made the first keystroke append to it —
  see `[untitled-is-a-fallback-not-a-seed]` in
  `BarkparkWeb.Studio.StudioLive.Handlers.Fields`.
  """
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
      # new-doc path): the locked title + an empty body paragraph to type into.
      # A nil `blocks` is the HTML-only ingest path — untouched.
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
  The gate half: declaration-violation errors for a locked-carrying block list.
  Returns `[]` for a valid doc AND for any doc with no locked blocks (additive,
  D3 — legacy papers stay byte-untouched). Delegates the enforcement math to
  `Barkpark.PortableDoc.Constraints`, plus the one paper rule the generic
  vocabulary doesn't carry (declarations have no type axis): the `role: "title"`
  block IS a heading — `derive_title/2` reads its `"text"` and the reader renders
  it as the document `<h1>`.
  """
  @spec validate(term()) :: [String.t()]
  def validate(blocks) when is_list(blocks) do
    if Enum.any?(blocks, &locked?/1) do
      Constraints.validate(blocks, paper_declarations()) ++ title_type_errors(blocks)
    else
      []
    end
  end

  def validate(_), do: []

  defp title_type_errors(blocks) do
    if Enum.any?(blocks, fn b ->
         role_of(b) == @title_role and not match?(%{"type" => "heading"}, b)
       end) do
      [~s(the role "title" block must be a heading)]
    else
      []
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
