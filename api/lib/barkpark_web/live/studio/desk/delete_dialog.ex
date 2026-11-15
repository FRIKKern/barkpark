defmodule BarkparkWeb.Studio.Desk.DeleteDialog do
  @moduledoc """
  The desk's delete dialog, the TanStack Studio's (`DeleteDialog.tsx`, J17):
  "Delete document?", the document, and when other documents refer to it a
  warning with how many, the list of them (`ul.used-in`) and what deleting
  does to them.

  The Studio's delete handler opens it (`delete-doc`), and its buttons send
  the Studio's own events: Cancel and Escape `close-delete`, the red button
  `confirm-delete`. Nothing here deletes or reads.

  The red button is the old Studio's choice, in its words. A document nobody
  refers to: "Delete document". A referenced one: "Disconnect references and
  delete", which takes the references out of the documents that hold them
  and then deletes; a referenced document is never deleted with its
  references left pointing at nothing.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.DocDialog

  attr :id, :string, required: true
  attr :title, :string, required: true, doc: "the open document's title"
  attr :published?, :boolean, required: true
  attr :rows, :list, required: true, doc: "`DocDialog.rows/1`: who refers to it"
  attr :base, :string, required: true

  @doc "The dialog, open."
  def dialog(assigns) do
    assigns = assign(assigns, :used, DocDialog.count(assigns.rows))

    ~H"""
    <DocDialog.frame id={@id} name="delete" title={gettext("Delete document?")} close="close-delete">
      <p>{gettext("Are you sure you want to delete this document?")}</p>
      <div class="dk-dialog-preview delete-preview">
        <span class="t">{@title}</span>
        <span class="s">{if @published?, do: gettext("Published"), else: gettext("Draft")}</span>
      </div>
      <section :if={@used > 0} class="delete-used" aria-label={gettext("Used in")}>
        <hr />
        <p class="caution-card" role="status">
          {DocDialog.refers(@used, @title)}
        </p>
        <p>
          {gettext(
            "You may not be able to delete “%{title}” because the following documents refer to it:",
            title: @title
          )}
        </p>
        <DocDialog.used_in rows={@rows} base={@base} />
        <p>
          {gettext(
            "If you delete this document, documents that refer to it will no longer be able to access it."
          )}
        </p>
      </section>
      <:actions>
        <button type="button" class="dk-dialog-btn btn" phx-click="close-delete" data-modal-focus>
          {gettext("Cancel")}
        </button>
        <button
          :if={@used == 0}
          type="button"
          class="dk-dialog-btn btn danger"
          phx-click="confirm-delete"
          data-desk-confirm="delete"
        >
          {gettext("Delete document")}
        </button>
        <button
          :if={@used > 0}
          type="button"
          class="dk-dialog-btn btn danger"
          phx-click="confirm-delete"
          phx-value-disconnect="true"
          data-desk-confirm="disconnect-delete"
        >
          {gettext("Disconnect references and delete")}
        </button>
      </:actions>
    </DocDialog.frame>
    """
  end
end
