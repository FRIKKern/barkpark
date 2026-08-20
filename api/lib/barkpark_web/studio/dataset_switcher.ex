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
      <%!-- `form-input` gives the select the themed chrome (appearance:none,
            token border/bg/text, the custom caret, the focus ring) so no
            native unthemed dropdown leaks; `dataset-switcher-select` layers
            the compact top-bar sizing on top (sup-w1 PART C). --%>
      <select
        class="dataset-switcher-select form-input"
        data-section-suffix={section_suffix(@current_section)}
        onchange={BarkparkWeb.CSP.dataset_switch_onchange()}
      >
        <%= for ds <- @datasets do %>
          <option value={ds} selected={ds == @current}><%= ds %></option>
        <% end %>
      </select>
    </label>
    """
  end

  # Raw path suffix carried in the `data-section-suffix` attribute and read by
  # the (now static, CSP-hashable) onchange handler as `this.dataset.sectionSuffix`
  # — no JS quoting (the browser stores/returns the literal string).
  defp section_suffix(:structure), do: ""
  defp section_suffix(:media), do: "/media"
  defp section_suffix(:api_tester), do: "/api-tester"
  defp section_suffix(_), do: ""
end
