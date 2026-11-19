defmodule BarkparkWeb.Studio.Desk.DocStatus do
  @moduledoc """
  The left of the edit pane's header, as the TanStack Studio draws it
  (`DocumentPane.tsx`, its `.chips`): who else is in the document, then a
  Published and a Draft pill.

  - Published is green when a published version exists, and greyed out
    (`data-off`, `aria-disabled`, a span) when none does.
  - Draft is filled (`data-active`) while there are edits not yet
    published, in the draft perspective.

  As TanStack's (`TipChip`), each pill that can be chosen is a button that
  switches the page's perspective (`aria-pressed`): Published opens the
  published version read-only (`?perspective=published`, `PublishedView`),
  Draft the draft again. The chosen one carries `data-selected`. Both keep
  the pane's own params; a patch, so the button keeps the focus.

  On a touch screen (`pointer: coarse`, up to 768 px) each pill button is a
  44 px tap, as TanStack's: a clear 10 px border above and below grows its
  box while the background and the ring keep their drawn size
  (`background-clip: padding-box`; an inset shadow is drawn inside the
  border), so the header looks the same. On a phone the header squeezes the
  pills to their dot; they stay at least 44 px wide. A mouse keeps the 25 px
  pill.

  The pills' state is in colour, so each also says it in words for screen
  readers ("Not published", "Draft: unpublished changes", …); the visible
  word is hidden from them, so the pill is read once.

  Before the pills, the TanStack Studio's avatar stack (`AvatarStack`,
  Sanity's): one avatar per other person in the document (several tabs are
  one person; you are not shown), their initials on their colour, up to
  three; past that a counter of the rest before the last two. Alone, there
  is none.

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
  attr :perspective, :atom, default: :drafts, values: [:drafts, :published]

  attr :published_href, :string,
    default: nil,
    doc: "the pane in the published perspective; nil draws the pills as words only"

  attr :drafts_href, :string, default: nil, doc: "the pane in the draft perspective"

  @doc "The avatar stack and the two pills."
  def chips(assigns) do
    ~H"""
    <style>
      .dk button.dk-chip { font: inherit; font-size: 13px; font-weight: 500; border: 0; background: var(--dk-bg); cursor: pointer; }
      .dk button.dk-chip:hover { box-shadow: inset 0 0 0 1px var(--dk-line-strong); }
      @media (max-width: 768px) and (pointer: coarse) {
        .dk button.dk-chip, .dk button.dk-chip:hover { border-style: solid; border-color: transparent; border-width: 10px 0; background-clip: padding-box; min-width: 44px; }
      }
    </style>
    <span class="dk-chips" data-desk-status>
      <span
        :if={@presences != []}
        class="p-avatars"
        data-testid="presence"
        role="img"
        aria-label={presence_label(@presences)}
      >
        <span :if={length(@presences) > 3} class="p-avatar more">{length(@presences) - 2}</span>
        <span
          :for={p <- if(length(@presences) > 3, do: Enum.take(@presences, -2), else: @presences)}
          class="p-avatar"
          style={"background: #{p.color}"}
          title={p.name}
        >
          {initials(p.name)}
        </span>
      </span>
      <.pill
        :if={@published?}
        href={@published_href}
        pressed={@perspective == :published}
        data-tone="positive"
      >
        <span class="dk-chip-dot dk-chip-dot-published" aria-hidden="true"></span>
        <span class="dk-chip-label" aria-hidden="true">{gettext("Published")}</span>
        <span class="sr-only">{gettext("Published")}</span>
      </.pill>
      <span
        :if={!@published?}
        class="dk-chip chip"
        data-off
        aria-disabled={@published_href && "true"}
        title={gettext("Unpublished")}
      >
        <span class="dk-chip-dot dk-chip-dot-published" aria-hidden="true"></span>
        <span class="dk-chip-label" aria-hidden="true">{gettext("Published")}</span>
        <span class="sr-only">{gettext("Not published")}</span>
      </span>
      <.pill
        href={@drafts_href}
        pressed={@perspective != :published}
        data-active={@draft? and @perspective != :published}
        title={@draft? && gettext("Edited")}
      >
        <span class="dk-chip-dot dk-chip-dot-draft" aria-hidden="true"></span>
        <span class="dk-chip-label" aria-hidden="true">{gettext("Draft")}</span>
        <span class="sr-only">
          {if @draft?, do: gettext("Draft: unpublished changes"), else: gettext("Draft: no changes")}
        </span>
      </.pill>
    </span>
    """
  end

  attr :href, :string, default: nil
  attr :pressed, :boolean, required: true
  attr :rest, :global, include: ~w(data-tone data-active)
  slot :inner_block, required: true

  # A pill that switches the perspective, or, with no path to switch to, the
  # words only (the chosen one still `data-selected`).
  defp pill(%{href: nil} = assigns) do
    ~H"""
    <span class="dk-chip chip" data-selected={@pressed} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  defp pill(assigns) do
    ~H"""
    <button
      type="button"
      class="dk-chip chip"
      data-selected={@pressed}
      aria-pressed={to_string(@pressed)}
      phx-click={Phoenix.LiveView.JS.patch(@href)}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
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

    me = assigns[:user_id]

    # One per other person, in the order they came.
    presences =
      for(
        p <- assigns[:presences] || [],
        p.doc_id == id and Map.get(p, :dataset) == dataset,
        is_nil(me) or Map.get(p, :user_id) != me,
        do: Map.put_new(p, :name, "User")
      )
      |> Enum.uniq_by(&(Map.get(&1, :user_id) || &1))

    %{draft?: draft?, published?: published?, presences: presences}
  end

  def state(_assigns), do: %{draft?: false, published?: false, presences: []}

  # "Ada Lovelace" is AL, "ada.lovelace@x.no" is AL, "Ada" is A.
  @doc "A name's initials, first and last word, as the avatars draw them."
  def initials(name) do
    words =
      name
      |> to_string()
      |> String.split("@")
      |> hd()
      |> String.split(~r/[\s._-]+/, trim: true)

    case words do
      [] -> "?"
      [one] -> String.upcase(String.first(one))
      [first | rest] -> String.upcase(String.first(first) <> String.first(List.last(rest)))
    end
  end

  defp presence_label(presences) do
    case Enum.map(presences, &Map.get(&1, :name, "User")) do
      [one] -> gettext("%{name} is editing", name: one)
      many -> gettext("%{names} are editing", names: Enum.join(many, ", "))
    end
  end
end
