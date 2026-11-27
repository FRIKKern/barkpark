defmodule Barkpark.Content.Forms.HtmlBody do
  @moduledoc """
  A top-level rich text the store holds as an HTML string, read under the
  write lock (task-bb19ab06ab1e87b2).

  A `body` or `blocks` richText with no `format` and no block editor is
  read by its stored value (`RichTextFormat`, `:legacy`). Written first into
  an empty field, it is stored as the posted HTML, and every later save
  writes HTML again. Under the lock it is read as a block body is: a post
  typed on a page that showed the store is written as posted; one typed on
  a value the store no longer holds keeps the store, and A is held. It is
  never merged: a merge gives blocks, and the stored string stays a string.
  """

  alias Barkpark.Content.PortableText
  alias Barkpark.Content.PortableTextMerge
  alias Barkpark.Content.RichTextFormat

  @doc """
  Whether `field`'s stored value `stored` is read this way: a richText
  whose format the stored value decides (`RichTextFormat`, `:legacy`),
  holding an HTML string or nothing. Written first into nothing, it is
  stored as the posted HTML.
  """
  def field?(%{"type" => "richText"} = field, stored) when is_binary(stored) or is_nil(stored),
    do: RichTextFormat.format(field) == :legacy

  def field?(_field, _stored), do: false

  @doc """
  Whether two values of the field draw the same: equal strings first, then
  the blocks the editor draws them as (`PortableText.from_html/1`). An HTML
  string and stored blocks compare by their blocks. nil draws as empty.
  """
  def same?(a, b) when is_binary(a) and is_binary(b) and a == b, do: true
  def same?(a, b), do: PortableTextMerge.same_drawn?(blocks(a), blocks(b))

  @doc "The blocks a value of the field draws: an HTML string read back, blocks as they are."
  def blocks(html) when is_binary(html), do: PortableText.from_html(html)
  def blocks(value) when is_list(value), do: value
  def blocks(_value), do: []

  @doc """
  What the write stores for an HTML post `mine`, read against `was` (what
  the page showed; `:unknown` after a rejoin) and `theirs` (the store under
  the lock): `mine` when the page showed the store or the post draws the
  store, else `theirs`, as stored.
  """
  def rebase(mine, theirs, was) do
    if same?(mine, theirs) or (was != :unknown and same?(was, theirs)),
      do: mine,
      else: theirs
  end

  @doc """
  Whether a written HTML post `posted` left A's words off the store: the
  store before the write (`before`) is not what the page showed (`was`),
  and the post draws neither of them.
  """
  def held?(posted, before, was) do
    not same?(posted, before) and
      (was == :unknown or (not same?(was, before) and not same?(posted, was)))
  end
end
