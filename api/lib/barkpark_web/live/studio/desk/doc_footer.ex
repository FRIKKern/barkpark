defmodule BarkparkWeb.Studio.Desk.DocFooter do
  @moduledoc """
  The edit pane's footer, as the TanStack Studio draws it (`DocumentPane.tsx`
  `.doc-footer`, `styles.css` `.doc-footer`, `.publish`): what happened last
  on the left, then a Publish button and the "…" on the right.

  - The left is a button named by its words, with TanStack's class names
    (`.save-state`, `.save-state-text`). It opens nothing yet and is disabled.
  - The left says "Edited 5m ago" while there are edits not yet published,
    "Last published 2h ago" when there are none, and the save's own words
    when a save went wrong ("Save failed", "Updated by another user"). A
    refused save names its field or its reason (`RefusedSave.status/1`).
  - Publish sends the Studio's own `publish` event. It is greyed out when
    there is nothing to publish (the Studio offers no Publish then), as
    TanStack's is. A pressed button goes grey, so the focus moves to the "…"
    beside it, as TanStack's does. Found by its id as an attribute: a pane
    id (`desk-pane-2-doc:post;x`) is no CSS id selector.

  - In the published perspective (`?perspective=published`,
    `Panes.perspective/1`) the button is Unpublish, red, as TanStack's
    `PublishedFooter`. It sends the Studio's own `unpublish` event, which
    opens the desk's dialog (`UnpublishDialog`): nothing is unpublished
    until that dialog is confirmed. It is greyed out, and says "Not
    published", when no published version exists. Over a draft it stays
    offered, as TanStack's: an unpublish keeps an existing draft as it is
    (`Content.Lifecycle.unpublish_document`, draft wins).

  The words are drawn when the pane renders, so "5m ago" moves on with the
  next change, not with the clock.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.StudioLive.RefusedSave
  alias Phoenix.LiveView.JS

  # The save's words worth showing over the time: a save that did not land.
  @problems ["Save failed", "Save cancelled", "Read-only", "Updated by another user"]

  attr :id, :string, required: true
  attr :status, :string, required: true

  attr :publish, :map,
    default: nil,
    doc: "the menu's Publish item, nil when there is nothing to publish"

  attr :menu_button, :string, required: true, doc: "the id of the \"…\" button beside it"

  attr :perspective, :atom,
    default: :drafts,
    values: [:drafts, :published],
    doc: "`:published` draws Unpublish in Publish's place"

  attr :published?, :boolean,
    default: false,
    doc: "whether a published version exists; Unpublish is greyed out without one"

  @doc "The left's words and the Publish button, or Unpublish in the published perspective."
  def bar(%{perspective: :published} = assigns) do
    ~H"""
    <.words status={@status} />
    <%!-- TanStack's `button.publish.danger`, named "Unpublish". The dialog it
          opens gives the focus back to it on Cancel (`ModalFocus`). --%>
    <style>
      .dk .dk-publish.danger:not(:disabled) { background: var(--dk-menu-danger-hover); color: var(--dk-bg); }
      .dk .dk-publish.danger:not(:disabled):hover { background: var(--dk-menu-danger); }
    </style>
    <button
      type="button"
      id={"#{@id}-unpublish"}
      class="dk-publish publish danger"
      disabled={!@published?}
      title={!@published? && gettext("Not published")}
      phx-click="unpublish"
      data-desk-unpublish
    >
      <BarkparkWeb.Icons.desk_icon name="unpublish" size={21} />
      {gettext("Unpublish")}
    </button>
    """
  end

  def bar(assigns) do
    ~H"""
    <.words status={@status} />
    <button
      type="button"
      id={"#{@id}-publish"}
      class="dk-publish"
      disabled={is_nil(@publish)}
      phx-click={JS.push("publish") |> JS.focus(to: ~s([id="#{@menu_button}"]))}
      data-desk-publish
    >
      <BarkparkWeb.Icons.desk_icon name="publish" size={21} />
      {(@publish && @publish.label) || gettext("Publish")}
    </button>
    """
  end

  attr :status, :string, required: true

  defp words(assigns) do
    ~H"""
    <%!-- The TanStack Studio's names (`DocumentPane.tsx` `.save-state-btn`,
          `.save-state`, `.save-state-text`): a button named by its words. It
          opens nothing yet, so it is disabled and out of the tab order. --%>
    <button type="button" class="dk-footer-status save-state-btn" data-desk-footer-status disabled>
      <span class="save-state"><span class="save-state-text">{@status}</span></span>
    </button>
    """
  end

  @doc "The footer's words for the open document."
  @spec status(map(), DateTime.t()) :: String.t()
  def status(assigns, now \\ DateTime.utc_now()) do
    doc = assigns[:editor_doc] || %{}
    at = Map.get(doc, :updated_at)

    cond do
      RefusedSave.token(assigns) in @problems ->
        BarkparkWeb.Studio.SaveStatus.label(RefusedSave.status(assigns))

      not match?(%DateTime{}, at) ->
        ""

      assigns[:editor_is_draft] == true ->
        gettext("Edited %{ago}", ago: ago(at, now))

      Map.get(doc, :status) == "published" ->
        gettext("Last published %{ago}", ago: ago(at, now))

      true ->
        ""
    end
  end

  # The desk's list rows say "Updated 5m ago" with the same words.
  defp ago(%DateTime{} = at, now) do
    secs = max(DateTime.diff(now, at, :second), 0)

    cond do
      secs < 60 -> gettext("just now")
      secs < 3_600 -> gettext("%{n}m ago", n: div(secs, 60))
      secs < 86_400 -> gettext("%{n}h ago", n: div(secs, 3_600))
      secs < 2_592_000 -> gettext("%{n}d ago", n: div(secs, 86_400))
      true -> gettext("%{n}mo ago", n: div(secs, 2_592_000))
    end
  end
end
