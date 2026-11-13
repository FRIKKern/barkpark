defmodule BarkparkWeb.Studio.Desk.DocFooter do
  @moduledoc """
  The edit pane's footer, as the TanStack Studio draws it (`DocumentPane.tsx`
  `.doc-footer`, `styles.css` `.doc-footer`, `.publish`): what happened last
  on the left, then a Publish button and the "…" on the right.

  - The left says "Edited 5m ago" while there are edits not yet published,
    "Last published 2h ago" when there are none, and the save's own words
    when a save went wrong ("Save failed", "Updated by another user"). A
    refused save names its field or its reason (`RefusedSave.status/1`).
  - Publish sends the Studio's own `publish` event. It is greyed out when
    there is nothing to publish (the Studio offers no Publish then), as
    TanStack's is. A pressed button goes grey, so the focus moves to the "…"
    beside it, as TanStack's does. Found by its id as an attribute: a pane
    id (`desk-pane-2-doc:post;x`) is no CSS id selector.

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

  @doc "The left's words and the Publish button."
  def bar(assigns) do
    ~H"""
    <span class="dk-footer-status" data-desk-footer-status>{@status}</span>
    <button
      type="button"
      id={"#{@id}-publish"}
      class="dk-publish"
      disabled={is_nil(@publish)}
      phx-click={JS.push("publish") |> JS.focus(to: ~s([id="#{@menu_button}"]))}
      data-desk-publish
    >
      <BarkparkWeb.Icons.icon name="send" size={21} />
      {(@publish && @publish.label) || gettext("Publish")}
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
