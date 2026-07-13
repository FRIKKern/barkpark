defmodule Barkpark.StudioChat.PlanPapers do
  @moduledoc """
  Projects an APPROVED ExitPlanMode plan into a real, published Bulldocs Paper
  (charter D49 — "the plan grows up").

  We ARE the API app, so there is no HTTP hop and no ingest token: the plan
  markdown goes straight through `FromMarkdown.blocks/1` into
  `Content.upsert_paper/2` (with the audited `bypass_wall: true` — charter
  D23-b/D26: this fire-and-forget projection cannot retry a publish-wall
  rejection, and plan markdown has no label surface), SCOPE-LESS. A
  scope-less upsert resolves the seeded
  Default workspace/project (`resolve_write_scope([])`,
  content/papers/block_ops.ex:78-80) — the SAME tenant the public
  `/papers/:slug` reader serves — and publishes the row unconditionally
  (`status: "published"`, content/papers/block_ops.ex:209). So the plan
  radiates for free to the reader, the TUI, and `/v1/structure`.

  The slug is DETERMINISTIC — `chat-plan-<first 12 hex of
  sha256(session_id <> request_id)>` — and `upsert_paper` keys writes on
  `{dataset, slug}`, so re-approving the same plan UPDATES the same row and
  never duplicates. `paper_id == slug`; `paper_url == "/papers/" <> slug`.

  D7 stands: the plan markdown persisted in the plan row's metadata is the
  source of truth; this Paper is a downstream projection of it.
  """

  alias Barkpark.Content
  alias Barkpark.PortableDoc.FromMarkdown

  @dataset "production"

  @doc """
  Publish (or idempotently re-publish) the approved plan as a Paper.

  Returns `{:ok, %{paper_id: slug, paper_url: "/papers/<slug>"}}` on success, or
  `{:error, reason}` (a changeset or any raised term the upsert surfaces) — the
  caller (a fire-and-forget Task) must never let a failure block or fail the
  approve, so it broadcasts honestly on `{:error, _}` rather than raising.
  """
  @spec publish(String.t(), String.t(), String.t()) ::
          {:ok, %{paper_id: String.t(), paper_url: String.t()}} | {:error, term()}
  def publish(session_id, request_id, plan_markdown)
      when is_binary(session_id) and is_binary(request_id) and is_binary(plan_markdown) do
    slug = slug_for(session_id, request_id)

    case Content.upsert_paper(
           %{
             "slug" => slug,
             "blocks" => FromMarkdown.blocks(plan_markdown),
             "style" => "article",
             "dataset" => @dataset
           },
           # bypass_wall (charter D23-b/D26): this is a fire-and-forget internal
           # projection of an ALREADY-approved plan — the approve must never fail
           # or silently drop the paper on a wall 422, and plan markdown carries
           # no label surface to retry with. Explicit, audited exemption.
           bypass_wall: true
         ) do
      {:ok, _doc} -> {:ok, %{paper_id: slug, paper_url: paper_url(slug)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The deterministic paper slug for a plan (charter D49). Same `session_id +
  request_id` ⇒ same slug ⇒ same paper row, forever — that is what makes a
  re-approve idempotent by construction.
  """
  @spec slug_for(String.t(), String.t()) :: String.t()
  def slug_for(session_id, request_id)
      when is_binary(session_id) and is_binary(request_id) do
    digest =
      :crypto.hash(:sha256, session_id <> request_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "chat-plan-" <> digest
  end

  @doc "The reader URL for a plan slug — the same route `/papers/:slug` serves."
  @spec paper_url(String.t()) :: String.t()
  def paper_url(slug) when is_binary(slug), do: "/papers/#{slug}"
end
