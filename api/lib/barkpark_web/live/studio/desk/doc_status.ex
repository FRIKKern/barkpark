defmodule BarkparkWeb.Studio.Desk.DocStatus do
  @moduledoc """
  The left of the edit pane's header, as the TanStack Studio draws it
  (`DocumentPane.tsx`, its `.chips`): who else is in the document, then a
  Published and a Draft pill.

  - Published is green when a published version exists, and greyed out
    (`data-off`) when none does.
  - Draft is the version the desk edits, so it is always the chosen one
    (`data-selected`). It is filled (`data-active`) while there are edits
    not yet published.

  In the TanStack Studio the pills are buttons that switch between the
  published and the draft view. The desk has no published view, so here
  they only say the state.

  The Studio's toolbar row used to say this with its badge and presence dots.
  The desk hides that row (`Desk.Style`), so they live here now.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content

  attr :doc, :map, required: true
  attr :draft?, :boolean, required: true
  attr :published?, :boolean, required: true
  attr :presences, :list, default: []

  @doc "The presence dots and the two pills."
  def chips(assigns) do
    ~H"""
    <span class="dk-chips" data-desk-status>
      <span :if={@presences != []} class="presence-dots" role="img" aria-label={presence_label(@presences)}>
        <span :for={p <- @presences} class="presence-dot" style={"background: #{p.color}"}></span>
      </span>
      <span
        class="dk-chip"
        data-tone={@published? && "positive"}
        data-off={!@published?}
        title={!@published? && gettext("Unpublished")}
      >
        <span class="dk-chip-dot dk-chip-dot-published" aria-hidden="true"></span>
        <span class="dk-chip-label">{gettext("Published")}</span>
      </span>
      <span
        class="dk-chip"
        data-selected
        data-active={@draft?}
        title={@draft? && gettext("Edited")}
      >
        <span class="dk-chip-dot dk-chip-dot-draft" aria-hidden="true"></span>
        <span class="dk-chip-label">{gettext("Draft")}</span>
      </span>
    </span>
    """
  end

  @doc """
  The pills' state from the page's assigns: a draft open over a published
  version (or one the save knows of), or the published document itself.
  """
  @spec state(map()) :: %{draft?: boolean(), published?: boolean(), presences: list()}
  def state(%{editor_doc: %{} = doc} = assigns) do
    draft? = assigns[:editor_is_draft] == true

    published? =
      if draft?,
        do: assigns[:editor_has_published] == true or is_map(assigns[:published_doc]),
        else: Map.get(doc, :status) == "published"

    id = Content.published_id(doc.doc_id)
    dataset = assigns[:dataset]

    presences =
      for p <- assigns[:presences] || [],
          p.doc_id == id and Map.get(p, :dataset) == dataset,
          do: p

    %{draft?: draft?, published?: published?, presences: presences}
  end

  def state(_assigns), do: %{draft?: false, published?: false, presences: []}

  defp presence_label(presences) do
    case Enum.map(presences, &Map.get(&1, :name, "User")) do
      [one] -> gettext("%{name} is editing", name: one)
      many -> gettext("%{names} are editing", names: Enum.join(many, ", "))
    end
  end
end
