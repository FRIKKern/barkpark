defmodule BarkparkWeb.DocumentOpsController do
  @moduledoc """
  `POST /v1/data/doc/:dataset/:type/:doc_id/ops` — apply one PortableDoc block
  op to any document type, over HTTP.

  The product-era core rule (docs/contracts/product-era.md): anything Studio can
  do, the API can do too. Studio's block editor writes a non-paper document by
  calling `Content.apply_document_block_op/5` in-process. Before this route no
  HTTP caller could, so an app outside the Phoenix process could not edit the
  blocks Studio edits. This controller is the same call behind the write tier.

  Body: `{"op": {...}, "ifRev": "<the document's current _rev>"}`.

  - `ifRev` is required, as it is for Studio's editor: an op without a
    revision fence could overwrite a newer edit.
  - A stale `ifRev` answers 412 `precondition_failed` and writes nothing.
  - Papers and sessions are refused: they carry an integer `rev` and stream
    frames, and take ops at `/v1/plugins/bulldocs/{papers,sessions}/:slug/ops`.
  - A type with no schema in scope answers 404 `not_found`.
  - Draft first: when `drafts.<doc_id>` exists the op edits the draft, as
    Studio's editor does and as `?perspective=raw` reads it. Otherwise it edits
    the document itself.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias BarkparkWeb.ErrorResponse

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  def apply_op(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id} = params) do
    op = params["op"]
    if_rev = params["ifRev"]
    opts = [source: :api] ++ scope_opts(conn)

    cond do
      not (is_map(op) and is_binary(op["op"])) ->
        ErrorResponse.emit_custom(
          conn,
          :unprocessable_entity,
          "malformed_op",
          "body must carry an op object naming a DocPatchOp in its \"op\" key"
        )

      not (is_binary(if_rev) and if_rev != "") ->
        ErrorResponse.emit_custom(
          conn,
          :unprocessable_entity,
          "malformed_op",
          "ifRev is required: read the document and send its current _rev"
        )

      Content.blocks_type?(type) ->
        ErrorResponse.emit_custom(
          conn,
          :unprocessable_entity,
          "invalid_op",
          "#{type} documents take ops at /v1/plugins/bulldocs/#{type}s/:slug/ops"
        )

      not match?({:ok, _}, Content.get_schema(type, dataset, opts)) ->
        ErrorResponse.emit(conn, {:error, :not_found}, "no schema for type #{type}")

      true ->
        run_op(conn, doc_id, type, op, dataset, opts ++ [if_rev: if_rev])
    end
  end

  defp run_op(conn, doc_id, type, op, dataset, opts) do
    target = edit_target(doc_id, type, dataset, opts)

    case Content.apply_document_block_op(target, type, op, dataset, opts) do
      {:ok, result} ->
        json(conn, %{ok: true, result: result})

      {:error, :not_found} ->
        ErrorResponse.emit(conn, {:error, :not_found})

      {:error, {:rev_mismatch, %{}} = reason} ->
        ErrorResponse.emit(conn, {:error, reason})

      {:error, :precondition_failed} ->
        ErrorResponse.emit_custom(
          conn,
          :precondition_failed,
          "precondition_failed",
          "this op needs a revision fence"
        )

      {:error, {:halted, _reason} = reason} ->
        ErrorResponse.emit(conn, {:error, reason})

      {:error, _other} ->
        ErrorResponse.emit_custom(
          conn,
          :unprocessable_entity,
          "invalid_op",
          "the op could not be applied"
        )
    end
  end

  defp edit_target("drafts." <> _ = doc_id, _type, _dataset, _opts), do: doc_id

  defp edit_target(doc_id, type, dataset, opts) do
    draft_id = "drafts." <> doc_id

    case Content.get_document(draft_id, type, dataset, opts) do
      {:ok, _draft} -> draft_id
      _ -> doc_id
    end
  end
end
