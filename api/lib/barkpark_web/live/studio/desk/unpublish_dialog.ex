defmodule BarkparkWeb.Studio.Desk.UnpublishDialog do
  @moduledoc """
  The desk's unpublish dialog, the TanStack Studio's (`UnpublishDialog.tsx`,
  B07 and J04): "Unpublish document?", asked every time. When other
  documents refer to this one it says how many in a `role="status"`, lists
  them with the type and field that refer (`ul.used-in`), and says what
  unpublishing does to them.

  The Studio's unpublish handler opens it (`unpublish`; on the desk also
  when nobody refers to the document, `Handlers.Doc.unpublish/1`), and its
  buttons send the Studio's own events. Nothing here unpublishes, reads or
  writes:

    * Cancel, Escape, the close button: `close-unpublish-guard`.
    * "Unpublish now" (nobody refers) or "Unpublish anyway": `confirm-unpublish`.
    * "Disconnect references and unpublish", only when someone refers:
      `confirm-unpublish` with `disconnect`. The Studio then takes the
      references out of the documents that hold them
      (`Content.disconnect_references`) before it unpublishes. Those
      documents are rewritten only on this press.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.DocDialog

  attr :id, :string, required: true
  attr :title, :string, required: true, doc: "the open document's title"
  attr :rows, :list, required: true, doc: "`DocDialog.rows/1`: who refers to it"
  attr :base, :string, required: true

  @doc "The dialog, open."
  def dialog(assigns) do
    assigns = assign(assigns, :used, DocDialog.count(assigns.rows))

    ~H"""
    <DocDialog.frame
      id={@id}
      name="unpublish"
      title={gettext("Unpublish document?")}
      close="close-unpublish-guard"
    >
      <p><.sure title={@title} /></p>
      <section
        :if={@used > 0}
        class="unpublish-used"
        aria-label={gettext("Referring to %{title}", title: @title)}
      >
        <p class="warning" role="status">{DocDialog.refers(@used, @title)}</p>
        <p>
          {gettext(
            "You may not be able to unpublish “%{title}” because the following documents refer to it:",
            title: @title
          )}
        </p>
        <DocDialog.used_in rows={@rows} base={@base} field />
        <p>
          {gettext(
            "If you unpublish this document, documents that refer to it will no longer be able to access it."
          )}
        </p>
      </section>
      <:actions>
        <button
          type="button"
          class="dk-dialog-btn btn"
          phx-click="close-unpublish-guard"
          data-modal-focus
        >
          {gettext("Cancel")}
        </button>
        <button
          :if={@used > 0}
          type="button"
          class="dk-dialog-btn btn"
          phx-click="confirm-unpublish"
          phx-value-disconnect="true"
          data-desk-confirm="disconnect-unpublish"
        >
          {gettext("Disconnect references and unpublish")}
        </button>
        <button
          type="button"
          class="dk-dialog-btn btn danger"
          phx-click="confirm-unpublish"
          data-desk-confirm="unpublish"
        >
          {if @used > 0, do: gettext("Unpublish anyway"), else: gettext("Unpublish now")}
        </button>
      </:actions>
    </DocDialog.frame>
    """
  end

  attr :title, :string, required: true

  # "Are you sure you want to unpublish “<strong>title</strong>”?": the words
  # round the title are the translation's, wherever it puts the title.
  defp sure(assigns) do
    marker = "\u0000"

    {before, after_title} =
      case String.split(
             gettext("Are you sure you want to unpublish “%{title}”?", title: marker),
             marker,
             parts: 2
           ) do
        [b, a] -> {b, a}
        [b] -> {b, ""}
      end

    assigns = assign(assigns, before: before, after_title: after_title)

    ~H"""
    {@before}<strong>{@title}</strong>{@after_title}
    """
  end
end
