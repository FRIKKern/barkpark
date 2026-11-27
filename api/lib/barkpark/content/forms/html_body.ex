defmodule Barkpark.Content.Forms.HtmlBody do
  @moduledoc """
  A top-level rich text the store holds as an HTML string, read under the
  write lock (task-bb19ab06ab1e87b2).

  A Portable Text richText the store holds as a string is read the same
  way (`stored_string?/2`): its post is blocks, and the string is kept or
  written over, never merged.

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
  Whether `stored` is an HTML string in a Portable Text richText: a `/v1`
  write takes a string for one as it is, and an import or an old row leaves
  one (task-49a96a7780dad558). Read as `field?/2`'s are, under the lock: a
  post typed on that string is written, as blocks (owner ruling #44 turns a
  stored string into blocks at the next save); one typed on another value
  leaves the string as stored, never merged or converted, and A is held.
  "Typed on that string" is the exact string (`string_held?/2`), never the
  drawing: `PortableText.from_html/1` drops markup the editor does not draw.
  """
  def stored_string?(%{"type" => "richText"} = field, stored) when is_binary(stored),
    do: RichTextFormat.format(field) == :portable_text

  def stored_string?(_field, _stored), do: false

  @doc """
  Whether a post on a `stored_string?/2` field is held: the page showed
  (`was`, `:unknown` after a rejoin) another value than the string the store
  held before the write (`before`), compared exactly (#29116 r1).
  """
  def string_held?(before, was), do: was !== before

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
  Whether two values of the field are the same stored value: two strings
  by their bytes, anything else as `same?/2` draws it (nothing and "", a
  hold's blocks). An image, an iframe or a class that `from_html/1` drops
  is a change of the string (task-62e3d093b98a3bc3, as #29116 r2 reads a
  `stored_string?/2` field).
  """
  def exact?(a, b) when is_binary(a) and is_binary(b), do: a === b
  def exact?(a, b), do: same?(a, b)

  @doc """
  What the write stores for an HTML post `mine`, read against `was` (what
  the page showed; `:unknown` after a rejoin) and `theirs` (the store under
  the lock): `mine` when the page showed the store or the post is it
  (`exact?/2`), else `theirs`, as stored.
  """
  def rebase(mine, theirs, was) do
    if exact?(mine, theirs) or (was != :unknown and exact?(was, theirs)),
      do: mine,
      else: theirs
  end

  @doc """
  Whether a written HTML post `posted` left A's words off the store: the
  store before the write (`before`) is not what the page showed (`was`,
  `exact?/2`), and the post draws neither of them.
  """
  def held?(posted, before, was) do
    not same?(posted, before) and
      (was == :unknown or (not exact?(was, before) and not same?(posted, was)))
  end
end
