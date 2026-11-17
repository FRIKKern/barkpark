defmodule BarkparkWeb.Studio.Desk.BulkBar do
  @moduledoc """
  What a desk list draws for its selection (`Bulk`), with the TanStack
  Studio's roles, names and words (`Structure.tsx`, `BulkBar.tsx`):

    * `tick/1`: a row's checkbox, "Select <title>", where the row's icon is.
      Out of the tab order and the accessibility tree (`inert`) until the
      list is selecting.
    * `bar/1`: the `region` "Bulk actions" under the rows: "3 selected" in a
      `status`, Clear, Publish selected, Unpublish selected, and the
      unpublish dialog while it is asked (`UnpublishDialog.many/1`).
    * `css/0`: their look, TanStack's `.bulk-row`, `.bulk-check` and
      `.bulk-bar` in the desk's own tokens (`Style` draws it).

  The tick is the pane's event (`bulk-pick`); the bar's buttons are the
  page's (`Bulk.handle_event/3`). `bp-desk-bulk.js` does the rest in the
  browser: a Cmd, Ctrl or Shift-click on a row, Escape, the summary toast.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.UnpublishDialog
  alias Phoenix.LiveView.JS

  attr :id, :string, required: true, doc: "the row's document"
  attr :title, :string, required: true
  attr :checked, :boolean, required: true
  attr :active, :boolean, required: true, doc: "whether the list is selecting"
  attr :target, :any, required: true, doc: "the list's pane"

  @doc "A row's tick."
  def tick(assigns) do
    ~H"""
    <label class="bulk-check" inert={!@active}>
      <input
        type="checkbox"
        aria-label={gettext("Select %{title}", title: @title)}
        checked={@checked}
        phx-click="bulk-pick"
        phx-value-id={@id}
        phx-target={@target}
      />
    </label>
    """
  end

  @doc "Escape in a list that is selecting (`bp-desk-bulk.js` runs it): selecting stops."
  def stop(pane), do: JS.push("bulk-clear", value: %{pane: pane})

  attr :pane, :string, required: true, doc: "the list pane's id"
  attr :count, :integer, required: true
  attr :running, :any, default: nil, doc: "`%{action, n}` while an action is under way"
  attr :at, :integer, default: 1, doc: "which document the action is at"
  attr :confirm, :any, default: nil, doc: "the unpublish dialog's documents while it is open"
  attr :base, :string, required: true

  @doc "The bar under a list with ticked rows."
  def bar(assigns) do
    ~H"""
    <div
      class="bulk-bar"
      role="region"
      aria-label={gettext("Bulk actions")}
      data-bulk-bar={@pane}
      tabindex="-1"
    >
      <span class="bulk-count" role="status">{status(@running, @at, @count)}</span>
      <button
        type="button"
        class="btn-text"
        disabled={@running != nil}
        phx-click="bulk-clear"
        phx-value-pane={@pane}
      >
        {gettext("Clear")}
      </button>
      <div class="bulk-actions">
        <button
          type="button"
          class="publish"
          disabled={@running != nil}
          phx-click="bulk-publish"
          phx-value-pane={@pane}
        >
          {gettext("Publish selected")}
        </button>
        <button
          type="button"
          class="btn"
          disabled={@running != nil}
          phx-click="bulk-unpublish"
          phx-value-pane={@pane}
        >
          {gettext("Unpublish selected")}
        </button>
      </div>
      <UnpublishDialog.many
        :if={@confirm}
        id={"#{@pane}-bulk-unpublish"}
        pane={@pane}
        docs={@confirm.docs}
        checking={@confirm.checking}
        base={@base}
      />
    </div>
    """
  end

  defp status(nil, _at, count), do: gettext("%{n} selected", n: count)

  defp status(%{action: :publish, n: n}, at, _count),
    do: gettext("Publishing %{at} of %{n}…", at: at, n: n)

  defp status(%{action: :unpublish, n: n}, at, _count),
    do: gettext("Unpublishing %{at} of %{n}…", at: at, n: n)

  @doc "The look of the ticks, the bar and the summary toast."
  def css do
    """
    .dk .bulk-row { position: relative; }
    .dk .bulk-check { position: absolute; z-index: 1; left: 3px; top: calc(50% - 22px); width: 44px; height: 44px; display: grid; place-items: center; opacity: 0; pointer-events: none; cursor: pointer; }
    .dk .bulk-check input { width: 18px; height: 18px; margin: 0; accent-color: var(--dk-publish-bg); cursor: pointer; }
    .dk .list-rows[data-selecting] .bulk-check, .dk .bulk-row:has(.bulk-check :focus-visible) .bulk-check { opacity: 1; pointer-events: auto; }
    .dk .list-rows[data-selecting] .bulk-row .dk-media, .dk .bulk-row:has(.bulk-check :focus-visible) .dk-media { visibility: hidden; }
    .dk .bulk-bar { flex: none; display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 8px 12px; border-top: 1px solid var(--dk-border); background: var(--dk-bg); font-size: 13px; line-height: 19px; }
    .dk .bulk-count { flex: 1; color: var(--dk-fg); font-weight: 500; }
    .dk .bulk-actions { display: flex; flex-wrap: wrap; gap: 8px; width: 100%; }
    .dk .bulk-bar > .btn-text, .dk .bulk-actions > .btn { height: auto; min-height: 0; font: inherit; font-size: 13px; font-weight: 500; border: 0; border-radius: 3px; background: none; box-shadow: none; color: var(--dk-fg); cursor: pointer; }
    .dk .bulk-bar > .btn-text { padding: 6px 8px; }
    .dk .bulk-actions > .btn { padding: 6px 12px; }
    .dk .bulk-bar > .btn-text:hover:not(:disabled), .dk .bulk-actions > .btn:hover:not(:disabled) { background: var(--dk-icon-btn-hover); }
    .dk .bulk-bar > .btn-text:disabled, .dk .bulk-actions > .btn:disabled { color: var(--dk-placeholder); cursor: default; }
    .dk .bulk-actions > .publish { display: inline-flex; align-items: center; gap: 6px; height: auto; min-height: 0; font: inherit; font-size: 13px; font-weight: 500; padding: 4px 12px; border: 0; border-radius: 3px; background: var(--dk-publish-bg); box-shadow: none; color: var(--dk-publish-fg); cursor: pointer; }
    .dk .bulk-actions > .publish:disabled { background: var(--dk-publish-off-bg); color: var(--dk-publish-off-fg); cursor: default; }
    .dk .bulk-bar:focus { outline: none; }
    .dk .bulk-bar button:focus-visible, .dk .bulk-check input:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: 2px; }
    @media (max-width: 768px) and (pointer: coarse) { .dk .bulk-bar button { min-height: 44px; } }
    """
  end
end
