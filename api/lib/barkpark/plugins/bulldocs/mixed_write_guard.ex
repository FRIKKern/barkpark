defmodule Barkpark.Plugins.Bulldocs.MixedWriteGuard do
  @moduledoc """
  THE PRODUCER CONTRACT for a verbatim `body_html` write onto a paper that
  still carries canonical blocks: it is REFUSED at the ingest boundary, 422.

  ## The decision (ruled 2026-09-07, task pe-w2-verbatim-html-overwrite-hazard)

  Blocks stay the source of truth. Since the reader-stamp slice, an UNSTAMPED
  `body_html` on a row that also carries blocks classifies `{:stale, rendered}`
  in `Barkpark.Content.Papers.reader_source/3`: the reader serves the blocks
  and `refresh_html_cache/3` REWRITES the derived cache from them. That trade
  is deliberate and correct — the alternative fail-closed 422 took 59 live
  papers dark for four weeks. But it left the producer with no signal at all:
  a `body_html` POST onto a blocks-backed paper answered 200, and the caller's
  hand-authored bytes were derived-cache-only, silently replaced on the very
  next read.

  Three options were on the table — (a) reject the mixed write here, (b) clear
  the blocks when a verbatim `body_html` arrives, (c) document it as-is. The
  ruling is (a): REFUSE. (b) is a destructive default — it makes losing the
  canonical block tree the thing that happens when a producer forgets a key —
  and (c) leaves the silent loss in place.

  ## The condition on that ruling: the refusal must NAME what to do instead

  A 422 that only declines makes the caller guess, and the guess that "works"
  is the destructive one. So the message names both honest paths, and BOTH
  exist:

    1. Send the same content as a `blocks` list on this same route. The
       canonical path; the only one that keeps in-canvas editing.

    2. If the paper really is HTML-only from now on, re-POST the same
       `body_html` with `"clear_blocks": true`. That drops the canonical
       blocks so the row is honestly HTML-only, and the reader stops
       re-rendering over the caller's bytes.

  Path 2 had to be BUILT for this refusal to be honest. Before it there was no
  way to demote a blocks-backed paper to HTML-only at all: the HTML-only leg of
  `BlockOps.write_encrypted_blocks_doc/8` preserves existing blocks by
  construction, and the ops route cannot clear them either because
  `ratchet_hollow/2` refuses every non-hollow → hollow edit. Naming a path the
  producer cannot walk is the same defect as saying nothing.

  ## Scope — which entry points this covers, and how that set was derived

  `grep -rn "upsert_paper(" api/lib` gives six call sites. Exactly ONE of them
  ever passes a `body_html` key: `BarkparkWeb.BulldocsIngestController`'s
  `ingest_html/4`, reached from `POST /v1/plugins/bulldocs/papers` when the
  body carries `slug` + `body_html`. The other five all send `blocks`:
  `sync_create_persist/6` (POST …/papers/:slug/sync), the blocks leg of
  `ingest/2` (which also absorbs the BPML spelling), `Barkpark.Seeds.Clean`,
  `Barkpark.StudioChat.PlanPapers`, and `PlaygroundController`. The sibling
  block-op route (POST …/papers/:slug/ops) whitelists ops and explicitly
  reserves the derived keys, `body_html` among them, so it cannot reach this
  shape. `internal/` (the `bp` CLI) sends `body_html` only in the READ
  projection (`PaperSource.DocumentJSON`) — no CLI path POSTs it.

  Deliberately NOT covered: the generic document surface (`/v1/data/mutate`),
  which can write any `content` key on any document. That is not the Papers
  ingest boundary and has never pretended to enforce paper doctrine.
  """

  alias Barkpark.Content.Papers
  alias Barkpark.PortableDoc.Projection

  # Reuse of the ALREADY-REGISTERED ingest 422 code (`Content.Errors`
  # @public_inline_codes, documented in docs/api/error-codes.md). A new code
  # would mean a registry edit plus an OpenAPI regen for a refusal that is
  # squarely "this paper body is not valid for this paper".
  @code "invalid_paper"

  @message "this paper already carries canonical blocks, and blocks are the source of truth: " <>
             "a verbatim body_html write here would be stored only as a derived cache and " <>
             "discarded by the next read, so it is refused rather than silently lost. " <>
             "Two honest paths: (1) send the same content as a `blocks` list on this route " <>
             "(POST /v1/plugins/bulldocs/papers) — the canonical path, and the only one that " <>
             "keeps in-canvas editing; or (2) if this paper really is HTML-only from now on, " <>
             "re-POST the same body_html with \"clear_blocks\": true, which drops the canonical " <>
             "blocks so the row is honestly HTML-only."

  @doc "The stable error code this refusal emits."
  @spec code() :: String.t()
  def code, do: @code

  @doc "The refusal message. Public so a test can pin its wording positively."
  @spec message() :: String.t()
  def message, do: @message

  @doc """
  Decide a verbatim-`body_html` ingest write against the row it would land on.

  `attrs` is the upsert attr map the controller has already built and scoped
  (string keys: `slug`, `dataset`, `workspace_id`, `project_id`,
  `clear_blocks`) — the SAME map `Content.upsert_paper/1` is about to receive,
  so the row this reads is the row that write would update.

  Returns `:ok` to let the write proceed, or `{:refuse, error_map}` for a 422.
  """
  @spec check(map()) :: :ok | {:refuse, map()}
  def check(%{} = attrs) do
    cond do
      # The caller stated the intent explicitly. Not a mixed write any more —
      # it is a demotion to HTML-only, which is exactly remedy 2.
      clear_blocks?(attrs["clear_blocks"]) ->
        :ok

      true ->
        case existing_blocks(attrs) do
          blocks when is_list(blocks) and blocks != [] ->
            {:refuse,
             %{
               code: @code,
               message: @message,
               block_count: length(blocks),
               remedies: [
                 "send the content as a `blocks` list",
                 "re-POST with \"clear_blocks\": true to make the row HTML-only"
               ]
             }}

          # No row yet, or a row with no canonical blocks: an HTML-only paper
          # stays HTML-only and a fresh slug is born HTML-only, both exactly as
          # before. The refusal is narrow BY CONSTRUCTION.
          _ ->
            :ok
        end
    end
  end

  def check(_attrs), do: :ok

  defp clear_blocks?(true), do: true
  defp clear_blocks?("true"), do: true
  defp clear_blocks?(_), do: false

  defp existing_blocks(attrs) do
    with slug when is_binary(slug) and slug != "" <- attrs["slug"],
         %{content: content} <- lookup(slug, attrs) do
      Projection.read_blocks(content || %{})
    else
      _ -> nil
    end
  end

  # The SAME scoped lookup the write itself does
  # (`BlockOps.get_existing_blocks_doc_for_write/4`): an explicit workspace in
  # attrs wins; absent it the seeded Default workspace; only on a fresh sandbox
  # with no Default at all does it fall back to unscoped. Reading a DIFFERENT
  # row than the write would update is the one way this guard could be both
  # over- and under-refusing at once, so the two must not drift.
  defp lookup(slug, attrs) do
    dataset = attrs["dataset"] || Papers.paper_default_dataset()

    case scope_opts(attrs) do
      [_ | _] = opts ->
        Papers.get_blocks_doc(slug, "paper", dataset, opts)

      [] ->
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: ws_id} when is_binary(ws_id) ->
            Papers.get_blocks_doc(slug, "paper", dataset, workspace_id: ws_id)

          _ ->
            Papers.get_blocks_doc(slug, "paper", dataset)
        end
    end
  end

  defp scope_opts(attrs) do
    case attrs["workspace_id"] do
      ws when is_binary(ws) and ws != "" ->
        case attrs["project_id"] do
          proj when is_binary(proj) and proj != "" -> [workspace_id: ws, project_id: proj]
          _ -> [workspace_id: ws]
        end

      _ ->
        []
    end
  end
end
