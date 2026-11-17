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
  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :title, :string, required: true, doc: "the open document's title"
  attr :rows, :list, required: true, doc: "`DocDialog.rows/1`: who refers to it"
  attr :base, :string, required: true

  attr :return_to, :string,
    default: nil,
    doc: "the id of the pane's \"Show document actions\" button"

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
          phx-click={confirm(@return_to)}
          phx-value-disconnect="true"
          data-desk-confirm="disconnect-unpublish"
        >
          {gettext("Disconnect references and unpublish")}
        </button>
        <button
          type="button"
          class="dk-dialog-btn btn danger"
          phx-click={confirm(@return_to)}
          data-desk-confirm="unpublish"
        >
          {if @used > 0, do: gettext("Unpublish anyway"), else: gettext("Unpublish now")}
        </button>
      </:actions>
    </DocDialog.frame>
    """
  end

  attr :id, :string, required: true
  attr :pane, :string, required: true, doc: "the list pane whose ticked rows are asked about"

  attr :docs, :list,
    required: true,
    doc: "the ticked documents that are published: `%{id, title, rows}`, `rows` who refers to it"

  attr :base, :string, required: true

  attr :checking, :boolean,
    default: false,
    doc: "who refers is still being read: the dialog says so and its buttons wait"

  attr :busy, :boolean,
    default: false,
    doc: "the unpublish it started is running: its buttons wait, Cancel puts it away"

  @doc """
  The same dialog for a list's ticked rows (B03, `Bulk`): "Unpublish 2
  documents?", and one section per document that others refer to. Its
  buttons send the page's `bulk-unpublish` with `confirm`; nothing here
  unpublishes.
  """
  def many(assigns) do
    assigns =
      assign(assigns,
        used: Enum.filter(assigns.docs, &(&1.rows != [])),
        many?: length(assigns.docs) > 1
      )

    ~H"""
    <DocDialog.frame
      id={@id}
      name="bulk-unpublish"
      title={
        if @many?,
          do: gettext("Unpublish %{n} documents?", n: length(@docs)),
          else: gettext("Unpublish document?")
      }
      close="bulk-unpublish-close"
    >
      <p :if={@checking} class="muted" role="status">
        {gettext("Looking for documents that refer to them…")}
      </p>
      <p :if={!@checking and (@used == [] or !@many?)}>
        <%= if @many? do %>
          {gettext("They will no longer be live. Each one stays as a draft you can publish again.")}
        <% else %>
          <.sure title={hd(@docs).title} />
        <% end %>
      </p>
      <section
        :for={doc <- @used}
        class="unpublish-used"
        aria-label={gettext("Referring to %{title}", title: doc.title)}
      >
        <p class="warning" role="status">{DocDialog.refers(length(doc.rows), doc.title)}</p>
        <p>
          {gettext(
            "You may not be able to unpublish “%{title}” because the following documents refer to it:",
            title: doc.title
          )}
        </p>
        <DocDialog.used_in rows={doc.rows} base={@base} field />
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
          phx-click="bulk-unpublish-close"
          data-modal-focus
        >
          {gettext("Cancel")}
        </button>
        <button
          :if={@used != []}
          type="button"
          class="dk-dialog-btn btn"
          phx-click="bulk-unpublish"
          phx-value-pane={@pane}
          phx-value-confirm="true"
          phx-value-disconnect="true"
          data-desk-confirm="disconnect-unpublish"
          disabled={@checking or @busy}
        >
          {gettext("Disconnect references and unpublish")}
        </button>
        <button
          type="button"
          class="dk-dialog-btn btn danger"
          phx-click="bulk-unpublish"
          phx-value-pane={@pane}
          phx-value-confirm="true"
          data-desk-confirm="unpublish"
          disabled={@checking or @busy}
        >
          {if @used != [], do: gettext("Unpublish anyway"), else: gettext("Unpublish now")}
        </button>
      </:actions>
    </DocDialog.frame>
    """
  end

  # The Studio's `confirm-unpublish`, and the focus to the pane's document
  # actions, as the TanStack Studio's (`PublishedFooter`): the footer's
  # Unpublish, when it opened the dialog, is greyed out once the document is
  # unpublished, and a greyed-out button cannot take the focus back.
  defp confirm(nil), do: "confirm-unpublish"

  defp confirm(return_to),
    do: JS.push("confirm-unpublish") |> JS.focus(to: ~s([id="#{return_to}"]))

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
