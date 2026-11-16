defmodule BarkparkWeb.Studio.WebhooksLive.View do
  @moduledoc """
  Markup for the Studio Webhooks page (`BarkparkWeb.Studio.WebhooksLive`), and
  the plain row maps it draws from.

  Rows are built from `%Webhook{}` and `%Delivery{}` structs but never carry
  the secret, the previous secret or a delivery's payload snapshot, so the
  socket never holds them. Draws only from the Studio's own classes (`.card`,
  `.btn`, `.form-input`, `.badge`) and design tokens.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  import BarkparkWeb.StudioComponents.Controls

  @cell "padding: 6px 12px 6px 0; border-bottom: 1px solid var(--border); text-align: left; vertical-align: middle;"
  @head @cell <> " color: var(--fg-muted); font-weight: 500;"
  @muted "color: var(--fg-muted);"
  @row_actions "display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px;"

  @doc "A webhook as the page shows it. No secret of any kind."
  def hook_row(wh, last_delivery, signed?) do
    %{
      id: wh.id,
      name: wh.name,
      url: wh.url,
      events: wh.events,
      types: wh.types,
      active: wh.active,
      signed: signed?,
      failures: wh.consecutive_failures,
      auto_disabled_at: wh.auto_disabled_at,
      disable_reason: wh.disable_reason,
      next_probe_at: Barkpark.Webhooks.next_probe_at(wh),
      project_wide: is_nil(wh.project_id),
      kind: kind(wh),
      last: last_delivery
    }
  end

  @doc "A delivery as the page shows it. No payload snapshot."
  def delivery_row(d) do
    %{
      id: d.id,
      event_id: d.event_id,
      status: d.status,
      attempts: d.attempts,
      code: d.last_status_code,
      error: d.last_error_text,
      latency_ms: d.last_latency_ms,
      at: d.updated_at || d.inserted_at
    }
  end

  defp kind(%{audit_categories: [_ | _]}), do: :audit
  defp kind(%{blocked_threshold_s: n}) when is_integer(n), do: :chat
  defp kind(_wh), do: :content

  attr :dataset, :string, required: true
  attr :events, :list, required: true
  attr :hooks, :list, required: true
  attr :form, :map, default: nil
  attr :form_error, :string, default: nil
  attr :confirm, :any, default: nil
  attr :reveal, :map, default: nil
  attr :tests, :map, required: true
  attr :open, :string, default: nil
  attr :deliveries, :list, required: true

  def page(assigns) do
    assigns = assign(assigns, cell: @cell, head: @head, muted: @muted, row_actions: @row_actions)

    ~H"""
    <div
      class="webhooks-live"
      style="max-width: 880px; margin: 32px auto; padding: 0 24px; font-family: var(--font);"
    >
      <h1 class="h1" style="margin-bottom: 4px;">{gettext("Webhooks")}</h1>
      <p style={@muted <> " margin-top: 0;"}>
        {gettext("A webhook tells another system when content in %{dataset} changes.",
          dataset: @dataset
        )}
      </p>

      <.secret_reveal :if={@reveal} reveal={@reveal} />

      <.bp_card aria-labelledby="webhooks-list-heading" data-test-id="webhooks-list">
        <.bp_section_header id="webhooks-list-heading" title={gettext("Webhooks")}>
          {gettext("Each delivery is signed with the webhook's secret.")}
        </.bp_section_header>

        <p :if={@hooks == []} role="status" data-test-id="webhooks-empty" style={@muted}>
          {gettext("No webhooks yet.")}
        </p>

        <div
          :for={h <- @hooks}
          data-test-id="webhook-row"
          id={"webhook-#{h.id}"}
          style="padding: 16px 0; border-bottom: 1px solid var(--border);"
        >
          <div style="display: flex; flex-wrap: wrap; align-items: center; gap: 8px;">
            <strong>{h.name}</strong>
            <.state_badge hook={h} />
            <span :if={h.project_wide} class="badge badge-muted">{gettext("every project")}</span>
            <span :if={not h.signed} class="badge badge-muted">{gettext("not signed")}</span>
            <span :if={h.kind == :audit} class="badge badge-muted">{gettext("audit events")}</span>
            <span :if={h.kind == :chat} class="badge badge-muted">{gettext("chat alerts")}</span>
          </div>
          <div class="text-sm" style="font-family: var(--font-mono); margin-top: 4px; word-break: break-all;">
            {h.url}
          </div>
          <div class="text-sm" style={@muted <> " margin-top: 4px;"}>
            {events_text(h.events)} · {types_text(h.types)}
          </div>
          <div class="text-sm" style={@muted <> " margin-top: 4px;"} data-test-id="webhook-last">
            <%= if h.last do %>
              {gettext("Last delivery:")} <.delivery_summary d={h.last} />
            <% else %>
              {gettext("No deliveries yet.")}
            <% end %>
          </div>
          <p
            :if={h.auto_disabled_at}
            class="text-sm"
            role="status"
            style="color: var(--destructive); margin: 4px 0 0;"
          >
            {gettext("Turned off by Barkpark after %{count} failed deliveries in a row.",
              count: h.failures
            )}
            <span :if={h.next_probe_at}>
              {gettext("It tries again after %{time}.", time: time(h.next_probe_at))}
            </span>
          </p>

          <div style={@row_actions}>
            <button type="button" class="btn btn-sm" phx-click="edit" phx-value-id={h.id}>
              {gettext("Edit")}
            </button>
            <button
              :if={h.auto_disabled_at}
              type="button"
              class="btn btn-sm btn-primary"
              phx-click="reenable"
              phx-value-id={h.id}
            >
              {gettext("Turn on again")}
            </button>
            <button
              :if={is_nil(h.auto_disabled_at)}
              type="button"
              class="btn btn-sm"
              phx-click="toggle"
              phx-value-id={h.id}
            >
              {if h.active, do: gettext("Turn off"), else: gettext("Turn on")}
            </button>
            <button type="button" class="btn btn-sm" phx-click="test" phx-value-id={h.id}>
              {gettext("Send test")}
            </button>
            <button
              type="button"
              class="btn btn-sm"
              phx-click={if @open == h.id, do: "deliveries_close", else: "deliveries"}
              phx-value-id={h.id}
              aria-expanded={to_string(@open == h.id)}
            >
              {gettext("Deliveries")}
            </button>
            <.confirm_button
              confirm={@confirm}
              action="rotate"
              id={h.id}
              label={gettext("New secret")}
              question={gettext("Make a new secret? The old one keeps working for 24 hours.")}
              yes={gettext("Yes, make a new secret")}
            />
            <.confirm_button
              confirm={@confirm}
              action="delete"
              id={h.id}
              label={gettext("Delete")}
              question={gettext("Delete this webhook?")}
              yes={gettext("Yes, delete")}
            />
          </div>

          <p
            :if={@tests[h.id]}
            role="status"
            class="text-sm"
            data-test-id="webhook-test-result"
            style="margin: 8px 0 0;"
          >
            {gettext("Test:")} <.delivery_summary d={@tests[h.id]} />
          </p>

          <.deliveries
            :if={@open == h.id}
            hook_id={h.id}
            rows={@deliveries}
            cell={@cell}
            head={@head}
          />
        </div>

        <div style="margin-top: 16px;">
          <button :if={is_nil(@form)} type="button" class="btn btn-primary" phx-click="new">
            {gettext("Add a webhook")}
          </button>
        </div>
      </.bp_card>

      <.hook_form :if={@form} form={@form} error={@form_error} events={@events} />
    </div>
    """
  end

  # The one-time secret. `phx-update="ignore"`: the server forgets the secret
  # right after this first render, and the browser keeps what it was sent. A
  # fresh render (a reconnect) gets the "already shown" line instead.
  attr :reveal, :map, required: true

  defp secret_reveal(assigns) do
    ~H"""
    <.bp_card aria-labelledby="webhook-secret-heading" data-test-id="webhook-secret">
      <h2 id="webhook-secret-heading" class="h3" style="margin: 0 0 8px;">
        {if @reveal.kind == :rotated,
          do: gettext("New secret for %{name}", name: @reveal.name),
          else: gettext("Secret for %{name}", name: @reveal.name)}
      </h2>
      <div id={"webhook-secret-#{@reveal.key}"} phx-update="ignore">
        <%= if @reveal.secret do %>
          <p class="text-sm" style="margin: 0 0 8px;">
            {gettext("Copy it now and give it to the receiver. It is shown only this once.")}
          </p>
          <div style="display: flex; gap: 8px;">
            <input
              type="text"
              readonly
              value={@reveal.secret}
              class="form-input"
              style="font-family: var(--font-mono);"
              aria-label={gettext("Signing secret")}
              data-test-id="webhook-secret-value"
            />
            <button
              type="button"
              class="btn btn-primary btn-sm"
              data-copied={gettext("Copied")}
              onclick={BarkparkWeb.CSP.copy_previous_value_onclick()}
            >
              {gettext("Copy")}
            </button>
          </div>
        <% else %>
          <p class="text-sm" style="margin: 0;">
            {gettext("The secret was shown once. Make a new secret if you did not copy it.")}
          </p>
        <% end %>
      </div>
      <button type="button" class="btn btn-sm" style="margin-top: 12px;" phx-click="secret_done">
        {gettext("Done")}
      </button>
    </.bp_card>
    """
  end

  attr :hook, :map, required: true

  defp state_badge(assigns) do
    ~H"""
    <span :if={@hook.active} class="badge" data-test-id="webhook-state">{gettext("on")}</span>
    <span :if={not @hook.active and is_nil(@hook.auto_disabled_at)} class="badge badge-muted" data-test-id="webhook-state">
      {gettext("off")}
    </span>
    <span :if={not @hook.active and @hook.auto_disabled_at} class="badge badge-muted" data-test-id="webhook-state">
      {gettext("off after failures")}
    </span>
    """
  end

  attr :confirm, :any, required: true
  attr :action, :string, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :question, :string, required: true
  attr :yes, :string, required: true

  defp confirm_button(assigns) do
    ~H"""
    <button
      :if={@confirm != {@action, @id}}
      type="button"
      class={["btn btn-sm", @action == "delete" && "btn-destructive"]}
      phx-click="ask"
      phx-value-action={@action}
      phx-value-id={@id}
    >
      {@label}
    </button>
    <span
      :if={@confirm == {@action, @id}}
      role="group"
      aria-label={@label}
      data-test-id={"webhook-confirm-#{@action}"}
      style="display: inline-flex; flex-wrap: wrap; align-items: center; gap: 8px;"
    >
      <span class="text-sm">{@question}</span>
      <button
        type="button"
        class="btn btn-sm btn-destructive"
        phx-click={@action}
        phx-value-id={@id}
      >
        {@yes}
      </button>
      <button type="button" class="btn btn-sm" phx-click="ask_cancel">{gettext("Cancel")}</button>
    </span>
    """
  end

  attr :hook_id, :string, required: true
  attr :rows, :list, required: true
  attr :cell, :string, required: true
  attr :head, :string, required: true

  defp deliveries(assigns) do
    ~H"""
    <div style="margin-top: 12px;" data-test-id="webhook-deliveries">
      <p :if={@rows == []} class="text-sm" style="color: var(--fg-muted); margin: 0;">
        {gettext("No deliveries yet.")}
      </p>
      <table :if={@rows != []} class="text-sm" style="width: 100%; border-collapse: collapse;">
        <thead>
          <tr>
            <th scope="col" style={@head}>{gettext("Time")}</th>
            <th scope="col" style={@head}>{gettext("Event")}</th>
            <th scope="col" style={@head}>{gettext("Result")}</th>
            <th scope="col" style={@head}>{gettext("Duration")}</th>
            <th scope="col" style={@head}>{gettext("Attempts")}</th>
            <th scope="col" style={@head}><span class="sr-only">{gettext("Actions")}</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={d <- @rows} data-test-id="webhook-delivery-row">
            <td style={@cell}>{time(d.at)}</td>
            <td style={@cell}>{d.event_id || "–"}</td>
            <td style={@cell} title={d.error}>{result_text(d)}</td>
            <td style={@cell}>{duration(d.latency_ms)}</td>
            <td style={@cell}>{d.attempts}</td>
            <td style={@cell}>
              <button
                :if={d.event_id}
                type="button"
                class="btn btn-sm"
                phx-click="replay"
                phx-value-id={@hook_id}
                phx-value-event_id={d.event_id}
              >
                {gettext("Send again")}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :error, :string, default: nil
  attr :events, :list, required: true

  defp hook_form(assigns) do
    ~H"""
    <.bp_card aria-labelledby="webhook-form-heading" data-test-id="webhook-form">
      <.bp_section_header
        id="webhook-form-heading"
        title={if @form.mode == :new, do: gettext("Add a webhook"), else: gettext("Edit webhook")}
      />
      <form id="webhook-form" phx-change="form_change" phx-submit="save">
        <.bp_field_row label={gettext("Name")} for="webhook-name" required>
          <.bp_input id="webhook-name" name="webhook[name]" value={@form.values["name"]} autocomplete="off" />
        </.bp_field_row>
        <.bp_field_row label={gettext("Address")} for="webhook-url" required>
          <.bp_input
            id="webhook-url"
            name="webhook[url]"
            type="url"
            value={@form.values["url"]}
            placeholder="https://example.com/api/revalidate"
            autocomplete="off"
          />
        </.bp_field_row>
        <.bp_field_row label={gettext("Events")}>
          <input type="hidden" name="webhook[events][]" value="" />
          <div style="display: flex; flex-wrap: wrap; gap: 8px 16px;">
            <.bp_checkbox
              :for={e <- @events}
              name="webhook[events][]"
              value={e}
              label={event_label(e)}
              checked={e in @form.values["events"]}
            />
          </div>
          <:hint>{gettext("Leave all unticked to send every event.")}</:hint>
        </.bp_field_row>
        <.bp_field_row label={gettext("Document types")} for="webhook-types">
          <.bp_input id="webhook-types" name="webhook[types]" value={@form.values["types"]} autocomplete="off" />
          <:hint>{gettext("Only send changes to these types, separated by commas. Leave empty for every type.")}</:hint>
        </.bp_field_row>

        <p
          :if={@error}
          role="alert"
          data-test-id="webhook-form-error"
          class="text-sm"
          style="color: var(--destructive); margin: 0 0 12px;"
        >
          {@error}
        </p>

        <div style="display: flex; gap: 8px;">
          <button type="submit" class="btn btn-primary">
            {if @form.mode == :new, do: gettext("Add webhook"), else: gettext("Save webhook")}
          </button>
          <button type="button" class="btn" phx-click="form_cancel">{gettext("Cancel")}</button>
        </div>
      </form>
    </.bp_card>
    """
  end

  attr :d, :map, required: true

  defp delivery_summary(assigns) do
    ~H"""
    <span>{result_text(@d)} · {time(@d.at)} · {duration(@d.latency_ms)}</span>
    """
  end

  defp result_text(%{status: "ok", code: code}), do: gettext("delivered (%{code})", code: code)

  defp result_text(%{status: "pending", code: nil}), do: gettext("waiting")

  defp result_text(%{status: "pending", code: code}),
    do: gettext("retrying after %{code}", code: code)

  defp result_text(%{code: code}) when is_integer(code),
    do: gettext("failed (%{code})", code: code)

  defp result_text(_d), do: gettext("failed (no answer)")

  defp events_text([]), do: gettext("All events")
  defp events_text(events), do: Enum.map_join(events, ", ", &event_label/1)

  defp types_text([]), do: gettext("all types")
  defp types_text(types), do: Enum.join(types, ", ")

  defp event_label("create"), do: gettext("Created")
  defp event_label("update"), do: gettext("Updated")
  defp event_label("publish"), do: gettext("Published")
  defp event_label("unpublish"), do: gettext("Unpublished")
  defp event_label("delete"), do: gettext("Deleted")
  defp event_label("discardDraft"), do: gettext("Draft discarded")
  defp event_label(other), do: other

  defp duration(ms) when is_integer(ms), do: "#{ms} ms"
  defp duration(_ms), do: "–"

  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
  defp time(_at), do: "–"
end
