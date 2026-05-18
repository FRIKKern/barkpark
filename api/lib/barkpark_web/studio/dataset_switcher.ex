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
    """
  end

  defp section_suffix(:structure), do: "''"
  defp section_suffix(:media), do: "'/media'"
  defp section_suffix(:api_tester), do: "'/_api'"
  defp section_suffix(_), do: "''"
end
