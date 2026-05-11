defmodule BarkparkWeb.Components.ConfirmModal do
  @moduledoc """
  Generic dry-run-then-real confirmation modal (Task #16 — schema action
  registry). Schemas declare `kind: "modal"` actions; Studio opens this
  modal when one is clicked.

  Two-stage flow:

    * **initial** — show the title/body, offer `Cancel` and `Confirm`.
    * **dryrun**  — after a dry-run runs, show preview (passed via the
      `:preview` slot) and offer `Cancel`, `Run again`, `Confirm for real`.

  The component is presentational — the parent LiveView wires the actual
  events. We accept event name strings (not `JS` literals) so plugin code
  paths that already declare `phx-click="confirm_publish_dryrun"` keep
  working unchanged.

  ## Assigns

    * `:id`         (required) — DOM id for the dialog backdrop.
    * `:title`      (required) — heading text.
    * `:body`       (optional) — explanatory paragraph.
    * `:stage`      (default `"initial"`) — `"initial"` | `"dryrun"`.
    * `:on_cancel`  (required) — `phx-click` event for the Cancel button.
    * `:on_confirm` (required) — `phx-click` event for the initial Confirm
                                  button (typically a dry-run trigger).
    * `:on_real`    (optional) — `phx-click` event for the "Confirm for
                                  real" button shown once `stage == "dryrun"`.
                                  Defaults to `nil` (button hidden).

  ## Slots

    * `:preview` (optional) — rendered inside the modal body when a dry-run
                              preview is available. Stage advancement is
                              controlled by the parent — set `stage="dryrun"`
                              and render preview content in this slot.

  ## Styling

  Uses inline styles for now (matches the existing book_editor publish
  modal). A future pass can hoist these into `app.css` under
  `.modal-backdrop` / `.modal-content`.
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, default: nil
  attr :stage, :string, default: "initial"
  attr :on_cancel, :string, required: true
  attr :on_confirm, :string, required: true
  attr :on_real, :string, default: nil
  attr :confirm_label, :string, default: "Confirm"
  attr :real_label, :string, default: "Confirm for real"
  attr :cancel_label, :string, default: "Cancel"

  slot :preview

  def confirm_modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="bp-modal-overlay"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      data-test-id="confirm-modal"
      style="position: fixed; inset: 0; background: rgba(0,0,0,0.4); display: flex; align-items: center; justify-content: center; z-index: 1000;"
    >
      <div
        class="bp-modal card"
        style="background: var(--surface, #fff); padding: 24px; min-width: 420px; max-width: 720px; max-height: 80vh; display: flex; flex-direction: column; gap: 12px; overflow: auto;"
      >
        <h2 id={"#{@id}-title"} class="h3" style="margin: 0;"><%= @title %></h2>
        <p :if={@body} class="text-sm text-muted" style="margin: 0;"><%= @body %></p>

        <%= if @stage == "dryrun" and @preview != [] do %>
          <div
            data-test-id="confirm-modal-preview"
            style="border: 1px solid var(--border-muted, #e5e7eb); border-radius: 4px; padding: 12px;"
          >
            <%= render_slot(@preview) %>
          </div>
        <% end %>

        <div style="display: flex; gap: 8px; justify-content: flex-end; padding-top: 8px;">
          <button
            type="button"
            class="btn btn-ghost"
            phx-click={@on_cancel}
            data-test-id="confirm-modal-cancel"
          ><%= @cancel_label %></button>
          <button
            type="button"
            class="btn"
            phx-click={@on_confirm}
            data-test-id="confirm-modal-confirm"
          ><%= @confirm_label %></button>
          <%= if @on_real && @stage == "dryrun" do %>
            <button
              type="button"
              class="btn btn-primary"
              phx-click={@on_real}
              data-test-id="confirm-modal-real"
            ><%= @real_label %></button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
