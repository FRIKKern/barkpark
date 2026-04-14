defmodule BarkparkWeb.Studio.DatasetSwitcher do
  @moduledoc """
  Function component: renders a <select> of known datasets that navigates
  to `/studio/:new_dataset[/:subpath]` on change, preserving the current
  section (structure / media / api-tester).
  """

  use Phoenix.Component

  alias Barkpark.Content

  attr :current, :string, required: true
  attr :current_section, :atom, default: :structure

  def switcher(assigns) do
    datasets = Content.list_datasets()
    assigns = assign(assigns, :datasets, datasets)

    ~H"""
    <label class="dataset-switcher">
      <span class="dataset-switcher-label">Dataset</span>
      <select
        class="dataset-switcher-select"
        onchange={"window.location = '/studio/' + encodeURIComponent(this.value) + #{section_suffix(@current_section)}"}
      >
        <%= for ds <- @datasets do %>
          <option value={ds} selected={ds == @current}><%= ds %></option>
        <% end %>
      </select>
    </label>
    <style>
      .dataset-switcher { display: inline-flex; align-items: center; gap: 8px; margin-left: 12px; font-size: 12px; }
      .dataset-switcher-label { color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.5px; font-weight: 600; font-size: 10px; }
      .dataset-switcher-select { background: var(--bg); color: var(--fg); border: 1px solid var(--border); border-radius: 4px; padding: 4px 8px; font-size: 12px; font-family: inherit; cursor: pointer; }
      .dataset-switcher-select:hover { border-color: var(--fg-muted); }
    </style>
    """
  end

  defp section_suffix(:structure), do: "''"
  defp section_suffix(:media), do: "'/media'"
  defp section_suffix(:api_tester), do: "'/api-tester'"
  defp section_suffix(_), do: "''"
end
