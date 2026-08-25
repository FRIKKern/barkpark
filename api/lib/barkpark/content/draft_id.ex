defmodule Barkpark.Content.DraftId do
  @moduledoc """
  Draft/Published id helpers.

  Pure string operations over Sanity's `drafts.` prefix convention:

    - Published document: `doc_id = "p1"`
    - Draft of same:      `doc_id = "drafts.p1"`

  Leaf concern — no DB, no state, no dependencies. Extracted from
  `Barkpark.Content`, which keeps a thin delegating facade.
  """

  @drafts_prefix "drafts."

  @doc "The `drafts.` id prefix used by the draft/published model."
  def drafts_prefix, do: @drafts_prefix

  def draft_id(published_id) do
    if String.starts_with?(published_id, @drafts_prefix) do
      published_id
    else
      @drafts_prefix <> published_id
    end
  end

  # @canonical capability:draft-published-id aka:strip drafts,drafts prefix,draft prefix,published id,draft twin,replace_prefix
  def published_id(doc_id) do
    String.replace_prefix(doc_id, @drafts_prefix, "")
  end

  def draft?(doc_id), do: String.starts_with?(doc_id, @drafts_prefix)
end
