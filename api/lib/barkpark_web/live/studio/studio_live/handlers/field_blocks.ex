defmodule BarkparkWeb.Studio.StudioLive.Handlers.FieldBlocks do
  @moduledoc """
  `field-block-ops` — the ops a block-configured `richText` FIELD's
  `<bp-paper-canvas>` emits (Gyldendal parity stage E1).

  Same gates as the document-level paper ops (`Shared.Paper.document_op/2`):
  the capability write gate (`write_denied?/1`, pds-w42) and the grant target
  gate. Then `Content.apply_field_block_ops/6` — the field-scoped apply path
  that touches `content[field]` only — and an echo on `bp:field-canvas-update`
  so the canvas advances its baseline (the same mechanism the paper canvas
  uses; a `phx-update="ignore"` wrapper cannot be re-rendered into).
  """

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  def field_block_ops(%{"field" => field, "ops" => ops, "if_rev" => if_rev} = params, socket)
      when is_binary(field) and is_list(ops) and ops != [] and is_binary(if_rev) and
             if_rev != "" do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    cond do
      is_nil(doc) or is_nil(type) ->
        reply(socket, params, false)

      Paper.write_denied?(socket) ->
        reply(Paper.refuse_write_denied(socket), params, false)

      Paper.grant_target_denied?(socket, type, doc.doc_id) ->
        reply(Paper.refuse_outside_grant(socket), params, false)

      true ->
        case Content.apply_field_block_ops(
               doc.doc_id,
               type,
               field,
               ops,
               dataset,
               Shared.hook_opts(socket) ++ [if_rev: if_rev]
             ) do
          {:ok, %{blocks: blocks}} ->
            socket = Paper.sync_editor_blocks(socket)
            fresh_rev = socket.assigns[:editor_doc].rev

            socket =
              Phoenix.LiveView.push_event(socket, "bp:field-canvas-update", %{
                field: field,
                doc_key: doc.doc_id,
                blocks: blocks,
                rev: fresh_rev,
                request_id: params["request_id"]
              })

            reply(socket, params, true, fresh_rev)

          {:error, {:rev_mismatch, current_rev}} ->
            socket = Paper.sync_editor_blocks(socket)

            {:reply,
             %{
               saved: false,
               request_id: params["request_id"],
               conflict: true,
               current_rev: current_revision(current_rev)
             }, socket}

          {:error, {:out_of_vocabulary, why}} ->
            reply(
              Phoenix.LiveView.put_flash(socket, :error, "Not allowed in this field: #{why}"),
              params,
              false
            )

          {:error, _reason} ->
            reply(Phoenix.LiveView.put_flash(socket, :error, "Edit failed"), params, false)
        end
    end
  end

  def field_block_ops(params, socket), do: reply(socket, params, false)

  defp reply(socket, params, saved, rev \\ nil) do
    payload = %{saved: saved, request_id: is_map(params) && params["request_id"]}
    payload = if saved, do: Map.put(payload, :rev, rev), else: payload
    {:reply, payload, socket}
  end

  defp current_revision(%{actual: actual}), do: actual
  defp current_revision(current), do: current
end
