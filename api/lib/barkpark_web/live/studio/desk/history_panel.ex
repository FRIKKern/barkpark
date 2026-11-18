defmodule BarkparkWeb.Studio.Desk.HistoryPanel do
  @moduledoc """
  Sanity's History inspector for the document in the desk's edit pane, as
  the TanStack Studio draws it (`HistoryPanel.tsx`): beside the form, a
  timeline of what happened to the document, who did it and when. Picking
  an entry shows the document as it was then, read-only, at a deep URL
  (`rev=<id>`, `RevisionView`); the newest entry is the document now.

  It is open while the pane's URL says so: `inspect=sanity/structure/history`
  with `changesInspectorTab=history` or `review` (Sanity's own names, read by
  `Panes` as `inspect: "history"` or `"review"`). Its two tabs, History and
  Review changes, are patches between the two, and so are the document
  menu's History and the close button: Back closes or reopens it. Review
  changes is its second tab (`ReviewChanges`), which reads this timeline.

  The timeline is `Content.list_revisions/4` under the page's scope, the
  newest 100, read when the inspector opens and again whenever the editor
  holds a newer version of the document (a save, a publish, someone else's
  edit). So a History opened right after a publish lists that publish.

  Entries fold as Sanity's (`timeline/1`): a run of edits by one author is
  one "Edited"; each "Published" holds the draft's edits it published,
  collapsed under it until its Expand is pressed.

  `EditorHost` owns the `desk_history` assign: `nil` while closed, else
  `%{entries: entries, revisions: revisions, key: key}`, `key` naming the
  version it was read for.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.DocFooter
  alias BarkparkWeb.Studio.Desk.DocStatus
  alias BarkparkWeb.Studio.Desk.IncomingRefs
  alias BarkparkWeb.Studio.Desk.Panes
  alias Phoenix.LiveView.JS

  # The most revisions read (TanStack's first page).
  @limit 100

  @typedoc "One timeline entry: its newest revision, its words, and the edits it holds."
  @type entry :: %{
          revision: map(),
          label: String.t(),
          count: pos_integer(),
          children: [entry()]
        }

  @doc "Whether `pane` asks for this inspector, on either of its tabs."
  def open?(%{kind: :doc, inspect: inspect}) when inspect in ["history", "review"], do: true
  def open?(_pane), do: false

  @doc "The tab `pane` asks for: `:history` or `:review`."
  def tab(%{inspect: "review"}), do: :review
  def tab(_pane), do: :history

  @doc """
  The menu items with the Studio's History (which opens its dialog) made a
  patch that opens this inspector on pane `index`.
  """
  def with_item(items, chain, index, base, perspective \\ :drafts) do
    to = path(chain, index, base, perspective, %{inspect: "history", rev: nil})

    Enum.map(items, fn
      %{name: "show-history"} = item -> %{item | event: JS.patch(to)}
      item -> item
    end)
  end

  @doc "The path to pane `index` with `params` changed, the perspective kept."
  def path(chain, index, base, perspective, params) do
    chain
    |> Panes.with_params(index, params, base)
    |> Panes.keep_perspective(perspective)
  end

  @doc """
  Reads the timeline when the last pane is the edited document and asks for
  the inspector, and again when the editor holds a newer version than the
  one it was read for; `nil` otherwise.
  """
  def load(%{assigns: %{editing: {_dataset, _type, _id}, chain: [_ | _] = chain}} = socket) do
    if open?(List.last(chain)) and is_map(socket.assigns[:editor_doc]),
      do: read(socket),
      else: Phoenix.Component.assign(socket, :desk_history, nil)
  end

  def load(socket), do: Phoenix.Component.assign(socket, :desk_history, nil)

  @doc "`load/1` only while the inspector is open, for every answer the editor gives."
  def follow(%{assigns: %{desk_history: %{}}} = socket), do: load(socket)
  def follow(socket), do: socket

  defp read(socket) do
    %{editing: {dataset, type, id}, editor_doc: doc} = socket.assigns
    key = {doc.doc_id, Map.get(doc, :updated_at), Map.get(doc, :rev)}

    case socket.assigns[:desk_history] do
      %{key: ^key} ->
        socket

      _ ->
        revisions =
          Content.list_revisions(
            id,
            type,
            dataset,
            [limit: @limit] ++ ScopeHelpers.scope_opts(socket)
          )
          # Each actor by name, as the REST history names them: a user's row
          # stores the id alone.
          |> Barkpark.Accounts.Privacy.redact_actor_labels()

        Phoenix.Component.assign(socket, :desk_history, %{
          entries: timeline(revisions),
          revisions: revisions,
          key: key
        })
    end
  end

  @doc "Sanity's words for what a revision did."
  @spec label(map()) :: String.t()
  def label(%{action: "publish"}), do: "Published"
  def label(%{action: "unpublish"}), do: "Unpublished"
  def label(%{action: "delete", status: "draft"}), do: "Discarded draft"
  def label(%{action: "delete"}), do: "Deleted"
  def label(%{action: "discardDraft"}), do: "Discarded draft"
  def label(%{action: "create"}), do: "Draft created"
  def label(%{action: "restore"}), do: "Restored"
  def label(_revision), do: "Edited"

  @doc """
  The timeline, newest first, as Sanity's (TanStack's `timeline()`): a run of
  edits by one author folds into one "Edited" entry; each "Published" holds
  the draft's edits that it published, while edits since the last publish
  stay on top. Each entry points at its newest revision.
  """
  @spec timeline([map()]) :: [entry()]
  def timeline(revisions) do
    {out, _publish} =
      Enum.reduce(revisions, {[], nil}, fn rev, {out, publish} ->
        draft_write? = rev.status == "draft" and rev.action in ["create", "update"]

        cond do
          draft_write? and publish != nil ->
            {List.update_at(out, publish, &%{&1 | children: fold(&1.children, rev)}), publish}

          draft_write? ->
            {fold(out, rev), nil}

          true ->
            out = fold(out, rev)
            {out, if(rev.action == "publish", do: length(out) - 1)}
        end
      end)

    out
  end

  defp fold(list, rev) do
    label = label(rev)

    case List.last(list) do
      %{label: "Edited", revision: %{actor_id: actor}} = last
      when label == "Edited" and actor == rev.actor_id ->
        List.replace_at(list, -1, %{last | count: last.count + 1})

      _ ->
        list ++ [%{revision: rev, label: label, count: 1, children: []}]
    end
  end

  @doc """
  The page's assigns for drawing the form while this inspector is open on
  the pane (`assigns.view`), as Sanity's: every field, its group tabs
  waiting (`desk_groups_waiting`). The group chosen before stays on the
  socket and is back when the inspector closes.
  """
  def waiting(assigns) do
    if open?(get_in(assigns, [:view, :pane])),
      do: assign(assigns, nav_group: nil, desk_groups_waiting: true),
      else: assigns
  end

  @doc "Who made a revision, by name; a service token's row says so."
  def who(%{actor_label: label}) when is_binary(label) and label != "", do: label
  def who(_revision), do: gettext("API token")

  attr :id, :string, required: true, doc: "the holder's id (`<pane>-history`)"
  attr :panel, :any, required: true, doc: "`desk_history`: nil while closed"
  attr :pane, :map, required: true
  attr :chain, :list, required: true
  attr :index, :integer, required: true
  attr :base, :string, required: true
  attr :menu_button, :string, required: true, doc: "the \"…\" button the close gives the focus to"
  attr :perspective, :atom, default: :drafts
  attr :review, :map, default: nil, doc: "`desk_review`: what Review changes shows"

  @doc """
  The inspector, beside the form. The holder is always in the page (hidden
  while closed), so opening and closing moves nothing around it.
  """
  def holder(assigns) do
    %{chain: chain, index: index, base: base, perspective: perspective} = assigns
    to = &path(chain, index, base, perspective, &1)

    assigns =
      assign(assigns,
        open: is_map(assigns.panel),
        tab: tab(assigns.pane),
        entries: (assigns.panel && assigns.panel.entries) || [],
        selected: assigns.pane[:rev],
        to: to,
        close:
          %{inspect: nil, rev: nil}
          |> to.()
          |> JS.patch()
          |> JS.focus(to: ~s([id="#{assigns.menu_button}"]))
      )

    ~H"""
    <aside
      id={@id}
      class={["dk-inspector", @open && "inspector history"]}
      data-desk-inspector
      aria-label={@open && gettext("History")}
      hidden={!@open}
    >
      <%= if @open do %>
        <IncomingRefs.sheet />
        <.sheet />
        <header class="dk-inspector-head">
          <div class="view-tabs" role="tablist" aria-label={gettext("Inspector")}>
            <button
              type="button"
              role="tab"
              aria-selected={to_string(@tab == :history)}
              phx-click={JS.patch(@to.(%{inspect: "history", rev: nil}))}
            >
              {gettext("History")}
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={to_string(@tab == :review)}
              phx-click={JS.patch(@to.(%{inspect: "review", rev: nil}))}
            >
              {gettext("Review changes")}
            </button>
          </div>
          <button
            type="button"
            class="dk-inspector-close icon-btn"
            aria-label={gettext("Close history")}
            phx-click={@close}
            phx-keydown={@close}
            phx-key="escape"
            data-desk-inspector-close
          >
            <BarkparkWeb.Icons.desk_icon name="close" size={21} />
          </button>
        </header>
        <p class="history-note">
          <BarkparkWeb.Icons.desk_icon name="info-outline" size={17} />
          <% [before, rest] = note() %>
          <span>{before}<strong>{gettext("Draft")}</strong>{rest}</span>
        </p>
        <div role="tabpanel" aria-label={if(@tab == :review, do: gettext("Review changes"), else: gettext("History"))}>
          <ul :if={@tab == :history} class="history-list" aria-label={gettext("Document revisions")}>
            <%= for {entry, at} <- Enum.with_index(@entries) do %>
              <.row
                entry={entry}
                selected={if @selected, do: entry.revision.id == @selected, else: at == 0}
                href={@to.(%{rev: if(at == 0, do: nil, else: entry.revision.id)})}
                group={"#{@id}-#{entry.revision.id}"}
                close={@close}
              />
              <.row
                :for={child <- entry.children}
                entry={child}
                selected={child.revision.id == @selected}
                href={@to.(%{rev: child.revision.id})}
                child={"#{@id}-#{entry.revision.id}"}
                close={@close}
              />
            <% end %>
          </ul>
          <BarkparkWeb.Studio.Desk.ReviewChanges.panel :if={@tab == :review} id={"#{@id}-review"} review={@review} />
        </div>
      <% end %>
    </aside>
    """
  end

  attr :entry, :map, required: true
  attr :selected, :boolean, required: true
  attr :href, :string, required: true
  attr :close, :any, required: true
  attr :group, :string, default: nil, doc: "a publish's id for the rows it holds"
  attr :child, :string, default: nil, doc: "the publish this row is held by"

  # One entry: the avatar with its what-happened badge, the words and when.
  # A held row is hidden until its publish's Expand shows it.
  defp row(assigns) do
    rev = assigns.entry.revision
    who = who(rev)
    words = Gettext.gettext(BarkparkWeb.Gettext, assigns.entry.label)
    at = Map.get(rev, :inserted_at)
    when_ = if match?(%DateTime{}, at), do: DocFooter.ago(at, DateTime.utc_now()), else: ""

    assigns =
      assign(assigns,
        who: who,
        words: words,
        when_: when_,
        at: at,
        kind: badge(assigns.entry.label),
        expandable: assigns.group != nil and assigns.entry.children != []
      )

    ~H"""
    <li
      data-current={@selected && ""}
      data-child={@child && ""}
      data-history-held={@child}
      hidden={@child != nil}
    >
      <button
        type="button"
        phx-click={JS.patch(@href)}
        phx-keydown={@close}
        phx-key="escape"
        aria-label={"#{@who} #{@words} #{@when_}"}
        aria-current={@selected && "true"}
        data-desk-revision={@entry.revision.id}
      >
        <span class="avatar" title={@who}>
          {if @who == gettext("API token"), do: "·", else: DocStatus.initials(@who)}
          <span class="badge" data-kind={@kind}>
            <BarkparkWeb.Icons.desk_icon name={icon(@kind)} size={17} />
          </span>
        </span>
        <span class="history-text">
          <span>{@words}</span>
          <time :if={@at} datetime={DateTime.to_iso8601(@at)}>{@when_}</time>
        </span>
      </button>
      <button
        :if={@expandable}
        type="button"
        class="history-expand"
        aria-label={gettext("Expand")}
        title={gettext("Expand")}
        aria-expanded="false"
        phx-click={
          JS.toggle_attribute({"hidden", ""}, to: ~s([data-history-held="#{@group}"]))
          |> JS.toggle_attribute({"aria-expanded", "true", "false"})
        }
      >
        <BarkparkWeb.Icons.desk_icon name="chevron-left" size={21} />
      </button>
    </li>
    """
  end

  # Sanity's badge: publish and create green, edit yellow, the rest orange.
  defp badge("Published"), do: "published"
  defp badge("Unpublished"), do: "unpublished"
  defp badge("Discarded draft"), do: "discarded"
  defp badge("Deleted"), do: "deleted"
  defp badge("Draft created"), do: "created"
  defp badge(_label), do: "edited"

  defp icon("published"), do: "publish"
  defp icon("unpublished"), do: "unpublish"
  defp icon("discarded"), do: "close"
  defp icon("deleted"), do: "trash"
  defp icon("created"), do: "add"
  defp icon(_kind), do: "edit"

  # Sanity's note, above both tabs, around its version name (drawn in bold).
  # A translation without the placeholder reads whole, the name after it.
  defp note do
    text =
      gettext("Showing the history for the %{draft} version of this document.", draft: "\u0000")

    case String.split(text, "\u0000") do
      [before, rest] -> [before, rest]
      _ -> [text <> " ", ""]
    end
  end

  # The labels, as msgids the extractor sees (`label/1` returns the English).
  @doc false
  def labels,
    do: [
      gettext("Published"),
      gettext("Unpublished"),
      gettext("Discarded draft"),
      gettext("Deleted"),
      gettext("Draft created"),
      gettext("Restored"),
      gettext("Edited")
    ]

  # The TanStack Studio's `.inspector.history` (barkpark-studio `styles.css`);
  # the inspector's place beside the form is `IncomingRefs.sheet/1`'s. Under
  # 600 px the inspector takes the pane, the form under it gone, as TanStack's.
  defp sheet(assigns) do
    ~H"""
    <style>
      @media (max-width: 599px) { .dk .dk-edit-body:has(> .dk-inspector.history:not([hidden])) > :not(.dk-inspector) { display: none; } }
      .dk .dk-inspector.history .dk-inspector-head { padding-left: 0; }
      .dk .dk-inspector.history .view-tabs { display: flex; gap: 4px; }
      .dk .dk-inspector.history .view-tabs [role=tab] { padding: 5px 8px; border: 0; border-radius: 3px; background: none; font: inherit; font-weight: 500; line-height: 19px; color: var(--dk-muted); cursor: pointer; }
      .dk .dk-inspector.history .view-tabs [role=tab][aria-selected=true] { background: var(--dk-fill-soft); color: var(--dk-fg); }
      .dk .dk-inspector .history-note { display: flex; align-items: center; gap: 3px; margin: -1px 0 12px; padding: 4px 8px 3px 4px; border-radius: 3px; background: var(--dk-card-hover); box-shadow: inset 0 0 0 1px var(--dk-border); font-size: 10px; line-height: 15px; color: var(--dk-muted); }
      .dk .dk-inspector .history-note strong { font-weight: 700; }
      .dk .dk-inspector .history-note svg { flex: none; }
      .dk .dk-inspector ul.history-list { margin: 0; padding: 0; border: 0; gap: 4px; }
      .dk .history-list li { display: flex; gap: 4px; }
      .dk .history-list li[hidden] { display: none; }
      .dk .history-list li > button:first-child { flex: 1; min-width: 0; }
      .dk .history-list li[data-child] { padding-left: 16px; }
      .dk .history-list button { display: flex; align-items: center; gap: 12px; width: 100%; padding: 7.5px 8px; border: 0; border-radius: 3px; background: none; font: inherit; text-align: left; cursor: pointer; color: var(--dk-fg); }
      .dk .history-list button:hover { background: var(--dk-card-hover); --dk-history-row: var(--dk-card-hover); }
      .dk .history-list button:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: -2px; }
      .dk .history-list .history-expand { flex: none; width: 25px; justify-content: center; padding: 0; color: var(--dk-muted); }
      .dk .history-list .history-expand[aria-expanded=true] { background: var(--dk-card-hover); }
      .dk .history-list .history-expand[aria-expanded=true] svg { transform: rotate(-90deg); }
      .dk .history-list [data-current] > button:first-child { background: var(--dk-fill-soft); --dk-history-row: var(--dk-fill-soft); }
      .dk .history-list .avatar { position: relative; flex: none; display: grid; place-items: center; width: 33px; height: 33px; border-radius: 50%; background: var(--dk-avatar-blue); color: var(--dk-avatar-fg); font-size: 12px; font-weight: 600; }
      .dk .history-list .badge { position: absolute; left: 18px; top: 18px; display: grid; place-items: center; width: 17px; height: 17px; border-radius: 50%; background: var(--dk-muted); color: var(--dk-avatar-fg); box-shadow: 0 0 0 1px var(--dk-history-row, var(--dk-bg)); }
      .dk .history-list .badge:is([data-kind=published], [data-kind=created]) { background: var(--dk-avatar-green); }
      .dk .history-list .badge:is([data-kind=unpublished], [data-kind=discarded], [data-kind=deleted]) { background: var(--dk-avatar-orange); }
      .dk .history-list .badge[data-kind=edited] { background: var(--dk-avatar-yellow); }
      .dk .history-text { display: flex; flex-direction: column; font-size: 13px; line-height: 17px; font-weight: 500; color: var(--dk-row-chain-fg); }
      .dk .history-text time { font-weight: 400; color: var(--dk-muted); }
      @media (pointer: coarse) { .dk .history-list .history-expand { min-width: 44px; } }
    </style>
    """
  end
end
