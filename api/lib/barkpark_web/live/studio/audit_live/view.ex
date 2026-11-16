defmodule BarkparkWeb.Studio.AuditLive.View do
  @moduledoc """
  Markup for the Studio Activity page (`BarkparkWeb.Studio.AuditLive`).

  Draws only the row fields `Barkpark.Audit.Feed` returns (no metadata ever
  reaches this module) and only the Studio's own classes (`.card`, `.btn`,
  `.form-input`, `.badge`) and design tokens.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  import BarkparkWeb.StudioComponents.Controls

  alias Barkpark.Audit.Event

  @cell "padding: 6px 12px 6px 0; border-bottom: 1px solid var(--border); text-align: left; vertical-align: top;"
  @head @cell <> " color: var(--fg-muted); font-weight: 500;"
  @muted "color: var(--fg-muted);"
  @mono "font-family: var(--font-mono); word-break: break-all;"

  attr :filters, :map, required: true
  attr :events, :list, required: true
  attr :more?, :boolean, required: true
  attr :error, :string, default: nil

  def page(assigns) do
    assigns =
      assign(assigns,
        cell: @cell,
        head: @head,
        muted: @muted,
        mono: @mono,
        categories: Event.categories()
      )

    ~H"""
    <div
      class="audit-live"
      style="max-width: 1040px; margin: 32px auto; padding: 0 24px; font-family: var(--font);"
    >
      <h1 class="h1" style="margin-bottom: 4px;">{gettext("Activity")}</h1>
      <p style={@muted <> " margin-top: 0;"}>
        {gettext(
          "Who changed what in this workspace: content, tokens, access, members and webhooks. Sign-ins and other account events are not listed here."
        )}
      </p>

      <.bp_card aria-labelledby="audit-filter-heading">
        <.bp_section_header id="audit-filter-heading" title={gettext("Filter")} />
        <form
          id="audit-filter"
          phx-submit="filter"
          style="display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end;"
        >
          <label class="text-sm" style="display: flex; flex-direction: column; gap: 4px;">
            {gettext("Category")}
            <select name="filter[category]" class="form-input">
              <option value="">{gettext("All")}</option>
              <option
                :for={c <- @categories}
                value={c}
                selected={@filters["category"] == c}
              >
                {category_label(c)}
              </option>
            </select>
          </label>
          <label class="text-sm" style="display: flex; flex-direction: column; gap: 4px;">
            {gettext("Actor id")}
            <input
              type="text"
              name="filter[actor]"
              class="form-input"
              value={@filters["actor"]}
              maxlength="200"
            />
          </label>
          <label class="text-sm" style="display: flex; flex-direction: column; gap: 4px;">
            {gettext("From")}
            <input type="date" name="filter[since]" class="form-input" value={@filters["since"]} />
          </label>
          <label class="text-sm" style="display: flex; flex-direction: column; gap: 4px;">
            {gettext("To")}
            <input type="date" name="filter[until]" class="form-input" value={@filters["until"]} />
          </label>
          <button type="submit" class="btn btn-primary">{gettext("Filter")}</button>
          <button :if={@filters != %{}} type="button" class="btn" phx-click="clear">
            {gettext("Clear filters")}
          </button>
        </form>
      </.bp_card>

      <p
        :if={@error}
        role="alert"
        data-test-id="audit-error"
        style="color: var(--destructive); margin: 16px 0;"
      >
        {@error}
      </p>

      <.bp_card aria-labelledby="audit-list-heading" data-test-id="audit-list">
        <.bp_section_header id="audit-list-heading" title={gettext("Events")}>
          {gettext("Newest first. Times are UTC.")}
        </.bp_section_header>

        <p
          :if={@events == [] and is_nil(@error)}
          role="status"
          data-test-id="audit-empty"
          style={@muted}
        >
          {gettext("No events match.")}
        </p>

        <div :if={@events != []} style="overflow-x: auto;">
          <table class="text-sm" style="width: 100%; border-collapse: collapse;">
            <thead>
              <tr>
                <th style={@head}>{gettext("Time")}</th>
                <th style={@head}>{gettext("Category")}</th>
                <th style={@head}>{gettext("Action")}</th>
                <th style={@head}>{gettext("Actor")}</th>
                <th style={@head}>{gettext("Target")}</th>
                <th style={@head}>{gettext("Dataset")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- @events} data-test-id="audit-row">
                <td style={@cell <> " white-space: nowrap;"}>{time(e.at)}</td>
                <td style={@cell}>{category_label(e.category)}</td>
                <td style={@cell <> @mono}>{e.action}</td>
                <td style={@cell}><.actor actor={e.actor} mono={@mono} muted={@muted} /></td>
                <td style={@cell}>
                  <span :if={e.target.type} style={@muted}>{e.target.type}</span>
                  <span :if={e.target.id} style={@mono}>{e.target.id}</span>
                  <span :if={e.doc_type} class="badge badge-muted">{e.doc_type}</span>
                  <span :if={e.project_wide} class="badge badge-muted">
                    {gettext("every project")}
                  </span>
                </td>
                <td style={@cell <> @mono}>{e.dataset || "–"}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@more?} style="margin-top: 12px;">
          <button type="button" class="btn" phx-click="more">{gettext("Load more")}</button>
        </div>
      </.bp_card>
    </div>
    """
  end

  attr :actor, :map, required: true
  attr :mono, :string, required: true
  attr :muted, :string, required: true

  defp actor(assigns) do
    ~H"""
    <%= cond do %>
      <% @actor.id -> %>
        <button
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click="actor"
          phx-value-id={@actor.id}
          title={gettext("Show only this actor")}
          style="padding: 0; text-align: left;"
        >
          <span :if={@actor.name}>{@actor.name}</span>
          <span :if={is_nil(@actor.name)} style={@mono}>{@actor.id}</span>
        </button>
        <div class="text-sm" style={@muted}>{actor_type_label(@actor.type)}</div>
      <% true -> %>
        <span style={@muted}>{actor_type_label(@actor.type)}</span>
    <% end %>
    """
  end

  @doc "The words for a filter the feed could not read."
  def invalid_message("category"), do: gettext("Pick a category from the list.")

  def invalid_message(field) when field in ["since", "until"],
    do: gettext("Enter dates as year-month-day, for example 2026-11-16.")

  def invalid_message(_field), do: gettext("The actor id is too long.")

  defp category_label("content_mutation"), do: gettext("Content")
  defp category_label("auth"), do: gettext("Sign-in")
  defp category_label("membership"), do: gettext("Members")
  defp category_label("secret"), do: gettext("Secrets")
  defp category_label("plugin_settings"), do: gettext("Settings and webhooks")
  defp category_label("token"), do: gettext("Tokens")
  defp category_label("access"), do: gettext("Access")
  defp category_label(other), do: other

  defp actor_type_label("user"), do: gettext("Person")
  defp actor_type_label(t) when t in ["api_token", "token"], do: gettext("Token")
  defp actor_type_label("system"), do: "Barkpark"
  defp actor_type_label("scim"), do: "SCIM"
  defp actor_type_label(nil), do: gettext("Not recorded")
  defp actor_type_label(other), do: other

  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")
  defp time(_at), do: "–"
end
