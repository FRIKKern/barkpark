defmodule Barkpark.Plugins.Bulldocs.ReadableBody do
  @moduledoc """
  The paper **producer gate** — a body no reader can read is refused at WRITE
  time (row `dr-w24-bl-paper-writer-accepts-unreadable-bodies`).

  ## The failure mode this closes

  A producer and a consumer that both worked and were never joined by a
  validating contract. `Barkpark.Content.Papers.reader_source/3` is the ONE
  classifier every paper reader uses (`BulldocsLive`, the source/email
  controllers, share links). Nothing on the write path asked it anything, so a
  paper whose body it cannot classify persisted SILENTLY and the first
  complaint arrived at read time, as a 422 `semantic_empty`, for every reader
  forever. Measured on guerrilla 2026-08-08: 68 of 727 published papers, in
  three writer dialects, over five weeks with no bisect point.

    1. `body` = a ProseMirror doc node — `%{"type" => "doc", "content" => […]}`
    2. `body` = a typeless wrapper — `%{"content" => […]}`
    3. `body` = `nil`, with the nodes parked at top-level `content`

  ## The predicate is the READER's, not a retyped list

  `reader_source/3` reads exactly one destination: the `"blocks"` key the
  Envelope promotes, and that promotion is
  `Barkpark.Content.Envelope.promote_paper_blocks/2` calling
  `Barkpark.PortableDoc.Projection.read_blocks/1`. So this module calls
  `read_blocks/1` — the same function, not a copy of its clause list. Widen
  `read_blocks/1` (teach the reader a new body shape) and this gate widens with
  it in the same commit, by construction.

  ## What it deliberately does NOT decide

    * **Emptiness / quality.** `reader_source/3` also answers `semantic_empty`
      for a hollow block list. That is `Barkpark.Content.Papers.Hollow`'s
      question and Bulldocs already asks it at two seams
      (`reject_hollow_published_save/1`, `reject_hollow_paper_publish/1`). It
      must NOT be asked here: mutate creates always land drafts and a fresh
      paper's seeded `tpl-body` paragraph is hollow, so a hollow arm on
      `before_save` would brick creation. This gate answers SHAPE only.
    * **A write carrying no body signal at all.** A metadata-only patch, or a
      create of a paper that simply has no body yet, presents nothing for a
      reader to misread; refusing it would fail closed on writes that are not
      the disease. `body_bearing?/1` is the door: the write must actually
      OFFER a body before its shape is judged.
    * **HTML quality.** A non-blank `content["body_html"]` is accepted as a
      source. `reader_source/3` may still call a whitespace-only render
      `semantic_empty`; this gate is deliberately the weaker of the two on that
      arm so it can never refuse a write a reader would have served.
    * **The existing broken population.** It reads only the INCOMING write and
      touches nothing at rest — repair is `pe-w2-bl-blockless-wave-papers`.
      A repair write (broken row → real blocks) passes this gate.
  """

  alias Barkpark.PortableDoc.Projection

  @message "This paper's body is in a shape no reader can read " <>
             "(Content.Papers.reader_source/3 classifies it as semantic_empty). " <>
             "A paper body must present a block list — content.blocks, " <>
             "content.body.blocks, content.body as a list of blocks, or " <>
             "content.body as a markdown string — or a non-blank content.body_html. " <>
             "A ProseMirror document node, a bare {\"content\": [...]} wrapper, and a " <>
             "null body with nodes parked at content.content are none of those: " <>
             "convert them to blocks before writing."

  @doc """
  Whether the incoming paper `content` presents a body a reader can classify.

  Returns `:ok`, or `{:error, :unreadable_body}` for a body-bearing content map
  that `Projection.read_blocks/1` cannot turn into a block list and that has no
  HTML source either. Non-maps (no content on the write) are `:ok`.
  """
  @spec classify(term()) :: :ok | {:error, :unreadable_body}
  def classify(content) when is_map(content) do
    cond do
      # The reader's own promotion succeeded — this is exactly what the
      # Envelope will hand `reader_source/3`.
      is_list(Projection.read_blocks(content)) -> :ok
      # The reader's second source.
      html_source?(content) -> :ok
      # Nothing offered, nothing to misread.
      not body_bearing?(content) -> :ok
      true -> {:error, :unreadable_body}
    end
  end

  def classify(_no_content), do: :ok

  @doc "The refusal copy, naming the shapes a reader can read."
  @spec message() :: String.t()
  def message, do: @message

  @doc """
  Whether `content` OFFERS a body at all. A write that names none of these keys
  is a metadata write; its shape is not this gate's business.
  """
  @spec body_bearing?(map()) :: boolean()
  def body_bearing?(content) when is_map(content) do
    Map.has_key?(content, "body") or Map.has_key?(content, "blocks") or
      Map.has_key?(content, "body_html") or is_list(Map.get(content, "content"))
  end

  defp html_source?(content) do
    case Map.get(content, "body_html") do
      html when is_binary(html) -> String.trim(html) != ""
      _ -> false
    end
  end
end
