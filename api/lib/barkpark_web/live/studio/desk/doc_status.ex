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
  border), so the header looks the same. The corners are 12.5 px across
  and 22.5 px down: the padding edge then keeps the 25 px pill's round ends
  (999 px would clamp to the 45 px box and draw an ellipse). On a phone
  (480 px and under) each pill, the greyed span too, is 44 px wide and its
  word ellipsizes, as TanStack's; the header makes the room as TanStack's
  does (no split and no close split on a narrow window, its phone padding,
  `Desk.Style`). As TanStack's chips, the row still gives way when the
  header has more in it (others' avatars): the pills shrink before any
  button is pushed past the edge, and nothing overlaps. The filled Draft
  (`data-active`) is named in the rule too: its `background` shorthand
  would set the clip back and fill the clear border. The focus ring is an
  inset ring of the same token, so it traces the pill, not the 45 px box
  (an outline follows the box). A mouse keeps the 25 px pill.

  The pills' state is in colour, so each also says it in words for screen
  readers ("Not published", "Draft: unpublished changes", …); the visible
  word is hidden from them, so the pill is read once.

  Before the pills, the TanStack Studio's avatar stack (`AvatarStack`,
  Sanity's): one avatar per other person in the document (several tabs are
  one person; you are not shown), their initials on their colour, up to
  three; past that a counter of the rest before the last two. Alone, there
  is none. On a phone under 390 px (touch) the stack from three others on is
  a counter and the last avatar, so the pills keep their 44 px beside the
  header's buttons (at 360 px three avatars left them 37 px). The phone
  counter comes first in the markup and is hidden elsewhere, so the avatar
  after it is drawn as the stack's first (no overlap margin). A counter's
  hover title names the people it stands for, as TanStack's, and the
  stack's label gives the count and every name.

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
        .dk button.dk-chip, .dk button.dk-chip:hover, .dk button.dk-chip[data-active] { border-style: solid; border-color: transparent; border-width: 10px 0; border-radius: 12.5px / 22.5px; background-clip: padding-box; }
        .dk button.dk-chip:focus-visible { outline: none; box-shadow: inset 0 0 0 1px var(--dk-focus-ring); }
      }
      @media (max-width: 480px) and (pointer: coarse) {
        .dk .dk-chips .dk-chip { box-sizing: border-box; flex: 0 1 auto; width: 44px; min-width: 0; padding-left: 6px; padding-right: 6px; gap: 6px; }
      }
      .dk .dk-chips .p-avatar.more.p-avatar-phone { display: none; }
      .dk .dk-chips .p-avatar-phone + .p-avatar { margin-left: 0; }
      @media (max-width: 389px) and (pointer: coarse) {
        .dk .dk-chips .p-avatars:has(> .p-avatar-phone) > .p-avatar:not(:last-child) { display: none; }
        .dk .dk-chips .p-avatars > .p-avatar.more.p-avatar-phone { display: inline-grid; }
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
        <span
          :if={length(@presences) > 2}
          class="p-avatar more p-avatar-phone"
          title={names(Enum.drop(@presences, -1))}
        >
          {length(@presences) - 1}
        </span>
        <span
          :if={length(@presences) > 3}
          class="p-avatar more"
          title={names(Enum.drop(@presences, -2))}
        >
          {length(@presences) - 2}
        </span>
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

  defp presence_label([one]), do: gettext("%{name} is editing", name: name(one))

  defp presence_label(presences),
    do:
      gettext("%{count} others are editing: %{names}",
        count: length(presences),
        names: names(presences)
      )

  # The people a counter stands for, by name: its hover title, as TanStack's.
  defp names(presences), do: Enum.map_join(presences, ", ", &name/1)

  defp name(presence), do: Map.get(presence, :name, "User")
end
