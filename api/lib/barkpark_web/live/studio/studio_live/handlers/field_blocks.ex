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

  def field_block_ops(%{"field" => field, "ops" => ops}, socket)
      when is_binary(field) and is_list(ops) and ops != [] do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    cond do
      is_nil(doc) or is_nil(type) ->
        {:noreply, socket}

      Paper.write_denied?(socket) ->
        {:noreply, Paper.refuse_write_denied(socket)}

      Paper.grant_target_denied?(socket, type, doc.doc_id) ->
        {:noreply, Paper.refuse_outside_grant(socket)}

      true ->
        case Content.apply_field_block_ops(
               doc.doc_id,
               type,
               field,
               ops,
               dataset,
               Shared.hook_opts(socket)
             ) do
          {:ok, %{blocks: blocks}} ->
            {:noreply,
             socket
             |> Paper.sync_editor_blocks()
             |> Phoenix.LiveView.push_event("bp:field-canvas-update", %{
               field: field,
               doc_key: doc.doc_id,
               blocks: blocks
             })}

          {:error, {:out_of_vocabulary, why}} ->
            {:noreply,
             Phoenix.LiveView.put_flash(socket, :error, "Not allowed in this field: #{why}")}

          {:error, _reason} ->
            {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Edit failed")}
        end
    end
  end

  def field_block_ops(_params, socket), do: {:noreply, socket}
end
